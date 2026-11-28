// A fake MeshSonar radio local API for tests and the app's Simulator: serves the example JSON of meshsonar-firmware
// docs/APP-INTEGRATION.md section 4 (with this radio's key) behind the real transport rules (X-MS on POST, Bearer token,
// error bodies), and pairs for real: it holds an Ed25519 key (default: the contract's test-vector seed 00 01 .. 1f), signs
// the hello text, and checks the pairing signature on pair/finish.
//
//   final radio = FakeMsRadio();
//   final c = MsRadioController.forCaps(caps, radioKey: radio.keyHex, secrets: InMemoryMsSecretKv(),
//       client: radio.client, browser: radio.browser, sign: radio.sign)!;
//
// [sign] stands in for the Bluetooth side (CMD_SIGN_*); the simulated companion radio (lib/radio/simulator.dart,
// `meshSonar: true`) signs with the same seed, so the Simulator can pair through its own Bluetooth link too.
// Knobs make the radio misbehave for tests (wrong key, bad radio signature, 410, 429, 503, approval answers, latency).
// Pure Dart: package:http's MockClient, no sockets.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cr;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../radio/crypto.dart' show fromHex, toHex;
import 'ms_discovery.dart';

/// The contract's Ed25519 test vector (APP-INTEGRATION.md 3.1).
abstract final class MsTestVector {
  static final Uint8List seed = Uint8List.fromList(List<int>.generate(32, (i) => i));
  static const String key = '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8';
  static const String nonce = '00112233445566778899aabbccddeeff';
  static const String appNonce = '0f1e2d3c4b5a69788796a5b4c3d2e1f0';
  static const String hello =
      'meshsonar-app-hello:v1:03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8:0f1e2d3c4b5a69788796a5b4c3d2e1f0:00112233445566778899aabbccddeeff';
  static const String helloSig =
      '6b410b6a77369b1fc536f2f951a9e74033af3d971418b7da152108de10896006d05be43f5410f7db55afbd61c17d7b1820d86bc4ecf16bd193a91fc053819402';
  static const String pair =
      'meshsonar-app-pair:v1:03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8:00112233445566778899aabbccddeeff:0f1e2d3c4b5a69788796a5b4c3d2e1f0';
  static const String pairSig =
      '333f27fd8894418af75e4a661f5843e4e576a3b87f6e2e5c7c7bab5e8a5dc196258d0132d5e55e9c5ca84bff2f571be30d71d7a4057a217f4385bbde82a8a603';
}

/// The example replies of APP-INTEGRATION.md section 4, as JSON text, exactly as the contract prints them (the spectrum
/// example's `...` is filled in so it parses).
abstract final class MsContractExamples {
  static const String info = '{"api":1,"product":"MeshSonar Firmware","fw":"0.1.0","core":"v1.18.0","fw_string":"v1.18.0-ms0.1.0",'
      '"board":"heltec_v4_touch","model":"Heltec V4 + Expansion Kit (MeshSonar)","key":"A1B2C3D4...","name":"KE4BFI Mobile",'
      '"host":"meshsonar-a1b2c3d4.local","ip":"192.168.1.77","pair":["sign","approve"],"paired":false,"web_console":true}';
  static const String status = '{"device":{"name":"KE4BFI Mobile","key":"A1B2...","fw":"0.1.0","core":"v1.18.0","board":"heltec_v4_touch","model":"...",'
      '"uptime_s":3600,"batt_mv":4012,"batt_pct":84,"clock_set":true,"time":1795000000,"clock_source":"GPS",'
      '"heap_internal":10432,"psram_free":180224},'
      '"radio":{"freq":910.525,"bw":62.5,"sf":7,"cr":5,"tx_dbm":22,"contacts":41},'
      '"wifi":{"state":"Connected to Home","ssid":"Home","ip":"192.168.1.77","rssi":-58,"host":"meshsonar-a1b2c3d4.local","mdns":true,"time_synced":true},'
      '"uplink":{"state":"Connected to MeshSonar (CMH)","capture":true,"share":true,"wardrive":false,"iata":"CMH","mqtt":true,"linked":false},'
      '"log":{"heard":5120,"heard_hour":88,"sent":4980,"sent_hour":85,"pending":12,"backlog_sent":340,"backlog_max_s":3300,'
      '"dropped":0,"logged":5130,"log_bytes":412000,"gps_points":220,"best_snr":11},'
      '"ota":{"state":"","busy":false,"progress":0,"update_available":false},'
      '"maps":{"busy":false,"progress":0},'
      '"apps":{"count":4,"running":false,"current":""},'
      '"rf":{"scanning":false,"tx_budget_pct":100},'
      '"lock":{"set":false,"locked":false}}';
  static const String pairStart = '{"key":"A1B2...64 hex","nonce":"<32 hex>","expires_in":120,'
      '"sign_text":"meshsonar-app-pair:v1:<key>:<nonce>:<app_nonce>","radio_sig":"<128 hex>"}';
  static const String pairFinish = '{"token":"<32 hex>","via":"sign","key":"A1B2..."}';
  static const String pairAsk = '{"n":"<16 hex>","expires_in":60}';
  static const String tokens = '{"tokens":[{"i":0,"app":"MeshSonar iOS","via":"sign","created":1795000000,"seen_s":3,"me":true}]}';
  static const String logRecords = '{"which":"current","size":412000,"off":0,"records":['
      '{"seq":101,"kind":"packet","ts":1795000000,"ms":412,"lat":39.961234,"lon":-82.998765,"snr":7.25,"rssi":-96,"raw":"1500AB..."},'
      '{"seq":102,"kind":"gps","ts":1795000015,"ms":0,"lat":39.961300,"lon":-82.998700},'
      '{"seq":103,"kind":"probe","ts":1795000030,"ms":5,"lat":39.9614,"lon":-82.9986,"best_snr":9.5,"best_rssi":-90,'
      '"probe":{"trigger":"manual","answered":3,"ping":"answered","ping_ms":840,"ping_repeater":"5F0A11B2",'
      '"nodes":[{"key":"5F0A11B2","type":2,"snr":9.5,"snr_them":6.25,"rssi":-90}]}}],'
      '"next":1234,"end":false}';
  static const String maps = '{"partition":true,"space_kb":8192,"busy":false,"progress":0,"last_result":"",'
      '"pack":{"name":"Columbus","zmin":8,"zmax":14,"zdef":12,"tiles":5321,"bytes":3911000,"lat":39.96,"lon":-82.99},'
      '"upload":{"method":"POST","path":"/maps","field":"file","size_arg":"size"}}';
  static const String ota = '{"state":"idle","state_text":"","busy":false,"progress":0,"last_result":"Updated to MeshSonar 0.1.0.",'
      '"beta":false,"auto_check":true,"feed":"https://meshsonar.com/firmware/heltec-v4-touch/stable.json","fw":"0.1.0",'
      '"board":"heltec_v4_touch","slot":"app0","pending_verify":false,"valid_in_s":0,'
      '"offer":{"newer":true,"allowed":true,"channel":"stable","version":"0.2.0","build":12,"size":2841000,"sha256":"...",'
      '"min_version":"0.1.0","notes":"...","checked_s_ago":40},'
      '"upload":{"method":"POST","path":"/update","field":"file"}}';
  static const String settings = '{"name":"KE4BFI Mobile","brightness":80,"screen_timeout_ms":120000,"screen_timeouts":[30000,60000,120000,300000,600000,0],'
      '"sounds":{"buzzer_built":true,"buzzer_fitted":true,"volume":2,"flash":true,"events":61,'
      '"event_bits":["dm","channel","mention","delivered","not_delivered","low_battery"],"quiet_on":false,"quiet_start":1320,"quiet_end":420},'
      '"lock":{"set":false,"locked":false}}';
  static const String owner = '{"linked":false,"owner_key":"","owner_name":"","self_key":"A1B2...","share":true}';
  static const String spectrum = '{"scanning":true,"bins_available":true,'
      '"scan":{"f0":902.000,"f1":928.000,"step":0.200,"n":131,"sweeps":4,"seq":7,"last":[-118.5,-120.0,null],"peak":[-110.0,-112.5,null]}}';
  static const String probeNow = '{"ok":true,"listen_s":8}';
  static const String error = '{"error":"plain English text","status":409}';
}

/// What a fake approval request ends with.
enum FakeAskAnswer { wait, yes, no, locked }

class FakeMsRadio {
  final Uint8List seed;
  final DateTime Function() _clock;
  final math.Random _rng;

  /// The address the fake browser reports.
  final String address;

  FakeMsRadio({Uint8List? seed, DateTime Function()? clock, math.Random? random, this.address = '192.168.1.77', this.name = 'KE4BFI Mobile', String? keyHex})
      : seed = seed ?? MsTestVector.seed,
        _clock = clock ?? DateTime.now,
        _rng = random ?? math.Random(7),
        _keyHex = keyHex ?? (seed == null ? MsTestVector.key : null);

  String? _keyHex;
  cr.SimpleKeyPair? _kp;
  String name;

  Future<cr.SimpleKeyPair> _keyPair() async {
    final kp = _kp ??= await cr.Ed25519().newKeyPairFromSeed(seed);
    _keyHex ??= toHex((await kp.extractPublicKey()).bytes);
    return kp;
  }

  /// This radio's public key, lower-case 64 hex (known at once for the default seed; otherwise after [ready]).
  String get keyHex => _keyHex ?? (throw StateError('await ready() first for a custom seed'));

  /// Derives the public key of a custom seed.
  Future<String> ready() async {
    await _keyPair();
    return _keyHex!;
  }

  // ---------------------------------------------------------------- knobs
  /// /info (and pair/start) answer with this key instead (wrong-radio tests).
  String? infoKeyOverride;

  /// pair/start sends a signature that does not verify.
  bool badRadioSig = false;

  /// pair/start sends this sign_text instead of its own.
  String? signTextOverride;

  /// pair/finish answers with this status (e.g. 410) and the radio's error text.
  int? finishStatus;

  /// Every pairing call answers 429.
  bool rateLimited = false;

  /// The next N requests answer 503.
  int busyCount = 0;

  /// Requests never answer (timeout tests).
  bool hang = false;

  /// The radio is not reachable: every request fails like a missing route.
  bool offline = false;

  /// Simulated time per request.
  Duration latency = Duration.zero;

  /// What an approval request turns into after [askAfterPolls] polls.
  FakeAskAnswer askAnswer = FakeAskAnswer.yes;
  int askAfterPolls = 1;

  /// Another device is already waiting for approval (409).
  bool askBusy = false;

  // ---------------------------------------------------------------- what happened
  /// Every request, in order (method and path with query).
  final List<String> requests = [];

  /// The last pairing text the radio checked on pair/finish.
  String? lastFinishText;

  /// Upload bodies received, per route.
  final Map<String, int> uploadedBytes = {};

  /// Requests that were running at once at most (the serial queue keeps this at 1).
  int maxInFlight = 0;
  int _inFlight = 0;

  // ---------------------------------------------------------------- state
  final Map<String, ({String app, String via, int created})> _tokens = {};
  final Map<String, ({String appNonce, DateTime at, String? app})> _challenges = {};
  final Map<String, ({int polls, String app})> _asks = {};
  int _badSigs = 0;
  bool capture = true, share = true, wardrive = false;
  String iata = 'CMH';
  String? ownerKey;
  String ownerName = '';
  bool lockSet = false, locked = false;
  String? pin;
  bool scanning = false;
  bool beta = false, autoCheck = true;
  int brightness = 80, screenTimeoutMs = 120000, volume = 2, events = 61, quietStart = 1320, quietEnd = 420;
  bool buzzerFitted = true, flash = true, quietOn = false;
  final List<Map<String, Object?>> apps = [
    {'id': 'clock', 'name': 'Clock', 'version': '1.0.0', 'icon': 'CL', 'desc': 'A big clock', 'source': 'builtin', 'http': false, 'memory_kb': 32, 'size': 2100},
    {'id': 'weather', 'name': 'Weather', 'version': '1.1.0', 'icon': 'WX', 'desc': 'Local weather', 'source': 'catalog', 'http': true, 'memory_kb': 64, 'size': 6400},
  ];
  String? runningApp;
  String catalogState = 'idle';

  /// Tokens issued (never shown in tests' failure text: compare, do not print).
  Iterable<String> get issuedTokens => _tokens.keys;

  /// Signs [data] with the radio key: the Bluetooth side (what CMD_SIGN_* returns on this radio).
  Future<Uint8List> sign(Uint8List data) async {
    final s = await cr.Ed25519().sign(data, keyPair: await _keyPair());
    return Uint8List.fromList(s.bytes);
  }

  /// An http client that talks to this fake radio.
  late final http.Client client = MockClient(handle);

  /// A DNS-SD browser that finds this radio (and [others]).
  late final FakeMsServiceBrowser browser = FakeMsServiceBrowser(() => [service]);

  /// This radio as DNS-SD sees it.
  MsFoundService get service => MsFoundService(
        name: 'meshsonar-${keyHex.substring(0, 8)}',
        addresses: [address],
        hostname: 'meshsonar-${keyHex.substring(0, 8)}.local',
        txt: {'v': '1', 'api': '/api/app/v1', 'fw': '0.1.0', 'core': 'v1.18.0', 'board': 'heltec_v4_touch', 'pk': keyHex.substring(0, 8)},
      );

  /// Makes a token for this app as if it had paired (tests that start paired).
  String issueToken({String app = 'MeshSonar iOS', String via = 'sign'}) {
    final t = _hex(16);
    _addToken(t, app, via);
    return t;
  }

  /// Revokes every token (the serial console's `appapi revoke all`).
  void revokeAll() => _tokens.clear();

  String _hex(int bytes) => toHex(List<int>.generate(bytes, (_) => _rng.nextInt(256)));

  void _addToken(String t, String app, String via) {
    if (_tokens.length >= 4) _tokens.remove(_tokens.keys.first);
    _tokens[t] = (app: app, via: via, created: _clock().millisecondsSinceEpoch ~/ 1000);
  }

  // ---------------------------------------------------------------- the handler
  http.Response _j(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});
  http.Response _err(int status, String text) => _j({'error': text, 'status': status}, status);

  Map<String, String> _fields(http.Request r) {
    final out = <String, String>{...r.url.queryParameters};
    final ct = r.headers['content-type'] ?? '';
    if (ct.startsWith('application/x-www-form-urlencoded')) {
      out.addAll(Uri.splitQueryString(r.body));
    } else if (ct.startsWith('application/json') && r.body.isNotEmpty) {
      final j = jsonDecode(r.body);
      if (j is Map) out.addAll({for (final e in j.entries) '${e.key}': '${e.value}'});
    }
    return out;
  }

  static bool? _bool(String? v) => switch (v) {
        'true' || '1' || 'on' => true,
        'false' || '0' || 'off' => false,
        _ => null,
      };

  Future<http.Response> handle(http.Request r) async {
    requests.add('${r.method} ${r.url.path}${r.url.hasQuery ? '?${r.url.query}' : ''}');
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      if (offline) throw http.ClientException('No route to host', r.url);
      if (hang) await Completer<void>().future;
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      if (busyCount > 0) {
        busyCount--;
        return _err(503, 'Radio busy, try again in a second.');
      }
      return await _route(r);
    } finally {
      _inFlight--;
    }
  }

  Future<http.Response> _route(http.Request r) async {
    final path = r.url.path;
    final post = r.method == 'POST';
    if (post && r.headers['X-MS'] != '1' && r.headers['x-ms'] != '1') return _err(403, 'Missing X-MS header.');
    final auth = r.headers['Authorization'] ?? r.headers['authorization'];
    final token = auth != null && auth.startsWith('Bearer ') ? auth.substring(7) : null;
    final authed = token != null && _tokens.containsKey(token);

    // root upload routes
    if (path == '/maps' || path == '/apps/upload' || path == '/update') {
      if (!post) return _err(405, 'Use POST.');
      if (!authed) return _err(401, 'Not paired.');
      uploadedBytes[path] = r.bodyBytes.length;
      return http.Response(path == '/maps' ? 'Done: ${(r.bodyBytes.length / 1024).round()} KB written.' : 'Done.', 200);
    }
    const prefix = '/api/app/v1';
    if (!path.startsWith(prefix)) return _err(404, 'Not found.');
    final p = path.substring(prefix.length);
    final f = _fields(r);
    final key = infoKeyOverride ?? keyHex;

    // open routes
    switch ((r.method, p)) {
      case ('GET', '' || '/'):
        return _j({'api': 1, 'paths': ['/info', '/status']});
      case ('GET', '/info'):
        return _j({
          'api': 1,
          'product': 'MeshSonar Firmware',
          'fw': '0.1.0',
          'core': 'v1.18.0',
          'fw_string': 'v1.18.0-ms0.1.0',
          'board': 'heltec_v4_touch',
          'model': 'Heltec V4 + Expansion Kit (MeshSonar)',
          'key': key.toUpperCase(),
          'name': name,
          'host': 'meshsonar-${key.substring(0, 8)}.local',
          'ip': address,
          'pair': ['sign', 'approve'],
          'paired': authed,
          'web_console': true,
        });
      case ('POST', '/pair/start'):
        if (rateLimited) return _err(429, 'Too many tries. Wait a minute.');
        final an = f['app_nonce'] ?? '';
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(an)) return _err(400, 'Bad app nonce.');
        final nonce = _hex(16);
        _challenges[nonce] = (appNonce: an, at: _clock(), app: f['app']);
        final hello = utf8.encode('meshsonar-app-hello:v1:$key:$an:$nonce');
        var sig = await sign(Uint8List.fromList(hello));
        if (badRadioSig) sig = Uint8List.fromList([...sig]..[0] ^= 0xff);
        return _j({
          'key': key.toUpperCase(),
          'nonce': nonce,
          'expires_in': 120,
          'sign_text': signTextOverride ?? 'meshsonar-app-pair:v1:$key:$nonce:$an',
          'radio_sig': toHex(sig),
        });
      case ('POST', '/pair/finish'):
        if (rateLimited || _badSigs >= 5) return _err(429, 'Too many bad signatures. Wait a minute.');
        if (finishStatus != null) {
          return _err(finishStatus!, finishStatus == 410 ? 'That pairing request expired. Start again.' : 'Refused.');
        }
        final nonce = f['nonce'] ?? '';
        final ch = _challenges.remove(nonce);
        if (ch == null || _clock().difference(ch.at) > const Duration(seconds: 120)) return _err(410, 'That pairing request expired. Start again.');
        final text = 'meshsonar-app-pair:v1:$keyHex:$nonce:${ch.appNonce}';
        lastFinishText = text;
        final sigHex = f['sig'] ?? '';
        var ok = false;
        if (RegExp(r'^[0-9a-fA-F]{128}$').hasMatch(sigHex)) {
          final kp = await _keyPair();
          ok = await cr.Ed25519().verify(utf8.encode(text), signature: cr.Signature(fromHex(sigHex), publicKey: await kp.extractPublicKey()));
        }
        if (!ok) {
          _badSigs++;
          return _err(403, 'Bad signature.');
        }
        final t = _hex(16);
        _addToken(t, f['app'] ?? 'App', 'sign');
        return _j({'token': t, 'via': 'sign', 'key': keyHex.toUpperCase()});
      case ('POST', '/pair/ask'):
        if (locked) return _j({'n': _newAsk(f['app'] ?? 'App'), 'expires_in': 60});
        if (askBusy) return _err(409, 'Another device is already waiting for an answer.');
        return _j({'n': _newAsk(f['app'] ?? 'App'), 'expires_in': 60});
      case ('GET', '/pair/ask'):
        final n = f['n'] ?? '';
        final a = _asks[n];
        if (a == null) return _err(410, 'That request expired.');
        if (locked) return _j({'state': 'locked'});
        final polls = a.polls + 1;
        _asks[n] = (polls: polls, app: a.app);
        if (polls < askAfterPolls || askAnswer == FakeAskAnswer.wait) return _j({'state': 'wait'});
        switch (askAnswer) {
          case FakeAskAnswer.no:
            _asks.remove(n);
            return _j({'state': 'no'});
          case FakeAskAnswer.locked:
            return _j({'state': 'locked'});
          case FakeAskAnswer.yes:
          case FakeAskAnswer.wait:
            _asks.remove(n);
            final t = _hex(16);
            _addToken(t, a.app, 'approve');
            return _j({'state': 'yes', 'token': t, 'via': 'approve'});
        }
    }

    if (!authed) return _err(401, 'Not paired. Pair this app again.');
    return _authed(r.method, p, f, token);
  }

  String _newAsk(String app) {
    final n = _hex(8);
    _asks[n] = (polls: 0, app: app);
    return n;
  }

  Map<String, Object?> get _uplinkJson =>
      {'state': share ? 'Connected to MeshSonar ($iata)' : 'Sharing off', 'capture': capture, 'share': share, 'wardrive': wardrive, 'iata': iata, 'mqtt': share, 'linked': ownerKey != null};
  Map<String, Object?> get _logJson => {
        'heard': 5120,
        'heard_hour': 88,
        'sent': 4980,
        'sent_hour': 85,
        'pending': 12,
        'backlog_sent': 340,
        'backlog_max_s': 3300,
        'dropped': 0,
        'logged': 5130,
        'log_bytes': 412000,
        'gps_points': 220,
        'best_snr': 11,
      };
  Map<String, Object?> get _lockJson => {'set': lockSet, 'locked': locked};
  Map<String, Object?> get _settingsJson => {
        'name': name,
        'brightness': brightness,
        'screen_timeout_ms': screenTimeoutMs,
        'screen_timeouts': [30000, 60000, 120000, 300000, 600000, 0],
        'sounds': {
          'buzzer_built': true,
          'buzzer_fitted': buzzerFitted,
          'volume': volume,
          'flash': flash,
          'events': events,
          'event_bits': ['dm', 'channel', 'mention', 'delivered', 'not_delivered', 'low_battery'],
          'quiet_on': quietOn,
          'quiet_start': quietStart,
          'quiet_end': quietEnd,
        },
        'lock': _lockJson,
      };
  Map<String, Object?> get _ownerJson => {'linked': ownerKey != null, 'owner_key': ownerKey ?? '', 'owner_name': ownerName, 'self_key': keyHex.toUpperCase(), 'share': share};

  Map<String, Object?> _probeRecord(int seq, int ts) => {
        'seq': seq,
        'kind': 'probe',
        'ts': ts,
        'ms': 5,
        'lat': 39.9614,
        'lon': -82.9986,
        'best_snr': 9.5,
        'best_rssi': -90,
        'probe': {
          'trigger': 'manual',
          'answered': 3,
          'ping': 'answered',
          'ping_ms': 840,
          'ping_repeater': '5F0A11B2',
          'nodes': [
            {'key': '5F0A11B2', 'type': 2, 'snr': 9.5, 'snr_them': 6.25, 'rssi': -90},
          ],
        },
      };

  Future<http.Response> _authed(String method, String p, Map<String, String> f, String token) async {
    switch ((method, p)) {
      case ('POST', '/unpair'):
        _tokens.remove(token);
        return _j({'ok': true});
      case ('GET', '/tokens'):
        var i = 0;
        return _j({
          'tokens': [
            for (final e in _tokens.entries) {'i': i++, 'app': e.value.app, 'via': e.value.via, 'created': e.value.created, 'seen_s': 3, 'me': e.key == token},
          ],
        });
      case ('POST', '/tokens/revoke'):
        final i = f['i'];
        if (i == 'all') {
          _tokens.clear();
        } else {
          final n = int.tryParse(i ?? '');
          if (n == null || n < 0 || n >= _tokens.length) return _err(400, 'No such app.');
          _tokens.remove(_tokens.keys.elementAt(n));
        }
        return _j({'ok': true});
      case ('GET', '/status'):
        return _j({
          'device': {
            'name': name,
            'key': keyHex.toUpperCase(),
            'fw': '0.1.0',
            'core': 'v1.18.0',
            'board': 'heltec_v4_touch',
            'model': 'Heltec V4 + Expansion Kit (MeshSonar)',
            'uptime_s': 3600,
            'batt_mv': 4012,
            'batt_pct': 84,
            'clock_set': true,
            'time': _clock().millisecondsSinceEpoch ~/ 1000,
            'clock_source': 'GPS',
            'heap_internal': 10432,
            'psram_free': 180224,
          },
          'radio': {'freq': 910.525, 'bw': 62.5, 'sf': 7, 'cr': 5, 'tx_dbm': 22, 'contacts': 41},
          'wifi': {'state': 'Connected to Home', 'ssid': 'Home', 'ip': address, 'rssi': -58, 'host': 'meshsonar-${keyHex.substring(0, 8)}.local', 'mdns': true, 'time_synced': true},
          'uplink': _uplinkJson,
          'log': _logJson,
          'ota': {'state': '', 'busy': false, 'progress': 0, 'update_available': false},
          'maps': {'busy': false, 'progress': 0},
          'apps': {'count': apps.length, 'running': runningApp != null, 'current': runningApp ?? ''},
          'rf': {'scanning': scanning, 'tx_budget_pct': 100},
          'lock': _lockJson,
        });
      case ('GET', '/uplink'):
        return _j({'uplink': _uplinkJson, 'log': _logJson, 'owner_key': ownerKey ?? '', 'owner_name': ownerName});
      case ('POST', '/uplink'):
        final c = _bool(f['capture']), s = _bool(f['share']), w = _bool(f['wardrive']), ia = f['iata'];
        if (ia != null && !RegExp(r'^[A-Za-z0-9]{3}$').hasMatch(ia)) return _err(400, 'IATA is 3 letters or digits.');
        if (w == true && !(c ?? capture)) return _err(409, 'Wardrive needs logging on.');
        if (c != null) capture = c;
        if (s != null) share = s;
        if (w != null) wardrive = w;
        if (!capture) wardrive = false;
        if (ia != null) iata = ia.toUpperCase();
        return _j({'uplink': _uplinkJson, 'log': _logJson, 'owner_key': ownerKey ?? '', 'owner_name': ownerName});
      case ('GET', '/log'):
        return _j({
          'uplink': _uplinkJson,
          'log': _logJson,
          'hourly': [for (var h = 0; h < 24; h++) (h * 37) % 120],
          'files': [
            {'which': 'old', 'path': '/mslog.old', 'size': 1200000},
            {'which': 'current', 'path': '/mslog.bin', 'size': 412000},
          ],
          'format': 'mslog-v1',
          'spiffs_used': 1650000,
          'spiffs_total': 3000000,
        });
      case ('GET', '/log/file'):
        final which = f['which'] == 'old' ? 'old' : 'current';
        // a few 24-byte header records, enough for a download test
        final b = BytesBuilder();
        for (var i = 0; i < (which == 'old' ? 3 : 5); i++) {
          b.add([0xA5, 1, 0, 28, ...List<int>.filled(20, i)]);
        }
        return http.Response.bytes(b.takeBytes(), 200, headers: {'content-type': 'application/octet-stream'});
      case ('GET', '/log/records'):
        final off = int.tryParse(f['off'] ?? '0') ?? 0;
        final ts = 1795000000;
        if (off == 0) {
          return _j({
            'which': f['which'] ?? 'current',
            'size': 412000,
            'off': 0,
            'records': [
              {'seq': 101, 'kind': 'packet', 'ts': ts, 'ms': 412, 'lat': 39.961234, 'lon': -82.998765, 'snr': 7.25, 'rssi': -96, 'raw': '1500AB'},
              {'seq': 102, 'kind': 'gps', 'ts': ts + 15, 'ms': 0, 'lat': 39.9613, 'lon': -82.9987},
            ],
            'next': 1234,
            'end': false,
          });
        }
        return _j({
          'which': f['which'] ?? 'current',
          'size': 412000,
          'off': off,
          'records': [_probeRecord(103, ts + 30)],
          'next': 1300,
          'end': true,
        });
      case ('GET', '/probes'):
        return _j({'records': [_probeRecord(103, 1795000030)], 'total': 1});
      case ('POST', '/probe/now'):
        if (scanning) return _err(409, 'The spectrum scan is on.');
        return _j({'ok': true, 'listen_s': 8});
      case ('GET', '/maps'):
        return _j(jsonDecode(MsContractExamples.maps) as Object);
      case ('GET', '/apps'):
        return _j({
          'installed': apps,
          'running': runningApp ?? '',
          'failed': '',
          'error': '',
          'catalog': {
            'state': catalogState,
            'note': '',
            'url': 'https://meshsonar.com/apps/catalog.json',
            'entries': catalogState == 'ok'
                ? [
                    {'id': 'weather', 'name': 'Weather', 'version': '1.2.0', 'icon': 'WX', 'desc': 'Local weather', 'installed_version': '1.1.0'},
                    {'id': 'snake', 'name': 'Snake', 'version': '0.3.0', 'icon': 'SN', 'desc': 'The game'},
                  ]
                : [],
          },
          'installing': '',
          'install_note': '',
          'upload': {'method': 'POST', 'path': '/apps/upload', 'field': 'file'},
        });
      case ('POST', '/apps/catalog'):
        catalogState = 'ok';
        return _j({'ok': true});
      case ('POST', '/apps/install'):
        return _j({'ok': true});
      case ('POST', '/apps/run'):
        final id = f['id'];
        if (!apps.any((a) => a['id'] == id)) return _err(400, 'No such app.');
        runningApp = id;
        return _j({'ok': true});
      case ('POST', '/apps/stop'):
        runningApp = null;
        return _j({'ok': true});
      case ('POST', '/apps/remove'):
        final id = f['id'];
        final a = apps.where((a) => a['id'] == id).firstOrNull;
        if (a == null) return _err(400, 'No such app.');
        if (a['source'] == 'builtin') return _err(403, 'Built-in apps cannot be removed.');
        apps.remove(a);
        return _j({'ok': true});
      case ('GET', '/ota'):
        final j = jsonDecode(MsContractExamples.ota) as Map<String, dynamic>;
        j['beta'] = beta;
        j['auto_check'] = autoCheck;
        return _j(j);
      case ('POST', '/ota/check' || '/ota/install'):
        return _j({'ok': true});
      case ('POST', '/ota/channel'):
        beta = _bool(f['beta']) ?? beta;
        return _j({'ok': true, 'beta': beta});
      case ('POST', '/ota/auto'):
        autoCheck = _bool(f['on']) ?? autoCheck;
        return _j({'ok': true, 'auto_check': autoCheck});
      case ('POST', '/ota/restart'):
        if (f['confirm'] != 'yes') return _err(400, 'Send confirm=yes.');
        return _j({'ok': true});
      case ('GET', '/settings'):
        return _j(_settingsJson);
      case ('POST', '/settings'):
        int? n(String k) => f[k] == null ? null : int.tryParse(f[k]!);
        final b = n('brightness'), st = n('screen_timeout_ms'), v = n('volume'), qs = n('quiet_start'), qe = n('quiet_end');
        final nm = f['name'];
        if ((b != null && (b < 5 || b > 100)) ||
            (st != null && ![30000, 60000, 120000, 300000, 600000, 0].contains(st)) ||
            (v != null && (v < 1 || v > 3)) ||
            (nm != null && (nm.isEmpty || nm.length > 31)) ||
            ((qs == null) != (qe == null)) ||
            (qs != null && (qs < 0 || qs > 1439 || qe! < 0 || qe > 1439))) {
          return _err(400, 'Value out of range.');
        }
        if (nm != null) name = nm;
        if (b != null) brightness = b;
        if (st != null) screenTimeoutMs = st;
        if (v != null) volume = v;
        if (n('events') != null) events = n('events')!;
        buzzerFitted = _bool(f['buzzer_fitted']) ?? buzzerFitted;
        flash = _bool(f['flash']) ?? flash;
        quietOn = _bool(f['quiet_on']) ?? quietOn;
        if (qs != null) {
          quietStart = qs;
          quietEnd = qe!;
        }
        return _j(_settingsJson);
      case ('POST', '/lock'):
        switch (f['action']) {
          case 'lock_now':
            if (!lockSet) return _err(409, 'Set a PIN first.');
            locked = true;
            return _j({'ok': true, 'lock': _lockJson});
          case 'set':
            if (lockSet) return _err(409, 'A PIN is already set.');
            if (!RegExp(r'^\d{4,8}$').hasMatch(f['pin'] ?? '')) return _err(400, 'The PIN is 4 to 8 digits.');
            pin = f['pin'];
            lockSet = true;
            return _j({'ok': true, 'lock': _lockJson});
          case 'clear':
            if (f['pin'] != pin) return _err(403, 'Wrong PIN');
            pin = null;
            lockSet = false;
            locked = false;
            return _j({'ok': true, 'lock': _lockJson});
        }
        return _err(400, 'Unknown action.');
      case ('GET', '/owner'):
        return _j(_ownerJson);
      case ('POST', '/owner'):
        final k = (f['key'] ?? '').toLowerCase();
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(k) || k == keyHex) return _err(400, 'That key cannot be the owner.');
        ownerKey = k;
        ownerName = f['name'] ?? '';
        return _j(_ownerJson);
      case ('POST', '/owner/clear'):
        ownerKey = null;
        ownerName = '';
        return _j(_ownerJson);
      case ('GET', '/spectrum'):
        if (!scanning) return _j({'scanning': false, 'bins_available': true, 'scan': null});
        return _j({
          'scanning': true,
          'bins_available': true,
          'scan': {
            'f0': 902.0,
            'f1': 928.0,
            'step': 0.2,
            'n': 131,
            'sweeps': 4,
            'seq': 7,
            'last': [for (var i = 0; i < 131; i++) i == 43 ? -92.5 : (i % 9 == 0 ? null : -118.5 - (i % 5))],
            'peak': [for (var i = 0; i < 131; i++) i == 43 ? -88.0 : -110.0 - (i % 4)],
          },
        });
      case ('POST', '/spectrum/start'):
        scanning = true;
        return _j({'ok': true});
      case ('POST', '/spectrum/stop'):
        scanning = false;
        return _j({'ok': true});
    }
    return _err(404, 'Not found.');
  }
}

/// A DNS-SD browser that returns what [_found] gives.
class FakeMsServiceBrowser implements MsServiceBrowser {
  final List<MsFoundService> Function() _found;
  FakeMsServiceBrowser(this._found);

  /// How many browses ran.
  int browses = 0;

  @override
  Future<List<MsFoundService>> browse(String type, {Duration timeout = const Duration(seconds: 5)}) async {
    browses++;
    return type == kMsServiceType ? _found() : const [];
  }
}
