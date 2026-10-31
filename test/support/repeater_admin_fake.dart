// Test-only fake companion radio + fake repeater that mimic what was MEASURED on a real repeater (INNO-OB-2, Oct 31 2026,
// meshsonar-infra/docs/planning/repeater-observer-live-research-2026-11-01.md) and what the firmware source does
// (MeshCore main, CommonCLI.cpp / CommonRadioPrefs.cpp / simple_repeater/MyMesh.cpp):
//  - SILENCE is the only failure signal: wrong password, replayed CLI timestamp, out of range, anon limiter, non-admin ACL
//    request all produce a SENT frame and then nothing.
//  - CLI works as CLI_DATA (txt_type 1); other types get ERR 1 from the companion. Replies come back through
//    MSG_WAITING -> SYNC_NEXT_MESSAGE. `NN|` command tags are reflected on the reply (only when strlen(command) > 4).
//  - Replies are cut at 159 characters; some replies are lost (dropNextReplies / lossEvery).
//  - Commands match by PREFIX like the firmware (`advertXYZ` sends an advert, `rebootXYZ` reboots), `set repeat` treats
//    anything but "off" as on, `setperm <key>` without a permission answers `Err - bad params`, `region load` swallows
//    following lines, `region default <unknown>` CREATES the region, `password` echoes the new password,
//    `get guest.password` answers in clear, `clock sync` never goes backwards, a blank password re-admits any ACL key.
//  - Binary requests (status, telemetry, neighbours, ACL, owner) and anonymous requests (4 per 180 s shared) answer with
//    zero-padded blocks.
// Real frames from lib/radio/protocol.dart are used on both sides. NOT part of the app.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/repeater_wire.dart';

class FakeRegion {
  String name;
  String? parent;
  bool floodAllowed;
  FakeRegion(this.name, this.parent, this.floodAllowed);
}

class FakeAdminRepeater {
  final Uint8List key;
  String name;
  String role; // repeater | room
  String firmware;
  String board;
  String adminPassword;
  String guestPassword;
  bool inRange = true;
  bool poweredOff = false;
  bool isObserver = false;

  /// Seconds the repeater's clock differs from real time.
  int clockOffsetSecs = 0;
  int uptimeSecs = 149365;
  int rebootCount = 0;

  /// key hex (64) -> permission byte. Our companion's key is added by the transport when it logs in with the right password.
  final Map<String, int> acl = {};
  final Map<String, String> prefs = {};
  final List<FakeRegion> regions = [FakeRegion('*', null, true), FakeRegion('cmh', '*', true)];
  String? defaultRegion = 'cmh';
  String? homeRegion;
  bool _regionLoad = false;

  /// What the repeater has been asked, exactly as received (after the tag), for assertions.
  final List<String> received = [];

  /// Replies that were produced (for assertions on what could leak).
  final List<String> sentReplies = [];

  int dropNextReplies = 0;

  /// Every Nth reply is lost (0 = none): the measured 3%.
  int lossEvery = 0;
  int _replyCount = 0;

  /// Reply text for the next command starting with this prefix is lost (the command still runs).
  String? dropOncePrefix;
  bool dropAllReplies = false;

  /// Commands starting with this are not executed at all and not answered (the write never arrived).
  String? ignoreOncePrefix;

  /// The next command starting with this is answered with an Error and NOT executed.
  String? errorOncePrefix;

  /// Binary requests that get no answer (counts down).
  int dropBinaryAnswers = 0;
  final List<RepeaterNeighbour> neighbours = [
    const RepeaterNeighbour('1bcee248', 72853, 7.75),
    const RepeaterNeighbour('1fd4038f', 15420, -1.5),
    const RepeaterNeighbour('8b4d0100', 3011, 2.25),
  ];
  RepeaterStats stats = const RepeaterStats(
    battMilliVolts: 3860,
    txQueueLen: 0,
    noiseFloorDbm: -108,
    lastRssiDbm: -103,
    packetsRecv: 1165,
    packetsSent: 604,
    airTimeSecs: 173,
    upTimeSecs: 149365,
    sentFlood: 407,
    sentDirect: 197,
    recvFlood: 803,
    recvDirect: 362,
    errEvents: 8,
    lastSnrDb: -3.0,
    directDups: 0,
    floodDups: 402,
    rxAirTimeSecs: 326,
    recvErrors: 193,
  );
  double voltageV = 3.86;
  double tempC = 45.0;

  /// Anonymous request window (fixed, 4 per 180 s, shared).
  int anonWindowStart = 0;
  int anonCount = 0;

  /// Canned observer answers (measured formats).
  final Map<String, String> observer = {
    'mqtt.status': '> msgs: on, 1: analyzer-us (ok), 2: meshmapper (ok), 3: okimesh-1 (ok), 4: meshomatic (ok), 5: custom (ok), q:1',
    'mqtt.stats': '> Free=134020 Max=120820 q:1/50 Outbox=0 drops=0/0 | s1=963/0 s2=1588/0',
    'mqtt.iata': '> CMH',
    'mqtt.origin': '> INNO-OB-2',
    'mqtt.ntp.diag': 'pool.ntp.org ok\ntime.google.com ok',
    'mqtt1.diag': '> mqtt1: ok, dc:76, first_disc:148510s, no errors',
    'mqtt5.preset': '> custom',
    'mqtt5.server': '> wss://user:secret@mqtt.meshsonar.com:443/mqtt',
    'mqtt6.diag': '> not configured',
  };

  final Map<String, int> _lastTs = {};
  final Set<String> sessions = {}; // client keys with a login

  FakeAdminRepeater({
    required this.key,
    this.name = 'INNO-OB-2',
    this.role = 'repeater',
    this.firmware = 'v1.17.1.5 (Build: 4 Oct 2026)',
    this.board = 'Heltec V4.3 OLED',
    this.adminPassword = 'secret',
    this.guestPassword = 'guest',
  }) {
    prefs.addAll({
      'lat': '39.961180',
      'lon': '-82.998800',
      'radio': '910.5250244,62.5,7,5',
      'tx': '28',
      'af': '1.0',
      'dutycycle': '50.0%',
      'txdelay': '0.5',
      'direct.txdelay': '0.3',
      'rxdelay': '0.0',
      'int.thresh': '0',
      'cad': 'off',
      'agc.reset.interval': '16',
      'multi.acks': '0',
      'flood.advert.interval': '6',
      'advert.interval': '180',
      'flood.max': '64',
      'flood.max.unscoped': '64',
      'flood.max.advert': '8',
      'repeat': 'on',
      'path.hash.mode': '1',
      'loop.detect': 'minimal',
      'owner.info': '',
      'allow.read.only': 'off',
    });
    stats = RepeaterStats(
      battMilliVolts: stats.battMilliVolts,
      txQueueLen: stats.txQueueLen,
      noiseFloorDbm: stats.noiseFloorDbm,
      lastRssiDbm: stats.lastRssiDbm,
      packetsRecv: stats.packetsRecv,
      packetsSent: stats.packetsSent,
      airTimeSecs: stats.airTimeSecs,
      upTimeSecs: uptimeSecs,
      errEvents: stats.errEvents,
      lastSnrDb: stats.lastSnrDb,
      floodDups: stats.floodDups,
      rxAirTimeSecs: stats.rxAirTimeSecs,
      recvErrors: stats.recvErrors,
    );
  }

  String get keyHex => toHex(key);
  int get nowSecs => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + clockOffsetSecs;

  RepeaterStats get currentStats => RepeaterStats(
        battMilliVolts: (voltageV * 1000).round(),
        txQueueLen: stats.txQueueLen,
        noiseFloorDbm: stats.noiseFloorDbm,
        lastRssiDbm: stats.lastRssiDbm,
        packetsRecv: stats.packetsRecv,
        packetsSent: stats.packetsSent,
        airTimeSecs: stats.airTimeSecs,
        upTimeSecs: uptimeSecs,
        sentFlood: stats.sentFlood,
        sentDirect: stats.sentDirect,
        recvFlood: stats.recvFlood,
        recvDirect: stats.recvDirect,
        errEvents: stats.errEvents,
        lastSnrDb: stats.lastSnrDb,
        directDups: stats.directDups,
        floodDups: stats.floodDups,
        rxAirTimeSecs: stats.rxAirTimeSecs,
        recvErrors: stats.recvErrors,
      );

  bool isAdmin(String clientKeyHex) => (acl[clientKeyHex] ?? 0) & 3 == 3;

  /// Login rule of handleLoginReq: a blank password re-admits any key already in the ACL with its stored role (no check);
  /// else strcmp admin, then guest; a wrong password is silent. Returns the perm or null for silence.
  int? login(String clientKeyHex, String password) {
    if (!inRange || poweredOff) return null;
    if (password.isEmpty) {
      final known = acl[clientKeyHex];
      if (known != null) {
        sessions.add(clientKeyHex);
        return known;
      }
    }
    if (password == adminPassword) {
      acl[clientKeyHex] = 3;
      sessions.add(clientKeyHex);
      return 3;
    }
    if (guestPassword.isNotEmpty ? password == guestPassword : password.isEmpty) {
      sessions.add(clientKeyHex);
      return 0;
    }
    return null;
  }

  // ------------------------------------------------------------------ CLI (prefix matching like the firmware)

  /// Runs one command from [clientKeyHex] with radio-clock timestamp [ts]. Returns the reply or null for no reply.
  String? cli(String clientKeyHex, int ts, String command) {
    if (!inRange || poweredOff || !sessions.contains(clientKeyHex) || !isAdmin(clientKeyHex)) return null;
    final last = _lastTs[clientKeyHex] ?? 0;
    if (ts < last) return null; // replay
    if (ts == last) return null; // retry: runs nothing, answers nothing
    _lastTs[clientKeyHex] = ts;
    var cmd = command;
    if (ignoreOncePrefix != null && _stripTag(cmd).startsWith(ignoreOncePrefix!)) {
      ignoreOncePrefix = null;
      return null;
    }
    var tag = '';
    if (!_regionLoad) {
      while (cmd.startsWith(' ')) {
        cmd = cmd.substring(1);
      }
      if (cmd.length > 4 && cmd[2] == '|') {
        tag = cmd.substring(0, 3);
        cmd = cmd.substring(3);
      }
    }
    received.add(cmd);
    if (errorOncePrefix != null && cmd.startsWith(errorOncePrefix!)) {
      errorOncePrefix = null;
      return '${tag}Error, simulated';
    }
    var reply = _handle(clientKeyHex, cmd);
    if (reply == null) return null;
    reply = tag + reply;
    if (reply.length > 159) reply = reply.substring(0, 159);
    sentReplies.add(reply);
    _replyCount++;
    if (dropOncePrefix != null && cmd.startsWith(dropOncePrefix!)) {
      dropOncePrefix = null;
      return null;
    }
    if (dropAllReplies) return null;
    if (dropNextReplies > 0) {
      dropNextReplies--;
      return null;
    }
    if (lossEvery > 0 && _replyCount % lossEvery == 0) return null;
    return reply;
  }

  static String _stripTag(String c) => c.length > 4 && c[2] == '|' ? c.substring(3) : c;

  static String _ftoa(double v) {
    var s = v.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s += '0';
    return s;
  }

  String? _handle(String client, String c) {
    if (_regionLoad) {
      if (c.trim().isEmpty) {
        _regionLoad = false;
        return 'OK - loaded ${regions.length} regions';
      }
      return ''; // swallowed
    }
    if (c.startsWith('setperm ')) {
      final rest = c.substring(8);
      final sp = rest.indexOf(' ');
      if (sp < 0) return 'Err - bad params';
      final hex = rest.substring(0, sp);
      if (!RegExp(r'^[0-9a-fA-F]*$').hasMatch(hex) || hex.length.isOdd) return 'Err - bad pubkey';
      final perms = int.tryParse(rest.substring(sp + 1)) ?? 0;
      final k = hex.toLowerCase();
      final matches = acl.keys.where((e) => e.startsWith(k)).toList();
      if (perms == 0) {
        if (matches.isEmpty) return 'Err - invalid params';
        for (final m in matches) {
          acl.remove(m);
          sessions.remove(m);
        }
        return 'OK';
      }
      if (k.length != 64) return 'Err - invalid params';
      acl[k] = perms;
      return 'OK';
    }
    if (c == 'get acl') return 'Unknown command'; // serial only
    if (c.startsWith('discover.neighbors')) {
      return c.substring(18).trim().isNotEmpty ? 'Err - discover.neighbors has no options' : 'OK - Discover sent';
    }
    // CommonRadioPrefs (exact for get, prefix for set)
    if (c == 'get radio') return '> ${prefs['radio']}';
    if (c.startsWith('set radio ')) {
      final p = c.substring(10).split(',');
      final f = p.isNotEmpty ? double.tryParse(p[0]) ?? 0 : 0.0;
      final bw = p.length > 1 ? double.tryParse(p[1]) ?? 0 : 0.0;
      final sf = p.length > 2 ? int.tryParse(p[2]) ?? 0 : 0;
      final cr = p.length > 3 ? int.tryParse(p[3]) ?? 0 : 0;
      if (f >= 150 && f <= 2500 && sf >= 5 && sf <= 12 && cr >= 5 && cr <= 8 && bw >= 7 && bw <= 500) {
        prefs['radio'] = '${_ftoa(f)},${_ftoa(bw)},$sf,$cr';
        return 'OK - reboot to apply';
      }
      return 'Error, invalid radio params';
    }
    for (final k in ['freq', 'af', 'dutycycle', 'int.thresh', 'cad', 'rxdelay', 'agc.reset.interval', 'path.hash.mode', 'multi.acks', 'txdelay', 'direct.txdelay']) {
      if (c == 'get $k') return '> ${prefs[k] ?? '0'}';
    }
    if (c == 'get tx' || c.startsWith('get tx ')) return '> ${prefs['tx']}';
    if (c.startsWith('set tx ')) {
      prefs['tx'] = (int.tryParse(c.substring(7)) ?? 0).toString(); // no range check in the firmware
      return 'OK';
    }
    if (c.startsWith('set af ')) {
      final v = double.tryParse(c.substring(7)) ?? -1;
      if (v < 0 || v > 9) return 'ERROR: af must be 0-9';
      prefs['af'] = _ftoa(v);
      return 'OK';
    }
    if (c.startsWith('set dutycycle ')) {
      final v = double.tryParse(c.substring(14)) ?? 0;
      if (v < 1 || v > 100) return 'ERROR: dutycycle must be 1-100';
      prefs['dutycycle'] = '${v.toStringAsFixed(1)}%';
      return 'OK - ${v.toStringAsFixed(1)}%';
    }
    for (final e in {'txdelay': 2.0, 'direct.txdelay': 2.0, 'rxdelay': 20.0}.entries) {
      if (c.startsWith('set ${e.key} ')) {
        final v = double.tryParse(c.substring(5 + e.key.length)) ?? -1;
        if (v < 0 || v > e.value) return 'Error, must be 0-${e.value.toInt()}';
        prefs[e.key] = _ftoa(v);
        return 'OK';
      }
    }
    if (c.startsWith('set int.thresh ')) {
      prefs['int.thresh'] = (int.tryParse(c.substring(15)) ?? 0).toString();
      return 'OK';
    }
    if (c.startsWith('set cad ')) {
      prefs['cad'] = c.substring(8).startsWith('on') ? 'on' : 'off';
      return 'OK';
    }
    if (c.startsWith('set multi.acks ')) {
      prefs['multi.acks'] = (int.tryParse(c.substring(15)) ?? 0).toString();
      return 'OK';
    }
    if (c.startsWith('set agc.reset.interval ')) {
      final v = (int.tryParse(c.substring(23)) ?? 0) ~/ 4 * 4;
      prefs['agc.reset.interval'] = v.toString();
      return 'OK - interval rounded to $v';
    }
    if (c.startsWith('set path.hash.mode ')) {
      final v = int.tryParse(c.substring(19));
      if (v == null || v < 0 || v > 2) return 'Error, must be 0,1, or 2';
      prefs['path.hash.mode'] = '$v';
      return 'OK';
    }
    // CommonCLI chain (memcmp = prefix)
    if (c.startsWith('poweroff') || c.startsWith('shutdown')) {
      poweredOff = true;
      return null;
    }
    if (c.startsWith('reboot')) {
      rebootCount++;
      uptimeSecs = 0;
      return null;
    }
    if (c.startsWith('clkreboot')) {
      clockOffsetSecs = 1715770351 - DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      rebootCount++;
      uptimeSecs = 0;
      return null;
    }
    if (c.startsWith('advert.zerohop') && (c.length == 14 || c[14] == ' ')) {
      adverts.add('zerohop');
      return 'OK - zerohop advert sent';
    }
    if (c.startsWith('advert')) {
      adverts.add('flood');
      return 'OK - Advert sent';
    }
    if (c.startsWith('clock sync')) {
      final radioClock = ts0;
      if (radioClock > nowSecs) {
        clockOffsetSecs += radioClock + 1 - nowSecs;
        return 'OK - clock set: ${_clockText(nowSecs)}';
      }
      return 'ERR: clock cannot go backwards';
    }
    if (c.startsWith('start ota')) return 'Error';
    if (c.startsWith('clock')) return _clockText(nowSecs);
    if (c.startsWith('neighbors')) {
      return [for (final n in neighbours) '${n.prefixHex.toUpperCase()}:${n.secondsAgo}:${(n.snrDb * 4).round()}'].join('\n');
    }
    if (c.startsWith('password ')) {
      adminPassword = c.substring(9);
      return 'password now: $adminPassword';
    }
    if (c.startsWith('get ')) return _get(c.substring(4));
    if (c.startsWith('set ')) return _set(c.substring(4));
    if (c.startsWith('ver')) return '$firmware';
    if (c.startsWith('board')) return board;
    if (c.startsWith('memory')) return isObserver ? 'Free: 134020, Min: 114636' : 'Unknown command';
    if (c.startsWith('region')) return _region(c);
    return 'Unknown command';
  }

  final List<String> adverts = [];

  /// The companion's clock as the repeater sees it (set by the transport per command).
  int ts0 = 0;

  static String _clockText(int s) {
    final d = DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} - ${d.day}/${d.month}/${d.year} UTC';
  }

  String _get(String k) {
    if (k.startsWith('allow.read.only')) return '> ${prefs['allow.read.only']}';
    if (k.startsWith('flood.advert.interval')) return '> ${prefs['flood.advert.interval']}';
    if (k.startsWith('advert.interval')) return '> ${prefs['advert.interval']}';
    if (k.startsWith('guest.password')) return '> $guestPassword'; // in clear: a firmware quirk
    if (k.startsWith('name')) return '> $name';
    if (k.startsWith('repeat')) return '> ${prefs['repeat']}';
    if (k.startsWith('lat')) return '> ${_ftoa(double.parse(prefs['lat']!))}';
    if (k.startsWith('lon')) return '> ${_ftoa(double.parse(prefs['lon']!))}';
    if (k.startsWith('flood.max.advert')) return '> ${prefs['flood.max.advert']}';
    if (k.startsWith('flood.max.unscoped')) return '> ${prefs['flood.max.unscoped']}';
    if (k.startsWith('flood.max')) return '> ${prefs['flood.max']}';
    if (k.startsWith('owner.info')) return '> ${prefs['owner.info']}';
    if (k.startsWith('loop.detect')) return '> ${prefs['loop.detect']}';
    if (k.startsWith('public.key')) return '> ${keyHex.toUpperCase()}';
    if (k.startsWith('role')) return '> $role';
    if (k.startsWith('bridge.type')) return '> none';
    if (k.startsWith('adc.multiplier')) return '> 5.420';
    if (k.startsWith('bootloader.ver')) return 'Error: unsupported';
    if (k.startsWith('timezone')) return '> ';
    if (isObserver && observer.containsKey(k)) return observer[k]!;
    return '??: $k';
  }

  String _set(String config) {
    if (config.startsWith('allow.read.only ')) {
      prefs['allow.read.only'] = config.substring(16).startsWith('on') ? 'on' : 'off';
      return 'OK';
    }
    if (config.startsWith('flood.advert.interval ')) {
      final h = int.tryParse(config.substring(22)) ?? 0;
      if ((h > 0 && h < 3) || h > 168) return 'Error: interval range is 3-168 hours';
      prefs['flood.advert.interval'] = '$h';
      return 'OK';
    }
    if (config.startsWith('advert.interval ')) {
      final m = int.tryParse(config.substring(16)) ?? 0;
      if ((m > 0 && m < 60) || m > 240) return 'Error: interval range is 60-240 minutes';
      prefs['advert.interval'] = '${m ~/ 2 * 2}';
      return 'OK';
    }
    if (config.startsWith('guest.password ')) {
      guestPassword = config.substring(15);
      return 'OK';
    }
    if (config.startsWith('prv.key ')) return 'Error, bad key';
    if (config.startsWith('name ')) {
      final n = config.substring(5);
      if (RegExp(r'[\[\]\\:,?*]').hasMatch(n)) return 'Error, bad chars';
      name = n;
      return 'OK';
    }
    if (config.startsWith('repeat ')) {
      prefs['repeat'] = config.substring(7).startsWith('off') ? 'off' : 'on';
      return prefs['repeat'] == 'off' ? 'OK - repeat is now OFF' : 'OK - repeat is now ON';
    }
    if (config.startsWith('lat ')) {
      prefs['lat'] = (double.tryParse(config.substring(4)) ?? 0).toString();
      return 'OK';
    }
    if (config.startsWith('lon ')) {
      prefs['lon'] = (double.tryParse(config.substring(4)) ?? 0).toString();
      return 'OK';
    }
    for (final k in ['flood.max.unscoped', 'flood.max.advert', 'flood.max']) {
      if (config.startsWith('$k ')) {
        final m = int.tryParse(config.substring(k.length + 1)) ?? 0;
        if (m > 64) return 'Error, max 64';
        prefs[k] = '$m';
        return 'OK';
      }
    }
    if (config.startsWith('owner.info ')) {
      prefs['owner.info'] = config.substring(11).replaceAll('|', '\n').replaceAll('\n', '|');
      return 'OK';
    }
    if (config.startsWith('loop.detect ')) {
      final v = config.substring(12);
      for (final m in ['off', 'minimal', 'moderate', 'strict']) {
        if (v.startsWith(m)) {
          prefs['loop.detect'] = m;
          return 'OK';
        }
      }
      return 'Error, must be: off, minimal, moderate, or strict';
    }
    return 'unknown config: $config';
  }

  // ------------------------------------------------------------------ regions

  FakeRegion? _byPrefix(String p) {
    for (final r in regions) {
      if (r.name.startsWith(p)) return r;
    }
    return null;
  }

  String _dump() {
    final b = StringBuffer();
    void walk(FakeRegion r, int depth) {
      b.writeln('${' ' * depth}${r.name}${r.floodAllowed ? ' F' : ''}');
      for (final c in regions.where((x) => x.parent == r.name)) {
        walk(c, depth + 1);
      }
    }

    walk(regions.first, 0);
    return b.toString();
  }

  String _region(String c) {
    final parts = c.split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length == 1) return _dump();
    final sub = parts[1];
    if (sub == 'load') {
      _regionLoad = true;
      return '';
    }
    if (sub == 'save') return 'OK';
    if ((sub == 'allowf' || sub == 'denyf') && parts.length >= 3) {
      final r = _byPrefix(parts[2]);
      if (r == null) return 'Err - unknown region';
      r.floodAllowed = sub == 'allowf';
      return 'OK';
    }
    if (sub == 'get' && parts.length >= 3) {
      final r = _byPrefix(parts[2]);
      if (r == null) return 'Err - unknown region';
      return ' ${r.name}${r.parent != null && r.parent != '*' ? ' (${r.parent})' : ''} ${r.floodAllowed ? 'F' : ''}';
    }
    if (sub == 'home' && parts.length == 2) return ' home is ${homeRegion ?? '*'}';
    if (sub == 'default' && parts.length == 2) return ' default scope is ${defaultRegion ?? '<null>'}';
    if (sub == 'default' && parts.length >= 3) {
      if (parts[2] == '<null>') {
        defaultRegion = null;
        return ' default scope is now <null>';
      }
      var r = _byPrefix(parts[2]);
      r ??= () {
        final n = FakeRegion(parts[2], '*', true);
        regions.add(n);
        return n;
      }();
      r.floodAllowed = true;
      defaultRegion = r.name;
      return ' default scope is now ${r.name}';
    }
    if (sub == 'list' && parts.length >= 3) {
      final want = parts[2] == 'allowed';
      final l = [for (final r in regions) if (r.floodAllowed == want) r.name];
      return l.isEmpty ? '-none-' : l.join(',');
    }
    return 'Err - ??';
  }
}

/// A companion radio (BLE transport level) with repeaters out in the mesh.
class AdminFakeTransport implements ByteTransport {
  final Uint8List publicKey;
  final Map<String, FakeAdminRepeater> repeaters;
  final _incoming = StreamController<Uint8List>.broadcast();
  final List<Uint8List> sentFrames = [];
  final Set<String> contacts = {};
  final List<Uint8List> _queue = [];
  bool _connected = true;
  int radioAheadSecs = 0;
  int _tag = 1000;
  int get _radioNow => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + radioAheadSecs;

  AdminFakeTransport(this.repeaters, {List<int>? key}) : publicKey = Uint8List.fromList(key ?? List<int>.generate(32, (i) => 200 - i));

  String get keyHex => toHex(publicKey);

  @override
  Stream<Uint8List> get incoming => _incoming.stream;
  @override
  bool get isConnected => _connected;

  void drop() {
    if (!_connected) return;
    _connected = false;
    _incoming.close();
  }

  @override
  Future<void> disconnect() async => drop();

  void _emit(Uint8List f) {
    if (_connected) Future<void>.delayed(Duration.zero, () => _connected ? _incoming.add(f) : null);
  }

  FakeAdminRepeater? _byPrefix(List<int> prefix) {
    for (final r in repeaters.values) {
      var ok = true;
      for (var i = 0; i < prefix.length; i++) {
        if (r.key[i] != prefix[i]) ok = false;
      }
      if (ok) return r;
    }
    return null;
  }

  static Uint8List _pad(List<int> d) {
    final out = BytesBuilder()..add(d);
    while (out.length % 16 != 0) {
      out.addByte(0);
    }
    return out.toBytes();
  }

  Uint8List _binaryPush(int tag, List<int> data) =>
      Uint8List.fromList([Push.binaryResponse, 0, tag & 0xff, (tag >> 8) & 0xff, (tag >> 16) & 0xff, (tag >> 24) & 0xff, ..._pad(data)]);

  @override
  Future<void> send(Uint8List f) async {
    if (!_connected) throw StateError('radio disconnected');
    sentFrames.add(f);
    switch (f[0]) {
      case Cmd.appStart:
        _emit(encodeSelfInfo(txPowerDbm: 20, maxTxPowerDbm: 22, publicKey: publicKey, freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5, name: 'My Companion'));
      case Cmd.deviceQuery:
        _emit(encodeDeviceInfo(firmwareVerCode: 13, maxChannels: 8, buildDate: '14 Aug 2026', manufacturer: 'Wio Tracker L1', firmwareVersion: 'v1.17.1'));
      case Cmd.getDeviceTime:
        _emit(encodeCurrTime(_radioNow));
      case Cmd.setDeviceTime:
        _emit(encodeOk());
      case Cmd.syncNextMessage:
        _emit(_queue.isEmpty ? encodeNoMoreMessages() : _queue.removeAt(0));
      case Cmd.getContactByKey:
        final k = toHex(f.sublist(1, 33));
        _emit(contacts.contains(k)
            ? encodeContactFrame(f.sublist(1, 33), type: repeaters[k]?.role == 'room' ? AdvType.room : AdvType.repeater, name: repeaters[k]?.name ?? '')
            : encodeErr(ErrCode.notFound));
      case Cmd.addUpdateContact:
        contacts.add(toHex(f.sublist(1, 33)));
        _emit(encodeOk());
      case Cmd.sendLogin:
        _login(f);
      case Cmd.logout:
        repeaters[toHex(f.sublist(1, 33))]?.sessions.remove(keyHex);
        _emit(encodeOk());
      case Cmd.sendStatusReq:
        final r = repeaters[toHex(f.sublist(1, 33))];
        if (r == null || !contacts.contains(r.keyHex)) {
          _emit(encodeErr(ErrCode.notFound));
        } else {
          _emit(encodeSent(tag: ++_tag, estTimeoutMs: 400));
          if (r.inRange && !r.poweredOff && r.sessions.contains(keyHex)) {
            _emit(Uint8List.fromList([Push.statusResponse, 0, ...r.key.take(6), ..._pad(r.currentStats.encode())]));
          }
        }
      case Cmd.sendTelemetryReq:
        if (f.length == 4) {
          _emit(encodeErr(ErrCode.unsupportedCmd));
          break;
        }
        final r = repeaters[toHex(f.sublist(4, 36))];
        if (r == null || !contacts.contains(r.keyHex)) {
          _emit(encodeErr(ErrCode.notFound));
        } else {
          _emit(encodeSent(tag: ++_tag, estTimeoutMs: 400));
          if (r.inRange && !r.poweredOff && r.sessions.contains(keyHex)) {
            _emit(Uint8List.fromList([Push.telemetryResponse, 0, ...r.key.take(6), ..._pad(RepeaterTelemetry.encodeLpp(voltageV: r.voltageV, temperatureC: r.tempC))]));
          }
        }
      case Cmd.sendBinaryReq:
        _binary(f, anon: false);
      case Cmd.sendAnonReq:
        _binary(f, anon: true);
      case Cmd.sendTxtMsg:
        _txt(f);
      default:
        _emit(encodeErr(ErrCode.unsupportedCmd));
    }
  }

  void _login(Uint8List f) {
    final k = toHex(f.sublist(1, 33));
    final r = repeaters[k];
    if (!contacts.contains(k)) {
      _emit(encodeErr(ErrCode.notFound));
      return;
    }
    var end = 33;
    while (end < f.length && f[end] != 0) {
      end++;
    }
    final pw = utf8.decode(f.sublist(33, end));
    _emit(encodeSent(flood: false, tag: ++_tag, estTimeoutMs: 500));
    if (r == null) return;
    final perm = r.login(keyHex, pw);
    if (perm == null) return;
    r._lastTs[keyHex] = _radioNow;
    _emit(encodeLoginSuccess(r.key, isAdmin: perm == 3, aclPermissions: perm));
  }

  void _binary(Uint8List f, {required bool anon}) {
    final r = repeaters[toHex(f.sublist(1, 33))];
    if (r == null || !contacts.contains(r.keyHex)) {
      _emit(encodeErr(ErrCode.notFound));
      return;
    }
    final tag = ++_tag;
    _emit(encodeSent(tag: tag, estTimeoutMs: 400));
    if (!r.inRange || r.poweredOff) return;
    if (r.dropBinaryAnswers > 0) {
      r.dropBinaryAnswers--;
      return;
    }
    final type = f[33];
    if (anon) {
      final now = r.nowSecs;
      if (now - r.anonWindowStart >= 180) {
        r.anonWindowStart = now;
        r.anonCount = 0;
      }
      if (r.anonCount >= 4) return; // limiter: silence
      r.anonCount++;
      final clock = [now & 0xff, (now >> 8) & 0xff, (now >> 16) & 0xff, (now >> 24) & 0xff];
      switch (type) {
        case 3:
          _emit(_binaryPush(tag, [...clock, 0]));
        case 1:
          _emit(_binaryPush(tag, [...clock, ...utf8.encode(r.regions.where((x) => x.floodAllowed).map((x) => x.name).join(','))]));
        case 2:
          _emit(_binaryPush(tag, [...clock, ...utf8.encode('${r.name}\n')]));
      }
      return;
    }
    if (!r.sessions.contains(keyHex)) return;
    switch (type) {
      case BinaryReqType.accessList:
        if (!r.isAdmin(keyHex)) return; // admin only: silence
        final b = BytesBuilder();
        r.acl.forEach((k, p) {
          if (p != 0) {
            b.add(fromHex(k).take(6).toList());
            b.addByte(p);
          }
        });
        _emit(_binaryPush(tag, b.toBytes()));
      case BinaryReqType.neighbours:
        final count = f[35];
        final offset = f[36] | (f[37] << 8);
        final page = r.neighbours.skip(offset).take(count).toList();
        _emit(_binaryPush(tag, NeighbourPage.encode(r.neighbours.length, page)));
      case BinaryReqType.owner:
        _emit(_binaryPush(tag, utf8.encode('${r.firmware}\n${r.name}\n')));
    }
  }

  void _txt(Uint8List f) {
    final r = _byPrefix(f.sublist(7, 13));
    if (r == null || !contacts.contains(r.keyHex)) {
      _emit(encodeErr(ErrCode.notFound));
      return;
    }
    if (f[1] != txtTypeCliData) {
      _emit(encodeErr(ErrCode.unsupportedCmd));
      return;
    }
    final cmd = utf8.decode(f.sublist(13));
    _emit(encodeSent(tag: ++_tag, estTimeoutMs: 400));
    final ts = ByteData.sublistView(f).getUint32(3, Endian.little);
    r.ts0 = _radioNow;
    final reply = r.cli(keyHex, ts, cmd);
    if (reply == null) return;
    _queue.add(encodeContactText(r.key, reply, txtType: txtTypeCliData, timestamp: 1700000000));
    _emit(encodeMsgWaiting());
  }
}
