// Shared fixtures for the Coverage mode tests (release 0.38 A9): plan-verify answers with a real 0.5 dB margin grid.
import 'dart:convert';
import 'dart:typed_data';

import 'package:meshsonar/core/plan_contract.dart';

const double kSensitivityDbm = -127.54, kNoiseDbm = -120.04;

/// The grid object of a coverage run: [radials] x [n] samples [stepM] apart, margin from [marginDb] (radial, sample 1-based).
Map<String, dynamic> gridJson({int radials = 36, int n = 30, double stepM = 100, required double Function(int r, int j) marginDb}) {
  final b = Int8List(radials * n);
  for (var r = 0; r < radials; r++) {
    for (var j = 1; j <= n; j++) {
      b[r * n + j - 1] = (marginDb(r, j) * 2).round().clamp(-128, 127);
    }
  }
  return {'radials': radials, 'n': n, 'stepM': stepM, 'margin': base64.encode(Uint8List.sublistView(b)), 'diffraction': '', 'scale': 0.5};
}

/// A plan-verify answer for a site at [lat], [lon] whose margin falls 1 dB per 100 m from +20 dB (decodes to 2 km).
PlanVerifyResult verifyAt(double lat, double lon,
    {double coveredKm2 = 12.6, double? newAreaKm2 = 8, double? alreadyKm2 = 4.6, int? newPeople, double Function(int r, int j)? marginDb, int sf = 7, List<PlanPredictedLink> links = const []}) {
  final raw = <String, dynamic>{
    'mode': 'coverage',
    'params': {'lat': lat, 'lon': lon},
    'model': {'name': 'profile+bullington+clutter v1', 'freqMHz': 910.525, 'bwKHz': 62.5, 'sf': sf, 'cr': 5, 'sensitivityDbm': kSensitivityDbm, 'noiseFloorDbm': kNoiseDbm, 'snrFloorDb': -7.5},
    'coveredKm2': coveredKm2,
    'bands': [
      {'id': 'below', 'label': 'Below 0 dB', 'areaKm2': 15},
      {'id': 'fringe', 'label': '0–6 dB', 'areaKm2': 4},
      {'id': 'usable', 'label': '6–12 dB', 'areaKm2': 4},
      {'id': 'solid', 'label': 'Over 12 dB', 'areaKm2': 4.6},
    ],
    'links': [for (final l in links) {'publicKey': l.publicKey, 'name': l.name, 'km': l.km, 'marginDb': l.marginDb}],
    'grid': gridJson(marginDb: marginDb ?? (r, j) => 20.0 - j),
    'newAreaKm2': newAreaKm2,
    'alreadyCoveredKm2': alreadyKm2,
    'newPeople': newPeople,
    'confidence': {'level': 'estimate', 'note': 'terrain model only here'},
    'terrain': {'source': 'AWS Terrain Tiles (test)'},
    'asOf': '2026-11-15T10:00:00Z',
  };
  return PlanVerifyResult.parse(raw);
}
