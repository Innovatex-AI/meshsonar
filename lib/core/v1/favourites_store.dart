// Favourites and watches of the Network tab (AZ-3.4), on the device only for now (contract 13.27: `favourite` is filled
// client-side; watches are the only server-side favourites, `/v1/me/watches`, AZ-3.8 adds the sync and push).
//
// - A favourite is a starred node or observer. Starred things are shown first in the Nodes lists, and "My nodes" (the
//   filter used across Network: Packets, the live map, Nodes) is the starred nodes plus the radios the person claimed.
// - A watch is stored in the shape of the contract's `Watch` (8.9: kind, target, region, events, channels, createdAt,
//   state) so AZ-3.8 can PUT each one to `/v1/me/watches/{kind}/{target}` as it is ([LocalWatch.putPath],
//   [LocalWatch.putBody]) and keep the server id in [LocalWatch.remoteId]. Nothing is sent anywhere yet, and there is
//   no push yet: the UI says so.
//
// One small JSON file next to the UI preferences, written atomically; memory only when there is no file (tests).
// Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:io';

/// What can be starred or watched.
enum FavouriteKind { node, observer }

String favouriteKindWire(FavouriteKind k) => k == FavouriteKind.node ? 'node' : 'observer';

FavouriteKind? favouriteKindOf(Object? s) => switch (s) {
      'node' => FavouriteKind.node,
      'observer' => FavouriteKind.observer,
      _ => null,
    };

/// One starred node or observer. [name] and [region] are what was shown when it was starred (a label for lists that
/// load before the server answers); the key or id is what counts.
class FavouriteRef {
  final FavouriteKind kind;

  /// Node: the 64-hex key (lowercase). Observer: its id (contract 1.3).
  final String id;
  final String? name, region;
  final DateTime addedAt;
  const FavouriteRef({required this.kind, required this.id, this.name, this.region, required this.addedAt});

  Map<String, dynamic> toJson() => {
        'kind': favouriteKindWire(kind),
        'id': id,
        if (name != null) 'name': name,
        if (region != null) 'region': region,
        'addedAt': addedAt.toUtc().toIso8601String(),
      };

  static FavouriteRef? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    final k = favouriteKindOf(j['kind']);
    if (k == null) return null;
    return FavouriteRef(
      kind: k,
      id: j['id'] as String,
      name: j['name'] is String ? j['name'] as String : null,
      region: j['region'] is String ? j['region'] as String : null,
      addedAt: DateTime.tryParse('${j['addedAt']}')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// The events a watch can ask for, by kind (contract 8.9).
const Map<String, List<String>> watchEventsByKind = {
  'node': ['silent', 'battery_low', 'clock_bad'],
  'observer': ['observer_offline'],
  'region': ['pulse'],
};

/// Plain words for a watch event.
String watchEventLabel(String e) => switch (e) {
      'silent' => 'Goes silent',
      'battery_low' => 'Battery low',
      'clock_bad' => 'Clock wrong',
      'observer_offline' => 'Goes offline',
      'pulse' => 'Something unusual',
      _ => e,
    };

/// A watch kept on the phone in the contract's `Watch` shape.
class LocalWatch {
  /// `node`, `observer` or `region`.
  final String kind;

  /// Node key, observer id or region slug.
  final String target;
  final String? region, name;
  final List<String> events;

  /// `email` / `push`; the app asks for push (AZ-3.8 turns it on).
  final List<String> channels;
  final DateTime createdAt;

  /// `ok`, `alerting`, `paused` once the server keeps it; `local` until then.
  final String state;

  /// The server's `w_...` id after a sync (AZ-3.8); null while it lives only on the phone.
  final String? remoteId;
  const LocalWatch({
    required this.kind,
    required this.target,
    this.region,
    this.name,
    required this.events,
    this.channels = const ['push'],
    required this.createdAt,
    this.state = 'local',
    this.remoteId,
  });

  String get id => '$kind:$target';

  /// `PUT /v1/me/watches/{kind}/{target}` (contract 8.9).
  String get putPath => 'me/watches/$kind/${Uri.encodeComponent(target)}';

  /// The PUT body (contract 8.9).
  Map<String, dynamic> get putBody => {'events': events, 'channels': channels, 'region': region};

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'target': target,
        if (region != null) 'region': region,
        if (name != null) 'name': name,
        'events': events,
        'channels': channels,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'state': state,
        if (remoteId != null) 'id': remoteId,
      };

  static LocalWatch? fromJson(Object? j) {
    if (j is! Map || j['kind'] is! String || j['target'] is! String) return null;
    final kind = j['kind'] as String;
    if (!watchEventsByKind.containsKey(kind)) return null;
    List<String> strs(Object? v) => [if (v is List) for (final e in v) if (e is String) e];
    final events = strs(j['events']);
    return LocalWatch(
      kind: kind,
      target: j['target'] as String,
      region: j['region'] is String ? j['region'] as String : null,
      name: j['name'] is String ? j['name'] as String : null,
      events: events.isEmpty ? watchEventsByKind[kind]! : events,
      channels: strs(j['channels']).isEmpty ? const ['push'] : strs(j['channels']),
      createdAt: DateTime.tryParse('${j['createdAt']}')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      state: j['state'] is String ? j['state'] as String : 'local',
      remoteId: j['id'] is String ? j['id'] as String : null,
    );
  }

  LocalWatch copyWith({List<String>? events, String? state, String? remoteId}) => LocalWatch(
      kind: kind,
      target: target,
      region: region,
      name: name,
      events: events ?? this.events,
      channels: channels,
      createdAt: createdAt,
      state: state ?? this.state,
      remoteId: remoteId ?? this.remoteId);
}

/// At most this many watches (the server's limit, contract 8.9 `maxWatches`).
const int maxLocalWatches = 25;

class NetworkFavouritesStore {
  final File? file;
  final DateTime Function() clock;
  List<FavouriteRef> _favs = const [];
  List<LocalWatch> _watches = const [];
  bool _loaded = false;
  Future<void>? _loading;
  Future<void> _last = Future<void>.value();
  final List<void Function()> _listeners = [];

  NetworkFavouritesStore({this.file, DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  bool get loaded => _loaded;
  List<FavouriteRef> get favourites => _favs;
  List<LocalWatch> get watches => _watches;

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    final f = file;
    if (f != null) {
      try {
        if (await f.exists()) {
          final j = jsonDecode(await f.readAsString());
          if (j is Map) {
            _favs = List.unmodifiable([if (j['favourites'] is List) for (final e in j['favourites'] as List) ?FavouriteRef.fromJson(e)]);
            _watches = List.unmodifiable([if (j['watches'] is List) for (final e in j['watches'] as List) ?LocalWatch.fromJson(e)]);
          }
        }
      } catch (_) {
        _favs = const [];
        _watches = const [];
      }
    }
    _loaded = true;
    _notify();
  }

  static String _norm(FavouriteKind k, String id) => k == FavouriteKind.node ? id.toLowerCase() : id;

  bool isFavourite(FavouriteKind kind, String id) {
    final i = _norm(kind, id);
    return _favs.any((f) => f.kind == kind && f.id == i);
  }

  /// Starred node keys (lowercase).
  Set<String> get favouriteNodeKeys => {for (final f in _favs) if (f.kind == FavouriteKind.node) f.id};

  /// Starred observer ids.
  Set<String> get favouriteObserverIds => {for (final f in _favs) if (f.kind == FavouriteKind.observer) f.id};

  /// Stars or un-stars; returns the new state.
  Future<bool> toggleFavourite(FavouriteKind kind, String id, {String? name, String? region}) async {
    await load();
    final i = _norm(kind, id);
    final on = !isFavourite(kind, i);
    _favs = List.unmodifiable(on
        ? [FavouriteRef(kind: kind, id: i, name: name, region: region, addedAt: clock().toUtc()), ..._favs]
        : [for (final f in _favs) if (!(f.kind == kind && f.id == i)) f]);
    _notify();
    await _write();
    return on;
  }

  LocalWatch? watchOf(String kind, String target) {
    final t = kind == 'node' ? target.toLowerCase() : target;
    for (final w in _watches) {
      if (w.kind == kind && w.target == t) return w;
    }
    return null;
  }

  bool isWatched(String kind, String target) => watchOf(kind, target) != null;

  /// Adds or replaces a watch. Throws [StateError] at [maxLocalWatches] (the server's limit) for a new one.
  Future<LocalWatch> setWatch(String kind, String target, {String? region, String? name, List<String>? events}) async {
    await load();
    if (!watchEventsByKind.containsKey(kind)) throw ArgumentError.value(kind, 'kind');
    final t = kind == 'node' ? target.toLowerCase() : target;
    final old = watchOf(kind, t);
    if (old == null && _watches.length >= maxLocalWatches) throw StateError('You can watch up to $maxLocalWatches things.');
    final allowed = watchEventsByKind[kind]!;
    final ev = [for (final e in events ?? allowed) if (allowed.contains(e)) e];
    final w = old?.copyWith(events: ev.isEmpty ? allowed : ev) ??
        LocalWatch(kind: kind, target: t, region: region, name: name, events: ev.isEmpty ? allowed : ev, createdAt: clock().toUtc());
    _watches = List.unmodifiable([w, for (final x in _watches) if (x.id != w.id) x]);
    _notify();
    await _write();
    return w;
  }

  Future<void> removeWatch(String kind, String target) async {
    await load();
    final t = kind == 'node' ? target.toLowerCase() : target;
    _watches = List.unmodifiable([for (final w in _watches) if (!(w.kind == kind && w.target == t)) w]);
    _notify();
    await _write();
  }

  Future<void> _write() {
    final f = file;
    if (f == null) return Future.value();
    final body = jsonEncode({
      'version': 1,
      'favourites': [for (final e in _favs) e.toJson()],
      'watches': [for (final w in _watches) w.toJson()],
    });
    final next = _last.then((_) async {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(f.path);
    });
    _last = next.then<void>((_) {}, onError: (_) {});
    return next;
  }
}

/// "My nodes" (the filter used across Network): the starred node keys plus the person's claimed radios. A hop prefix
/// matches when it starts one of those keys (MeshCore hops are 1 to 3 byte prefixes of the key).
class MyNodes {
  final Set<String> keys;
  final Set<String> observerIds;
  const MyNodes({this.keys = const {}, this.observerIds = const {}});

  static const MyNodes empty = MyNodes();

  bool get isEmpty => keys.isEmpty && observerIds.isEmpty;

  bool hasKey(String? key) => key != null && keys.contains(key.toLowerCase());

  /// True when [prefix] (2, 4 or 6 hex) is the start of one of my node keys.
  bool matchesPrefix(String prefix) {
    final p = prefix.toLowerCase();
    if (p.isEmpty) return false;
    for (final k in keys) {
      if (k.startsWith(p)) return true;
    }
    return false;
  }
}
