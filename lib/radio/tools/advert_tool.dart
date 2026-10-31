// Adverts explorer: send this radio's advert (CMD_SEND_SELF_ADVERT 7) with a visible cooldown and an airtime note, and a
// book of every advert the radio has heard.
//
// Sending (VERIFIED on hardware): [7][0 zero-hop | 1 flood] -> OK in 60 ms. A zero-hop advert is heard by direct neighbours
// only. A flood advert is repeated by every repeater in the radio's default scope, so it costs airtime across the mesh: the
// tool allows a zero-hop advert every 30 s and a flood advert every 5 minutes (decision recorded in HANDOFF; the firmware
// has no limit of its own).
//
// Hearing: every ADVERT packet in the RX log is decoded (name, type, position, path, SNR, timestamp), because LOG_RX shows
// adverts from nodes that are NOT contacts too. Pushes ADVERT (0x80) / NEW_ADVERT (0x8A) mark nodes the radio keeps.
// Adverts are public broadcasts, but a heard advert is unsigned here (no Ed25519 in the pure layer): a hint, not proof.
// Pure Dart.
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../command_queue.dart';
import '../inbound.dart';
import '../packet.dart';
import '../protocol.dart';
import '../radio_api.dart' show RxPacket;
import '../tx_arbiter.dart';
import 'advert_decode.dart';
import 'tool_frames.dart';
import 'tool_state.dart';
import 'tools_radio.dart';
import 'rx_log.dart' show advertTypeName;
import 'transport_code.dart';

class HeardAdvert {
  final String keyHex;
  String name;
  int nodeType;
  double? lat, lon;

  /// Newest path (hex hash per hop) and how it travelled.
  List<String> path = const [];
  int hashSize = 1;
  int routeType = RouteType.flood;
  double? snrDb;
  double? bestSnrDb;
  double? rssiDbm;
  final DateTime firstSeen;
  DateTime lastSeen;
  int count = 1;

  /// How far the advert's own timestamp is from the phone clock when heard, seconds (advert minus phone).
  int? clockSkewSecs;

  /// The radio keeps this node as a contact (a 0x80 / 0x8A push named it).
  bool inContacts = false;
  ScopeResult scope = const ScopeResult(ScopeVerdict.unscoped);

  HeardAdvert(this.keyHex, this.name, this.nodeType, DateTime at)
      : firstSeen = at,
        lastSeen = at;

  int get hops => path.length;
  bool get hasPosition => lat != null && lon != null;
  String get shortKey => keyHex.substring(0, 8);
  String get displayName => name.isEmpty ? '${advertTypeName(nodeType)} $shortKey' : name;
}

enum AdvertSendStatus { sent, cooldown, notConnected, refused }

class AdvertSendResult {
  final AdvertSendStatus status;
  final String message;
  final Duration? wait;
  const AdvertSendResult(this.status, this.message, {this.wait});
  bool get ok => status == AdvertSendStatus.sent;
}

class AdvertTool with ToolChanges {
  final ToolsRadio radio;
  final TxArbiter arbiter;
  final DateTime Function() _clock;
  final int capacity;
  final Duration zeroHopCooldown;
  final Duration floodCooldown;

  final LinkedHashMap<String, HeardAdvert> _book = LinkedHashMap();
  List<String> _scopeNames = const [];
  StreamSubscription<RxPacket>? _rxSub;
  StreamSubscription<RadioEvent>? _evSub;
  DateTime? _lastZeroHop, _lastFlood;

  AdvertTool(this.radio, this.arbiter,
      {DateTime Function()? clock,
      this.capacity = 300,
      this.zeroHopCooldown = const Duration(seconds: 30),
      this.floodCooldown = const Duration(minutes: 5)})
      : _clock = clock ?? DateTime.now;

  /// Region names to test scoped adverts against ("#cmh"): the viewed region's scope, the channels' scopes.
  set scopeNames(List<String> v) {
    _scopeNames = List.unmodifiable(v);
    for (final a in _book.values) {
      final p = _lastScope[a.keyHex];
      if (p != null) a.scope = checkScope(p, _scopeNames);
    }
    notifyChanged();
  }

  List<String> get scopeNames => _scopeNames;
  final Map<String, MeshPacket> _lastScope = {};

  bool get listening => _rxSub != null;

  /// Newest heard first.
  List<HeardAdvert> get heard => (_book.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen)));
  int get count => _book.length;

  /// Starts collecting adverts from the radio's RX log and pushes. Safe to call twice.
  void start() {
    _rxSub ??= radio.rxPackets.listen(_onRx, onError: (Object _) {});
    _evSub ??= radio.events.listen(_onEvent, onError: (Object _) {});
  }

  Future<void> stop() async {
    await _rxSub?.cancel();
    await _evSub?.cancel();
    _rxSub = null;
    _evSub = null;
  }

  void clear() {
    _book.clear();
    _lastScope.clear();
    notifyChanged();
  }

  void _onRx(RxPacket rx) => hear(rx.raw, snrDb: rx.snrDb, rssiDbm: rx.rssiDbm, at: rx.at);

  /// One heard packet (also the test entry point). Non-adverts are ignored.
  HeardAdvert? hear(Uint8List raw, {double? snrDb, double? rssiDbm, DateTime? at}) {
    final p = MeshPacket.tryParse(raw);
    if (p == null || p.payloadType != PayloadType.advert) return null;
    final info = AdvertInfo.tryParse(p);
    if (info == null) return null;
    final now = at ?? _clock();
    var a = _book[info.publicKeyHex];
    if (a == null) {
      a = HeardAdvert(info.publicKeyHex, info.name, info.nodeType, now);
      _book[info.publicKeyHex] = a;
      while (_book.length > capacity) {
        // Forget the node not heard for the longest time.
        final oldest = _book.values.reduce((x, y) => x.lastSeen.isBefore(y.lastSeen) ? x : y);
        _book.remove(oldest.keyHex);
        _lastScope.remove(oldest.keyHex);
      }
    } else {
      a.count++;
      a.lastSeen = now;
      if (info.name.isNotEmpty) a.name = info.name;
      a.nodeType = info.nodeType;
    }
    if (info.hasPosition) {
      a.lat = info.lat;
      a.lon = info.lon;
    }
    a.path = p.pathHex;
    a.hashSize = p.pathHashSize;
    a.routeType = p.routeType;
    a.snrDb = snrDb;
    a.rssiDbm = rssiDbm;
    if (snrDb != null && (a.bestSnrDb == null || snrDb > a.bestSnrDb!)) a.bestSnrDb = snrDb;
    a.clockSkewSecs = info.timestamp - now.toUtc().millisecondsSinceEpoch ~/ 1000;
    _lastScope[a.keyHex] = p;
    a.scope = checkScope(p, _scopeNames);
    notifyChanged();
    return a;
  }

  void _onEvent(RadioEvent e) {
    if (e is! AdvertHeardEvent) return;
    final a = _book[e.publicKeyHex];
    if (a != null) {
      a.inContacts = true;
      notifyChanged();
    } else if (e.contact != null) {
      // A known node advertised but its packet was not in the RX log (dropped on the BLE queue): list it from the contact.
      final c = e.contact!;
      final n = HeardAdvert(c.publicKeyHex, c.name, c.type, e.at)
        ..inContacts = true
        ..lat = c.lat
        ..lon = c.lon;
      _book[c.publicKeyHex] = n;
      notifyChanged();
    }
  }

  /// Airtime of one advert: about 120 bytes (VERIFIED 118-124 B on hardware).
  double estimateAirtimeMs() => arbiter.airParams?.call()?.airtimeMs(120) ?? 400;

  /// Wait before an advert of this kind may go; null when it may go now.
  Duration? cooldown({required bool flood}) {
    final last = flood ? _lastFlood : _lastZeroHop;
    if (last == null) return null;
    final left = (flood ? floodCooldown : zeroHopCooldown) - _clock().difference(last);
    return left > Duration.zero ? left : null;
  }

  /// Sends this radio's advert. Never throws.
  Future<AdvertSendResult> send({required bool flood}) async {
    if (!radio.isConnected) return const AdvertSendResult(AdvertSendStatus.notConnected, 'No radio is connected.');
    final wait = cooldown(flood: flood);
    if (wait != null) {
      return AdvertSendResult(AdvertSendStatus.cooldown, 'Wait ${_fmt(wait)} before sending another ${flood ? 'mesh-wide' : 'local'} advert.', wait: wait);
    }
    try {
      final f = await radio.send(encodeSendSelfAdvert(flood: flood), priority: CommandPriority.advert);
      if (f is ErrFrame) {
        return AdvertSendResult(AdvertSendStatus.refused,
            f.code == ErrCode.tableFull ? 'The radio is too busy to send an advert now. Try again in a moment.' : 'The radio refused the advert.');
      }
      if (f is! OkFrame) return const AdvertSendResult(AdvertSendStatus.refused, 'The radio gave an unexpected answer.');
    } on TimeoutException {
      return const AdvertSendResult(AdvertSendStatus.refused, 'The radio did not answer. It may still have sent the advert.');
    } on StateError {
      return const AdvertSendResult(AdvertSendStatus.notConnected, 'The radio disconnected.');
    }
    final now = _clock();
    if (flood) {
      _lastFlood = now;
    } else {
      _lastZeroHop = now;
    }
    arbiter.recordTx(TxPriority.advert, estimateAirtimeMs());
    notifyChanged();
    return AdvertSendResult(AdvertSendStatus.sent,
        flood ? 'Advert sent to the whole mesh. Repeaters will pass it on.' : 'Local advert sent. Only radios in direct range hear it.');
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds + 1;
    return s >= 90 ? '${(s / 60).ceil()} min' : '$s s';
  }

  Future<void> dispose() async {
    await stop();
    disposeChanges();
  }
}
