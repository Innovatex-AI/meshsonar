// The account settings the app edits and the server mirrors: callsign, display name, anonymous drives, leaderboard opt-in
// (`GET/POST /api/cmh/driver-settings`, capability `driverSettings`, contract meshsonar-infra
// docs/planning/build-66-settings-contract.md). Same rules as the privacy zones: an edit is on disk before anything else
// happens and is pending until the server acknowledges it; a pending edit WINS over the server's value; with nothing pending
// the server's value replaces the phone's (the person may have changed it on the website). Older servers (no capability)
// keep working: the rows are hidden and nothing is sent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/driver_settings.dart';
import '../core/privacy_zones.dart' show ZoneScope;
import 'privacy_zones_controller.dart' show ZoneSupport;

/// Where the pending edits and the last server answer are kept.
abstract class DriverSettingsStore {
  Future<Map<String, dynamic>?> load();
  Future<void> save(Map<String, dynamic> json);
}

class MemoryDriverSettingsStore implements DriverSettingsStore {
  Map<String, dynamic>? json;
  @override
  Future<Map<String, dynamic>?> load() async => json;
  @override
  Future<void> save(Map<String, dynamic> j) async => json = j;
}

class FileDriverSettingsStore implements DriverSettingsStore {
  final File file;
  FileDriverSettingsStore(this.file);
  @override
  Future<Map<String, dynamic>?> load() async {
    try {
      if (!await file.exists()) return null;
      final j = jsonDecode(await file.readAsString());
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(Map<String, dynamic> j) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(j), flush: true);
    await tmp.rename(file.path);
  }
}

enum SettingsSyncStatus { idle, syncing, synced, waitingForKey, offline, unsupported, rejected }

class DriverSettingsController extends ChangeNotifier {
  final DriverSettingsStore store;
  final String? Function() driverKey;
  final CmatClient Function() client;
  final ZoneSupport Function() support;

  DriverSettingsController({required this.store, required this.driverKey, required this.client, required this.support});

  DriverSettings? _server;
  final Map<SettingField, Object?> _pending = {};
  bool _loaded = false;
  bool _disposed = false;
  bool _again = false;
  Future<void>? _running;
  SettingsSyncStatus _status = SettingsSyncStatus.idle;
  SettingsSyncStatus get status => _status;

  /// The server's plain-words reason when [status] is [SettingsSyncStatus.rejected].
  String? error;

  /// The server said the leaderboard needs a website account (409 `needs_account`).
  bool needsAccount = false;

  bool get loaded => _loaded;
  bool get supported => support() == ZoneSupport.yes;
  bool get hasPending => _pending.isNotEmpty;
  DriverSettings? get server => _server;

  /// The leaderboard needs a website account: a key with no account cannot opt in.
  bool get leaderboardAvailable => !needsAccount;

  /// What the person sees: their pending edit, else the server's value, else the default.
  String? get callsign => _pending.containsKey(SettingField.callsign) ? _pending[SettingField.callsign] as String? : _server?.callsign;
  String? get display => _pending.containsKey(SettingField.display) ? _pending[SettingField.display] as String? : _server?.display;
  bool get anonymous => _pending.containsKey(SettingField.anonymous) ? _pending[SettingField.anonymous] == true : (_server?.anonymous ?? false);
  bool get leaderboardOptIn =>
      _pending.containsKey(SettingField.leaderboardOptIn) ? _pending[SettingField.leaderboardOptIn] == true : (_server?.leaderboardOptIn ?? false);

  Future<void> load() async {
    if (_loaded) return;
    final j = await store.load();
    if (j != null) {
      _server = DriverSettings.tryParse({'settings': j['server']});
      final p = j['pending'];
      if (p is Map) {
        for (final f in SettingField.values) {
          if (p.containsKey(f.name)) _pending[f] = p[f.name];
        }
      }
      needsAccount = j['needsAccount'] == true;
    }
    _loaded = true;
    _status = _compute();
    _notify();
  }

  SettingsSyncStatus _compute() {
    if (support() == ZoneSupport.no) return SettingsSyncStatus.unsupported;
    if ((driverKey() ?? '').isEmpty) return _pending.isEmpty ? SettingsSyncStatus.idle : SettingsSyncStatus.waitingForKey;
    return _pending.isEmpty ? SettingsSyncStatus.idle : SettingsSyncStatus.offline;
  }

  /// Sets a field. On disk before this returns; sent in the background.
  Future<void> set(SettingField f, Object? value) async {
    if (!_loaded) await load();
    final v = switch (f) {
      SettingField.callsign => value is String ? cleanCallsign(value) : null,
      SettingField.display => value is String ? cleanDisplayName(value) : null,
      _ => value == true,
    };
    if (_server != null && !_pending.containsKey(f) && _server!.valueOf(f) == (v ?? (f == SettingField.callsign || f == SettingField.display ? null : false))) return;
    _pending[f] = v;
    error = null;
    _status = _compute();
    _notify();
    await _save();
    unawaited(sync());
  }

  Future<void> _save() => store.save({
        if (_server != null) 'server': _server!.toJson(),
        'pending': {for (final e in _pending.entries) e.key.name: e.value},
        'needsAccount': needsAccount,
      });

  /// Sends what is waiting, or reads the server's values when nothing is. One run at a time.
  Future<SettingsSyncStatus> sync() async {
    if (!_loaded) await load();
    final running = _running;
    if (running != null) {
      _again = true;
      await running;
      return _status;
    }
    final done = () async {
      do {
        _again = false;
        await _pass();
      } while (_again && !_disposed);
    }();
    _running = done;
    try {
      await done;
    } finally {
      _running = null;
    }
    return _status;
  }

  Future<void> _pass() async {
    if (support() != ZoneSupport.yes) return _set(support() == ZoneSupport.no ? SettingsSyncStatus.unsupported : _compute());
    final key = driverKey();
    if (key == null || key.isEmpty) return _set(_compute());
    _set(SettingsSyncStatus.syncing);
    final sent = Map<SettingField, Object?>.of(_pending);
    try {
      final DriverSettings got;
      if (sent.isNotEmpty) {
        got = await client().setDriverSettings(key, {for (final e in sent.entries) e.key.name: e.value});
      } else {
        got = await client().driverSettings(key);
      }
      error = null;
      needsAccount = got.leaderboardOptIn == null && got.scope == ZoneScope.driver;
      _server = got;
      for (final e in sent.entries) {
        // Edited again while the request was in flight: the newer value stays pending and goes on the next pass.
        if (_pending.containsKey(e.key) && _pending[e.key] == e.value) _pending.remove(e.key);
      }
      if (_pending.isNotEmpty) _again = true;
      await _save();
      _set(_pending.isEmpty ? SettingsSyncStatus.synced : SettingsSyncStatus.offline);
    } on CmatException catch (e) {
      final s = e.status;
      if (s == 404 || s == 405) return _set(SettingsSyncStatus.unsupported);
      if (s == 409 && e.code == 'needs_account') {
        needsAccount = true;
        _pending.remove(SettingField.leaderboardOptIn); // all or nothing: the rest goes on the next pass
        if (_pending.isNotEmpty) _again = true;
        await _save();
        return _set(SettingsSyncStatus.idle);
      }
      if (s == 400 || s == 401 || s == 403) {
        error = s == 401 ? 'The server does not recognise this driver key.' : e.message;
        if (s == 400) {
          _pending.removeWhere((f, v) => sent.containsKey(f) && sent[f] == v); // would be refused forever
          await _save();
        }
        return _set(SettingsSyncStatus.rejected);
      }
      _set(_compute()); // offline, 429, 5xx: tried again at the next trigger
    } catch (_) {
      _set(_compute());
    }
  }

  void _set(SettingsSyncStatus s) {
    _status = s;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
