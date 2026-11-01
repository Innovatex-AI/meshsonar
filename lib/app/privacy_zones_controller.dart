// The privacy zones as the app holds them: the list the person edits (saved on the phone at once), and the sync with the
// server's `driver-privacy` endpoint. Rules (design decision D9, lazy key): the editor works with no driver key, no signal
// and a server that has not been asked yet; every change is on disk before anything else happens and is marked pending;
// it is sent as soon as there is a key, a server that takes it and a connection. While a change is pending the phone's
// list wins; with nothing pending the server's list replaces the phone's (the person may have edited it on the website).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/privacy_zone_store.dart';
import '../core/privacy_zones.dart';

/// Whether the server takes zones (`site-config.capabilities.driverPrivacy`).
enum ZoneSupport { unknown, yes, no }

enum ZoneSyncStatus {
  /// Nothing has been tried yet this run.
  idle,
  syncing,

  /// The server holds exactly what the phone shows.
  synced,

  /// Changes are saved here and wait for a driver key.
  waitingForKey,

  /// Changes are saved here and wait for a connection (or for the server to answer).
  offline,

  /// This server has no privacy-zone endpoint. Zones stay on this phone only.
  unsupported,

  /// The server refused the list (a plain-words reason is in [PrivacyZonesController.error]) or the key.
  rejected,
}

class PrivacyZonesController extends ChangeNotifier {
  final PrivacyZoneStore store;
  final String? Function() driverKey;
  final CmatClient Function() client;
  final ZoneSupport Function() support;
  final DateTime Function() clock;

  PrivacyZonesController({
    required this.store,
    required this.driverKey,
    required this.client,
    required this.support,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  PrivacyZoneState _state = const PrivacyZoneState();
  PrivacyZoneState get state => _state;
  List<PrivacyZone> get zones => _state.zones;
  int get trimM => _state.trimM;
  bool get pending => _state.pending;
  bool _loaded = false;
  bool get loaded => _loaded;

  ZoneSyncStatus _status = ZoneSyncStatus.idle;
  ZoneSyncStatus get status => _status;

  /// The server's reason when [status] is [ZoneSyncStatus.rejected].
  String? error;
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  Future<void> load() async {
    if (_loaded) return;
    _state = await store.load();
    _loaded = true;
    _status = _compute(idle: true);
    _notify();
  }

  /// The status implied by what is known without asking the server.
  ZoneSyncStatus _compute({bool idle = false}) {
    if (support() == ZoneSupport.no) return ZoneSyncStatus.unsupported;
    if ((driverKey() ?? '').isEmpty) return _state.pending || _state.zones.isNotEmpty ? ZoneSyncStatus.waitingForKey : ZoneSyncStatus.idle;
    if (_state.pending) return ZoneSyncStatus.offline;
    return idle ? ZoneSyncStatus.idle : ZoneSyncStatus.synced;
  }

  /// Replaces the zones (at most [kZoneMax], every one normalised: 4 decimals, longitude wrapped, radius 50-5000 m). On
  /// disk before this returns; sending is attempted in the background.
  Future<void> setZones(List<PrivacyZone> zones) async {
    final clean = [
      for (final z in zones.take(kZoneMax)) PrivacyZone.normalized(lat: z.lat, lon: z.lon, radiusM: z.radiusM, label: z.label),
    ];
    if (listEquals(clean, _state.zones)) return;
    await _commit(_state.copyWith(zones: clean, pending: true));
  }

  Future<void> setTrim(int metres) async {
    final t = metres.clamp(0, kTrimMaxM);
    if (t == _state.trimM) return;
    await _commit(_state.copyWith(trimM: t, pending: true));
  }

  Future<void> _commit(PrivacyZoneState next) async {
    _state = next;
    error = null;
    _status = _compute();
    _notify();
    await store.save(next);
    unawaited(sync());
  }

  /// Sends what is waiting, or (nothing waiting) reads the server's list. Safe to call at any time and as often as wanted:
  /// one run at a time, a change made during a run is sent by the next pass. Returns the status it ended in.
  Future<ZoneSyncStatus> sync() async {
    if (!_loaded) await load();
    final running = _running;
    if (running != null) {
      _again = true; // the pass in flight will go round once more, with whatever changed since it started
      await running;
      return _status;
    }
    final done = _loop();
    _running = done;
    try {
      await done;
    } finally {
      _running = null;
    }
    return _status;
  }

  Future<void> _loop() async {
    do {
      _again = false;
      await _pass();
    } while (_again && !_disposed);
  }

  Future<void> _pass() async {
    if (support() == ZoneSupport.no) return _set(ZoneSyncStatus.unsupported);
    final key = driverKey();
    if (key == null || key.isEmpty) return _set(_state.pending || _state.zones.isNotEmpty ? ZoneSyncStatus.waitingForKey : ZoneSyncStatus.idle);
    _set(ZoneSyncStatus.syncing);
    final sent = _state;
    try {
      final DriverPrivacy got;
      if (sent.pending) {
        got = await client().setDriverPrivacy(key, zones: sent.zones, trimM: sent.trimM);
      } else {
        got = await client().driverPrivacy(key);
      }
      error = null;
      if (_state.pending && !identical(_state, sent)) {
        // Edited while the request was in flight: what was sent is stale; send the newer list on the next pass.
        _again = true;
        return _set(ZoneSyncStatus.offline);
      }
      _state = PrivacyZoneState(zones: got.zones, trimM: got.trimM, pending: false, scope: got.scope, syncedAt: clock());
      await store.save(_state);
      _set(ZoneSyncStatus.synced);
    } on CmatException catch (e) {
      final s = e.status;
      if (s == 404 || s == 405) {
        return _set(ZoneSyncStatus.unsupported); // an older server answers 404 for the endpoint
      }
      if (s == 400 || s == 401 || s == 403) {
        error = s == 401 ? 'The server does not recognise this driver key.' : e.message;
        return _set(ZoneSyncStatus.rejected);
      }
      _set(_state.pending ? ZoneSyncStatus.offline : ZoneSyncStatus.idle); // offline, 429, 5xx: tried again at the next trigger
    } catch (_) {
      _set(_state.pending ? ZoneSyncStatus.offline : ZoneSyncStatus.idle);
    }
  }

  void _set(ZoneSyncStatus s) {
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
