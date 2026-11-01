// The map's own remembered choices, kept apart from the big Settings object so a map change never touches the upload/engine
// settings code. Pure Dart: the file is read and written through the two callbacks the platform hands in
// (lib/platform/map_prefs_store.dart); tests use none and get plain in-memory preferences.
//
//   headingUp       the map turns so the direction of travel is up (default off: north-up).
//   autoResumeSec   a map the person moved re-centres by itself after this many seconds without a touch; 0 = only the button.
//   zoomBySpeed     zoom out gently at highway speed (default off: the zoom stays where the person put it).
//   healthOverlay   the small "Map and GPS health" readout on the map (Settings > Diagnostics).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ChangeNotifier;

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
  bool _loaded = false;
  Future<void>? _loading;

  bool get headingUp => _headingUp;
  int get autoResumeSec => _autoResumeSec;
  bool get zoomBySpeed => _zoomBySpeed;
  bool get healthOverlay => _healthOverlay;
  bool get loaded => _loaded;

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
  };

  void applyJson(Object? j) {
    if (j is! Map) return;
    if (j['heading_up'] is bool) _headingUp = j['heading_up'] as bool;
    if (j['auto_resume_sec'] is int) _autoResumeSec = (j['auto_resume_sec'] as int).clamp(0, 600);
    if (j['zoom_by_speed'] is bool) _zoomBySpeed = j['zoom_by_speed'] as bool;
    if (j['health_overlay'] is bool) _healthOverlay = j['health_overlay'] as bool;
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
