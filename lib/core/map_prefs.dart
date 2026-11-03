// The map's own remembered choices, kept apart from the big Settings object so a map change never touches the upload/engine
// settings code. Pure Dart: the file is read and written through the two callbacks the platform hands in
// (lib/platform/map_prefs_store.dart); tests use none and get plain in-memory preferences.
//
//   headingUp       the map turns so the direction of travel is up (default off: north-up).
//   autoResumeSec   a map the person moved re-centres by itself after this many seconds without a touch; 0 = only the button.
//   zoomBySpeed     zoom out gently at highway speed (default off: the zoom stays where the person put it).
//   healthOverlay   the small "Map and GPS health" readout on the map (Settings > Diagnostics).
//   layers          per map page (`drive`, later `analyze`): which layers are on or off, the Pings colour mode, and the network
//                   coverage options (colour by, detail, window, source). See [LayerPrefs]. Drive plan 7.2 (fix F11).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ChangeNotifier, immutable, mapEquals;

/// The page-config ids [MapPrefs.layerPrefs] is kept under.
const String kDriveLayerPage = 'drive';

/// What one map page remembers about its layers (Drive plan 7.2): only choices the person made. A layer with no entry in
/// [toggles] takes the registry default, so a layer added later arrives with its own default instead of "off".
///
/// NOT remembered, by design: the filter drawer, the timeline position (always Live on launch) and the selection.
@immutable
class LayerPrefs {
  /// Layer id to on/off, for layers the person has switched.
  final Map<String, bool> toggles;

  /// Layer id to mode (`pings`: `snr` | `result`).
  final Map<String, String> modes;

  /// Network coverage options, as the enum names / wire words; null = default (Best SNR, Auto detail, All, All).
  final String? colorBy;

  /// Pinned H3 resolution 7..11, null = Auto.
  final int? res;
  final String? since;
  final String? source;
  const LayerPrefs({this.toggles = const {}, this.modes = const {}, this.colorBy, this.res, this.since, this.source});

  static const LayerPrefs empty = LayerPrefs();

  bool get isEmpty => toggles.isEmpty && modes.isEmpty && colorBy == null && res == null && since == null && source == null;

  LayerPrefs copyWith({
    Map<String, bool>? toggles,
    Map<String, String>? modes,
    String? colorBy,
    bool clearColorBy = false,
    int? res,
    bool clearRes = false,
    String? since,
    bool clearSince = false,
    String? source,
    bool clearSource = false,
  }) => LayerPrefs(
    toggles: toggles ?? this.toggles,
    modes: modes ?? this.modes,
    colorBy: clearColorBy ? null : (colorBy ?? this.colorBy),
    res: clearRes ? null : (res ?? this.res),
    since: clearSince ? null : (since ?? this.since),
    source: clearSource ? null : (source ?? this.source),
  );

  Map<String, Object?> toJson() => {
    if (toggles.isNotEmpty) 'on': {for (final e in (toggles.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) e.key: e.value},
    if (modes.isNotEmpty) 'mode': {for (final e in (modes.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) e.key: e.value},
    if (colorBy != null) 'color_by': colorBy,
    if (res != null) 'res': res,
    if (since != null) 'since': since,
    if (source != null) 'source': source,
  };

  /// Tolerant: anything of the wrong shape is ignored (a damaged or future file leaves the defaults).
  static LayerPrefs fromJson(Object? j) {
    if (j is! Map) return empty;
    Map<String, T> typed<T>(Object? m) => m is Map ? {for (final e in m.entries) if (e.key is String && e.value is T) e.key as String: e.value as T} : <String, T>{};
    final r = j['res'];
    return LayerPrefs(
      toggles: typed<bool>(j['on']),
      modes: typed<String>(j['mode']),
      colorBy: j['color_by'] is String ? j['color_by'] as String : null,
      res: r is int && r >= 7 && r <= 11 ? r : null,
      since: j['since'] is String ? j['since'] as String : null,
      source: j['source'] is String ? j['source'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LayerPrefs &&
      mapEquals(other.toggles, toggles) &&
      mapEquals(other.modes, modes) &&
      other.colorBy == colorBy &&
      other.res == res &&
      other.since == since &&
      other.source == source;
  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(toggles.entries.map((e) => '${e.key}=${e.value}')), Object.hashAllUnordered(modes.entries.map((e) => '${e.key}=${e.value}')), colorBy, res, since, source);
}

class MapPrefs extends ChangeNotifier {
  MapPrefs({this.read, this.write});

  /// The shared instance the app uses; opened by the platform at start (see openSharedMapPrefs).
  static final MapPrefs shared = MapPrefs();

  Future<String?> Function()? read;
  Future<void> Function(String json)? write;

  bool _headingUp = false;
  int _autoResumeSec = 10;
  bool _zoomBySpeed = false;
  bool _healthOverlay = false;
  final Map<String, LayerPrefs> _layers = {};
  bool _loaded = false;
  Future<void>? _loading;

  bool get headingUp => _headingUp;
  int get autoResumeSec => _autoResumeSec;
  bool get zoomBySpeed => _zoomBySpeed;
  bool get healthOverlay => _healthOverlay;
  bool get loaded => _loaded;

  /// The remembered layer choices of map page [pageId] (read synchronously: the file is loaded before the first frame, see
  /// openSharedMapPrefs in main). [LayerPrefs.empty] when nothing was chosen.
  LayerPrefs layerPrefs(String pageId) => _layers[pageId] ?? LayerPrefs.empty;

  /// Remembers [p] for [pageId]; an empty one forgets the page ("Reset layers").
  void setLayerPrefs(String pageId, LayerPrefs p) {
    if (p == layerPrefs(pageId)) return;
    p.isEmpty ? _layers.remove(pageId) : _layers[pageId] = p;
    notifyListeners();
    unawaited(_save());
  }

  set headingUp(bool v) => _set(() => _headingUp = v, _headingUp != v);
  set autoResumeSec(int v) => _set(() => _autoResumeSec = v.clamp(0, 600), _autoResumeSec != v.clamp(0, 600));
  set zoomBySpeed(bool v) => _set(() => _zoomBySpeed = v, _zoomBySpeed != v);
  set healthOverlay(bool v) => _set(() => _healthOverlay = v, _healthOverlay != v);

  void _set(void Function() apply, bool changed) {
    if (!changed) return;
    apply();
    notifyListeners();
    unawaited(_save());
  }

  Map<String, Object?> toJson() => {
    'heading_up': _headingUp,
    'auto_resume_sec': _autoResumeSec,
    'zoom_by_speed': _zoomBySpeed,
    'health_overlay': _healthOverlay,
    if (_layers.isNotEmpty) 'layers': {for (final e in _layers.entries) e.key: e.value.toJson()},
  };

  void applyJson(Object? j) {
    if (j is! Map) return;
    if (j['heading_up'] is bool) _headingUp = j['heading_up'] as bool;
    if (j['auto_resume_sec'] is int) _autoResumeSec = (j['auto_resume_sec'] as int).clamp(0, 600);
    if (j['zoom_by_speed'] is bool) _zoomBySpeed = j['zoom_by_speed'] as bool;
    if (j['health_overlay'] is bool) _healthOverlay = j['health_overlay'] as bool;
    final ls = j['layers'];
    if (ls is Map) {
      _layers.clear();
      for (final e in ls.entries) {
        if (e.key is! String) continue;
        final p = LayerPrefs.fromJson(e.value);
        if (!p.isEmpty) _layers[e.key as String] = p;
      }
    }
  }

  /// Reads the saved choices once (a missing or damaged file leaves the defaults).
  Future<void> load() => _loading ??= () async {
    try {
      final s = await read?.call();
      if (s != null && s.isNotEmpty) {
        applyJson(jsonDecode(s));
        notifyListeners();
      }
    } catch (_) {
      // defaults
    }
    _loaded = true;
  }();

  Future<void> _save() async {
    try {
      await write?.call(jsonEncode(toJson()));
    } catch (_) {
      // a read-only disk: the choice holds for this session
    }
  }
}
