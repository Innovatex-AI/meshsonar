// Locates the real hosted CMH region pack for the opt-in real-pack tests. The pack (53 MB) is NEVER committed.
// Order: $MESHSONAR_REAL_PACK, then the agreed local copy beside the worktrees. Absent -> tests skip with a reason.
import 'dart:io';
import 'dart:math' as math;

const defaultRealPackPath = '/Users/innovatex/Developer/ms-app-wt/_packs/CMH-v261024.pmtiles';

/// The pack file, or null when it is not on this machine.
File? realPackFile() {
  final env = Platform.environment['MESHSONAR_REAL_PACK'];
  final f = File(env != null && env.isNotEmpty ? env : defaultRealPackPath);
  return f.existsSync() ? f : null;
}

/// `skip:` value: false when the pack is present, otherwise the reason string.
Object get realPackSkip =>
    realPackFile() == null ? 'real pack not found (set MESHSONAR_REAL_PACK to a CMH-v261024.pmtiles copy)' : false;

/// Facts from https://tiles.meshsonar.com/manifest.json for CMH v261024 (the copy the tests expect).
const realPackBytes = 52955695;
const realPackSha256 = '7bc7c18446530296f1aff48da0c282f6d6d0b083cda9c4daed4d6ac2bb83c1d0';
const realPackBbox = [-83.6534, 39.3613, -82.0242, 40.7127];

/// Slippy-map tile containing lat/lon at zoom z.
(int, int) tileXY(double lat, double lon, int z) {
  final n = 1 << z;
  final x = ((lon + 180) / 360 * n).floor();
  final r = lat * math.pi / 180;
  final t = math.tan(r);
  final asinh = math.log(t + math.sqrt(t * t + 1));
  final y = ((1 - asinh / math.pi) / 2 * n).floor();
  return (x, y);
}
