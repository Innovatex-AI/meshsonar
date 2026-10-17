// Redaction and coordinate rounding for problem reports: CMAT docs/specs/m1-problem-reports.md §8, rules R1–R6 and
// C1, in the same order with the same replacement text, so text the app cleaned is stored unchanged by the server.
// test/fixtures/redaction-vectors.json is CMAT's canonical vectors file; both sides must give every output and count.
// Pure Dart: no Flutter imports.

/// Count keys, in the order CMAT reports them.
const List<String> redactionCountKeys = ['driverKey', 'jwt', 'bearer', 'secret', 'mqtt', 'coords'];

class RedactionResult {
  final String text;

  /// How many replacements each rule group made (every key of [redactionCountKeys] is present).
  final Map<String, int> counts;
  const RedactionResult(this.text, this.counts);
}

class _Rule {
  final RegExp pattern;
  final String countKey;
  final String Function(Match m) replace;
  const _Rule(this.pattern, this.countKey, this.replace);
}

final List<_Rule> _rules = [
  // R1: driver keys are `ms_` + 43 base64url characters.
  _Rule(RegExp(r'\bms_[A-Za-z0-9_-]{20,}'), 'driverKey', (_) => '[redacted:driver-key]'),
  // R2: JSON Web Tokens.
  _Rule(RegExp(r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*'), 'jwt', (_) => '[redacted:jwt]'),
  // R3: bearer tokens.
  _Rule(RegExp(r'\b(Bearer)\s+[A-Za-z0-9._~+/-]+=*', caseSensitive: false), 'bearer', (m) => '${m[1]} [redacted]'),
  // R4: a password in a URL. The password runs to the last '@' before the host, so one containing '@' is hidden whole
  // (`mqtt://u:p@ss@host` → `mqtt://u:[redacted]@host`). An already redacted password is left (and not counted).
  _Rule(
    RegExp(
      r'\b((?:mqtts?|wss?|https?|tcp|ssl)://[^\s:/@]+):(?!\[redacted\]@[^\s/@]*(?:[\s/]|$))[^\s/]+@',
      caseSensitive: false,
    ),
    'mqtt',
    (m) => '${m[1]}:[redacted]@',
  ),
  // R5: observer firmware CLI passwords and tokens (an already redacted value is left, and not counted).
  _Rule(
    RegExp(r'\b(set\s+mqtt\d*\.(?:password|pass|token))\s+(?!\[redacted\](?!\S))\S+', caseSensitive: false),
    'mqtt',
    (m) => '${m[1]} [redacted]',
  ),
  // R6: secret-looking fields. The lookahead leaves R1–R3 output alone.
  _Rule(
    RegExp(
      r'''\b(x-driver-key|x-admin-key|x-user-jwt|x-access-token|authorization|apikey|api_key|access_token|refresh_token|password|passwd|pwd|secret|token)(["']?\s*[:=]\s*["']?)(?!\[redacted|Bearer\b)([^\s"',;&}]+)''',
      caseSensitive: false,
    ),
    'secret',
    (m) => '${m[1]}${m[2]}[redacted]',
  ),
];

/// C1: a decimal number with 4 or more decimals, not part of a dotted chain such as a version string `10.12345.6789`
/// (no digit or '.' right before it, no digit or '.digit' right after); a sentence-ending '.' is fine. Only values up to
/// 180 are treated as coordinates.
final RegExp _coordinate = RegExp(r'(?<![\d.])(-?)\b(\d{1,3}\.\d{4,})\b(?!\d|\.\d)');

/// [v] rounded to 3 decimals, half away from zero (about 110 m for latitude).
double roundCoordinate(double v) => v.sign * (v.abs() * 1000).round() / 1000;

/// Applies R1–R6 then C1 to [input].
///
/// [secrets] are literal strings that must never leave the phone even when no rule recognises them (the driver key,
/// the full server URL); each is replaced by `[redacted]` first and counted as `secret`. Blank entries are ignored.
RedactionResult redactText(String input, {Iterable<String> secrets = const []}) {
  final counts = {for (final k in redactionCountKeys) k: 0};
  var text = input;
  final literals = secrets.where((s) => s.trim().isNotEmpty).toSet().toList()
    ..sort((a, b) => b.length.compareTo(a.length)); // longest first, so one secret inside another can't leave a piece
  for (final s in literals) {
    final n = s.allMatches(text).length;
    if (n == 0) continue;
    counts['secret'] = counts['secret']! + n;
    text = text.replaceAll(s, '[redacted]');
  }
  for (final r in _rules) {
    text = text.replaceAllMapped(r.pattern, (m) {
      counts[r.countKey] = counts[r.countKey]! + 1;
      return r.replace(m);
    });
  }
  text = text.replaceAllMapped(_coordinate, (m) {
    final v = double.parse(m[2]!);
    if (v > 180) return m[0]!;
    counts['coords'] = counts['coords']! + 1;
    return '${m[1]}${roundCoordinate(v).toStringAsFixed(3)}';
  });
  return RedactionResult(text, counts);
}
