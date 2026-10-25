// Offline region map packs: a versioned manifest of per-region PMTiles files (our own OSM-derived vector tiles, built by
// meshsonar-infra/scripts/tiles/build-region-pack.sh), a resumable downloader and storage accounting. Pure Dart.
//
// Privacy/hosts: the manifest is a public static file on the MeshSonar tiles host (R2 behind tiles.meshsonar.com); pack URLs must be https and on the SAME host as
// the manifest (no wildcard, no third-party CDN without a spec decision). No driver key or identifier is ever sent here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

const defaultPackManifestUrl = 'https://tiles.meshsonar.com/manifest.json';

class PackManifestEntry {
  final String code, name, sha256;
  final int version, bytes, minZoom, maxZoom;
  final Uri url;
  final List<double> bbox; // minLon, minLat, maxLon, maxLat
  const PackManifestEntry({
    required this.code,
    required this.name,
    required this.version,
    required this.bytes,
    required this.sha256,
    required this.url,
    required this.bbox,
    required this.minZoom,
    required this.maxZoom,
  });

  /// Throws [FormatException] for an unusable entry (callers skip it rather than fail the whole manifest).
  factory PackManifestEntry.fromJson(Map<String, dynamic> j, Uri manifestUri, {bool requireHttps = true}) {
    final code = (j['code'] as String?)?.toUpperCase();
    if (code == null || !RegExp(r'^[A-Z0-9]{2,8}$').hasMatch(code)) {
      throw const FormatException('bad pack code');
    }
    final url = manifestUri.resolve(j['url'] as String? ?? '');
    if ((requireHttps && url.scheme != 'https') || url.host != manifestUri.host) {
      throw FormatException('pack url not on manifest host: $url');
    }
    final bytes = j['bytes'];
    final version = j['version'];
    final sha = (j['sha256'] as String? ?? '').toLowerCase();
    final bbox = (j['bbox'] as List?)?.map((e) => (e as num).toDouble()).toList();
    if (bytes is! int || bytes <= 0 || version is! int || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) || bbox == null || bbox.length != 4) {
      throw const FormatException('bad pack fields');
    }
    return PackManifestEntry(
      code: code,
      name: j['name'] as String? ?? code,
      version: version,
      bytes: bytes,
      sha256: sha,
      url: url,
      bbox: bbox,
      minZoom: (j['min_zoom'] as int?) ?? 0,
      maxZoom: (j['max_zoom'] as int?) ?? 14,
    );
  }

  bool covers(double lat, double lon) => lat >= bbox[1] && lat <= bbox[3] && lon >= bbox[0] && lon <= bbox[2];

  /// Same shape as the manifest entry (absolute url), so a queued download survives a restart with no network.
  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'version': version,
    'bytes': bytes,
    'sha256': sha256,
    'url': url.toString(),
    'bbox': bbox,
    'min_zoom': minZoom,
    'max_zoom': maxZoom,
  };
}

class PackManifest {
  final List<PackManifestEntry> packs;
  final String attribution;

  /// When this copy was last confirmed by the server (200 or 304). Null for a freshly parsed body.
  final DateTime? fetchedAt;

  /// True when the server could not be reached and this is the last saved copy.
  final bool fromCache;
  const PackManifest(this.packs, this.attribution, {this.fetchedAt, this.fromCache = false});

  PackManifest copyWith({DateTime? fetchedAt, bool? fromCache}) =>
      PackManifest(packs, attribution, fetchedAt: fetchedAt ?? this.fetchedAt, fromCache: fromCache ?? this.fromCache);

  factory PackManifest.parse(String body, Uri manifestUri) {
    final j = jsonDecode(body);
    if (j is! Map<String, dynamic> || j['packs'] is! List) {
      throw const FormatException('manifest shape');
    }
    final out = <PackManifestEntry>[];
    for (final e in j['packs'] as List) {
      try {
        out.add(PackManifestEntry.fromJson(e as Map<String, dynamic>, manifestUri));
      } on FormatException {
        // skip an unusable entry
      } on TypeError {
        // skip
      }
    }
    return PackManifest(out, j['attribution'] as String? ?? '© OpenStreetMap contributors');
  }
}

class InstalledPack {
  final String code, name, sha256;
  final int version, bytes;
  final List<double> bbox; // stored so the map can pick a pack with no network and no manifest
  final DateTime installedAt;
  const InstalledPack({
    required this.code,
    required this.name,
    required this.version,
    required this.bytes,
    required this.sha256,
    required this.bbox,
    required this.installedAt,
  });
  factory InstalledPack.fromJson(String code, Map<String, dynamic> j) => InstalledPack(
    code: code,
    name: j['name'] as String? ?? code,
    version: j['version'] as int,
    bytes: j['bytes'] as int,
    sha256: j['sha256'] as String,
    bbox: (j['bbox'] as List).map((e) => (e as num).toDouble()).toList(),
    installedAt: DateTime.parse(j['installed_at'] as String),
  );
  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    'bytes': bytes,
    'sha256': sha256,
    'bbox': bbox,
    'installed_at': installedAt.toUtc().toIso8601String(),
  };
  bool covers(double lat, double lon) => lat >= bbox[1] && lat <= bbox[3] && lon >= bbox[0] && lon <= bbox[2];
}

/// What kind of network the device is on, as far as the download policy cares. Pure Dart: the platform seam
/// (lib/platform/network_monitor.dart) maps the OS answer onto this.
enum NetworkKind { wifi, cellular, offline, unknown }

/// Reports the current network and its changes. The app uses connectivity_plus behind lib/platform; tests use a fake.
abstract class NetworkMonitor {
  Future<NetworkKind> current();
  Stream<NetworkKind> get changes;
}

/// [waiting]: the user asked for this pack but the policy holds it (Wi-Fi only on cellular, or no connection); it
/// starts or resumes by itself when the network allows.
enum PackPhase { downloading, verifying, waiting, failed }

class PackProgress {
  final PackPhase phase;
  final int received, total;
  final String? error;
  const PackProgress(this.phase, this.received, this.total, [this.error]);
  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

/// Why [OfflinePackManager.start] did not begin downloading at once.
enum StartResult { started, needsCellularConsent, offline }

class OfflinePackManager {
  final Directory root;
  final http.Client _client;
  final Uri manifestUri;

  /// Opens the sink a download writes to. Tests replace it to simulate a full disk.
  final IOSink Function(File file, FileMode mode) openSink;

  /// A download that receives nothing for this long fails (keeping the .part) instead of hanging forever.
  final Duration idleTimeout;
  OfflinePackManager({
    required this.root,
    required http.Client client,
    Uri? manifestUri,
    IOSink Function(File file, FileMode mode)? openSink,
    this.idleTimeout = const Duration(seconds: 30),
  }) : _client = client, // ignore: prefer_initializing_formals
       manifestUri = manifestUri ?? Uri.parse(defaultPackManifestUrl),
       openSink = openSink ?? ((f, m) => f.openWrite(mode: m));

  final Map<String, InstalledPack> _installed = {};
  final Map<String, PackProgress> _active = {};
  final Map<String, bool> _cancel = {};
  // Downloads the user asked for and has not paused or finished: resumed automatically (persisted in prefs.json).
  final Map<String, PackManifestEntry> _pending = {};
  // Packs the user OK'd over cellular in this app session (never persisted: a new session asks again).
  final Set<String> _cellularOk = {};
  bool _wifiOnly = true;
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;
  Map<String, InstalledPack> get installed => Map.unmodifiable(_installed);
  Map<String, PackProgress> get active => Map.unmodifiable(_active);
  Map<String, PackManifestEntry> get pending => Map.unmodifiable(_pending);

  /// Download packs only on Wi-Fi (default ON). On cellular the app shows the size and asks first.
  bool get wifiOnly => _wifiOnly;
  File get _indexFile => File(p.join(root.path, 'packs.json'));
  File get _prefsFile => File(p.join(root.path, 'prefs.json'));
  File get _manifestCache => File(p.join(root.path, 'manifest.cache.json'));
  File packFile(String code) => File(p.join(root.path, '$code.pmtiles'));
  File _partFile(String code) => File(p.join(root.path, '$code.pmtiles.part'));
  // Which version the .part holds; a .part for another version (or of unknown origin) is discarded, never appended to.
  File _partMeta(String code) => File(p.join(root.path, '$code.pmtiles.part.json'));

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> load() async {
    await root.create(recursive: true);
    _installed.clear();
    try {
      final j = jsonDecode(await _indexFile.readAsString()) as Map<String, dynamic>;
      for (final e in j.entries) {
        try {
          final ip = InstalledPack.fromJson(e.key, e.value as Map<String, dynamic>);
          if (await packFile(ip.code).exists()) _installed[ip.code] = ip;
        } catch (_) {}
      }
    } catch (_) {
      // missing or corrupt index: nothing installed; orphan files are reclaimed by deleteAll/usedBytes
    }
    _pending.clear();
    try {
      final j = jsonDecode(await _prefsFile.readAsString()) as Map<String, dynamic>;
      _wifiOnly = j['wifi_only'] as bool? ?? true;
      for (final e in (j['pending'] as List? ?? const [])) {
        try {
          // Written by us from an entry that already passed the manifest checks; re-checked against its own URL.
          final j = e as Map<String, dynamic>;
          final pe = PackManifestEntry.fromJson(j, Uri.parse(j['url'] as String), requireHttps: false);
          _pending[pe.code] = pe;
          _active[pe.code] = PackProgress(PackPhase.waiting, await _partBytes(pe), pe.bytes);
        } catch (_) {}
      }
    } catch (_) {
      // no prefs yet: Wi-Fi only, nothing queued
    }
    _notify();
  }

  // Index/prefs writes are synchronous (files of a few hundred bytes): a pause and a restart, or two packs, can save at
  // the same moment, and async writers sharing one .tmp lost a rename. A Future-chain queue fixed that but deadlocked
  // widget tests (a write queued inside the fake-async zone never ran, blocking every later write), so: no awaits.
  Future<void> _atomicWrite(File f, String Function() content) async {
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(content(), flush: true);
    tmp.renameSync(f.path);
  }

  Future<void> _saveIndex() =>
      _atomicWrite(_indexFile, () => jsonEncode({for (final e in _installed.entries) e.key: e.value.toJson()}));

  Future<void> _savePrefs() => _atomicWrite(
    _prefsFile,
    () => jsonEncode({
      'wifi_only': _wifiOnly,
      'pending': [for (final e in _pending.values) e.toJson()],
    }),
  );

  Future<void> setWifiOnly(bool on) async {
    _wifiOnly = on;
    await root.create(recursive: true);
    await _savePrefs();
    _notify();
  }

  /// The pack list. Sends If-None-Match with the saved ETag (a 304 costs no body) and keeps the last good copy on
  /// disk, so the screen still lists packs with no network ([PackManifest.fromCache]). Throws only when there is
  /// neither a server answer nor a saved copy.
  Future<PackManifest> fetchManifest() async {
    Map<String, dynamic>? cache;
    try {
      cache = jsonDecode(await _manifestCache.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    PackManifest? cached() {
      if (cache == null) return null;
      try {
        return PackManifest.parse(cache['body'] as String, manifestUri).copyWith(
          fetchedAt: DateTime.tryParse(cache['fetched_at'] as String? ?? ''),
        );
      } catch (_) {
        return null;
      }
    }

    try {
      final etag = cache?['etag'] as String?;
      final r = await _client
          .get(manifestUri, headers: {if (etag != null && cached() != null) 'if-none-match': etag})
          .timeout(const Duration(seconds: 20));
      final now = DateTime.now().toUtc();
      if (r.statusCode == 304 && cached() != null) {
        cache!['fetched_at'] = now.toIso8601String();
        await _writeManifestCache(cache);
        return cached()!.copyWith(fetchedAt: now);
      }
      if (r.statusCode != 200) {
        throw HttpException('manifest HTTP ${r.statusCode}', uri: manifestUri);
      }
      final body = utf8.decode(r.bodyBytes);
      final m = PackManifest.parse(body, manifestUri).copyWith(fetchedAt: now);
      await _writeManifestCache({'etag': r.headers['etag'], 'fetched_at': now.toIso8601String(), 'body': body});
      return m;
    } catch (e) {
      final c = cached();
      if (c != null) return c.copyWith(fromCache: true);
      rethrow;
    }
  }

  Future<void> _writeManifestCache(Map<String, dynamic> j) async {
    try {
      await root.create(recursive: true);
      final tmp = File('${_manifestCache.path}.tmp');
      await tmp.writeAsString(jsonEncode(j), flush: true);
      await tmp.rename(_manifestCache.path);
    } catch (_) {
      // a cache we cannot write only costs a re-download of a few hundred bytes next time
    }
  }

  bool updateAvailable(PackManifestEntry e) => (_installed[e.code]?.version ?? e.version) < e.version;

  /// Bytes on disk used by installed packs plus partial downloads.
  /// Never throws: files are renamed (`.part` -> `.pmtiles`) or deleted while this runs (a download finishing, a
  /// delete, a test tearing its folder down). That race made the Offline maps screen test flaky on main
  /// (PathNotFoundException from `File.length` on a `.part` that had just been renamed).
  Future<int> usedBytes() async {
    var n = 0;
    for (final v in (await bytesByPack()).values) {
      n += v;
    }
    return n;
  }

  /// Bytes of a partial download that belongs to [e] (0 when none, or when it is for another version).
  Future<int> _partBytes(PackManifestEntry e) async {
    final part = _partFile(e.code);
    try {
      final meta = jsonDecode(await _partMeta(e.code).readAsString()) as Map<String, dynamic>;
      if (meta['sha256'] == e.sha256 && meta['bytes'] == e.bytes) return await _lengthOr0(part);
    } catch (_) {}
    return 0;
  }

  /// Policy gate for a user's Download / Update / Retry tap. On Wi-Fi (or with Wi-Fi only off) it starts at once.
  /// On cellular with Wi-Fi only on, nothing starts until the user answers ([needsCellularConsent]: call
  /// [allowCellular] + [start] again, or [queueForWifi]). With no connection it is queued and starts by itself later.
  Future<StartResult> start(PackManifestEntry e, NetworkKind net) async {
    if (net == NetworkKind.offline) {
      await queueForWifi(e);
      return StartResult.offline;
    }
    if (!_mayUse(e.code, net)) return StartResult.needsCellularConsent;
    unawaited(download(e));
    return StartResult.started;
  }

  bool _mayUse(String code, NetworkKind net) =>
      net == NetworkKind.wifi || (net != NetworkKind.offline && (!_wifiOnly || _cellularOk.contains(code)));

  /// The user said yes to this pack over cellular for this session.
  void allowCellular(String code) => _cellularOk.add(code);

  /// Remember the request; [onNetwork] / [resumePending] start it when the policy allows.
  Future<void> queueForWifi(PackManifestEntry e) async {
    _pending[e.code] = e;
    _active[e.code] = PackProgress(PackPhase.waiting, await _partBytes(e), e.bytes);
    await root.create(recursive: true);
    await _savePrefs();
    _notify();
  }

  /// Call when the network changes. Wi-Fi only: a running download on a pack not OK'd for cellular is paused (the
  /// .part is kept) when the phone drops to cellular; queued downloads start when Wi-Fi is back.
  Future<void> onNetwork(NetworkKind net) async {
    for (final code in _active.keys.toList()) {
      if (_active[code]?.phase == PackPhase.downloading && !_mayUse(code, net) && net != NetworkKind.offline) {
        _cancel[code] = true;
        _holdForNetwork.add(code);
      }
    }
    await resumePending(net);
  }

  final Set<String> _holdForNetwork = {};

  /// Starts or resumes every queued download the network allows (call on launch, on return to the foreground and on
  /// network changes). Returns how many were started.
  Future<int> resumePending(NetworkKind net) async {
    var n = 0;
    for (final e in _pending.values.toList()) {
      final ph = _active[e.code]?.phase;
      if (ph == PackPhase.downloading || ph == PackPhase.verifying) continue;
      if (ph == PackPhase.failed && !_retryable.contains(e.code)) continue;
      if (!_mayUse(e.code, net)) {
        if (ph != PackPhase.waiting) {
          _active[e.code] = PackProgress(PackPhase.waiting, await _partBytes(e), e.bytes);
          _notify();
        }
        continue;
      }
      unawaited(download(e));
      n++;
    }
    return n;
  }

  // Failures worth retrying by themselves (network, timeouts). Checksum mismatches, HTTP 4xx and a full disk are not.
  final Set<String> _retryable = {};

  /// Downloads (or resumes) a pack. Resumes from `<code>.pmtiles.part` with an HTTP Range request; a server that ignores
  /// Range (200) restarts it. The file is size- and SHA-256-verified before it replaces any installed version, so an
  /// older installed version keeps working until the new one is verified. Callers normally go through [start].
  Future<void> download(PackManifestEntry e) async {
    final ph = _active[e.code]?.phase;
    if (ph == PackPhase.downloading || ph == PackPhase.verifying) return;
    _cancel[e.code] = false;
    _holdForNetwork.remove(e.code);
    _retryable.remove(e.code);
    await root.create(recursive: true);
    if (!_pending.containsKey(e.code) || _pending[e.code]!.sha256 != e.sha256) {
      _pending[e.code] = e;
      await _savePrefs();
    }
    final part = _partFile(e.code);
    IOSink? sink;
    try {
      var have = await _partBytes(e);
      if (have == 0 && await part.exists()) await part.delete(); // other version or unknown origin
      if (have > e.bytes) {
        await part.delete();
        have = 0;
      }
      await _partMeta(e.code).writeAsString(jsonEncode({'sha256': e.sha256, 'bytes': e.bytes, 'version': e.version}));
      _active[e.code] = PackProgress(PackPhase.downloading, have, e.bytes);
      _notify();
      if (have < e.bytes) {
        final req = http.Request('GET', e.url);
        if (have > 0) req.headers['range'] = 'bytes=$have-';
        final resp = await _client.send(req).timeout(const Duration(seconds: 30));
        if (resp.statusCode == 200 && have > 0) {
          have = 0; // server ignored Range: start over
        } else if (resp.statusCode == 206) {
          final cr = RegExp(r'bytes (\d+)-').firstMatch(resp.headers['content-range'] ?? '');
          if (cr != null && int.parse(cr.group(1)!) != have) {
            throw HttpException('server resumed at ${cr.group(1)}, expected $have', uri: e.url);
          }
        } else if (resp.statusCode != 200) {
          if (resp.statusCode >= 500 || resp.statusCode == 408 || resp.statusCode == 429) _retryable.add(e.code);
          throw HttpException('pack HTTP ${resp.statusCode}', uri: e.url);
        }
        final out = sink = openSink(part, have > 0 ? FileMode.append : FileMode.write);
        var got = have;
        var lastNotify = 0;
        await for (final chunk in resp.stream.timeout(idleTimeout)) {
          if (_cancel[e.code] == true) {
            await out.flush();
            await out.close();
            sink = null;
            if (_holdForNetwork.remove(e.code)) {
              _active[e.code] = PackProgress(PackPhase.waiting, got, e.bytes); // resumes on Wi-Fi
            } else {
              _active.remove(e.code);
            }
            return; // .part kept so the next download resumes
          }
          out.add(chunk);
          got += chunk.length;
          if (got - lastNotify > 256 * 1024 || got >= e.bytes) {
            lastNotify = got;
            _active[e.code] = PackProgress(PackPhase.downloading, got, e.bytes);
            _notify();
          }
        }
        await out.flush();
        await out.close();
        sink = null;
      }
      _active[e.code] = PackProgress(PackPhase.verifying, e.bytes, e.bytes);
      _notify();
      final len = await part.length();
      if (len != e.bytes) {
        _retryable.add(e.code); // connection closed early: resume from what we have
        throw FormatException('incomplete download (${len ~/ 1024} of ${e.bytes ~/ 1024} KB)');
      }
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != e.sha256) {
        await part.delete();
        await _deleteQuietly(_partMeta(e.code));
        _pending.remove(e.code);
        await _savePrefs();
        throw const FormatException('checksum mismatch (download discarded)');
      }
      await part.rename(packFile(e.code).path); // atomic replace of any older version
      await _deleteQuietly(_partMeta(e.code));
      _installed[e.code] = InstalledPack(
        code: e.code,
        name: e.name,
        version: e.version,
        bytes: e.bytes,
        sha256: e.sha256,
        bbox: e.bbox,
        installedAt: DateTime.now(),
      );
      _pending.remove(e.code); // same moment as installed: no observer sees "installed and still queued"
      _active.remove(e.code);
      await _saveIndex();
      await _savePrefs();
    } catch (err) {
      try {
        await sink?.close();
      } catch (_) {}
      final noSpace = _isNoSpace(err);
      if (err is TimeoutException || err is SocketException || err is http.ClientException) _retryable.add(e.code);
      if (noSpace) _retryable.remove(e.code);
      final kept = await _partBytes(e);
      _active[e.code] = PackProgress(
        PackPhase.failed,
        kept,
        e.bytes,
        noSpace
            ? 'Not enough free space on this device. Free some space, then Retry (${_mb(kept)} of ${_mb(e.bytes)} kept).'
            : 'Download failed: ${_short(err)}${kept > 0 ? ' (${_mb(kept)} of ${_mb(e.bytes)} kept, Retry resumes)' : ''}',
      );
    } finally {
      _notify();
    }
  }

  static bool _isNoSpace(Object err) {
    if (err is! FileSystemException) return false;
    final code = err.osError?.errorCode;
    return code == 28 || code == 112 || (err.osError?.message.toLowerCase().contains('no space') ?? false);
  }

  static String _mb(int b) => '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';

  String _short(Object e) {
    if (e is TimeoutException) return 'the connection stalled';
    if (e is SocketException || e is http.ClientException) return 'connection lost';
    return e.toString().replaceAll(RegExp(r'\s+'), ' ').split(' (')[0].replaceFirst(RegExp(r'^\w+Exception: '), '');
  }

  // A .part can be renamed to .pmtiles between listing the folder and reading its length.
  static Future<int> _lengthOr0(File f) async {
    try {
      return await f.length();
    } on FileSystemException {
      return 0;
    }
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Pauses a running download (the user's choice: it is NOT resumed automatically). The partial file is kept so
  /// [download] resumes from it.
  Future<void> cancel(String code) async {
    _cancel[code] = true;
    _holdForNetwork.remove(code);
    if (_pending.remove(code) != null) await _savePrefs();
    if (_active[code]?.phase == PackPhase.waiting) {
      _active.remove(code);
      _notify();
    }
  }

  void dismissError(String code) {
    if (_active[code]?.phase == PackPhase.failed) {
      _active.remove(code);
      _notify();
    }
  }

  /// Removes an installed pack and any partial download.
  Future<void> delete(String code) async {
    _cancel[code] = true;
    _active.remove(code);
    _pending.remove(code);
    for (final f in [packFile(code), _partFile(code), _partMeta(code)]) {
      if (await f.exists()) await f.delete();
    }
    _installed.remove(code);
    await _saveIndex();
    await _savePrefs();
    _notify();
  }

  /// Removes every pack, every partial download and any stray pack file (e.g. left by a crash or an old version).
  /// Keeps the manifest cache and the Wi-Fi setting.
  Future<void> deleteAll() async {
    for (final code in {..._active.keys, ..._pending.keys}) {
      _cancel[code] = true;
    }
    _active.clear();
    _pending.clear();
    _installed.clear();
    if (await root.exists()) {
      await for (final f in root.list()) {
        if (f is File && RegExp(r'\.pmtiles(\.part(\.json)?)?$').hasMatch(f.path)) await _deleteQuietly(f);
      }
    }
    await root.create(recursive: true);
    await _saveIndex();
    await _savePrefs();
    _notify();
  }

  /// Per-pack bytes on disk (installed file plus any partial download), for the storage list.
  /// Same race-safety as [usedBytes].
  Future<Map<String, int>> bytesByPack() async {
    final out = <String, int>{};
    try {
      await for (final f in root.list()) {
        if (f is! File) continue;
        final m = RegExp(r'^([A-Za-z0-9]+)\.pmtiles(\.part)?$').firstMatch(p.basename(f.path));
        if (m == null) continue;
        out[m.group(1)!] = (out[m.group(1)!] ?? 0) + await _lengthOr0(f);
      }
    } on FileSystemException {
      // folder missing or removed mid-listing: what was counted so far
    }
    return out;
  }

  /// The installed pack whose bounding box contains the point (smallest box wins, ties by code so the choice is
  /// stable), for the map's offline layer. [where] filters candidates (e.g. only packs whose file opened).
  InstalledPack? packCovering(double lat, double lon, {bool Function(String code)? where}) {
    InstalledPack? best;
    var bestArea = double.infinity;
    for (final ip in _installed.values) {
      if (!ip.covers(lat, lon) || (where != null && !where(ip.code))) continue;
      final area = (ip.bbox[2] - ip.bbox[0]) * (ip.bbox[3] - ip.bbox[1]);
      if (area < bestArea || (area == bestArea && best != null && ip.code.compareTo(best.code) < 0)) {
        best = ip;
        bestArea = area;
      }
    }
    return best;
  }

  void dispose() => _changes.close();
}
