// Where the contract tests find CMAT (meshcore-insights) and bun, so they run on any machine that has them:
//   CMAT_DIR=<checkout>   default /home/claude/meshcore-insights (the agent container)
//   BUN=<path to bun>     else `which bun`, else ~/.bun/bin/bun, else /root/.bun/bin/bun
// Tests skip (with the reason) when either is missing.
import 'dart:io';

String cmatDir() {
  final env = Platform.environment['CMAT_DIR'];
  return (env == null || env.trim().isEmpty) ? '/home/claude/meshcore-insights' : env.trim();
}

/// A file inside the CMAT checkout, e.g. cmatPath('src/lib/drive/handlers.ts').
String cmatPath(String relative) => '${cmatDir()}/$relative';

String? findBun() {
  final env = Platform.environment['BUN'];
  if (env != null && env.trim().isNotEmpty && File(env.trim()).existsSync()) return env.trim();
  try {
    final r = Process.runSync('which', ['bun']);
    final out = (r.stdout as String).trim();
    if (r.exitCode == 0 && out.isNotEmpty && File(out).existsSync()) return out;
  } catch (_) {}
  for (final c in [
    if (Platform.environment['HOME'] != null) '${Platform.environment['HOME']}/.bun/bin/bun',
    '/root/.bun/bin/bun',
  ]) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

/// Null when bun and [cmatFile] are both present; otherwise why the test is skipped.
String? contractSkipReason(String cmatFile) {
  if (findBun() == null) return 'bun not installed (set BUN or put bun on PATH)';
  final f = cmatPath(cmatFile);
  if (!File(f).existsSync()) return 'CMAT checkout not found: $f (set CMAT_DIR)';
  return null;
}
