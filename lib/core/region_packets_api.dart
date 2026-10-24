// Read-only client for the website's per-region packet feed (`region-packets`, public GET, region host only).
// Pure Dart. Contract: meshcore-insights `src/lib/region/types.ts` (PacketRow / PacketPage / Sourced).
// The live view is polled (not SSE): the server caches this read for 15 s, so polling every 10 s is cheap.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'etag_client.dart';

/// Payload type names (MeshCore header bits 2-5), same table as the site's `packet-types.ts`.
const Map<int, String> packetTypeNames = {
  0: 'Request',
  1: 'Response',
  2: 'Direct message',
  3: 'Ack',
  4: 'Advert',
  5: 'Group text',
  6: 'Group data',
  7: 'Anonymous request',
  8: 'Path',
  9: 'Trace',
  10: 'Multipart',
  11: 'Control',
  15: 'Raw custom',
};
String packetTypeName(int t) => packetTypeNames[t] ?? 'Type $t';

/// 0 transport flood, 1 flood, 2 direct, 3 transport direct.
const List<String> packetRouteNames = ['Transport flood', 'Flood', 'Direct', 'Transport direct'];
String packetRouteName(int r) => r >= 0 && r < packetRouteNames.length ? packetRouteNames[r] : 'Route $r';

/// Server data-availability state (`Sourced.state`).
enum SourcedState { ready, partial, pending, unavailable, stale }

class PacketsStatus {
  final SourcedState state;
  final String? reason;
  const PacketsStatus(this.state, this.reason);

  factory PacketsStatus.fromJson(Object? j) {
    if (j is! Map) return const PacketsStatus(SourcedState.ready, null);
    final s = SourcedState.values.where((e) => e.name == j['state']).firstOrNull ?? SourcedState.unavailable;
    return PacketsStatus(s, j['reason'] is String ? j['reason'] as String : null);
  }
}

class PacketRow {
  final String hash;
  final int type;
  final int route;
  final DateTime firstAt;
  final int observers;
  final int minHops;
  final double? bestSnrDb;
  final String? originName;

  /// Bytes per hop hash. The list endpoint does not send it today; read when a server version adds `hashSize`.
  final int? hashSize;
  const PacketRow({
    required this.hash,
    required this.type,
    required this.route,
    required this.firstAt,
    required this.observers,
    required this.minHops,
    this.bestSnrDb,
    this.originName,
    this.hashSize,
  });

  /// Null when the row is unusable (no hash or time); the caller skips it.
  static PacketRow? tryParse(Object? j) {
    if (j is! Map) return null;
    final hash = j['hash'];
    final at = j['firstAt'] is String ? DateTime.tryParse(j['firstAt'] as String) : null;
    if (hash is! String || hash.isEmpty || at == null) return null;
    int i(Object? v, int d) => v is num ? v.toInt() : d;
    return PacketRow(
      hash: hash,
      type: i(j['type'], -1),
      route: i(j['route'], -1),
      firstAt: at.toUtc(),
      observers: i(j['observers'], 0),
      minHops: i(j['minHops'], 0),
      bestSnrDb: j['bestSnrDb'] is num ? (j['bestSnrDb'] as num).toDouble() : null,
      originName: j['originName'] is String && (j['originName'] as String).isNotEmpty ? j['originName'] as String : null,
      hashSize: j['hashSize'] is num ? (j['hashSize'] as num).toInt() : null,
    );
  }
}

class PacketPage {
  final PacketsStatus status;
  final List<PacketRow> rows;
  final String? nextCursor;
  const PacketPage({required this.status, required this.rows, this.nextCursor});

  factory PacketPage.fromJson(Map<String, dynamic> j) {
    final rows = <PacketRow>[];
    final raw = j['rows'];
    if (raw is List) {
      for (final r in raw) {
        final p = PacketRow.tryParse(r);
        if (p != null) rows.add(p);
      }
    }
    return PacketPage(
      status: PacketsStatus.fromJson(j['status']),
      rows: rows,
      nextCursor: j['nextCursor'] is String ? j['nextCursor'] as String : null,
    );
  }
}

/// A failed read. [busy] = the server (or its rate limit) asked us to back off: keep what is on screen and retry.
class PacketsException implements Exception {
  final String message;
  final int? status;
  final bool busy;
  const PacketsException(this.message, {this.status, this.busy = false});
  @override
  String toString() => message;
}

abstract class RegionPacketsApi {
  /// [route]: 0 transport flood, 1 flood, 2 direct, 3 transport direct; null = any. [type]: 0-15 or null.
  Future<PacketPage> packets({int limit = 50, int? route, int? type, String? cursor});
}

class HttpRegionPacketsApi implements RegionPacketsApi {
  final Uri baseUrl;
  final http.Client _http;
  final Duration timeout;
  HttpRegionPacketsApi(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 20)})
      : _http = client ?? newRegionWireClient();

  Uri endpoint(Map<String, String> query) {
    var path = baseUrl.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return baseUrl.replace(path: '$path/api/cmh/region-packets', queryParameters: query.isEmpty ? null : query, fragment: null);
  }

  @override
  Future<PacketPage> packets({int limit = 50, int? route, int? type, String? cursor}) async {
    final q = <String, String>{
      'limit': '${limit.clamp(1, 200)}',
      if (route != null) 'route': '$route',
      if (type != null) 'type': '$type',
      'cursor': ?cursor,
    };
    http.Response res;
    try {
      res = await _http.get(endpoint(q), headers: {'accept': 'application/json'}).timeout(timeout);
    } on TimeoutException {
      throw PacketsException('timed out talking to ${baseUrl.host}');
    } on SocketException catch (e) {
      throw PacketsException('network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw PacketsException('network error: ${e.message}');
    } on HandshakeException catch (e) {
      throw PacketsException('secure connection failed: ${e.message}');
    }
    Object? body;
    try {
      body = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      body = null;
    }
    if (res.statusCode != 200) {
      final err = body is Map && body['error'] is String ? body['error'] as String : null;
      final busy = res.statusCode == 429 || res.statusCode == 503 || res.statusCode == 502 || res.statusCode == 504;
      throw PacketsException(err ?? 'server answered ${res.statusCode}', status: res.statusCode, busy: busy);
    }
    if (body is! Map) throw PacketsException('server sent an unreadable answer', status: res.statusCode);
    return PacketPage.fromJson(body.cast<String, dynamic>());
  }
}
