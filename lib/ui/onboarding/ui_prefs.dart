// Small UI-only preferences kept outside Settings (so lib/core/api.dart stays unchanged):
// whether the first-run intro has been seen, and drive names the user typed on this phone.
//
// Drive names: since 0.3.0 a rename is saved in the drive itself (DriveStore.renameSession), so exports and uploads
// carry it. Names typed under 0.2.x lived only here; they are moved into the drives once, then forgotten here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../app/app_state.dart';
import '../../app/drive_context_hook.dart' show collectionDisclosureVersion, collectionDisclosedKey;

class UiPrefs extends ChangeNotifier {
  bool _onboardingSeen;
  bool _telemetryDisclosed;

  /// The shell tab last open (AppTab.name), so the app comes back where the person left it. Null = never chosen.
  String? _lastTab;

  /// The collection disclosure version last seen (0 = never; 1 = the packet-header-only sheet of <= 0.19).
  int _disclosedVersion;
  final Map<String, String> _labels;
  bool _loaded;

  /// [telemetryDisclosed] defaults to true so tests and file-less runs never open the disclosure sheet.
  UiPrefs({bool seen = false, Map<String, String>? labels, bool telemetryDisclosed = true})
      : _onboardingSeen = seen,
        // ignore: prefer_initializing_formals
        _telemetryDisclosed = telemetryDisclosed,
        _disclosedVersion = telemetryDisclosed ? collectionDisclosureVersion : 0,
        _labels = {...?labels},
        _loaded = true;

  UiPrefs._unloaded()
      : _onboardingSeen = false,
        _telemetryDisclosed = false,
        _disclosedVersion = 0,
        _labels = {},
        _loaded = false;

  bool get loaded => _loaded;

  /// The shell tab last open (an AppTab name), or null.
  String? get lastTab => _lastTab;

  Future<void> setLastTab(String name) async {
    if (_lastTab == name) return;
    _lastTab = name;
    await persist();
  }
  bool get onboardingSeen => _onboardingSeen;

  /// True once the person has seen the CURRENT disclosure sheet (whatever they chose). Since stream 7 that is the
  /// version-2 sheet listing every collection category: someone who only saw the packet-header sheet (version 1,
  /// `telemetry_disclosed` alone) sees the new one once, and the app shell opens it while this is false.
  bool get telemetryDisclosed => _disclosedVersion >= collectionDisclosureVersion;

  /// The packet-header disclosure (version 1 or later) was seen: packet headers may flow as before.
  bool get packetHeadersDisclosed => _telemetryDisclosed;

  /// The regions the person switched to by hand, most recent first, at most [kRecentRegionsMax] (region codes).
  final List<String> _recentRegions = [];
  List<String> get recentRegions => List.unmodifiable(_recentRegions);
  static const int kRecentRegionsMax = 3;

  Future<void> pushRecentRegion(String code) async {
    if (_recentRegions.isNotEmpty && _recentRegions.first == code) return;
    _recentRegions
      ..remove(code)
      ..insert(0, code);
    while (_recentRegions.length > kRecentRegionsMax) {
      _recentRegions.removeLast();
    }
    notifyListeners();
    await persist();
  }

  /// The disclosure version last seen.
  int get disclosedVersion => _disclosedVersion;

  Future<void> markTelemetryDisclosed() async {
    if (_telemetryDisclosed && telemetryDisclosed) return;
    _telemetryDisclosed = true; // the v2 sheet lists packet headers too
    _disclosedVersion = collectionDisclosureVersion;
    notifyListeners();
    await persist();
  }

  /// Name typed on this phone for a drive, if any.
  String? labelFor(String sessionId) => _labels[sessionId];

  /// All phone-only names (session id → name).
  Map<String, String> get labels => Map.unmodifiable(_labels);

  Future<void> load() async {}

  Future<void> markOnboardingSeen() async {
    if (_onboardingSeen) return;
    _onboardingSeen = true;
    notifyListeners();
    await persist();
  }

  /// Empty or null clears the name.
  Future<void> setLabel(String sessionId, String? label) async {
    final v = label?.trim() ?? '';
    if (v.isEmpty) {
      _labels.remove(sessionId);
    } else {
      _labels[sessionId] = v;
    }
    notifyListeners();
    await persist();
  }

  Future<void> forget(String sessionId) async {
    if (_labels.remove(sessionId) != null) {
      notifyListeners();
      await persist();
    }
  }

  /// Saves. The in-memory version only keeps values.
  Future<void> persist() async {}

  Map<String, dynamic> toJson() => {
        'onboarding_seen': _onboardingSeen,
        'telemetry_disclosed': _telemetryDisclosed,
        if (_lastTab != null) 'last_tab': _lastTab,
        if (_disclosedVersion > 0) collectionDisclosedKey: _disclosedVersion,
        if (_recentRegions.isNotEmpty) 'recent_regions': _recentRegions,
        'labels': _labels,
      };
}

/// JSON file next to settings.json. A damaged or missing file means "first run" with no names.
class FileUiPrefs extends UiPrefs {
  final File file;
  Future<void>? _loading;
  FileUiPrefs(this.file) : super._unloaded();

  @override
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      if (await file.exists()) {
        final j = jsonDecode(await file.readAsString());
        if (j is Map) {
          _onboardingSeen = j['onboarding_seen'] == true;
          _telemetryDisclosed = j['telemetry_disclosed'] == true;
          final lt = j['last_tab'];
          _lastTab = lt is String ? lt : null;
          final v = j[collectionDisclosedKey];
          _disclosedVersion = v is num ? v.toInt() : (_telemetryDisclosed ? 1 : 0);
          final rr = j['recent_regions'];
          if (rr is List) _recentRegions..clear()..addAll([for (final c in rr) if (c is String) c].take(UiPrefs.kRecentRegionsMax));
          final l = j['labels'];
          if (l is Map) l.forEach((k, v) => _labels['$k'] = '$v');
        }
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist() async {
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(toJson()), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Only costs the intro showing again or a drive name; never block the app on it.
    }
  }
}

final Expando<UiPrefs> _prefs = Expando('uiPrefs');

/// The UiPrefs for this app. With no prefs file (tests, or no file system) the intro counts as already seen.
UiPrefs uiPrefsFor(AppState state) {
  var p = _prefs[state];
  if (p == null) {
    final f = state.services.uiPrefsFile;
    p = f == null ? UiPrefs(seen: true) : FileUiPrefs(f);
    _prefs[state] = p;
    final prefs = p;
    prefs.load().then((_) => migrateLegacyLabels(state, prefs));
  }
  return p;
}

/// Moves names typed under 0.2.x (kept only in this file) into the drives, so they're exported and uploaded too.
/// A name whose drive is gone is dropped; one that can't be written now is kept and tried again next launch.
Future<void> migrateLegacyLabels(AppState state, UiPrefs prefs) async {
  final names = prefs.labels;
  if (names.isEmpty) return;
  for (final e in names.entries) {
    try {
      final ses = await state.services.store.session(e.key);
      if (ses != null && ses.label != e.value) {
        if (!await state.renameSession(e.key, e.value, quiet: true)) continue;
      }
      await prefs.forget(e.key);
    } catch (_) {}
  }
}

/// Use [prefs] for this app (tests: e.g. `UiPrefs()` to see the first-run intro).
void attachUiPrefs(AppState state, UiPrefs prefs) => _prefs[state] = prefs;

/// Display name for a drive: the name typed on this phone, else the label it was recorded with.
String? driveLabel(AppState state, String sessionId, String? recorded) =>
    uiPrefsFor(state).labelFor(sessionId) ?? recorded;
