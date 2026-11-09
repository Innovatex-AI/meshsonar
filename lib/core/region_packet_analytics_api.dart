// Packet analytics of the viewed region (website vertical W, migration 0106): public, region-scoped reads on the region
// host, the same data as the website's /analysis tabs "Silent repeaters" and "Wardrive share". (The "Hops and routes" read,
// region-hop-route, left the app in M0, Nov 8 2026: the hop chart lives once, in Analysis > Hops and top repeaters.)
//   region-silent-repeaters          repeaters heard advertising in 24 h that never appear as a relay hop in any path
//   region-airtime-share?hours=1..48 unique transmissions by type/hops/hash size; airtime is MODELLED on the phone (airtime_share.dart)
// The source (ext_packet) holds header-level fields only: no packet text. A wardrive ping therefore cannot be told from other
// group text, and the airtime view says so. Every dataset carries its window, the newest packet (data age) and the sample size;
// unknown is null, never 0. Pure Dart: no Flutter imports.
import 'package:http/http.dart' as http;

import 'airtime_share.dart';
import 'region_dataset_fetch.dart';
import 'region_overview_api.dart' show RegionDataStatus;

/// Window, sample size and data age shared by the datasets.
class PacketSample {
  final int windowHours;
  final int? observations, packets, observers;
  final DateTime? oldest, newest;
  const PacketSample({required this.windowHours, this.observations, this.packets, this.observers, this.oldest, this.newest});

  static PacketSample parse(Map<String, dynamic> j) => PacketSample(
        windowHours: jInt(j['windowHours']) ?? 24,
        observations: jInt(j['observations']),
        packets: jInt(j['packets']),
        observers: jInt(j['observers']),
        oldest: jTime(j['oldest']),
        newest: jTime(j['newest']),
      );
}

// ---------------------------------------------------------------- silent repeaters
class SilentRepeater {
  final String key, hashPrefix, hintCode, hintText;
  final String? name, signalGrade;
  final int? hashSizeBytes, adverts24h, observers24h;
  final double? snrMeanDb;
  final DateTime? lastHeardAt;
  final List<String> checks;
  const SilentRepeater({
    required this.key,
    required this.hashPrefix,
    required this.hintCode,
    required this.hintText,
    required this.checks,
    this.name,
    this.signalGrade,
    this.hashSizeBytes,
    this.adverts24h,
    this.observers24h,
    this.snrMeanDb,
    this.lastHeardAt,
  });

  String get title => name ?? '${key.substring(0, key.length < 8 ? key.length : 8)}...';

  /// Name or key / code fragment, case-insensitive (the website's matchesSilent).
  bool matches(String q) {
    final s = q.trim().toLowerCase();
    return s.isEmpty || (name ?? '').toLowerCase().contains(s) || key.startsWith(s) || hashPrefix.startsWith(s);
  }
}

class SilentRepeaters {
  final RegionDataStatus status;
  final PacketSample sample;
  final int relayEvidence, repeaters, advertising, relaying, silentCount;
  final List<SilentRepeater> silent;
  final List<String> caveats;
  const SilentRepeaters(this.status, this.sample, this.relayEvidence, this.repeaters, this.advertising, this.relaying, this.silentCount, this.silent, this.caveats);

  static SilentRepeaters parse(Map<String, dynamic> j) {
    final c = jMap(j['counts']);
    return SilentRepeaters(
      RegionDataStatus.fromJson(j['status']),
      PacketSample.parse(j),
      jInt(j['relayEvidence']) ?? 0,
      jInt(c['repeaters']) ?? 0,
      jInt(c['advertising']) ?? 0,
      jInt(c['relaying']) ?? 0,
      jInt(c['silent']) ?? 0,
      [
        for (final r in jMaps(j['silent']))
          if (jStr(r['key']) != null)
            SilentRepeater(
              key: jStr(r['key'])!,
              hashPrefix: jStr(r['hashPrefix']) ?? '',
              name: jStr(r['name']),
              signalGrade: jStr(r['signalGrade']),
              hashSizeBytes: jInt(r['hashSizeBytes']),
              adverts24h: jInt(r['adverts24h']),
              observers24h: jInt(r['observers24h']),
              snrMeanDb: jDbl(r['snrMeanDb']),
              lastHeardAt: jTime(r['lastHeardAt']),
              hintCode: jStr(jMap(r['hint'])['code']) ?? 'unknown_link',
              hintText: jStr(jMap(r['hint'])['text']) ?? '',
              checks: [for (final x in (r['checks'] is List ? r['checks'] as List : const [])) if (x is String) x],
            ),
      ],
      [for (final x in (j['caveats'] is List ? j['caveats'] as List : const [])) if (x is String) x],
    );
  }
}

// ---------------------------------------------------------------- airtime share
class AirtimeShareData {
  final RegionDataStatus status;
  final PacketSample sample;
  final int? transmissions;
  final List<MixRow> rows;
  final List<PayloadAssumption> assumptions;
  final String note;
  const AirtimeShareData(this.status, this.sample, this.transmissions, this.rows, this.assumptions, this.note);

  static AirtimeShareData parse(Map<String, dynamic> j) {
    final a = [
      for (final r in jMaps(j['assumptions']))
        if (jInt(r['t']) != null && jInt(r['payloadBytes']) != null)
          PayloadAssumption(jInt(r['t'])!, jStr(r['label']) ?? 'Type ${jInt(r['t'])}', jInt(r['payloadBytes'])!, jStr(r['basis']) ?? ''),
    ];
    return AirtimeShareData(
      RegionDataStatus.fromJson(j['status']),
      PacketSample.parse(j),
      jInt(j['transmissions']),
      [
        for (final r in jMaps(j['rows']))
          if (jInt(r['t']) != null && jInt(r['n']) != null)
            MixRow(jInt(r['t'])!, r['transport'] == true, jInt(r['hops']) ?? 0, jInt(r['ps']) ?? 1, jInt(r['n'])!),
      ],
      a.isEmpty ? defaultPayloadAssumptions : a,
      jStr(j['note']) ?? airtimeNote,
    );
  }

  AirtimeModel model(LoraRadio radio) => modelAirtime(rows, radio, assumptions);
}

class PacketAnalyticsApi {
  final String baseUrl;
  final http.Client? client;
  PacketAnalyticsApi(this.baseUrl, {this.client});

  static Map<String, String> _q(int hours) => {'hours': '$hours'};
  Future<RegionFetch<SilentRepeaters>> silentRepeaters() =>
      fetchRegionDataset(regionDatasetUri(baseUrl, 'region-silent-repeaters'), SilentRepeaters.parse, client: client);
  Future<RegionFetch<AirtimeShareData>> airtimeShare({int hours = 24}) =>
      fetchRegionDataset(regionDatasetUri(baseUrl, 'region-airtime-share', _q(hours)), AirtimeShareData.parse, client: client);
}
