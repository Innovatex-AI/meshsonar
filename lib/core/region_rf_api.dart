// `region-rf`: the region's RF picture from MeshSonar's own observers (public, region host, ETag, max-age 300):
//   {status, observers[{key, name, series[{at, dbm}], meanDbm, maxDbm}], noiseByHour[{hour (UTC), meanDbm}],
//    snrHistogram[{fromDb, toDb, n}]}
// Shape: meshcore-insights src/lib/region/types.ts RfAnalysis; recorded live on cmh Oct 24 2026 (2 observers, hourly
// points, one observer silent since 2026-10-21 16:00 UTC). Parsing is tolerant: a bad row is skipped, an unknown
// number is null (never 0). Pure Dart: no Flutter imports.
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'region_dataset_fetch.dart';
import 'region_overview_api.dart' show RegionDataStatus;
import 'rf_thresholds.dart';

class RfPoint {
  final DateTime at; // UTC, bucket start
  final double dbm;
  const RfPoint(this.at, this.dbm);
}

class RfObserver {
  final String key;
  final String? name;
  final List<RfPoint> series; // time order
  final double? meanDbm, maxDbm;
  const RfObserver({required this.key, this.name, required this.series, this.meanDbm, this.maxDbm});

  String get label => name ?? '${key.substring(0, math.min(8, key.length))}…';
  DateTime? get lastAt => series.isEmpty ? null : series.last.at;
}

class NoiseHour {
  final int hour; // 0..23, UTC
  final double? meanDbm;
  const NoiseHour(this.hour, this.meanDbm);
}

class SnrBin {
  final double fromDb, toDb;
  final int n;
  const SnrBin(this.fromDb, this.toDb, this.n);
}

class RegionRf {
  final RegionDataStatus status;
  final List<RfObserver> observers;
  final List<NoiseHour> noiseByHour;
  final List<SnrBin> snrHistogram;
  const RegionRf({required this.status, required this.observers, required this.noiseByHour, required this.snrHistogram});

  bool get isEmpty => observers.isEmpty && noiseByHour.every((h) => h.meanDbm == null) && snrHistogram.isEmpty;

  List<double> get observerMeans => [for (final o in observers) if (o.meanDbm != null) o.meanDbm!];

  /// Share of received packets at or below 0 dB SNR (the website's weakSnrShare); null when there are none.
  double? get weakSnrShare {
    final total = snrHistogram.fold<int>(0, (a, b) => a + b.n);
    if (total <= 0) return null;
    return snrHistogram.where((b) => b.toDb <= snrWeakDb).fold<int>(0, (a, b) => a + b.n) / total;
  }

  /// Observers whose newest reading is more than [after] older than [asOf] (the server's computedAt): their line
  /// stops there and the screen says so instead of stretching it.
  List<RfObserver> silentObservers(DateTime asOf, {Duration after = const Duration(hours: 3)}) => [
        for (final o in observers)
          if (o.lastAt != null && asOf.difference(o.lastAt!) > after) o,
      ];

  /// The website's one-sentence reading (analysis-model.ts rfFinding), with the hour in the given words.
  String? finding({String Function(int utcHour)? hourText}) {
    final withMean = [for (final o in observers) if (o.meanDbm != null) o];
    if (withMean.isEmpty) return null;
    final worst = withMean.reduce((a, b) => b.meanDbm! > a.meanDbm! ? b : a);
    final loud = withMean.where((o) => o.meanDbm! > noiseFloorInterferenceDbm).length;
    final hours = [for (final h in noiseByHour) if (h.meanDbm != null) h];
    String when = '';
    if (hours.isNotEmpty) {
      final top = hours.reduce((a, b) => b.meanDbm! > a.meanDbm! ? b : a);
      when = ' Across observers it is highest at ${hourText?.call(top.hour) ?? '${top.hour.toString().padLeft(2, '0')}:00 UTC'}.';
    }
    final ref = noiseFloorInterferenceDbm.round();
    if (loud > 0) {
      return '$loud of ${withMean.length} observers sit above $ref dBm, where interference is likely. '
          'Noisiest: ${worst.label} at ${worst.meanDbm!.round()} dBm.$when';
    }
    return 'No observer is above $ref dBm. Noisiest: ${worst.label} at ${worst.meanDbm!.round()} dBm.$when';
  }

  static RegionRf parse(Map<String, dynamic> j) {
    final obs = <RfObserver>[];
    for (final o in jMaps(j['observers'])) {
      final key = jStr(o['key']);
      if (key == null) continue;
      final pts = <RfPoint>[
        for (final p in jMaps(o['series']))
          if (jTime(p['at']) != null && jDbl(p['dbm']) != null) RfPoint(jTime(p['at'])!, jDbl(p['dbm'])!),
      ]..sort((a, b) => a.at.compareTo(b.at));
      obs.add(RfObserver(key: key, name: jStr(o['name']), series: pts, meanDbm: jDbl(o['meanDbm']), maxDbm: jDbl(o['maxDbm'])));
    }
    final hours = <NoiseHour>[
      for (final h in jMaps(j['noiseByHour']))
        if (jInt(h['hour']) != null && jInt(h['hour'])! >= 0 && jInt(h['hour'])! < 24) NoiseHour(jInt(h['hour'])!, jDbl(h['meanDbm'])),
    ]..sort((a, b) => a.hour.compareTo(b.hour));
    final bins = <SnrBin>[
      for (final b in jMaps(j['snrHistogram']))
        if (jDbl(b['fromDb']) != null && jDbl(b['toDb']) != null && jInt(b['n']) != null)
          SnrBin(jDbl(b['fromDb'])!, jDbl(b['toDb'])!, jInt(b['n'])!),
    ]..sort((a, b) => a.fromDb.compareTo(b.fromDb));
    return RegionRf(status: RegionDataStatus.fromJson(j['status']), observers: obs, noiseByHour: hours, snrHistogram: bins);
  }
}

class RegionRfApi {
  final String baseUrl;
  final http.Client? client;
  RegionRfApi(this.baseUrl, {this.client});

  Uri get uri => regionDatasetUri(baseUrl, 'region-rf');
  Future<RegionFetch<RegionRf>> fetch() => fetchRegionDataset(uri, RegionRf.parse, client: client);
}
