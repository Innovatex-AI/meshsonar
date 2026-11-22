// ID step 5 on the wire (site: meshcore-insights src/lib/platform/person-observers.ts and person-observer-handlers.ts;
// docs/PLATFORM_CONTRACT.md "The person's observers"). Behind `capabilities.radioProof` like the rest of the person
// identity calls: while the server flag is off every call answers 404 {"error":"not found"}.
//   GET  person-observers        -> {observers: [fixed | phone], offers: [...]}
//   POST person-observer-offer   {key, action: accept|decline} -> {ok, accepted | declined | already}; 409 owned; 404 not_found
//   POST person-observer-pref    {key, showRadioName} -> {ok}; 404 not_found
// A fixed observer's name and position are changed with the existing claim PATCH and it is released with claim DELETE.
// Parsing is tolerant: unknown fields are ignored, missing optional fields are null, a row of an unknown `kind` or without a
// key is skipped. Never an email and never a device key. Pure Dart.
import 'node_claim.dart';

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
String? _s(Object? v, [int max = 120]) => v is String && v.trim().isNotEmpty ? (v.length > max ? v.substring(0, max) : v) : null;
final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// Where a fixed observer's position is shown in public.
enum ObserverPosition { hidden, rounded1km, exact }

ObserverPosition _position(Object? v) => switch (v) {
      'exact' => ObserverPosition.exact,
      'rounded_1km' => ObserverPosition.rounded1km,
      _ => ObserverPosition.hidden,
    };

/// One observer of the person: a fixed radio ([FixedObserver]) or a phone ([PhoneObserver]).
sealed class PersonObserver {
  /// Lower-case 64-hex observer key.
  final String key;
  final String name;
  final DateTime? lastHeardAt;
  final bool blocked;
  const PersonObserver({required this.key, required this.name, this.lastHeardAt, this.blocked = false});

  /// Null for an unknown `kind`, a row that is not an object, or a row without a usable key.
  static PersonObserver? tryParse(Object? j) {
    if (j is! Map) return null;
    final key = j['key'];
    if (key is! String || !_hex64.hasMatch(key)) return null;
    return switch (j['kind']) {
      'fixed' => FixedObserver._parse(j, key.toLowerCase()),
      'phone' => PhoneObserver._parse(j, key.toLowerCase()),
      _ => null,
    };
  }
}

/// A claimed radio that publishes to the broker. Its name and position are the claim's.
class FixedObserver extends PersonObserver {
  /// The public name the owner set; null when none.
  final String? publicName;

  /// What the radio calls itself.
  final String? nodeName;

  /// How the claim was proved.
  final ClaimMethod method;
  final DateTime? claimedAt;

  /// An observer that named its owner and the owner agreed (method `login`).
  final bool named;
  final String? iata, model, firmware;
  final DateTime? lastPacketAt, lastStatusAt;

  /// null = the owner has not chosen (the server default applies).
  final bool? positionPublic;
  final ObserverPosition position;
  final ObserverHealth? health;
  const FixedObserver({
    required super.key,
    required super.name,
    super.lastHeardAt,
    super.blocked,
    this.publicName,
    this.nodeName,
    this.method = ClaimMethod.other,
    this.claimedAt,
    this.named = false,
    this.iata,
    this.model,
    this.firmware,
    this.lastPacketAt,
    this.lastStatusAt,
    this.positionPublic,
    this.position = ObserverPosition.hidden,
    this.health,
  });

  /// The name field of the edit sheet: the owner's own name, empty when the shown name is the radio's.
  String get editableName => publicName != null && publicName != nodeName ? publicName! : '';

  /// The position switch of the edit sheet (the site: shown unless the owner chose otherwise).
  bool get positionShown => positionPublic != false;

  static FixedObserver _parse(Map j, String key) {
    final node = _s(j['nodeName'], 60);
    return FixedObserver(
      key: key,
      name: _s(j['name'], 60) ?? node ?? 'Observer ${key.substring(0, 8)}',
      lastHeardAt: _time(j['lastHeardAt']),
      blocked: j['blocked'] == true,
      publicName: _s(j['publicName'], 60),
      nodeName: node,
      method: parseClaimMethod(j['method']),
      claimedAt: _time(j['claimedAt']),
      named: j['named'] == true,
      iata: _s(j['iata'], 8),
      model: _s(j['model'], 40),
      firmware: _s(j['firmware'], 40),
      lastPacketAt: _time(j['lastPacketAt']),
      lastStatusAt: _time(j['lastStatusAt']),
      positionPublic: j['positionPublic'] is bool ? j['positionPublic'] as bool : null,
      position: _position(j['position']),
      health: ObserverHealth.tryParse(j['health']),
    );
  }
}

/// One phone of the person: ONE entry per phone (a reinstall is the same entry).
class PhoneObserver extends PersonObserver {
  final String deviceId, deviceName;

  /// How many app installs of this person reported as this phone (2 after a reinstall).
  final int installs;

  /// `background`, `home` or `drive`; null when unknown.
  final String? mode;
  final String? radioKey, radioName;

  /// `phone` (the app's upload) and, when its radio also publishes to the MQTT broker, `broker`.
  final List<String> feeds;

  /// Public name: the pseudonym (false, the default) or the name of the phone's radio (true).
  final bool showRadioName;
  final bool countedOnce;
  const PhoneObserver({
    required super.key,
    required super.name,
    super.lastHeardAt,
    super.blocked,
    required this.deviceId,
    required this.deviceName,
    this.installs = 1,
    this.mode,
    this.radioKey,
    this.radioName,
    this.feeds = const ['phone'],
    this.showRadioName = false,
    this.countedOnce = false,
  });

  /// Needs a radio the server knows: without one the switch has nothing to show.
  bool get canShowRadioName => radioKey != null && radioName != null;

  static PhoneObserver _parse(Map j, String key) {
    final d = j['device'] is Map ? j['device'] as Map : const {};
    final feeds = [
      if (j['feeds'] is List)
        for (final f in j['feeds'] as List)
          if (f == 'phone' || f == 'broker') f as String,
    ];
    final m = j['mode'];
    return PhoneObserver(
      key: key,
      name: _s(j['name'], 60) ?? 'MeshSonar phone',
      lastHeardAt: _time(j['lastHeardAt']),
      blocked: j['blocked'] == true,
      deviceId: _s(d['id'], 64) ?? '',
      deviceName: _s(d['name'], 60) ?? 'Device',
      installs: j['installs'] is num ? (j['installs'] as num).round().clamp(1, 99) : 1,
      mode: m == 'background' || m == 'home' || m == 'drive' ? m as String : null,
      radioKey: _s(j['radioKey'], 64),
      radioName: _s(j['radioName'], 60),
      feeds: feeds.isEmpty ? const ['phone'] : feeds,
      showRadioName: j['showRadioName'] == true,
      countedOnce: j['countedOnce'] == true,
    );
  }
}

/// An observer whose login token names one of the person's radios as its owner: only an offer until the person says yes.
class ObserverOffer {
  final String key;
  final String? name, iata;
  final String offeredByKey;
  final String? offeredByName;
  final DateTime? firstSeenAt, lastSeenAt;
  const ObserverOffer({required this.key, this.name, this.iata, required this.offeredByKey, this.offeredByName, this.firstSeenAt, this.lastSeenAt});

  /// The offer's name, else the start and end of its key (as the site shows it).
  String get label => name ?? shortKey(key);

  /// The radio that named the person, by name, else by key.
  String get radioLabel => offeredByName ?? shortKey(offeredByKey);

  static ObserverOffer? tryParse(Object? j) {
    if (j is! Map) return null;
    final key = j['key'];
    if (key is! String || !_hex64.hasMatch(key)) return null;
    final by = j['offeredBy'] is Map ? j['offeredBy'] as Map : const {};
    final byKey = by['key'];
    return ObserverOffer(
      key: key.toLowerCase(),
      name: _s(j['name'], 60),
      iata: _s(j['iata'], 8),
      offeredByKey: byKey is String ? byKey.toLowerCase() : '',
      offeredByName: _s(by['name'], 60),
      firstSeenAt: _time(j['firstSeenAt']),
      lastSeenAt: _time(j['lastSeenAt']),
    );
  }
}

/// `abcd1234…ef90`, like the website.
String shortKey(String k) => k.length <= 12 ? k : '${k.substring(0, 8)}…${k.substring(k.length - 4)}';

class PersonObservers {
  final List<PersonObserver> observers;
  final List<ObserverOffer> offers;
  const PersonObservers(this.observers, this.offers);
  static const empty = PersonObservers([], []);

  static PersonObservers parse(Map<String, dynamic> j) => PersonObservers([
        if (j['observers'] is List)
          for (final o in j['observers'] as List) ?PersonObserver.tryParse(o),
      ], [
        if (j['offers'] is List)
          for (final o in j['offers'] as List) ?ObserverOffer.tryParse(o),
      ]);
}

/// The answer of `person-observer-offer`.
enum OfferOutcome { accepted, declined, already }

OfferOutcome parseOfferOutcome(Map<String, dynamic> j) {
  if (j['accepted'] == true) return OfferOutcome.accepted;
  if (j['declined'] == true) return OfferOutcome.declined;
  return OfferOutcome.already;
}
