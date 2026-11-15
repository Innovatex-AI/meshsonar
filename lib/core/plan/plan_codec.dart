// The share codec of a plan (release 0.38, Map Definition `plan.share`: `codec: deflate+base64url`, `fragment: true`): the
// plan's JSON v1 (plan_model.dart), deflated (zlib format, RFC 1950: what the browser's `CompressionStream('deflate')`
// and `DecompressionStream('deflate')` speak, so the /share/plan page decodes it with no library) and written as base64url
// without padding, in the URL FRAGMENT of `https://meshsonar.com/share/plan`. The fragment never reaches a server.
//
// Privacy (build plan 5.6): by default every `mine` or `installed` node's position is rounded to 2 decimals (about 1 km) and
// marked `approx`; [encodePlanShare] reports how many were rounded so the share sheet can say so. `exactPositions: true`
// (the person turned the warning's switch) keeps them exact. The sharer's `mine` flag never travels (the receiver's own
// claims decide what is theirs), and neither do the edit times.
// Decoding refuses anything that inflates past [maxShareJsonBytes] or is not a v1 plan. Pure Dart.
import 'dart:convert';
import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:typed_data';

import 'plan_model.dart';

/// Where share links point (Map Definition `plan.share.base`).
const String planShareBase = 'https://meshsonar.com/share/plan';

/// A plan's JSON is a few KB at 30 nodes; anything far larger is not a plan (or is a deflate bomb).
const int maxShareJsonBytes = 64 * 1024;

/// Longest code accepted (a 30-node plan encodes to well under 3,000 characters).
const int maxShareCodeLength = 16 * 1024;

class PlanShareEncoding {
  /// The base64url text that goes after `#`.
  final String code;

  /// How many node positions were rounded to about 1 km (show the warning when it is not 0).
  final int roundedNodes;
  const PlanShareEncoding(this.code, this.roundedNodes);

  bool get rounded => roundedNodes > 0;

  /// The plain-words warning for the share sheet, or null when nothing was rounded.
  String? get warning => roundedNodes == 0
      ? null
      : '$roundedNodes ${roundedNodes == 1 ? 'position' : 'positions'} of your own or installed radios ${roundedNodes == 1 ? 'is' : 'are'} '
          'rounded to about 1 km in this link. Turn on exact positions only if you want the people you share with to see the exact spot.';
}

double _round2(double v) => double.parse(v.toStringAsFixed(2));

/// The plan as it travels in a link: sensitive positions rounded (unless [exactPositions]), no `mine`, no edit time.
Map<String, dynamic> shareJson(Plan plan, {bool exactPositions = false}) {
  final j = plan.toJson()..remove('updatedAt');
  j['nodes'] = [
    for (final n in plan.nodes)
      (() {
        final rounded = !exactPositions && n.sensitivePosition;
        final m = (rounded ? n.copyWith(lat: _round2(n.lat), lon: _round2(n.lon), approximate: true) : n).toJson()..remove('mine');
        return m;
      })(),
  ];
  return j;
}

PlanShareEncoding encodePlanShare(Plan plan, {bool exactPositions = false}) {
  final rounded = exactPositions ? 0 : plan.nodes.where((n) => n.sensitivePosition).length;
  final bytes = ZLibEncoder(level: 9).convert(utf8.encode(jsonEncode(shareJson(plan, exactPositions: exactPositions))));
  return PlanShareEncoding(base64Url.encode(bytes).replaceAll('=', ''), rounded);
}

/// The share link for [code] (`<base>#<code>`).
Uri planShareUri(String code, {String base = planShareBase}) => Uri.parse('$base#$code');

/// The code in a plan link's fragment (`#<code>`, also `#plan=<code>`), or null when there is none.
String? planCodeFrom(Uri uri) {
  var f = uri.fragment.trim();
  if (f.startsWith('plan=')) f = f.substring(5);
  return f.isEmpty ? null : f;
}

class _CappedSink implements Sink<List<int>> {
  final BytesBuilder out = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (out.length + data.length > maxShareJsonBytes) throw const FormatException('plan link is too large');
    out.add(data);
  }

  @override
  void close() {}
}

/// Decodes a share code into a plan. Throws [FormatException] (with a sentence the UI can show) when it is not one.
Plan decodePlanShare(String code) {
  var c = code.trim();
  if (c.isEmpty) throw const FormatException('the link has no plan in it');
  if (c.length > maxShareCodeLength) throw const FormatException('plan link is too large');
  if (!RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(c)) throw const FormatException('the plan in this link is damaged');
  c = c.replaceAll('=', '');
  final List<int> deflated;
  try {
    deflated = base64Url.decode(c.padRight((c.length + 3) ~/ 4 * 4, '='));
  } on FormatException {
    throw const FormatException('the plan in this link is damaged');
  }
  final sink = _CappedSink();
  try {
    final conv = ZLibDecoder().startChunkedConversion(sink);
    // Feed in slices so the size cap trips before a bomb is fully inflated.
    const step = 512;
    for (var i = 0; i < deflated.length; i += step) {
      conv.add(deflated.sublist(i, i + step > deflated.length ? deflated.length : i + step));
    }
    conv.close();
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('the plan in this link is damaged');
  }
  final Object? j;
  try {
    j = jsonDecode(utf8.decode(sink.out.takeBytes()));
  } catch (_) {
    throw const FormatException('the plan in this link is damaged');
  }
  return Plan.fromJson(j);
}

/// Decodes the plan in a share link; throws [FormatException] when the link carries none.
Plan decodePlanUri(Uri uri) {
  final code = planCodeFrom(uri);
  if (code == null) throw const FormatException('the link has no plan in it');
  return decodePlanShare(code);
}
