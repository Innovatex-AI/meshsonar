// App-wide state: settings, radio connection, the running drive, live stats and sync.
// A plain ChangeNotifier (no state-management packages). The UI reads it through AppScope.
//
// Save-first rule: every ping the engine finishes is appended to the DriveStore before anything else
// happens to it. If a write fails, the ping stays in memory and is retried on the next ping and at Stop,
// and the user is told. Sync failures never touch stored pings.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/antenna_profile.dart';
import '../core/api.dart';
import '../core/coverage_query.dart';
import '../core/diagnostics.dart';
import '../core/drive_context.dart' show stripContextCategories;
import '../core/drive_context_session.dart';
import '../core/drive_env_cache.dart';
import '../core/drive_store.dart' show closeOrphanedSessions;
import '../core/heard.dart';
import '../core/model.dart';
import '../core/etag_client.dart';
import '../core/idle_region_watcher.dart';
import '../core/region_cache.dart';
import '../core/region_lookup.dart';
import '../core/region_pick.dart';
import '../core/region_preset.dart';
import '../core/region_tracker.dart';
import '../core/repeater_directory.dart';
import '../core/repeater_sync.dart';
import '../core/startup_location.dart';
import '../core/report_body.dart';
import '../core/server_url.dart';
import '../core/telemetry.dart';
import '../core/telemetry_uploader.dart';
import '../core/phone_sensors.dart';
import '../core/units.dart';
import '../platform/app_lifecycle_bridge.dart';
import '../radio/radio_api.dart';
import 'drive_context_hook.dart';
import 'messages.dart';
import 'services.dart';

enum RadioKind { none, bluetooth, simulator }

/// What became of a problem report the person sent.
class ProblemReportOutcome {
  final bool sent;

  /// The server refused the report as written (400): sending it again won't help, editing it might.
  final bool rejected;

  /// Plain-language result to show.
  final String message;
  const ProblemReportOutcome({required this.sent, required this.message, this.rejected = false});
}

class AppState extends ChangeNotifier {
  final AppServices services;
  AppState(this.services);

  // ---------- settings ----------
  Settings _settings = const Settings();
  Settings get settings => _settings;

  /// Distance/speed/height formatting for the current Units setting (Auto follows the phone's region).
  Units get units => Units.resolve(_settings.units, localeName: localeNameProvider(), overrides: _settings.unitOverrides);

  /// The device locale name for Auto units; tests replace it so results do not depend on the host Mac's region.
  static String? Function() localeNameProvider = () {
    try {
      return Platform.localeName;
    } catch (_) {
      return null;
    }
  };
  bool _loaded = false;
  bool get loaded => _loaded;

  CmatClient? _client;
  CmatClient get client {
    final url = Uri.tryParse(_settings.serverUrl) ?? Uri.parse(const Settings().serverUrl);
    if (_client == null || _client!.baseUrl != url) _client = services.cmatClientFactory(url);
    return _client!;
  }

  SyncService? _sync;
  CmatClient? _syncClient;
  SyncService get _syncService {
    final c = client;
    if (_sync == null || !identical(_syncClient, c)) {
      _syncClient = c;
      _sync = services.syncServiceFactory(c);
    }
    return _sync!;
  }

  bool get hasKey => (_settings.driverKey ?? '').isNotEmpty;
  bool get keyApproved => hasKey && _settings.keyStatus == DriverKeyStatus.approved;

  // ---------- drive weather (stream 7 WP6: lib/core/drive_env_cache.dart, lib/ui/report/drive_weather_section.dart) ----------
  DriveEnvCache? _driveEnvCache;

  /// The server looks up weather for uploaded drives, this driver key is approved and the weather category is on.
  bool get driveWeatherEnabled => (siteConfig?.driveEnv ?? false) && keyApproved && collectionOn('weather');

  /// Server weather for the uploaded drive [sessionId], from the on-disk cache while fresh. Throws [CmatException].
  Future<DriveEnvResult> driveWeather(String sessionId) {
    final key = _settings.driverKey;
    if (key == null || key.isEmpty) return Future.error(const CmatException('no driver key', status: 401));
    final rc = services.regionCache?.dir;
    final cache = _driveEnvCache ??= DriveEnvCache(
        dir: rc == null ? null : Directory('${rc.parent.path}${Platform.pathSeparator}drive_env'), clock: services.clock);
    return cache.get(sessionId, () => client.driveEnv(key, sessionId));
  }

  // ---------- region data disk cache (offline / as-of labels) ----------
  CachedBody? _siteConfigMeta;
  CachedBody? _coverageMeta;

  /// Loads [load] live and mirrors it into the region disk cache; when the live load fails, serves the cached copy
  /// (flagged offline). Rethrows only when there is nothing cached either. Without a cache it is a plain call.
  Future<({T value, CachedBody? meta})> _cachedFetch<T>(
      String key, Future<T> Function() load, String Function(T) encode, T? Function(String) decode) async {
    final cache = services.regionCache;
    if (cache == null) return (value: await load(), meta: null);
    Object? failure;
    T? live;
    final got = await cache.fetch(key, (etag) async {
      try {
        live = await load();
      } catch (e) {
        failure = e;
        rethrow;
      }
      return CacheFetch.fresh(encode(live as T));
    });
    if (got == null) throw failure ?? StateError('nothing cached for $key');
    if (!got.offline && live != null) return (value: live as T, meta: got);
    final cachedValue = decode(got.body);
    if (cachedValue == null) throw failure ?? StateError('cached $key unreadable');
    return (value: cachedValue, meta: got);
  }

  /// "Offline - as of 3h ago" when the coverage/preset on screen came from the disk cache because the live fetch
  /// failed; null when everything is live (or no cache is in use).
  String? get regionDataOfflineLabel {
    final m = (_coverageMeta?.offline ?? false) ? _coverageMeta : ((_siteConfigMeta?.offline ?? false) ? _siteConfigMeta : null);
    if (m != null) return asOfLabel(m.fetchedAt, services.clock(), offline: true);
    final wire = sharedEtagClient?.offlineSince; // a region panel was served from the on-disk ETag cache
    return wire == null ? null : asOfLabel(wire, services.clock(), offline: true);
  }

  // ---------- site config (region + radio preset) ----------
  SiteConfig? _siteConfig;

  /// The server's active region and its suggested radio preset, from `GET /api/cmh/site-config`. Null until the
  /// first fetch answers (or if it fails) — informational only, so Settings must keep working either way.
  SiteConfig? get siteConfig => _siteConfig;

  /// Fetches [siteConfig] once. Failures are swallowed quietly (logged, not shown) so the Server URL tile keeps
  /// working regardless of whether this server's `site-config` endpoint exists or answers. Called unawaited at
  /// startup and again whenever the server URL changes.
  Future<void> refreshSiteConfig() => _siteConfigLatest = _refreshSiteConfig();
  Future<void>? _siteConfigLatest; // the newest fetch: the launch repeater sync waits for it (delta capability)

  Future<void> _refreshSiteConfig() async {
    final server = _settings.serverUrl;
    try {
      final viewing = viewingRegion;
      final r = await _cachedFetch<SiteConfig>('siteconfig_${viewing?.code ?? 'default'}', () => _coverageClient(viewing).siteConfig(),
          siteConfigToJson, siteConfigFromJson);
      if (_settings.serverUrl != server) return; // the server changed again while this was in flight
      if (viewing?.code != viewingRegion?.code) return;
      _siteConfig = r.value;
      _siteConfigMeta = r.meta;
      notifyListeners();
    } catch (e) {
      _logError('Fetching site-config failed', e);
    }
  }

  // ---------- network coverage (the website's /coverage cells, network-wide) ----------
  PublicCoverage? _networkCoverage;
  CoverageQuery _coverageQuery = const CoverageQuery();
  int _coverageSeq = 0;
  bool _coverageLoading = false;
  bool _coverageFailed = false;

  /// True while the newest network-coverage request is in flight (the timeline slider's "loading" state).
  bool get networkCoverageLoading => _coverageLoading;

  /// True when the newest network-coverage request failed (cells already on screen, if any, are stale).
  bool get networkCoverageFailed => _coverageFailed;

  /// What the layer last asked for (res null = server default).
  CoverageQuery get coverageQuery => _coverageQuery;

  /// Network-wide measured coverage cells (`GET /api/cmh/public-coverage`) — the map's background "where hasn't
  /// this been driven" layer (see lib/ui/map/map_layers.dart's `networkCoverage`). Null until the first fetch
  /// answers.
  PublicCoverage? get networkCoverage => _networkCoverage;

  /// Fetches [networkCoverage] once. A failure never clears cells already on screen — stale coverage is still
  /// useful for "where hasn't this been driven", so it's kept rather than blanked on a network hiccup; failures
  /// are logged quietly, same as [refreshSiteConfig]. Called unawaited at startup and again whenever the server
  /// URL changes.
  Future<void> refreshNetworkCoverage({CoverageQuery? query}) async {
    final server = _settings.serverUrl;
    if (query != null) _coverageQuery = query;
    final q = _coverageQuery;
    final seq = ++_coverageSeq;
    _coverageLoading = true;
    notifyListeners();
    try {
      final viewing = viewingRegion;
      final until = q.until;
      final key = 'coverage_${viewing?.code ?? 'default'}_r${q.res ?? 'd'}_${q.since.name}_${q.source.name}'
          '${until == null ? '' : '_u${until.toUtc().millisecondsSinceEpoch ~/ 1000}'}';
      final r = await _cachedFetch<PublicCoverage>(
        key,
        () => _coverageClient(viewing).publicCoverage(
          res: q.res,
          // "Measured in the last X" is relative to the as-of instant when the timeline is scrubbed back.
          since: q.since.window == null ? null : (until ?? DateTime.now().toUtc()).subtract(q.since.window!),
          until: until,
          source: q.source.wire,
        ),
        publicCoverageToJson,
        publicCoverageFromJson,
      );
      if (seq != _coverageSeq) return; // a newer request (zoom/filter change) superseded this one
      if (_settings.serverUrl != server) return; // the server changed again while this was in flight
      if (viewing?.code != viewingRegion?.code) return; // the viewed region changed while this was in flight
      _networkCoverage = r.value;
      _coverageMeta = r.meta;
      _coverageLoading = false;
      _coverageFailed = false;
      notifyListeners();
    } catch (e) {
      _logError('Fetching network coverage failed', e);
      if (seq == _coverageSeq) {
        _coverageLoading = false;
        _coverageFailed = true;
        notifyListeners();
      }
    }
  }

  /// The client that reads coverage: the viewed region's own host when this app talks to the MeshSonar hub, else
  /// the configured server (a custom server keeps single-region behaviour).
  CmatClient _coverageClient(RegionIndexEntry? viewing) {
    if (viewing != null && isSameServer(_settings.serverUrl, defaultServerUrl)) {
      final u = Uri.tryParse(viewing.url);
      if (u != null && u.host.isNotEmpty) return services.cmatClientFactory(u);
    }
    return client;
  }

  // ---------- viewed region (the switcher) ----------
  /// Andy's rule (Oct 21): the app opens on the region the phone's GPS is in; the switcher lists every region; outside
  /// every region the nearest one shows. A manual pick wins until the person goes back to "follow my location".
  RegionIndexEntry? get viewingRegion {
    final idx = regionIndex;
    if (idx.isEmpty) return null;
    RegionIndexEntry? byCode(String? c) {
      if (c == null) return null;
      for (final r in idx) {
        if (r.code == c) return r;
      }
      return null;
    }

    final manual = byCode(_settings.regionManual);
    if (manual != null) return manual;
    final hold = byCode(_viewHoldCode);
    if (hold != null) return hold; // a different-preset border crossing waits for the person's answer
    if (_currentRegion != null) return _currentRegion;
    final f = _lastRegionFix;
    if (f != null) {
      final n = nearestRegion(idx, f.lat, f.lon);
      if (n != null) return n;
    }
    return byCode(_settings.regionLast) ?? idx.first;
  }

  /// True when the person picked the region (not following GPS).
  bool get viewingIsManual => _settings.regionManual != null && viewingRegion?.code == _settings.regionManual;

  /// Every region for the switcher: GPS region first, then nearest.
  List<RegionIndexEntry> get switcherRegions =>
      regionsForSwitcher(regionIndex, gpsRegion: _currentRegion, lat: _lastRegionFix?.lat, lon: _lastRegionFix?.lon);

  /// Picks [code] to view, or null to follow the phone's GPS region again.
  Future<void> setViewingRegion(String? code) =>
      updateSettings(code == null ? _settings.copyWith(clearRegionManual: true) : _settings.copyWith(regionManual: code));

  String? _viewCode;
  void _syncViewing() {
    final v = viewingRegion;
    if (v?.code == _viewCode) return;
    _viewCode = v?.code;
    _refreshSyncedNames();
    // The first-region fallback (nothing picked, never located) is not remembered: it is a guess, and remembering it
    // would hide the hub view (Stream 4) on the next launch without a fix.
    final guess = _settings.regionManual == null && _viewHoldCode == null && _currentRegion == null && _lastRegionFix == null;
    if (v != null && v.code != _settings.regionLast && !(guess && _settings.regionLast == null)) {
      _settings = _settings.copyWith(regionLast: v.code);
      unawaited(services.settingsStore.save(_settings).catchError((_) {}));
    }
    if (v != null) {
      unawaited(refreshNetworkCoverage());
      unawaited(refreshSiteConfig());
      unawaited(syncRepeaterLists(SyncTrigger.view));
    }
  }

  @override
  void notifyListeners() {
    if (_loaded) _syncViewing();
    super.notifyListeners();
  }

  // ---------- region awareness (live, local; GET /api/cmh/regions-index) ----------
  // The server already tags every ping's true region correctly at upload time regardless of connectivity — this
  // is purely live, in-app feedback: "which region is the phone physically in right now", for a badge on the
  // Drive screen and a one-shot notice on a border crossing mid-drive. bbox-only this pass (lib/core/
  // region_lookup.dart's regionAt).
  late final RegionIndexService _regionIndexService = RegionIndexService(
    fetch: () => client.regionsIndex(),
    cache: services.regionIndexCache ?? MemoryRegionIndexCache(),
  );

  /// Every region `regions-index` knows about: the on-disk cache before the first fetch answers, then whatever
  /// the most recent successful fetch returned. Empty before anything has ever loaded (first run, offline).
  List<RegionIndexEntry> get regionIndex => _regionIndexService.regions;

  /// True once [regionIndex] holds something (cache or a live fetch); false only on a first run with no cache
  /// and no connectivity yet. Drives the Drive screen's region badge: nothing to show before this is true.
  bool get regionIndexLoaded => _regionIndexService.everLoaded;

  /// True when [regionIndex] is the last-known cache rather than a fresh fetch — the live `regions-index` fetch
  /// most recently failed (offline, server hiccup). Region matching still runs off the stale cache; this only
  /// says it might be stale.
  bool get regionIndexStale => _regionIndexService.lastError != null;

  RegionIndexEntry? _currentRegion;

  /// Which MeshSonar region the phone is physically in right now (bbox-only match against [regionIndex]). Null
  /// with no GPS fix yet, or with a fix outside every known region's bbox — both real, expected states, not
  /// errors.
  RegionIndexEntry? get currentRegion => _currentRegion;

  GeoFix? _lastRegionFix;

  /// True once a GPS fix has ever been used to evaluate [currentRegion] (distinguishes "still locating" from
  /// "located, but outside coverage" — both show as [currentRegion] == null).
  bool get regionFixKnown => _lastRegionFix != null;

  /// Re-evaluates [currentRegion] for [fix] against [regionIndex]. A genuine crossing into a different *known*
  /// region while driving fires the one-shot notice (reusing [_say]/[takeNotice], the same mechanism the upload
  /// success/error banners use) — detection at startup or while idle updates the badge quietly, with no popup.
  void _updateRegion(GeoFix? fix, {bool live = true}) {
    if (fix == null) return;
    if (live) {
      // The region was seeded at launch from an old position (last-known on disk, or an OS-cached fix): the first live
      // fix re-seeds it, so opening the app somewhere else never reads as "you crossed a border" (no notice, no prompt).
      if (_regionSeededFromOld && _isLiveAge(fix)) {
        _regionSeededFromOld = false;
        _tracker.reset();
      }
      _notePhoneFix(fix);
    }
    // Older than [staleFixAge] (72 h): never moves the region (no switch, no notice, no preset prompt). It can still
    // centre the map as [phoneFix], labelled with its age.
    if (services.clock().toUtc().difference(fix.at.toUtc()) > staleFixAge) {
      notifyListeners();
      return;
    }
    _lastRegionFix = fix;
    final u = _tracker.update(regionIndex, fix.lat, fix.lon, fix.at);
    _regionNearEdge = u.nearEdge;
    _currentRegion = u.current;
    if (_loaded) _refreshSyncedNames();
    if (u.changed) {
      _viewHoldCode = null;
      final next = u.current;
      if (next != null && u.previous != null) unawaited(_onRegionChanged(u.previous!, next));
    }
    notifyListeners();
  }

  final RegionTracker _tracker = RegionTracker();
  bool _regionNearEdge = false;

  /// True when the last fix was within a few hundred metres of the current region's edge (the badge can hint
  /// "near the border"; the tracker already refuses to flap there).
  bool get regionNearEdge => _regionNearEdge;

  String? _viewHoldCode;
  RegionPresetPrompt? _presetPrompt;

  /// A pending "this region uses a different radio preset" question for the person; null when none. The UI shows
  /// a dialog (not while driving) and answers through [resolvePresetPrompt]. The radio is never changed by it.
  RegionPresetPrompt? get presetPrompt => _presetPrompt;

  /// Answer the prompt: [switchView] true = show the new region now (the person will change their radio themselves);
  /// false = keep showing the region they were in.
  void resolvePresetPrompt({required bool switchView}) {
    final p = _presetPrompt;
    if (p == null) return;
    _presetPrompt = null;
    if (switchView) _viewHoldCode = null;
    notifyListeners();
  }

  /// Genuine crossing into [next] from [prev] (the tracker has already debounced it). Same radio preset (or nothing
  /// to compare): tell the person and, when following GPS, the view switches by itself. Different preset: hold the
  /// view and ask. Nothing here ever touches the radio.
  Future<void> _onRegionChanged(RegionIndexEntry prev, RegionIndexEntry next) async {
    SiteConfig? sc;
    try {
      sc = (await _cachedFetch<SiteConfig>('siteconfig_${next.code}', () => _coverageClient(next).siteConfig(), siteConfigToJson, siteConfigFromJson)).value;
    } catch (e) {
      _logError('Fetching ${next.code} site-config for the border crossing failed', e);
    }
    if (_currentRegion?.code != next.code) return; // moved on again while this was in flight
    final radio = _selfInfo?.radio;
    final preset = sc?.radioPreset;
    final manual = _settings.regionManual != null;
    final differs = radio != null && preset != null && !presetMatchesRadio(preset, radio);
    if (!differs) {
      _say(manual ? 'Entered ${next.name}. Still viewing your chosen region.' : 'Entered ${next.name}. Now showing ${next.code}.');
    } else {
      if (!manual) _viewHoldCode = prev.code;
      _presetPrompt = RegionPresetPrompt(from: prev, to: next, preset: preset, radio: radio);
      _say('Entered ${next.name}. It uses a different radio preset; your radio was not changed.');
    }
    notifyListeners();
  }

  /// Loads the cached regions-index (if any), fetches the live one, and re-checks [currentRegion] against the
  /// best GPS fix available — all at startup, before any drive begins (the owner wants region awareness the
  /// moment the app opens, not only once a drive starts). Called unawaited by [init] and again whenever the
  /// server URL changes. Failures are quiet (logged, not shown): the badge just falls back to "no fix"/"no
  /// region" states, exactly like [refreshSiteConfig].
  Future<void> refreshRegionIndex() async {
    await _regionIndexService.loadCached();
    notifyListeners();
    // Stream 4: never wait for GPS to show something. The last place the phone was seen goes on screen at once; a fresh
    // fix refines it in parallel (bounded by [launchFixWait]); the idle watcher starts after that.
    Future<void>? locating;
    if (!_launchLocated) {
      _launchLocated = true;
      final last = await services.lastKnownStore?.load();
      if (last != null && _phoneFix == null) {
        _phoneFix = PhoneFix(last, live: false);
        _regionSeededFromOld = true;
        _updateRegion(last, live: false);
      }
      locating = _locateFresh();
    }
    await _regionIndexService.refresh();
    final regionErr = _regionIndexService.lastError;
    if (regionErr != null) diagnostics.add('Fetching regions-index failed: $regionErr');
    // The index may have just changed (first fetch, or a different index than the cache): re-check the best fix.
    final best = _phoneFix?.fix ?? _lastRegionFix;
    if (best != null) _updateRegion(best, live: false);
    notifyListeners();
    // The rosters need the region, the region needs the index: sync once both are in (and init has finished loading).
    final syncing = () async {
      if (!_loaded) await _loadedSignal.future;
      await syncRepeaterLists(SyncTrigger.launch);
    }();
    if (locating == null) {
      unawaited(syncing);
      return;
    }
    await locating;
    _startIdleWatcher();
    await syncing;
    await _initSync;
    await services.repeaterSync?.writesDone;
    if (!_launchSettled.isCompleted) _launchSettled.complete();
  }

  final Completer<void> _loadedSignal = Completer<void>();
  final Completer<void> _launchSettled = Completer<void>();
  Future<void>? _initSync;

  /// Completes once launch has done everything it starts in the background: the regions index, the fresh GPS fix
  /// (or its timeout), the launch repeater sync and the store writes it queued. For tests and diagnostics; the app
  /// never waits on it.
  Future<void> get launchSettled => _launchSettled.future;

  // ---------- where the phone is (Stream 4: open on the phone at once) ----------
  bool _launchLocated = false;
  bool _regionSeededFromOld = false;
  PhoneFix? _phoneFix;
  DateTime? _lastKnownSavedAt;

  /// How long launch waits for a fresh GPS fix (the last-known fix is already on screen). Tests shorten it.
  @visibleForTesting
  Duration launchFixWait = launchFixTimeout;

  /// The best-known position of the phone: a live GPS fix of this run, else the last-known one from disk (labelled by
  /// [phoneFixLabel] when it is not live). Null when the phone has never been located.
  PhoneFix? get phoneFix => _phoneFix;

  /// "Last known location, 2 d ago" while the position on screen is not a live fix; null otherwise.
  String? get phoneFixNote => phoneFixLabel(_phoneFix, services.clock());

  /// Where a map with no drive on it opens (phone, else the viewed region, else every region, else the world).
  MapStart get mapStart => mapStartFor(
        phone: _phoneFix,
        viewing: viewingRegion,
        viewingIsManual: viewingIsManual,
        viewingRemembered: _settings.regionLast != null,
        index: regionIndex,
        now: services.clock(),
      );

  bool _isLiveAge(GeoFix f) {
    final d = services.clock().toUtc().difference(f.at.toUtc());
    return d <= liveFixAge;
  }

  /// A GPS fix of this run: becomes [phoneFix] (unless older than the one held) and is saved as the last-known
  /// position (at most once a minute, so a drive's 1 Hz fixes do not hammer the disk).
  void _notePhoneFix(GeoFix fix) {
    final cur = _phoneFix;
    if (cur != null && cur.live && fix.at.isBefore(cur.fix.at)) return;
    _phoneFix = PhoneFix(fix, live: true);
    final now = services.clock();
    final saved = _lastKnownSavedAt;
    if (saved == null || now.difference(saved).abs() >= const Duration(minutes: 1)) {
      _lastKnownSavedAt = now;
      unawaited(services.lastKnownStore?.save(fix));
    }
  }

  Future<void> _locateFresh() async {
    final fix = await fixWithin(services.location, launchFixWait,
        onError: (e) => _logError('Getting a GPS fix at launch failed', e));
    if (fix == null) {
      if (_phoneFix == null) diagnostics.add('No GPS fix at launch; showing the last region');
      return;
    }
    _updateRegion(fix);
  }

  LocationAccess _locationAccess = LocationAccess.unknown;

  /// Location permission as last read (never prompts). Drives [locationNote].
  LocationAccess get locationAccess => _locationAccess;

  /// The plain-language location state and its action for the Drive and Region screens; null when all is well.
  LocationNote? get locationNote => locationNoteFor(_locationAccess, regionName: viewingRegion?.name);

  /// Re-reads the permission (launch and every resume, e.g. back from Settings). When it just became usable, locates
  /// the phone and lets the idle watcher start.
  Future<void> refreshLocationAccess() async {
    final probe = services.locationAccess;
    if (probe == null) return;
    LocationAccess a;
    try {
      a = await probe.check();
    } catch (_) {
      a = LocationAccess.unknown;
    }
    _setLocationAccess(a);
  }

  void _setLocationAccess(LocationAccess a) {
    final was = _locationAccess;
    _locationAccess = a;
    final usable = a == LocationAccess.granted || a == LocationAccess.approximate;
    final wasUsable = was == LocationAccess.granted || was == LocationAccess.approximate;
    if (usable && !wasUsable && was != LocationAccess.unknown) {
      diagnostics.add('Location allowed; locating the phone');
      unawaited(_locateFresh());
      unawaited(_idle?.setForeground(true)); // re-checks the permission and opens the idle stream
    }
    if (a != was) notifyListeners();
  }

  /// The action of [locationNote], after the person tapped it: the system question, or the phone's Settings.
  Future<void> resolveLocationNote() async {
    final probe = services.locationAccess;
    final note = locationNote;
    if (probe == null || note == null) return;
    try {
      switch (note.action) {
        case LocationAction.ask:
          _setLocationAccess(await probe.request());
        case LocationAction.openAppSettings:
          if (!await probe.openAppSettings()) _say('Open the Settings app, then Privacy, Location Services, MeshSonar.');
        case LocationAction.openLocationSettings:
          if (!await probe.openLocationSettings()) _say('Open the Settings app and turn on Location Services.');
        case null:
          break;
      }
    } catch (e) {
      _logError('Location permission action failed', e);
    }
  }

  // ---------- repeater lists (Stream 3: roster + network list, synced on open and resume) ----------
  /// The region roster / network repeater sync, or null when this build has none (tests). The map layer reads
  /// `repeaterSync.regionSet(slug)` and `repeaterSync.globalSet`; AppState notifies whenever either changes.
  RepeaterSync? get repeaterSync => services.repeaterSync;

  /// The viewed region's roster as map rows (empty without a sync or a stored roster).
  RepeaterSet get regionRepeaterSet => services.repeaterSync?.regionSet(viewingRegion?.slug) ?? RepeaterSet.empty;

  /// The whole network's repeaters as map rows (empty until the server offers network-repeaters).
  RepeaterSet get globalRepeaterSet => services.repeaterSync?.globalSet ?? RepeaterSet.empty;

  bool _syncListening = false;

  /// Where a region's roster is read: its own host on the MeshSonar hub, else the configured server (custom server).
  String _rosterBase(RegionIndexEntry r) => isSameServer(_settings.serverUrl, defaultServerUrl) ? r.url : _settings.serverUrl;

  /// Syncs the rosters of the region the phone is in and the viewed one, and the network list, within the sync's rate
  /// limits. [trigger] force = pull to refresh. Never throws; failures only reach the diagnostics log.
  Future<void> syncRepeaterLists(SyncTrigger trigger) async {
    final sync = services.repeaterSync;
    if (sync == null || !_loaded) return;
    final regions = <String, RegionIndexEntry>{};
    for (final r in [_currentRegion, viewingRegion]) {
      if (r != null) regions[r.slug] = r;
    }
    final server = Uri.tryParse(_settings.serverUrl);
    await Future.wait([
      for (final r in regions.values) sync.syncRoster(baseUrl: _rosterBase(r), slug: r.slug, trigger: trigger),
      if (server != null && server.host.isNotEmpty) _syncNetworkWithCapability(sync, server, trigger),
    ]);
  }

  /// The network list, after the site config answered (it says whether `?updated_since=` deltas exist), but never
  /// waiting more than a few seconds: without an answer the sync simply downloads the full list.
  Future<void> _syncNetworkWithCapability(RepeaterSync sync, Uri server, SyncTrigger trigger) async {
    if (_siteConfig == null) {
      try {
        await _siteConfigLatest?.timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    await sync.syncNetwork(server: server, trigger: trigger);
  }

  /// Pull to refresh on a region's repeater list: that roster and the network list, forced (still floored so a
  /// repeated pull cannot loop).
  Future<void> refreshRegionRoster(String baseUrl, String slug) async {
    final sync = services.repeaterSync;
    if (sync == null) return;
    final server = Uri.tryParse(_settings.serverUrl);
    await Future.wait([
      sync.syncRoster(baseUrl: baseUrl, slug: slug, trigger: SyncTrigger.force),
      if (server != null && server.host.isNotEmpty) sync.syncNetwork(server: server, trigger: SyncTrigger.force),
    ]);
  }

  /// Back in front: permission may have changed in Settings, and the lists may be due (rate limits apply).
  void _onForeground(bool fg) {
    if (!fg) return;
    unawaited(refreshLocationAccess());
    unawaited(syncRepeaterLists(SyncTrigger.resume));
  }

  List<RosterRecord> _lookupRosterSrc = const [];
  List<RepeaterRef> _rosterRefs = const [];
  Set<String> _rosterShared = const {};
  NetworkRecord? _nearbySrc;
  ({double lat, double lon})? _nearbyAt;
  List<RepeaterRef> _networkNearby = const [];

  /// Called when the sync's stored lists change: names and pins follow at once.
  void _onRepeaterSync() {
    _refreshSyncedNames();
    notifyListeners();
  }

  /// Rebuilds the name sources that come from the sync, only when their inputs changed.
  void _refreshSyncedNames() {
    final sync = services.repeaterSync;
    if (sync == null) return;
    var changed = false;
    // Rosters of the region the phone is in and the viewed one (current first).
    final slugs = <String>{?_currentRegion?.slug, ?viewingRegion?.slug};
    final records = [for (final slug in slugs) ?sync.roster(slug)];
    final same = records.length == _lookupRosterSrc.length &&
        [for (var i = 0; i < records.length; i++) identical(records[i].data, _lookupRosterSrc[i].data)].every((x) => x);
    if (!same) {
      final refs = <String, RepeaterRef>{};
      final shared = <String>{};
      for (final r in records) {
        for (final x in r.data.rows) {
          if (x.ambiguous) shared.add(x.hashPrefix);
          if (x.hasPosition) refs.putIfAbsent(x.key, () => RepeaterRef(key: x.key, name: x.name?.trim() ?? '', lat: x.lat!, lon: x.lon!));
        }
      }
      _lookupRosterSrc = records;
      _rosterRefs = refs.values.toList();
      _rosterShared = shared;
      changed = true;
    }
    // The network list near the phone (the same 150 km neighbourhood the map.meshcore.io directory keeps).
    final n = sync.network;
    final centre = _phoneFix == null ? null : (lat: _phoneFix!.fix.lat, lon: _phoneFix!.fix.lon);
    final at = centre ?? (viewingRegion == null ? null : regionCenter(viewingRegion!));
    final moved = at == null || _nearbyAt == null || haversineM(at.lat, at.lon, _nearbyAt!.lat, _nearbyAt!.lon) > 75000;
    if (n == null) {
      if (_networkNearby.isNotEmpty) {
        _networkNearby = const [];
        changed = true;
      }
    } else if (at != null && (!identical(n, _nearbySrc) || moved)) {
      final next = n.data.nearby(at.lat, at.lon, now: services.clock().toUtc());
      if (!identical(n.data, _nearbySrc?.data) || moved) {
        _networkNearby = next;
        changed = true;
      }
      _nearbySrc = n;
      _nearbyAt = at;
    }
    if (changed) _rebuildLookup();
  }

  // Idle region detection (WP-R4): a low-power foreground stream while NOT driving feeds the same tracker the drive
  // uses, so a same-preset crossing notifies and switches the view, and a different-preset one prompts (never a
  // silent radio change). Paused during drives and, unless "Always" location is granted, while backgrounded.
  IdleRegionWatcher? _idle;
  AppLifecycleBridge? _lifecycle;
  AppLifecycleBridge? _resumeBridge;

  void _startIdleWatcher() {
    final src = services.idleLocation;
    if (src == null || _idle != null) return;
    final w = _idle = IdleRegionWatcher(source: src, store: services.lastKnownStore, onFix: _updateRegion);
    _lifecycle = AppLifecycleBridge((fg) => unawaited(w.setForeground(fg)))..attach();
    unawaited(w.setDriving(driving));
    unawaited(w.start());
  }

  /// Last few characters only; the full key is never shown.
  String get maskedKey {
    final k = _settings.driverKey ?? '';
    if (k.isEmpty) return '';
    return '••••${k.length > 4 ? k.substring(k.length - 4) : ''}';
  }

  // ---------- messages ----------
  /// One plain-language message for a snackbar/banner. Cleared once shown.
  String? _notice;
  String? takeNotice() {
    final n = _notice;
    _notice = null;
    return n;
  }

  String? get pendingNotice => _notice;

  void _say(String msg) {
    _notice = msg;
    diagnostics.add(msg);
    notifyListeners();
  }

  /// What happened in the app recently (memory only), for problem reports.
  late final Diagnostics diagnostics = Diagnostics(clock: services.clock);

  /// Logs a caught error: its type and message, never a stack trace.
  void _logError(String what, Object e) =>
      diagnostics.add('$what: ${e is CmatException ? 'HTTP ${e.status ?? 'none'}, ${e.message}' : '${e.runtimeType}: $e'}');

  // ---------- radio ----------
  RadioKind _radioKind = RadioKind.none;
  RadioKind get radioKind => _radioKind;
  RadioDevice? _device;
  RadioDevice? get device => _device;
  CompanionLink? _link;
  SelfInfo? _selfInfo;
  SelfInfo? get selfInfo => _selfInfo;
  bool _connecting = false;
  bool get connecting => _connecting;
  String? _connectError;
  String? get connectError => _connectError;
  bool get connected => _link != null && _link!.isConnected;

  String get connectionLabel {
    if (_connecting) return 'Connecting…';
    if (!connected) return 'Not connected';
    if (_radioKind == RadioKind.simulator) return 'Simulator';
    return _selfInfo?.name ?? _device?.name ?? 'Radio';
  }

  RadioScanner scannerFor(RadioKind kind) =>
      kind == RadioKind.simulator ? services.simulatorScanner : services.bluetoothScanner;

  LocationSource get _locationSource =>
      _radioKind == RadioKind.simulator ? services.simulatedLocation : services.location;

  /// The location source a drive uses with the current radio (read-only; the Drive screen's map follows it).
  LocationSource get activeLocation => _locationSource;

  // ---------- packet-header telemetry (lib/core/telemetry_uploader.dart) ----------
  // On by default, off with the Settings toggle; headers and signal metadata only, sent only to the configured server.
  StreamSubscription<RxPacket>? _telemetrySub;
  bool _telemetryDisclosedSeen = false;
  TelemetryUploader? _telemetry;
  TelemetryUploader get _tele => _telemetry ??= TelemetryUploader(
        // Nothing is collected before the person has seen the first-run disclosure (the sheet in lib/ui/telemetry_sheet.dart).
        enabled: () => _settings.telemetryEnabled && _telemetryDisclosed(),
        driverKey: () => _settings.driverKey,
        keyApproved: () => keyApproved,
        transport: () {
          final c = client;
          return c is TelemetryTransport ? c as TelemetryTransport : null;
        },
        appVersion: services.appInfo.version,
        platform: services.appInfo.platform,
        queueFile: services.telemetryQueueFile,
        now: () => services.clock().toUtc(),
      );

  bool _telemetryDisclosed() {
    if (_telemetryDisclosedSeen) return true;
    final f = services.uiPrefsFile;
    if (f == null) return _telemetryDisclosedSeen = true; // tests / no file system: nothing is ever sent anyway
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map && j['telemetry_disclosed'] == true) return _telemetryDisclosedSeen = true;
    } catch (_) {}
    return false;
  }

  void _onTelemetryRx(RxPacket rx) {
    if (!_settings.telemetryEnabled) return;
    final r = TelemetryRecord.fromRx(rx, region: _currentRegion?.code);
    if (r != null) _tele.add(r);
  }

  /// Packet headers waiting on this phone to be sent (Settings > Privacy & data sharing shows the count).
  int get telemetryQueued => _telemetry?.queued ?? 0;

  /// An erase of the server's copy was asked for but has not gone through yet (it is retried).
  bool get telemetryErasePending => _telemetry?.pendingErase ?? false;

  /// Sends what is due now (the uploader also does this on its own timer). For tests and an app-resume hook.
  Future<void> flushTelemetry() => _tele.flush();

  /// Opt-out follow-up: asks the server to erase every packet header this phone ever sent. Returns the number erased, or
  /// null if it could not be done yet (it is remembered and retried).
  Future<int?> eraseTelemetry() {
    _tele.discard();
    return _tele.eraseServerData();
  }

  // ---------- drive context (stream 7: lib/app/drive_context_hook.dart, lib/core/drive_context_session.dart) ----------
  DriveContextSession? _ctx;
  bool _collectionSeen = false;
  SensorStatus? _baroStatus;

  /// The collection category [id] is on: its switch (opt-out) AND the disclosure that lists it has been seen. Read at
  /// every write of the drive context, so off takes effect at the next sample.
  bool collectionOn(String id) =>
      _settings.collectionOn(id) && (id == 'packet_headers' ? _telemetryDisclosed() : _collectionDisclosed());

  bool _collectionDisclosed() {
    if (_collectionSeen) return true;
    final f = services.uiPrefsFile;
    if (f == null) return _collectionSeen = true; // tests / no file system, as for packet headers
    return _collectionSeen = collectionDisclosureSeenIn(f);
  }

  /// The disclosure sheet was just seen: collection may start now (also mid-drive).
  void noteCollectionDisclosed() {
    _collectionSeen = true;
    _telemetryDisclosedSeen = true;
    _ctx?.refresh();
    notifyListeners();
  }

  /// The phone barometer as last seen by a drive (Settings shows it); unsupported when this build has none.
  SensorStatus get barometerStatus =>
      services.barometer == null ? SensorStatus.unsupported : (_ctx?.barometerStatus ?? _baroStatus ?? SensorStatus.notStarted);

  /// Deletes category [id]'s recorded context from every drive on this phone. Returns how many drives changed.
  Future<int> deleteCollectedLocally(String id) async {
    final ledger = contextLedgerOf(services);
    if (ledger == null) return 0;
    final ids = [for (final x in await services.store.sessions()) x.session.id];
    return (await stripContextCategories(ledger, ids, {id})).length;
  }

  void _stopDriveContext() {
    final c = _ctx;
    if (c == null) return;
    _baroStatus = c.barometerStatus;
    c.stop();
    _ctx = null;
  }

  Future<bool> connect(RadioDevice device, RadioKind kind) async {
    if (driving) {
      _say('Stop the drive before switching radios.');
      return false;
    }
    await disconnect(quiet: true);
    _connecting = true;
    _connectError = null;
    _device = device;
    _radioKind = kind;
    notifyListeners();
    ByteTransport? transport;
    try {
      transport = await scannerFor(kind).connect(device).timeout(const Duration(seconds: 25));
      final link = services.linkFactory(transport);
      final info = await link.start().timeout(const Duration(seconds: 20));
      _link = link;
      _selfInfo = info;
      unawaited(_telemetrySub?.cancel());
      _telemetrySub = link.rxPackets.listen(_onTelemetryRx, onError: (Object _) {});
      _connecting = false;
      // A radio used for the first time is asked once how its antenna is set up (the UI opens the sheet).
      _antennaPrompt = antennaProfile == null;
      diagnostics.add('Connected to ${kind == RadioKind.simulator ? 'the simulator' : 'radio "${info.name}"'}, '
          'firmware ${info.firmware ?? 'unknown'}');
      notifyListeners();
      return true;
    } catch (e) {
      try {
        await transport?.disconnect();
      } catch (_) {}
      _connecting = false;
      _link = null;
      _selfInfo = null;
      _device = null;
      _radioKind = RadioKind.none;
      _connectError = e is TimeoutException
          ? 'The radio didn\'t answer. Make sure it\'s on, nearby, and not connected to another app.'
          : 'Couldn\'t connect to ${device.name}. ${friendlyError(e, action: 'Connecting')}';
      _logError('Connecting failed', e);
      notifyListeners();
      return false;
    }
  }

  /// Connects to the simulator's single device.
  Future<bool> connectSimulator() async {
    try {
      final lists = await services.simulatorScanner.scan(timeout: const Duration(seconds: 2)).toList();
      final all = lists.expand((l) => l).toList();
      final dev = all.isNotEmpty ? all.first : const RadioDevice(id: 'simulator', name: 'MeshSonar Simulator');
      return await connect(dev, RadioKind.simulator);
    } catch (e) {
      _connectError = friendlyError(e, action: 'Starting the simulator');
      notifyListeners();
      return false;
    }
  }

  Future<void> disconnect({bool quiet = false}) async {
    if (driving) await stopDrive();
    final link = _link;
    _link = null;
    unawaited(_telemetrySub?.cancel());
    _telemetrySub = null;
    _selfInfo = null;
    _device = null;
    _radioKind = RadioKind.none;
    _antennaPrompt = false;
    if (link != null) {
      diagnostics.add('Radio disconnected');
      try {
        await link.close();
      } catch (_) {}
    }
    if (!quiet) notifyListeners();
  }

  // ---------- drive ----------
  WardriveEngine? _engine;
  EngineStatus _status = const EngineStatus(EngineState.idle);
  EngineStatus get status => _status;
  DriveSession? _session;
  DriveSession? get currentSession => _session;
  bool get driving => _session != null;
  bool _busy = false; // starting/stopping
  bool get busy => _busy;
  bool _pinging = false;
  bool get pinging => _pinging;

  final List<DrivePing> _recent = [];
  List<DrivePing> get recentPings => List.unmodifiable(_recent);

  /// Every ping of the current drive, oldest first (the map and the ping log use the whole drive).
  final List<DrivePing> _drivePings = [];
  List<DrivePing> get drivePings => List.unmodifiable(_drivePings);

  /// Who's in range: repeaters heard this drive; "live" until not heard for settings.heardHoldPings pings.
  final HeardTracker heard = HeardTracker();

  /// Prefix → repeater (name, key, position) from CMAT's list plus any extra directories.
  RepeaterLookup _lookup = RepeaterLookup.empty;
  RepeaterLookup get lookup => _lookup;
  List<RepeaterRef> _extraRepeaters = const [];

  /// Adds repeaters from another source (e.g. a public node map) used after CMAT's list.
  void setExtraRepeaters(List<RepeaterRef> list) {
    _extraRepeaters = list;
    _rebuildLookup();
    notifyListeners();
  }

  /// Name priority (Stream 3): the region roster (MeshSonar's own, per-region, freshest view) before drive-repeaters
  /// (MeshSonar's key-gated list), then the network list near the phone, then the map.meshcore.io directory download.
  /// Prefixes the roster marks as shared never resolve to one name (RepeaterLookup.ambiguousPrefixes).
  void _rebuildLookup() {
    _lookup = RepeaterLookup([
      (RepeaterSource.cmat, _rosterRefs),
      (RepeaterSource.cmat, _repeaters),
      (RepeaterSource.publicMap, _networkNearby),
      (RepeaterSource.publicMap, _extraRepeaters),
    ], ambiguousPrefixes: _rosterShared);
    _nameCache.clear(); // names from either list may have changed
    heard.relookup(_lookup);
  }

  // ---------- antenna, per radio ----------
  String? get _radioKey => _selfInfo?.publicKey.toLowerCase();

  /// How the connected radio's antenna is set up; null when no radio is connected or it was never set up.
  AntennaProfile? get antennaProfile {
    final k = _radioKey;
    return k == null ? null : _settings.antennaProfiles[k];
  }

  /// A radio is connected whose antenna hasn't been set up yet; Start drive waits for it.
  bool get needsAntennaSetup => connected && antennaProfile == null;

  bool _antennaPrompt = false;

  /// A radio without an antenna profile just connected and the setup sheet should open (once).
  bool get antennaPromptPending => _antennaPrompt;

  /// True once per connect that needs the antenna setup; the caller opens the sheet.
  bool takeAntennaPrompt() {
    final p = _antennaPrompt && needsAntennaSetup;
    _antennaPrompt = false;
    return p;
  }

  /// The single antenna setting from before 0.4.0, if the person ever changed it from the default; it prefills a
  /// radio's first setup.
  Antenna? get legacyAntenna {
    final a = _settings.antenna;
    return (a.type == 'external' || a.gainDbi != null || a.heightM != null) ? a : null;
  }

  /// Saves [profile] for [radioKey] (default: the connected radio). Used by the next drive with that radio.
  Future<void> saveAntennaProfile(AntennaProfile profile, {String? radioKey}) async {
    final k = (radioKey ?? _radioKey)?.toLowerCase();
    if (k == null) return;
    _antennaPrompt = false;
    await updateSettings(_settings.copyWith(antennaProfiles: {..._settings.antennaProfiles, k: profile}));
  }

  /// Forgets a radio's antenna; it is asked again the next time it connects.
  Future<void> forgetAntennaProfile(String radioKey) async {
    final k = radioKey.toLowerCase();
    await updateSettings(_settings.copyWith(antennaProfiles: {
      for (final e in _settings.antennaProfiles.entries)
        if (e.key != k) e.key: e.value,
    }));
  }

  /// A radio's name: the connected radio's, else the one recorded with its most recent drive.
  String? radioName(String radioKey) {
    final k = radioKey.toLowerCase();
    if (_radioKey == k) return _selfInfo?.name;
    for (final x in _sessions) {
      final c = x.session.companion;
      if (c.publicKey?.toLowerCase() == k && (c.name ?? '').isNotEmpty) return c.name;
    }
    return null;
  }
  static const int recentLimit = 50;

  int _pingCount = 0;
  int _txCount = 0;
  int _heardCount = 0;
  int _syncedCount = 0;
  int get pingCount => _pingCount;
  int get heardCount => _heardCount;
  int get syncedCount => _syncedCount;

  /// tx-aware guard, same as [lib/ui/drive_stats.dart]'s `DriveStats.heardPercent` and `SessionSummary.txCount`:
  /// an all-rx (discovery/listen-only) drive has no tx pings at all, so "0% heard" would misread live as a failed
  /// drive rather than a successful listen session.
  int? get heardPercent => _txCount == 0 ? null : (100 * _heardCount / _txCount).round();

  final Set<String> _seenPingIds = {};
  final List<DrivePing> _unsaved = [];
  int get unsavedCount => _unsaved.length;
  Future<void> _writeChain = Future.value();
  StreamSubscription<DrivePing>? _pingSub;
  StreamSubscription<EngineStatus>? _statusSub;

  /// Stats for the drive screen when not driving: the last finished drive stays visible.
  DriveSession? _lastSession;
  DriveSession? get lastSession => _lastSession;

  // ---------- uploads during / at the end of a drive (Agent 4) ----------
  /// When the last upload (during a drive, at Stop, or a manual sync) finished without error.
  DateTime? _lastUploadAt;
  DateTime? get lastUploadAt => _lastUploadAt;

  /// Plain-language reason the last upload failed; null after a successful one.
  String? _lastUploadError;
  String? get lastUploadError => _lastUploadError;

  bool _uploading = false;

  /// An upload is running (the periodic in-drive upload, the one at Stop, or a manual sync).
  bool get uploading => _uploading || _syncing.isNotEmpty;

  /// The drive that just stopped (for the "View drive report" card); cleared when a new drive starts or it's deleted.
  String? _lastFinishedSessionId;
  String? get lastFinishedSessionId => _lastFinishedSessionId;

  /// Period of the in-drive upload timer for a [Settings.syncEveryMin] value. Tests shorten it.
  @visibleForTesting
  Duration Function(int minutes) syncPeriodFor = (m) => Duration(minutes: m);

  Timer? _driveSyncTimer;
  Duration? _driveSyncPeriod;
  Future<void>? _driveSyncInFlight;

  /// Whether the in-drive upload timer should be running with the current settings.
  bool get _wantDriveSync => driving && _settings.autoSync && _settings.syncDuringDrive && keyApproved;

  /// Starts, restarts (new period) or stops the in-drive upload timer to match the settings.
  void _scheduleDriveSync() {
    if (!_wantDriveSync) {
      _cancelDriveSync();
      return;
    }
    final period = syncPeriodFor(_settings.syncEveryMin);
    if (_driveSyncTimer != null && _driveSyncPeriod == period) return;
    _driveSyncTimer?.cancel();
    _driveSyncPeriod = period;
    _driveSyncTimer = Timer.periodic(period, (_) => _driveSyncTick());
  }

  void _cancelDriveSync() {
    _driveSyncTimer?.cancel();
    _driveSyncTimer = null;
    _driveSyncPeriod = null;
  }

  /// One in-drive upload of the current drive's saved pings. Never overlaps another; failures are quiet (status
  /// line only) and retried on the next tick.
  void _driveSyncTick() {
    if (_driveSyncInFlight != null || _busy || !_wantDriveSync) return;
    final sid = _session?.id;
    if (sid == null) return;
    _driveSyncInFlight = _uploadQuietly(sid).whenComplete(() => _driveSyncInFlight = null);
  }

  Future<void> _uploadQuietly(String sessionId) async {
    _uploading = true;
    notifyListeners();
    try {
      await _writeChain; // only pings already saved on the phone are sent
      final r = await _syncService.syncSession(sessionId);
      _logSync('Upload during the drive', r);
      if (r.error != null) {
        _lastUploadError = friendlySyncError(r.error!);
        final l = r.error!.toLowerCase();
        if (l.contains('403') || l.contains('not approved') || l.contains('not recognised')) {
          unawaited(refreshKeyStatus(quiet: true));
        }
      } else {
        _lastUploadAt = services.clock();
        _lastUploadError = null;
      }
    } catch (e) {
      _logError('Upload during the drive failed', e);
      _lastUploadError = friendlyError(e, action: 'Upload');
      if (e is CmatException && e.status == 403) unawaited(refreshKeyStatus(quiet: true));
    } finally {
      _uploading = false;
      await refreshSessions(); // updates syncedCount live
    }
  }

  Future<void> startDrive({String? label}) async {
    if (driving || _busy) return;
    final link = _link;
    if (link == null || !link.isConnected) {
      _say('Connect a radio (or the simulator) first.');
      return;
    }
    // Every drive records how its radio's antenna is set up (the simulator's too, like a real radio).
    final profile = antennaProfile;
    if (profile == null) {
      _say('Set up this radio\'s antenna before driving with it.');
      return;
    }
    _busy = true;
    notifyListeners();
    final location = _locationSource;
    try {
      final ok = await location.ensurePermission();
      if (!ok) {
        _say('MeshSonar needs location access to record where each ping was sent. '
            'Turn on location for MeshSonar in your phone\'s settings.');
        return;
      }
      final s = _settings;
      final info = _selfInfo;
      final session = DriveSession(
        id: services.newId(),
        startedAt: services.clock().toUtc(),
        label: (label == null || label.trim().isEmpty) ? null : label.trim(),
        channel: s.channel,
        radio: info?.radio ?? const Radio(),
        antenna: profile.toAntenna(),
        companion: Companion(
          publicKey: info?.publicKey.toLowerCase(),
          name: info?.name,
          firmware: info?.firmware,
        ),
      );
      await services.store.startSession(session);
      _session = session;
      _lastSession = null;
      _lastFinishedSessionId = null;
      _recent.clear();
      _drivePings.clear();
      heard
        ..holdPings = s.heardHoldPings
        ..reset();
      _seenPingIds.clear();
      _pingCount = 0;
      _txCount = 0;
      _heardCount = 0;
      _syncedCount = 0;

      final engine = services.engineFactory(link, location);
      _engine = engine;
      _status = engine.current;
      _pingSub = engine.pings.listen(_onPing, onError: (Object e) => _say(friendlyError(e, action: 'A ping')));
      _statusSub = engine.status.listen((st) {
        _status = st;
        // Rides the engine's own GPS stream (already gated to active drives only) rather than opening a second,
        // always-on Geolocator subscription just for region awareness.
        if (st.lastFix != null) _updateRegion(st.lastFix);
        if (st.lastFix != null) _ctx?.onFix(st.lastFix!);
        notifyListeners();
      });
      final txW = info?.radio.txDbm == null ? null : _dbmToWatts(info!.radio.txDbm!);
      await engine.start(WardriveConfig(
        channel: s.channel,
        intervalSec: s.intervalSec,
        minDistanceM: s.minDistanceM,
        txPowerW: txW,
        txDbm: info?.radio.txDbm,
        listenOnly: s.discoveryMode,
      ));
      _ctx = newDriveContext(
          services: services,
          sessionId: session.id,
          link: link,
          isOn: collectionOn,
          pingBusy: () => _pinging || engine.current.state == EngineState.pinging,
          onStatus: notifyListeners);
      unawaited(_ctx?.start());
      _scheduleDriveSync();
      unawaited(_idle?.setDriving(true));
      diagnostics.add(s.discoveryMode
          ? 'Drive started on ${s.channel}, listen-only (nothing transmitted)'
          : 'Drive started on ${s.channel}, auto-ping every ${s.intervalSec} s');
      unawaited(refreshSessions());
    } catch (e) {
      // The session folder may exist. With no pings it's just an empty drive, so remove it; otherwise close it so it
      // doesn't look "still driving".
      final sid = _session?.id;
      _cancelDriveSync();
      _stopDriveContext();
      await _teardownEngine();
      await _flushWrites();
      if (sid != null) {
        try {
          final saved = await services.store.pings(sid);
          if (saved.isEmpty && _unsaved.isEmpty && _drivePings.isEmpty) {
            await services.store.deleteSession(sid);
          } else {
            await services.store.endSession(sid, services.clock().toUtc());
          }
        } catch (_) {
          try {
            await services.store.endSession(sid, services.clock().toUtc());
          } catch (_) {}
        }
      }
      _session = null;
      _logError('Starting the drive failed', e);
      _say('Couldn\'t start the drive. ${friendlyError(e, action: 'Starting')}');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  static double _dbmToWatts(double dbm) => math.pow(10, dbm / 10) / 1000;

  @visibleForTesting
  void debugOnPing(DrivePing ping) => _onPing(ping);

  void _onPing(DrivePing ping) {
    if (!_seenPingIds.add(ping.id)) return;
    // Our own transmission (and so its echoes) is never telemetry.
    if (ping.pktHash != null) _telemetry?.excludeHash(ping.pktHash!);
    final sid = _session?.id;
    if (sid == null) return;
    _pingCount++;
    if (ping.kind == PingKind.tx) {
      _txCount++;
      if (!ping.heardNothing) _heardCount++;
    }
    _recent.insert(0, ping);
    if (_recent.length > recentLimit) _recent.removeLast();
    _drivePings.add(ping);
    heard.addPing(ping);
    // First GPS fix of the drive: make sure the public node directory covers this area (no-op when fresh).
    if (_drivePings.length == 1) unawaited(refreshDirectory(lat: ping.lat, lon: ping.lon));
    notifyListeners();
    _enqueueWrite(sid, ping);
  }

  void _enqueueWrite(String sessionId, DrivePing ping) {
    _writeChain = _writeChain.then((_) async {
      // Retry anything that failed earlier first, in order.
      final pending = [..._unsaved, ping];
      _unsaved.clear();
      for (var i = 0; i < pending.length; i++) {
        try {
          await services.store.appendPing(sessionId, pending[i]);
          if (_session?.id == sessionId) unawaited(_ctx?.onPingSaved(pending[i])); // context only after the ping is saved
        } catch (e) {
          _unsaved.addAll(pending.sublist(i));
          _say('Couldn\'t save a ping to this device; will retry. ${friendlyError(e, action: 'Saving')}');
          return;
        }
      }
    });
  }

  Future<void> _flushWrites() async {
    await _writeChain;
    final sid = _session?.id;
    if (_unsaved.isNotEmpty && sid != null) {
      final pending = List.of(_unsaved);
      _unsaved.clear();
      for (var i = 0; i < pending.length; i++) {
        try {
          await services.store.appendPing(sid, pending[i]);
        } catch (e) {
          _unsaved.addAll(pending.sublist(i));
          break;
        }
      }
    }
  }

  Future<DrivePing?> pingNow() async {
    final engine = _engine;
    if (engine == null || !driving) {
      _say('Start a drive first.');
      return null;
    }
    if (_pinging) return null;
    _pinging = true;
    notifyListeners();
    try {
      final p = await engine.pingNow();
      _onPing(p); // de-duplicated against the stream
      return p;
    } catch (e) {
      _say(friendlyError(e, action: 'The ping'));
      return null;
    } finally {
      _pinging = false;
      notifyListeners();
    }
  }

  Future<void> stopDrive() async {
    final session = _session;
    if (session == null || _busy) return;
    _busy = true;
    _cancelDriveSync();
    notifyListeners();
    try {
      try {
        await _engine?.stop();
      } catch (e) {
        _say(friendlyError(e, action: 'Stopping'));
      }
      // Let any ping emitted during stop arrive, then write everything.
      await Future<void>.microtask(() {});
      await _teardownEngine();
      await _flushWrites();
      _stopDriveContext();
      try {
        await services.store.endSession(session.id, services.clock().toUtc());
      } catch (e) {
        _say(friendlyError(e, action: 'Closing the drive'));
      }
      if (_unsaved.isNotEmpty) {
        _say('${_unsaved.length} ping(s) couldn\'t be saved to this device. Export the drive before closing the app.');
      }
      _lastSession = session.copyWith(endedAt: services.clock().toUtc());
      _lastFinishedSessionId = session.id;
      diagnostics.add('Drive stopped after $_pingCount ping${_pingCount == 1 ? '' : 's'}');
      _session = null;
      unawaited(_idle?.setDriving(false));
      _status = const EngineStatus(EngineState.idle);
    } finally {
      _busy = false;
      notifyListeners();
    }
    // An in-drive upload may still be running; let it finish so the final one sends what's left plus ended_at.
    final inFlight = _driveSyncInFlight;
    if (inFlight != null) await inFlight;
    await refreshSessions();
    if (_settings.autoSync && keyApproved) {
      await syncSession(session.id, quietIfNothing: true);
    } else if (_settings.autoSync && hasKey && !keyApproved) {
      _say('Drive saved. It will upload once your driver key is approved.');
    } else {
      _say('Drive saved on this phone.');
    }
  }

  Future<void> _teardownEngine() async {
    // Not awaited: nothing depends on the cancel finishing, and some stream cancels complete late.
    unawaited(_pingSub?.cancel());
    unawaited(_statusSub?.cancel());
    _pingSub = null;
    _statusSub = null;
    _engine = null;
  }

  String get statusLine {
    final st = _status;
    if (st.message != null && st.message!.isNotEmpty) return st.message!;
    switch (st.state) {
      case EngineState.idle:
        return connected ? 'Ready. Press Start drive.' : 'Connect a radio to begin.';
      case EngineState.starting:
        return 'Starting…';
      case EngineState.driving:
        final next = st.nextPingAt;
        if (next == null) return 'Driving.';
        final secs = next.difference(services.clock()).inSeconds;
        return secs > 0 ? 'Driving. Next ping in ${secs}s.' : 'Driving. Ping due.';
      case EngineState.pinging:
        return 'Pinging… listening for repeaters.';
      case EngineState.stopping:
        return 'Stopping…';
      case EngineState.error:
        return 'Radio problem. Check the connection.';
    }
  }

  // ---------- sessions ----------
  List<SessionSummary> _sessions = const [];
  List<SessionSummary> get sessions => _sessions;
  bool _sessionsLoading = false;
  bool get sessionsLoading => _sessionsLoading;
  String? _sessionsError;
  String? get sessionsError => _sessionsError;

  Future<void> refreshSessions() async {
    _sessionsLoading = true;
    try {
      _sessions = await services.store.sessions();
      _sessionsError = null;
      final cur = _session ?? _lastSession;
      if (cur != null) {
        for (final s in _sessions) {
          if (s.session.id == cur.id) {
            _syncedCount = s.syncedCount;
            if (_session == null) {
              _pingCount = s.pingCount;
              _txCount = s.txCount;
              _heardCount = s.heardCount;
            }
          }
        }
      }
    } catch (e) {
      _sessionsError = 'Couldn\'t read saved drives. ${friendlyError(e, action: 'Reading')}';
    } finally {
      _sessionsLoading = false;
      notifyListeners();
    }
  }

  // ---------- sync ----------
  final Set<String> _syncing = {};
  bool isSyncing(String sessionId) => _syncing.contains(sessionId);
  bool get anySyncing => _syncing.isNotEmpty;
  String? _lastSyncMessage;
  String? get lastSyncMessage => _lastSyncMessage;
  bool _lastSyncFailed = false;
  bool get lastSyncFailed => _lastSyncFailed;

  bool _canSync() {
    if (!hasKey) {
      _say('Request a driver key in Settings before syncing. Your drives are saved on this phone.');
      return false;
    }
    if (_settings.keyStatus != DriverKeyStatus.approved) {
      _say('Your driver key is ${_settings.keyStatus.name}. Drives upload once it\'s approved; tap Refresh in Settings.');
      return false;
    }
    return true;
  }

  Future<SyncReport?> syncSession(String sessionId, {bool quietIfNothing = false}) async {
    if (!_canSync()) return null;
    if (driving && _session?.id == sessionId) {
      await _flushWrites();
    }
    _syncing.add(sessionId);
    notifyListeners();
    try {
      final r = await _syncService.syncSession(sessionId);
      _logSync('Upload of one drive', r);
      _handleReport(r, quietIfNothing: quietIfNothing);
      return r;
    } catch (e) {
      _logError('Upload of one drive failed', e);
      _syncFailed(friendlyError(e, action: 'Sync'), e);
      return null;
    } finally {
      _syncing.remove(sessionId);
      await refreshSessions();
    }
  }

  Future<SyncReport?> syncAll() async {
    if (!_canSync()) return null;
    _syncing.add('*');
    notifyListeners();
    try {
      final r = await _syncService.syncAll();
      _logSync('Upload of all drives', r);
      _handleReport(r);
      return r;
    } catch (e) {
      _logError('Upload of all drives failed', e);
      _syncFailed(friendlyError(e, action: 'Sync'), e);
      return null;
    } finally {
      _syncing.remove('*');
      await refreshSessions();
    }
  }

  void _logSync(String what, SyncReport r) => diagnostics.add(r.error != null
      ? '$what failed: ${r.error}'
      : '$what: ${r.stored} stored, ${r.duplicate} already on the server, ${r.rejected} rejected');

  void _handleReport(SyncReport r, {bool quietIfNothing = false}) {
    if (r.error != null) {
      _syncFailed(friendlySyncError(r.error!), null);
      final l = r.error!.toLowerCase();
      if (l.contains('403') || l.contains('not approved') || l.contains('not recognised')) {
        unawaited(refreshKeyStatus(quiet: true));
      }
      return;
    }
    _lastSyncFailed = false;
    _lastUploadAt = services.clock();
    _lastUploadError = null;
    final parts = <String>['Uploaded ${r.stored} new ping${r.stored == 1 ? '' : 's'}'];
    if (r.duplicate > 0) parts.add('${r.duplicate} already on the server');
    if (r.rejected > 0) parts.add('${r.rejected} rejected');
    _lastSyncMessage = '${parts.join(', ')}.';
    if (quietIfNothing && r.stored == 0 && r.duplicate == 0 && r.rejected == 0) {
      _say('Drive saved. Nothing new to upload.');
    } else {
      _say(_lastSyncMessage!);
    }
  }

  void _syncFailed(String msg, Object? e) {
    _lastSyncFailed = true;
    _lastSyncMessage = msg;
    _lastUploadError = msg;
    _say(msg);
    if (e is CmatException && e.status == 403) unawaited(refreshKeyStatus(quiet: true));
  }

  // ---------- rename ----------
  /// Names a drive (blank clears it). The name is saved in the drive itself, so exports carry it, and the drive is
  /// marked so the next sync sends the new name to the server.
  Future<bool> renameSession(String sessionId, String? label, {bool quiet = false}) async {
    final v = label?.trim();
    final name = (v == null || v.isEmpty) ? null : v;
    try {
      await services.store.renameSession(sessionId, name);
      final cur = _session;
      if (cur != null && cur.id == sessionId) _session = _withLabel(cur, name);
      final last = _lastSession;
      if (last != null && last.id == sessionId) _lastSession = _withLabel(last, name);
      await refreshSessions();
      return true;
    } catch (e) {
      if (!quiet) _say(friendlyError(e, action: 'Renaming'));
      return false;
    }
  }

  static DriveSession _withLabel(DriveSession s, String? label) => DriveSession(
        id: s.id,
        startedAt: s.startedAt,
        endedAt: s.endedAt,
        label: label,
        channel: s.channel,
        radio: s.radio,
        antenna: s.antenna,
        companion: s.companion,
      );

  // ---------- export / delete ----------
  Future<void> exportAndShare(String sessionId) async {
    try {
      final dir = await services.exportDir();
      final file = await services.store.exportSession(sessionId, services.appInfo, dir);
      await services.shareFile(file);
    } catch (e) {
      _say(friendlyError(e, action: 'Export'));
    }
  }

  /// [quiet]: no "Drive deleted." notice (Settings > Data & storage removes several at once and says so itself).
  Future<bool> deleteSession(String sessionId, {bool quiet = false}) async {
    if (_session?.id == sessionId) {
      if (!quiet) _say('Stop the drive before deleting it.');
      return false;
    }
    try {
      await services.store.deleteSession(sessionId);
      if (_lastFinishedSessionId == sessionId) _lastFinishedSessionId = null;
      if (_lastSession?.id == sessionId) {
        _lastSession = null;
        _pingCount = 0;
        _txCount = 0;
        _heardCount = 0;
        _syncedCount = 0;
        _recent.clear();
      }
      await refreshSessions();
      if (!quiet) _say('Drive deleted.');
      return true;
    } catch (e) {
      if (!quiet) _say(friendlyError(e, action: 'Delete'));
      return false;
    }
  }

  // ---------- settings / key ----------
  Future<void> init() async {
    try {
      _settings = await services.settingsStore.load();
    } catch (e) {
      _settings = const Settings();
      _notice = 'Settings couldn\'t be read, so defaults are in use.';
    }
    // 0.5.0: the website moved off Lovable to MeshSonar's own server (same API and database), so a saved retired
    // address is rewritten to https://meshsonar.com and the driver key is kept (see lib/core/server_url.dart).
    final migrated = migratedServerUrl(_settings.serverUrl);
    if (migrated != null) {
      final from = Uri.tryParse(_settings.serverUrl.trim())?.host ?? 'the old address';
      _settings = _settings.copyWith(serverUrl: migrated);
      diagnostics.add('Server address moved from $from to $migrated (same server, driver key kept)');
      try {
        await services.settingsStore.save(_settings);
      } catch (e) {
        // In use for this run either way; the rewrite repeats at the next launch until a save succeeds.
        _logError('Saving the moved server address failed', e);
        debugPrint('MeshSonar: saving the moved server address failed: $e');
      }
    }
    heard.holdPings = _settings.heardHoldPings;
    try {
      _setRepeaters(await services.repeaterCache.load());
    } catch (_) {}
    final rs = services.repeaterSync;
    if (rs != null) {
      rs.log ??= diagnostics.add;
      rs.deltaCapable = () => _siteConfig?.networkRepeatersDelta ?? false; // unknown site config = full list
      if (!_syncListening) {
        _syncListening = true;
        rs.addListener(_onRepeaterSync);
      }
      await rs.load(); // stored rosters + network list: names and pins before any network call
      _refreshSyncedNames();
    }
    unawaited(refreshLocationAccess());
    _resumeBridge ??= (AppLifecycleBridge(_onForeground)..attach());
    unawaited(_loadDirectory());
    unawaited(refreshSiteConfig());
    unawaited(refreshNetworkCoverage());
    unawaited(refreshRegionIndex());
    await _loadSavedReport();
    _loaded = true;
    notifyListeners();
    _initSync = syncRepeaterLists(SyncTrigger.launch);
    if (!_loadedSignal.isCompleted) _loadedSignal.complete();
    // A drive cut off by a crash or an app kill is still open; close it at its last ping so its end gets synced.
    var orphans = const <String>[];
    try {
      orphans = await closeOrphanedSessions(services.store, except: {if (_session != null) _session!.id});
    } catch (_) {}
    await refreshSessions();
    if (services.telemetryQueueFile != null) {
      // Resume queued headers and any erase request that could not reach the server last time.
      await _tele.load();
      unawaited(_tele.flush());
    }
    if (keyApproved) unawaited(refreshRepeaters(quiet: true));
    if (orphans.isNotEmpty && _settings.autoSync && keyApproved) unawaited(_syncClosedQuietly(orphans));
  }

  /// Background upload of drives closed at startup (their remaining pings and ended_at). Failures stay quiet; the
  /// drives show as not synced and go up with the next sync.
  Future<void> _syncClosedQuietly(List<String> ids) async {
    for (final id in ids) {
      try {
        await _syncService.syncSession(id);
      } catch (_) {}
    }
    await refreshSessions();
  }

  Future<void> updateSettings(Settings s) async {
    // Keys belong to one server: a new server URL with the old key would only be refused, so the key goes with it.
    // Another address of the same server (lib/core/server_url.dart sameServerHosts) keeps it.
    if (s.serverUrl != _settings.serverUrl &&
        !isSameServer(s.serverUrl, _settings.serverUrl) &&
        s.driverKey != null &&
        s.driverKey == _settings.driverKey) {
      s = s.copyWith(clearKey: true);
      _keyError = null;
    }
    // A new server means a new (or no) region/preset; the old one must never display against the new server, so it
    // is cleared immediately and refetched, rather than left stale until the fetch comes back.
    final serverChanged = s.serverUrl != _settings.serverUrl;
    if (serverChanged) _siteConfig = null;
    // Same reasoning as _siteConfig: a new server means new (or no) network-wide coverage; the old server's
    // cells must never display against the new one.
    if (serverChanged) {
      _networkCoverage = null;
      _coverageMeta = null;
      _siteConfigMeta = null;
      _tracker.reset();
    }
    if (_settings.telemetryEnabled && !s.telemetryEnabled) _telemetry?.discard(); // the opt-out takes effect at once
    _settings = s;
    heard.holdPings = s.heardHoldPings; // the heard list's live/stale rule follows the slider at once, even mid-drive
    _scheduleDriveSync(); // in-drive upload follows the toggles, the period and the key status
    _applyPingCadence(s);
    _ctx?.refresh(); // a drive-context category switched off stops at once, one switched on starts now
    notifyListeners();
    if (serverChanged) unawaited(refreshSiteConfig());
    if (serverChanged) unawaited(refreshNetworkCoverage());
    // Not cleared immediately like siteConfig/networkCoverage: the phone's physical region hasn't changed just
    // because the server did, and the old index is a defensible stale guess until the new one answers.
    if (serverChanged) unawaited(refreshRegionIndex());
    try {
      await services.settingsStore.save(s);
    } catch (e) {
      _say('Couldn\'t save settings. ${friendlyError(e, action: 'Saving')}');
    }
  }

  /// Auto-ping interval/distance changed mid-drive: the running engine picks them up at once.
  void _applyPingCadence(Settings s) {
    final engine = _engine;
    if (engine == null || !driving) return;
    final txDbm = _selfInfo?.radio.txDbm;
    engine.updateConfig(WardriveConfig(
      channel: s.channel,
      intervalSec: s.intervalSec,
      minDistanceM: s.minDistanceM,
      txPowerW: txDbm == null ? null : _dbmToWatts(txDbm),
      txDbm: txDbm,
      listenOnly: s.discoveryMode, // ignored by a running engine anyway: listenOnly can't change mid-drive
    ));
  }

  bool _keyBusy = false;
  bool get keyBusy => _keyBusy;
  String? _keyError;
  String? get keyError => _keyError;

  Future<bool> requestKey({required String name, String? callsign, String? email}) async {
    _keyBusy = true;
    _keyError = null;
    notifyListeners();
    final server = _settings.serverUrl;
    try {
      final r = await client.requestKey(
        name: name.trim(),
        callsign: _blankToNull(callsign),
        email: _blankToNull(email),
      );
      if (_settings.serverUrl != server) {
        _keyError = 'The server changed while the key was being requested. Request it again.';
        return false;
      }
      await updateSettings(_settings.copyWith(driverKey: r.key, keyStatus: r.status, display: r.display));
      if (r.status == DriverKeyStatus.approved) unawaited(refreshRepeaters(quiet: true));
      return true;
    } catch (e) {
      _keyError = friendlyError(e, action: 'The key request');
      return false;
    } finally {
      _keyBusy = false;
      notifyListeners();
    }
  }

  /// Uses a driver key created on the website (or copied from another device). The key is checked with the
  /// server first and saved only if it can upload (pending or approved), so a typo, a key from another server or a
  /// dead key never replaces a working setup.
  Future<bool> useExistingKey(String raw) async {
    // Keys never contain whitespace; a paste from a wrapped page or an email can carry a line break mid-key.
    final key = raw.replaceAll(RegExp(r'\s+'), '');
    if (key.isEmpty) {
      _keyError = 'Paste the driver key from the website.';
      notifyListeners();
      return false;
    }
    _keyBusy = true;
    _keyError = null;
    notifyListeners();
    final server = _settings.serverUrl;
    try {
      final r = await client.status(key);
      if (_settings.serverUrl != server) {
        _keyError = 'The server changed while the key was being checked. Paste it again.';
        return false;
      }
      if (r.status != DriverKeyStatus.pending && r.status != DriverKeyStatus.approved) {
        final why = switch (r.status) {
          DriverKeyStatus.rejected => 'was rejected',
          DriverKeyStatus.revoked => 'was revoked',
          _ => "can't upload",
        };
        _keyError = 'That key $why. Create a new one at ${webPage('/me/devices')}.';
        return false;
      }
      await updateSettings(_settings.copyWith(driverKey: key, keyStatus: r.status, display: r.display));
      if (r.status == DriverKeyStatus.approved) unawaited(refreshRepeaters(quiet: true));
      return true;
    } catch (e) {
      _keyError = (e is CmatException && e.status == 401)
          ? "This server doesn't recognise that key. Check you copied all of it, and that it came from ${webPage('/me/devices')}."
          : friendlyError(e, action: 'Checking the key');
      return false;
    } finally {
      _keyBusy = false;
      notifyListeners();
    }
  }

  Future<void> refreshKeyStatus({bool quiet = false}) async {
    final key = _settings.driverKey;
    if (key == null || key.isEmpty) return;
    _keyBusy = true;
    _keyError = null;
    notifyListeners();
    try {
      final r = await client.status(key);
      if (_settings.driverKey != key) return; // the key was removed or replaced (e.g. server changed) meanwhile
      await updateSettings(_settings.copyWith(keyStatus: r.status, display: r.display));
      if (r.status == DriverKeyStatus.approved) unawaited(refreshRepeaters(quiet: true));
    } catch (e) {
      if (e is CmatException && e.status == 401 && _settings.driverKey == key) {
        await updateSettings(_settings.copyWith(keyStatus: DriverKeyStatus.unknown));
      }
      if (!quiet) _keyError = friendlyError(e, action: 'Checking the key');
    } finally {
      _keyBusy = false;
      notifyListeners();
    }
  }

  /// The server's own web page at [path] (e.g. `/me`, `/me/devices`), from the configured server URL.
  String webPage(String path) => '${_settings.serverUrl.replaceAll(RegExp(r'/+$'), '')}$path';

  /// Opens one of the server's web pages in the browser. If no browser can open it, says where to go instead.
  Future<bool> openWebPage(String path) async {
    final url = webPage(path);
    final uri = Uri.tryParse(url);
    var ok = false;
    if (uri != null) {
      try {
        ok = await services.openUrl(uri);
      } catch (_) {}
    }
    if (!ok) _say('Couldn\'t open a browser. Go to $url');
    return ok;
  }

  Future<void> forgetKey() => updateSettings(_settings.copyWith(clearKey: true));

  static String? _blankToNull(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

  // ---------- repeater names ----------
  List<RepeaterRef> _repeaters = const [];
  List<RepeaterRef> get repeaters => _repeaters;
  DateTime? _repeatersAt;
  DateTime? get repeatersUpdatedAt => _repeatersAt;

  void _setRepeaters(List<RepeaterRef> list) {
    _repeaters = list;
    _nameCache.clear();
    _rebuildLookup();
  }

  final Map<String, String?> _nameCache = {};

  /// Name of the repeater whose key starts with [prefix], if exactly one known repeater matches.
  String? repeaterName(String prefix) {
    final p = prefix.toLowerCase();
    return _nameCache.putIfAbsent(p, () {
      final m = _lookup.resolve(p);
      return (m.ref == null || m.ref!.name.isEmpty) ? null : m.ref!.name;
    });
  }

  /// Name if known, else the hex prefix.
  String repeaterLabel(String prefix) => repeaterName(prefix) ?? prefix.toLowerCase();

  Future<void> refreshRepeaters({bool quiet = false}) async {
    if (!quiet) unawaited(refreshDirectory(force: true)); // a manual refresh also refetches the public node map
    final key = _settings.driverKey;
    if (key == null || key.isEmpty) {
      if (!quiet) _say('Request a driver key first.');
      return;
    }
    try {
      final list = await client.repeaters(key);
      _repeatersAt = services.clock();
      // An empty answer never wipes names we already have (names are only a display aid).
      if (list.isNotEmpty || _repeaters.isEmpty) {
        _setRepeaters(list);
        await services.repeaterCache.save(list);
      }
      diagnostics.add('Repeater names: ${list.length} from the server');
      if (!quiet) _say('Updated ${list.length} repeater names.');
      notifyListeners();
    } catch (e) {
      _logError('Updating repeater names failed', e);
      if (!quiet) _say(friendlyError(e, action: 'Updating repeater names'));
    }
  }

  /// Settings > Data & storage: forgets the saved repeater names (on disk and in memory). Repeaters show as short codes
  /// until [refreshRepeaters] downloads the list again.
  Future<void> clearRepeaterNames() async {
    try {
      await services.repeaterCache.save(const []);
    } catch (e) {
      _logError('Clearing the saved repeater names failed', e);
    }
    _setRepeaters(const []);
    _repeatersAt = null;
    notifyListeners();
  }

  /// Settings > Data & storage: forgets the cached public node map (map.meshcore.io). It downloads again around the
  /// first ping of the next drive.
  Future<void> clearPublicNodeMap() async {
    await services.directory?.clear();
    _directory = null;
    setExtraRepeaters(const []);
  }

  // ---------- problem reports ----------
  /// Reports go with the driver key; the server takes them from pending and approved keys.
  bool get canReport =>
      hasKey && (_settings.keyStatus == DriverKeyStatus.pending || _settings.keyStatus == DriverKeyStatus.approved);

  ProblemReportDraft? _savedReport;

  /// The last report that wasn't sent, with its form, kept on the phone until it is sent or discarded. Never sent on
  /// its own.
  ProblemReportDraft? get savedReport => _savedReport;

  Future<void> _loadSavedReport() async {
    try {
      final raw = await services.reportDraftStore?.load();
      if (raw != null) _savedReport = ProblemReportDraft.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
    } catch (e) {
      _logError('The saved problem report couldn\'t be read', e);
    }
  }

  /// Builds the report exactly as it would be sent: what the person wrote, app, phone and radio details, and (if
  /// [includeLog]) the diagnostic log plus a settings snapshot, all redacted. [driveId] attaches a drive by id only.
  Future<ProblemReport> previewProblemReport({
    required String category,
    required String description,
    bool includeLog = true,
    String? driveId,
  }) async {
    final info = connected ? _selfInfo : null;
    return buildProblemReport(
      category: category,
      description: description,
      app: services.appInfo,
      device: {'os': Platform.operatingSystem, 'osVersion': Platform.operatingSystemVersion, 'locale': Platform.localeName},
      radio: info == null
          ? null
          : {
              'name': info.name,
              'firmware': info.firmware,
              'freqMhz': info.radio.freqMhz,
              'bwKhz': info.radio.bwKhz,
              'sf': info.radio.sf,
              'cr': info.radio.cr,
              'txDbm': info.radio.txDbm,
            },
      driveId: driveId,
      log: includeLog ? [...diagnostics.lines, ...settingsSnapshot(_settings, antenna: antennaProfile)] : null,
      // The app's own log may hold the key and the server's full address; they never leave in a report.
      driverKey: _settings.driverKey,
      serverUrl: _settings.serverUrl,
    );
  }

  /// Sends a report the person reviewed. It is saved on the phone first (with [form], so the form can be restored;
  /// without one, the form is read back from the report) and stays saved unless the server takes it.
  Future<ProblemReportOutcome> sendProblemReport(ProblemReport report, {ReportForm? form}) async {
    final key = _settings.driverKey;
    if (!canReport || key == null) {
      return const ProblemReportOutcome(sent: false, message: 'Reports are sent with your driver key. Check it in Settings.');
    }
    if (report.tooLarge) return const ProblemReportOutcome(sent: false, message: 'The report is too large.');
    final draft = ProblemReportDraft(report: report, form: form ?? ReportForm.fromBody(report.body));
    _savedReport = draft;
    notifyListeners();
    try {
      await services.reportDraftStore?.save(jsonEncode(draft.toJson()));
    } catch (e) {
      _logError('Saving the problem report on the phone failed', e);
    }
    try {
      final r = await client.reportProblem(key, report.body);
      final id = r.id.length > 8 ? r.id.substring(0, 8) : r.id;
      diagnostics.add('Problem report sent ($id)');
      await _clearSavedReport();
      return ProblemReportOutcome(sent: true, message: 'Sent. Thank you. Your report number is $id.');
    } catch (e) {
      _logError('Problem report not sent', e);
      return ProblemReportOutcome(
        sent: false,
        message: friendlyReportError(e),
        rejected: e is CmatException && e.status == 400,
      );
    } finally {
      notifyListeners();
    }
  }

  /// Deletes the saved report without sending it.
  Future<void> discardSavedReport() async {
    await _clearSavedReport();
    notifyListeners();
  }

  Future<void> _clearSavedReport() async {
    _savedReport = null;
    try {
      await services.reportDraftStore?.clear();
    } catch (e) {
      _logError('Deleting the saved problem report failed', e);
    }
  }

  // ---------- public node directory (map.meshcore.io; Agent 2) ----------
  /// True when the MeshSonar server's network list (synced, confirmed within 14 days) stands in for the direct
  /// map.meshcore.io download. Without it (404, never fetched, too old) the directory works exactly as before.
  bool get _networkListReplacesDirectory => services.repeaterSync?.networkUsable() ?? false;

  DirectorySnapshot? _directory;

  /// The cached public node directory (repeaters near the last drive area), or null.
  DirectorySnapshot? get directory => _directory;

  void _applyDirectory(DirectorySnapshot? s) {
    if (s == null || identical(s, _directory)) return;
    _directory = s;
    setExtraRepeaters(s.repeaters);
  }

  Future<void> _loadDirectory() async {
    final d = services.directory;
    if (d == null) return;
    try {
      final s = await d.load();
      _applyDirectory(s);
      if (s != null && d.isStale(s) && !_networkListReplacesDirectory) await refreshDirectory(); // once a day, around the last area used
    } catch (_) {}
  }

  /// Refreshes the public node directory around [lat]/[lon] (default: the last drive position, else the cached
  /// centre). Respects the directory's 24 h cache unless [force]. Never throws; offline just keeps the cache.
  Future<void> refreshDirectory({double? lat, double? lon, bool force = false}) async {
    final d = services.directory;
    if (d == null) return;
    if (lat == null || lon == null) {
      final last = _drivePings.isNotEmpty ? _drivePings.last : null;
      lat = last?.lat ?? _directory?.centerLat;
      lon = last?.lon ?? _directory?.centerLon;
    }
    if (lat == null || lon == null) return;
    if (_networkListReplacesDirectory) {
      // The server's network list already holds every repeater with a position: no 17 MB map.meshcore.io download.
      _refreshSyncedNames();
      notifyListeners();
      return;
    }
    try {
      final snap = await d.refresh(lat: lat, lon: lon, force: force);
      if (snap != null && !identical(snap, _directory)) {
        diagnostics.add('Public node map: ${snap.repeaters.length} repeaters nearby');
      }
      _applyDirectory(snap);
    } catch (e) {
      _logError('Refreshing the public node map failed', e);
    }
  }

  @override
  void dispose() {
    _lifecycle?.detach();
    _resumeBridge?.detach();
    services.repeaterSync?.removeListener(_onRepeaterSync);
    unawaited(_idle?.dispose());
    _cancelDriveSync();
    _pingSub?.cancel();
    _statusSub?.cancel();
    _telemetrySub?.cancel();
    unawaited(_telemetry?.dispose());
    super.dispose();
  }
}
