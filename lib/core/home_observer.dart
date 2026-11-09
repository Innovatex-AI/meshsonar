// Home observer (phone observer step O3; contract meshsonar-infra docs/planning/phone-observer-contract-v2-2026-11-08.md
// section 4, Andy's decision Q3 Nov 8 2026): a phone left at home next to its radio becomes a fixed observer at a position
// the owner places on a map. The owner chooses how the public map shows it: exact, or rounded to about 1 km (the server's
// 0.01 degree rule); analysis uses the exact position. Its packets carry no cell (the position is the registered one).
//
// Calls, all with `x-driver-key`:
//  * `PUT  /api/cmh/observer/home`       {"id", "lat", "lon", "location_public": "exact" | "rounded_1km"}
//  * `POST /api/cmh/observer/heartbeat`  {"id"} every 5 min while home mode is on and the radio is connected
//  * `DELETE /api/cmh/observer/home?id=..` back to a mobile observer, the home position hidden
//  * `GET  /api/cmh/observer/me`         this driver's phone observers
//
// Pure Dart.
import 'dart:async';
import 'dart:convert';

/// How the public map shows the home position.
enum HomeLocationPublic {
  exact('exact', 'Exact position'),
  rounded1km('rounded_1km', 'About 1 km (rounded)');

  final String wire;
  final String label;
  const HomeLocationPublic(this.wire, this.label);

  static HomeLocationPublic parse(Object? v) => v == exact.wire ? exact : rounded1km;
}

/// The saved home observer choice (Settings `home_observer`). [on] = home mode is active.
class HomeObserverConfig {
  final bool on;
  final double lat;
  final double lon;
  final HomeLocationPublic locationPublic;
  const HomeObserverConfig({required this.on, required this.lat, required this.lon, this.locationPublic = HomeLocationPublic.rounded1km});

  static bool validPosition(double lat, double lon) =>
      lat.isFinite && lon.isFinite && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 && !(lat == 0 && lon == 0);

  HomeObserverConfig copyWith({bool? on, double? lat, double? lon, HomeLocationPublic? locationPublic}) => HomeObserverConfig(
        on: on ?? this.on,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        locationPublic: locationPublic ?? this.locationPublic,
      );

  Map<String, dynamic> toJson() => {'on': on, 'lat': lat, 'lon': lon, 'location_public': locationPublic.wire};

  static HomeObserverConfig? fromJson(Object? j) {
    if (j is! Map) return null;
    final lat = j['lat'], lon = j['lon'];
    if (lat is! num || lon is! num || !validPosition(lat.toDouble(), lon.toDouble())) return null;
    return HomeObserverConfig(
      on: j['on'] == true,
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      locationPublic: HomeLocationPublic.parse(j['location_public']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeObserverConfig && other.on == on && other.lat == lat && other.lon == lon && other.locationPublic == locationPublic;

  @override
  int get hashCode => Object.hash(on, lat, lon, locationPublic);
}

/// The position the public map shows for [locationPublic]: exact, or the server's `ms_round_1km` rule (contract section 7):
/// the CENTRE of the 0.01 degree cell, `(floor(x / 0.01) + 0.5) * 0.01`, rounded to 3 decimals (about 1 km).
({double lat, double lon}) publicHomePosition(double lat, double lon, HomeLocationPublic p) =>
    p == HomeLocationPublic.exact ? (lat: lat, lon: lon) : (lat: round1kmCentre(lat), lon: round1kmCentre(lon));

/// One coordinate on the server's 0.01 degree centre-of-cell grid (39.98765 -> 39.985, -83.01234 -> -83.015).
double round1kmCentre(double x) => (((x * 100).floorToDouble() + 0.5) * 10).roundToDouble() / 1000;

/// One answer from the server; a network failure is a thrown exception instead.
class HomeObserverHttpResult {
  final int status;
  final Map<String, dynamic>? body;
  const HomeObserverHttpResult(this.status, {this.body});
  bool get ok => status >= 200 && status < 300;
}

/// The HTTP side, implemented by HttpCmatClient (lib/core/cmat_client.dart).
abstract class HomeObserverTransport {
  /// `PUT /api/cmh/observer/home` with [body].
  Future<HomeObserverHttpResult> putHome(String driverKey, Map<String, dynamic> body);

  /// `POST /api/cmh/observer/heartbeat` {"id": [observerId]}.
  Future<HomeObserverHttpResult> heartbeat(String driverKey, String observerId);

  /// `DELETE /api/cmh/observer/home?id=[observerId]`.
  Future<HomeObserverHttpResult> deleteHome(String driverKey, String observerId);

  /// `GET /api/cmh/observer/me`.
  Future<HomeObserverHttpResult> me(String driverKey);
}

/// The request body of `PUT /observer/home` (contract section 4). Exact lat/lon go to the server (analysis uses them);
/// [HomeLocationPublic] says what the public map may show.
Map<String, dynamic> homeObserverBody(String observerId, HomeObserverConfig c) => {
      'id': observerId,
      'lat': double.parse(c.lat.toStringAsFixed(6)),
      'lon': double.parse(c.lon.toStringAsFixed(6)),
      'location_public': c.locationPublic.wire,
    };

/// One of the driver's phone observers, from `GET /observer/me`.
class PhoneObserverInfo {
  final String? id;
  final String? key;
  final String kind; // mobile | fixed
  final DateTime? lastPacketAt;
  final DateTime? lastHeartbeatAt;
  final int? packets24h;
  final int? rawPackets24h;
  final double? homeLat;
  final double? homeLon;
  final HomeLocationPublic? homePublic;
  const PhoneObserverInfo({
    this.id,
    this.key,
    required this.kind,
    this.lastPacketAt,
    this.lastHeartbeatAt,
    this.packets24h,
    this.rawPackets24h,
    this.homeLat,
    this.homeLon,
    this.homePublic,
  });

  bool get fixed => kind == 'fixed';

  static PhoneObserverInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final home = j['home'] is Map ? j['home'] as Map : const {};
    double? num_(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    final last = j['last_packet_at'];
    final pk = j['packets_24h'] ?? j['packets24h'];
    final rawPk = j['raw_packets_24h'];
    final hb = j['last_heartbeat_at'];
    return PhoneObserverInfo(
      id: j['id'] is String ? j['id'] as String : null,
      key: j['key'] is String ? (j['key'] as String).toLowerCase() : (j['public_key'] is String ? (j['public_key'] as String).toLowerCase() : null),
      kind: j['kind'] is String ? j['kind'] as String : 'mobile',
      lastPacketAt: last is String ? DateTime.tryParse(last)?.toUtc() : null,
      lastHeartbeatAt: hb is String ? DateTime.tryParse(hb)?.toUtc() : null,
      packets24h: pk is num ? pk.toInt() : null,
      rawPackets24h: rawPk is num ? rawPk.toInt() : null,
      homeLat: num_(home['lat'] ?? j['lat']),
      homeLon: num_(home['lon'] ?? j['lon']),
      homePublic: (home['location_public'] ?? j['location_public']) is String
          ? HomeLocationPublic.parse(home['location_public'] ?? j['location_public'])
          : null,
    );
  }
}

/// Reads `GET /observer/me`: `{"observers": [...]}` (contract section 4.1), or a bare list.
List<PhoneObserverInfo> parsePhoneObservers(Object? body) {
  final list = body is Map ? body['observers'] : body;
  if (list is! List) return const [];
  return list.map(PhoneObserverInfo.fromJson).whereType<PhoneObserverInfo>().toList();
}

/// Picks this phone's entry: by the observer id, else by the key the server gave for this phone, else the only one.
PhoneObserverInfo? thisPhoneObserver(List<PhoneObserverInfo> all, {String? id, String? key}) {
  for (final o in all) {
    if (id != null && o.id == id) return o;
  }
  for (final o in all) {
    if (key != null && o.key == key.toLowerCase()) return o;
  }
  return all.length == 1 ? all.first : null;
}

/// What a call came to, in words the screen can show.
enum HomeCallOutcome { ok, noKey, notOnServer, keyRefused, rateLimited, offline, failed }

String homeCallText(HomeCallOutcome o) => switch (o) {
      HomeCallOutcome.ok => 'Done.',
      HomeCallOutcome.noKey => 'This phone needs a confirmed driver key first (Settings > Account).',
      HomeCallOutcome.notOnServer => 'Your server does not support home observers yet. Your choice is kept and sent when it does.',
      HomeCallOutcome.keyRefused => 'The server did not accept this phone\'s driver key.',
      HomeCallOutcome.rateLimited => 'The server asked to slow down. It is tried again shortly.',
      HomeCallOutcome.offline => 'No connection to the server. It is tried again when there is one.',
      HomeCallOutcome.failed => 'The server could not do that right now. It is tried again shortly.',
    };

HomeCallOutcome _outcome(HomeObserverHttpResult r) {
  if (r.ok) return HomeCallOutcome.ok;
  if (r.status == 404 || r.status == 405 || r.status == 501) return HomeCallOutcome.notOnServer;
  if (r.status == 401 || r.status == 403) return HomeCallOutcome.keyRefused;
  if (r.status == 429) return HomeCallOutcome.rateLimited;
  return HomeCallOutcome.failed;
}

/// Talks to the server for home mode and keeps the 5-minute heartbeat while home mode is on and the radio is connected.
class HomeObserverService {
  final HomeObserverTransport? Function() transport;
  final String? Function() driverKey;
  final Future<String> Function() observerId;

  /// Home mode is on (saved choice).
  final bool Function() active;

  /// The radio is connected (no heartbeat without it: the server measures uptime by it).
  final bool Function() connected;

  /// The saved home, re-sent with `PUT` when a heartbeat gets 404 (the server does not know this id yet, contract section 7).
  final HomeObserverConfig? Function()? config;
  final Duration heartbeatEvery;

  /// Start the periodic heartbeat timer by itself. Tests switch it off and call [heartbeatNow].
  final bool autoTimer;

  HomeObserverService({
    required this.transport,
    required this.driverKey,
    required this.observerId,
    required this.active,
    required this.connected,
    this.config,
    this.heartbeatEvery = const Duration(minutes: 5),
    this.autoTimer = true,
  });

  Timer? _timer;
  int heartbeatsSent = 0;
  HomeCallOutcome? lastOutcome;

  /// The server's key for this phone's observer, from the last `{observer: {key, kind}}` answer (PUT, DELETE, heartbeat).
  String? lastKey;

  /// The last status read from the server for this phone (null before the first read or when the server has none).
  PhoneObserverInfo? status;
  DateTime? statusAt;

  bool get heartbeatRunning => _timer != null;

  Future<HomeCallOutcome> _call(Future<HomeObserverHttpResult> Function(HomeObserverTransport tx, String key) f,
      {bool notFoundIsOk = false, void Function(HomeObserverHttpResult r)? seen}) async {
    final key = driverKey();
    final tx = transport();
    if (key == null || key.isEmpty || tx == null) return lastOutcome = HomeCallOutcome.noKey;
    try {
      final r = await f(tx, key);
      final o = r.body?['observer'];
      if (o is Map && o['key'] is String) lastKey = (o['key'] as String).toLowerCase();
      seen?.call(r);
      if (notFoundIsOk && r.status == 404) return lastOutcome = HomeCallOutcome.ok;
      return lastOutcome = _outcome(r);
    } catch (_) {
      return lastOutcome = HomeCallOutcome.offline;
    }
  }

  /// `PUT /observer/home`: registers or moves the home observer.
  Future<HomeCallOutcome> register(HomeObserverConfig c) async {
    final id = await observerId();
    return _call((tx, key) => tx.putHome(key, homeObserverBody(id, c)));
  }

  /// `DELETE /observer/home?id=..`: back to a mobile observer, the home position hidden.
  Future<HomeCallOutcome> unregister() async {
    stopHeartbeat();
    final id = await observerId();
    // 404 = the server holds no home for this id: nothing to delete, which is what was asked.
    return _call((tx, key) => tx.deleteHome(key, id), notFoundIsOk: true);
  }

  /// One heartbeat, only while home mode is on and the radio is connected. Returns null when it was not due.
  Future<HomeCallOutcome?> heartbeatNow() async {
    if (!active() || !connected()) return null;
    final id = await observerId();
    var notFound = false;
    var o = await _call((tx, key) => tx.heartbeat(key, id), seen: (r) => notFound = r.status == 404);
    // 404 = the server does not know this id (contract section 7): register the saved home again, then beat once more.
    final c = config?.call();
    if (notFound && c != null && c.on) {
      if (await register(c) == HomeCallOutcome.ok) o = await _call((tx, key) => tx.heartbeat(key, id));
    }
    if (o == HomeCallOutcome.ok) heartbeatsSent++;
    return o;
  }

  /// Starts (or keeps) the heartbeat: one now, then every [heartbeatEvery]. Each tick checks home mode and the radio.
  void startHeartbeat() {
    if (!autoTimer || _timer != null) return;
    unawaited(heartbeatNow());
    _timer = Timer.periodic(heartbeatEvery, (_) => unawaited(heartbeatNow()));
  }

  void stopHeartbeat() {
    _timer?.cancel();
    _timer = null;
  }

  /// `GET /observer/me`, then picks this phone's entry ([id] / [key]).
  Future<HomeCallOutcome> refreshStatus({String? key, DateTime? now}) async {
    final id = await observerId();
    HomeObserverHttpResult? res;
    final o = await _call((tx, k) async => res = await tx.me(k));
    if (o == HomeCallOutcome.ok && res != null) {
      status = thisPhoneObserver(parsePhoneObservers(res!.body), id: id, key: key);
      statusAt = now ?? DateTime.now().toUtc();
    }
    return o;
  }

  void dispose() => stopHeartbeat();
}

/// The JSON body bytes for a request (kept here so the transport and the tests encode the same way).
List<int> homeObserverJson(Map<String, dynamic> body) => utf8.encode(jsonEncode(body));
