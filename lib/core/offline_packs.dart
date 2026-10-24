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
  factory PackManifestEntry.fromJson(Map<String, dynamic> j, Uri manifestUri) {
    final code = (j['code'] as String?)?.toUpperCase();
    if (code == null || !RegExp(r'^[A-Z0-9]{2,8}$').hasMatch(code)) {
      throw const FormatException('bad pack code');
    }
    final url = manifestUri.resolve(j['url'] as String? ?? '');
    if (url.scheme != 'https' || url.host != manifestUri.host) {
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
}

class PackManifest {
  final List<PackManifestEntry> packs;
  final String attribution;
  const PackManifest(this.packs, this.attribution);

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

enum PackPhase { downloading, verifying, failed }

class PackProgress {
  final PackPhase phase;
  final int received, total;
  final String? error;
  const PackProgress(this.phase, this.received, this.total, [this.error]);
  double? get fraction => total > 0 ? (received / total).clamp(0.0, 1.0) : null;
}

class OfflinePackManager {
  final Directory root;
  final http.Client _client;
  final Uri manifestUri;
  OfflinePackManager({required this.root, required http.Client client, Uri? manifestUri})
    : _client = client, // ignore: prefer_initializing_formals
      manifestUri = manifestUri ?? Uri.parse(defaultPackManifestUrl);

  final Map<String, InstalledPack> _installed = {};
  final Map<String, PackProgress> _active = {};
  final Map<String, bool> _cancel = {};
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;
  Map<String, InstalledPack> get installed => Map.unmodifiable(_installed);
  Map<String, PackProgress> get active => Map.unmodifiable(_active);
  File get _indexFile => File(p.join(root.path, 'packs.json'));
  File packFile(String code) => File(p.join(root.path, '$code.pmtiles'));
  File _partFile(String code) => File(p.join(root.path, '$code.pmtiles.part'));

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
    _notify();
  }

  Future<void> _saveIndex() async {
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({for (final e in _installed.entries) e.key: e.value.toJson()}), flush: true);
    await tmp.rename(_indexFile.path);
  }

  Future<PackManifest> fetchManifest() async {
    final r = await _client.get(manifestUri).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw HttpException('manifest HTTP ${r.statusCode}', uri: manifestUri);
    }
    return PackManifest.parse(utf8.decode(r.bodyBytes), manifestUri);
  }

  bool updateAvailable(PackManifestEntry e) => (_installed[e.code]?.version ?? e.version) < e.version;

  /// Bytes on disk used by installed packs plus partial downloads.
  Future<int> usedBytes() async {
    var n = 0;
    if (!await root.exists()) return 0;
    await for (final f in root.list()) {
      if (f is File && (f.path.endsWith('.pmtiles') || f.path.endsWith('.pmtiles.part'))) n += await f.length();
    }
    return n;
  }

  /// Downloads (or resumes) a pack. Resumes from `<code>.pmtiles.part` with an HTTP Range request; a server that ignores
  /// Range (200) restarts it. The file is size- and SHA-256-verified before it replaces any installed version.
  Future<void> download(PackManifestEntry e) async {
    if (_active.containsKey(e.code)) return;
    _cancel[e.code] = false;
    await root.create(recursive: true);
    final part = _partFile(e.code);
    IOSink? sink;
    try {
      var have = await part.exists() ? await part.length() : 0;
      if (have > e.bytes) {
        await part.delete();
        have = 0;
      }
      _active[e.code] = PackProgress(PackPhase.downloading, have, e.bytes);
      _notify();
      if (have < e.bytes) {
        final req = http.Request('GET', e.url);
        if (have > 0) req.headers['range'] = 'bytes=$have-';
        final resp = await _client.send(req).timeout(const Duration(seconds: 30));
        if (resp.statusCode == 200 && have > 0) {
          have = 0; // server ignored Range: start over
        } else if (resp.statusCode != 200 && resp.statusCode != 206) {
          throw HttpException('pack HTTP ${resp.statusCode}', uri: e.url);
        }
        final out = sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
        var got = have;
        var lastNotify = 0;
        await for (final chunk in resp.stream) {
          if (_cancel[e.code] == true) {
            await out.flush();
            await out.close();
            sink = null;
            _active.remove(e.code);
            _notify();
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
      if (await part.length() != e.bytes) {
        throw const FormatException('incomplete download');
      }
      final digest = await sha256.bind(part.openRead()).first;
      if (digest.toString() != e.sha256) {
        await part.delete();
        throw const FormatException('checksum mismatch (download discarded)');
      }
      await part.rename(packFile(e.code).path); // atomic replace of any older version
      _installed[e.code] = InstalledPack(
        code: e.code,
        name: e.name,
        version: e.version,
        bytes: e.bytes,
        sha256: e.sha256,
        bbox: e.bbox,
        installedAt: DateTime.now(),
      );
      await _saveIndex();
      _active.remove(e.code);
    } catch (err) {
      try {
        await sink?.close();
      } catch (_) {}
      final noSpace = err is FileSystemException && err.osError?.errorCode == 28;
      _active[e.code] = PackProgress(
        PackPhase.failed,
        0,
        e.bytes,
        noSpace ? 'Not enough free space on this device' : 'Download failed: ${_short(err)}',
      );
    } finally {
      _notify();
    }
  }

  String _short(Object e) => e.toString().replaceAll(RegExp(r'\s+'), ' ').split(' (')[0];

  /// Stops a running download. The partial file is kept so [download] resumes.
  void cancel(String code) => _cancel[code] = true;

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
    for (final f in [packFile(code), _partFile(code)]) {
      if (await f.exists()) await f.delete();
    }
    _installed.remove(code);
    await _saveIndex();
    _notify();
  }

  /// The installed pack whose bounding box contains the point (smallest box wins), for the map's offline layer.
  InstalledPack? packCovering(double lat, double lon) {
    InstalledPack? best;
    var bestArea = double.infinity;
    for (final ip in _installed.values) {
      if (!ip.covers(lat, lon)) continue;
      final area = (ip.bbox[2] - ip.bbox[0]) * (ip.bbox[3] - ip.bbox[1]);
      if (area < bestArea) {
        best = ip;
        bestArea = area;
      }
    }
    return best;
  }

  void dispose() => _changes.close();
}
