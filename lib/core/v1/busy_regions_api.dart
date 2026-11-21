// `GET /v1/regions/busy` on the hub (build 71, "All regions"): the busiest regions of the last 10 minutes, by distinct
// packets. Rows: `{region: {slug, name}, packets, observations, packetsPerMin}` (site: src/server/v1/endpoints/replay.ts).
// Read through [networkApiFactory], so tests inject their HTTP client the same way as the other Network reads.
// Pure Dart: no Flutter imports.
import 'network_api.dart';

class BusyRegion {
  final String slug, name;
  final int packets, observations;
  final double packetsPerMin;
  const BusyRegion({required this.slug, required this.name, this.packets = 0, this.observations = 0, this.packetsPerMin = 0});

  /// The region code as the app shows it (`CMH`).
  String get code => slug.toUpperCase();

  static BusyRegion? tryParse(Object? j) {
    if (j is! Map) return null;
    final r = j['region'];
    if (r is! Map || r['slug'] is! String || (r['slug'] as String).isEmpty) return null;
    final slug = (r['slug'] as String).toLowerCase();
    num n(String k) => j[k] is num ? j[k] as num : 0;
    final packets = n('packets').toInt();
    return BusyRegion(
      slug: slug,
      name: r['name'] is String && (r['name'] as String).isNotEmpty ? r['name'] as String : slug.toUpperCase(),
      packets: packets,
      observations: n('observations').toInt(),
      packetsPerMin: j['packetsPerMin'] is num ? (j['packetsPerMin'] as num).toDouble() : packets / 10,
    );
  }
}

/// The busiest regions, busiest first (the server's order). Throws [V1Error]; [V1NotLive] when the hub has no `/v1` yet.
Future<NetworkRead<List<BusyRegion>>> fetchBusyRegions(String hubUrl, {int limit = 20}) async {
  final api = networkApiFactory(hubUrl);
  try {
    final env = await api.v1.getPage('regions/busy', BusyRegion.tryParse, limit: limit);
    return NetworkRead(env.data, meta: env.meta, offlineAsOf: env.offlineAsOf);
  } finally {
    api.close();
  }
}
