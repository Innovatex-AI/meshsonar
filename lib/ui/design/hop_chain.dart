// HopChain: the read-only route diagram (plan 4.7 / 2.5). "You - Ridge - Hill - Maya" with the link quality between nodes.
// Horizontal only for 3 nodes or fewer AND text at 1.3x or less; otherwise a vertical timeline. Always has a text
// alternative for VoiceOver (see [describeHopChain]). No Material list widgets.
import 'package:flutter/material.dart';

import 'app_type.dart';
import 'tokens.dart';

enum LinkQuality { strong, good, weak, unknown }

/// Plain word for a link, from the SNR in dB (LoRa: above +5 is clean, below -5 is marginal).
LinkQuality linkQualityOfSnr(double? snr) {
  if (snr == null) return LinkQuality.unknown;
  if (snr >= 5) return LinkQuality.strong;
  if (snr >= -5) return LinkQuality.good;
  return LinkQuality.weak;
}

String linkQualityWord(LinkQuality q) => switch (q) {
      LinkQuality.strong => 'Strong',
      LinkQuality.good => 'Good',
      LinkQuality.weak => 'Weak',
      LinkQuality.unknown => 'Unknown',
    };

/// One node of the chain. [unknown] draws a "?" hop (a hash with no known repeater). [linkToNext] is the quality of the link
/// from this node to the next one (null on the last node).
class HopNode {
  final String label;

  /// Small second line, e.g. the hash "a1".
  final String? detail;
  final bool unknown;
  final LinkQuality? linkToNext;
  const HopNode(this.label, {this.detail, this.unknown = false, this.linkToNext});
}

/// "Route: You, then Ridge (hash a1), then Hill, then Maya. Ridge to Hill is a weak link." for screen readers.
String describeHopChain(List<HopNode> nodes, {String prefix = 'Route'}) {
  if (nodes.isEmpty) return '$prefix: no route.';
  final b = StringBuffer('$prefix: ');
  for (var i = 0; i < nodes.length; i++) {
    final n = nodes[i];
    if (i > 0) b.write(', then ');
    b.write(n.unknown ? 'unknown repeater${n.detail == null ? '' : ' ${n.detail}'}' : n.label);
    if (!n.unknown && n.detail != null) b.write(' (${n.detail})');
  }
  b.write('.');
  for (var i = 0; i < nodes.length - 1; i++) {
    final q = nodes[i].linkToNext;
    if (q == null || q == LinkQuality.unknown) continue;
    final a = nodes[i].unknown ? 'the unknown repeater' : nodes[i].label;
    final c = nodes[i + 1].unknown ? 'the unknown repeater' : nodes[i + 1].label;
    b.write(' $a to $c is a ${linkQualityWord(q).toLowerCase()} link.');
  }
  return b.toString();
}

class HopChain extends StatelessWidget {
  final List<HopNode> nodes;

  /// Overrides the generated text alternative.
  final String? semanticsLabel;
  const HopChain({super.key, required this.nodes, this.semanticsLabel});

  /// Horizontal layout allowed: at most 3 nodes and text no larger than 1.3x.
  static bool horizontalFits(int nodeCount, double textScale) => nodeCount <= 3 && textScale <= 1.3;

  Color _linkColor(AppColors c, LinkQuality? q) => switch (q) {
        LinkQuality.strong => c.ok,
        LinkQuality.good => c.accent,
        LinkQuality.weak => c.warning,
        _ => c.outline,
      };

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final horizontal = horizontalFits(nodes.length, scale);
    return Semantics(
      container: true,
      label: semanticsLabel ?? describeHopChain(nodes),
      child: ExcludeSemantics(child: horizontal ? _horizontal(context, c) : _vertical(context, c)),
    );
  }

  Widget _dot(AppColors c, HopNode n, bool endpoint) {
    final fill = n.unknown ? c.surface : (endpoint ? c.accent : c.surfaceHigh);
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: n.unknown ? c.warning : (endpoint ? c.accent : c.outline), width: n.unknown ? 2 : 1),
      ),
      child: n.unknown ? Text('?', textScaler: TextScaler.noScaling, style: AppType.footnote.copyWith(color: c.warning, fontWeight: FontWeight.w700)) : null,
    );
  }

  Widget _horizontal(BuildContext context, AppColors c) {
    final kids = <Widget>[];
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final endpoint = i == 0 || i == nodes.length - 1;
      kids.add(Flexible(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _dot(c, n, endpoint),
          const SizedBox(height: Gap.xs),
          Text(n.unknown ? 'Unknown' : n.label, key: Key('hop-label-$i'), maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: c.textPrimary)),
          if (n.detail != null) Text(n.detail!, textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: c.textMuted)),
        ]),
      ));
      if (i < nodes.length - 1) {
        final q = nodes[i].linkToNext;
        kids.add(Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 10, left: Gap.xs, right: Gap.xs),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(key: Key('hop-link-$i'), height: 3, decoration: BoxDecoration(color: _linkColor(c, q), borderRadius: BorderRadius.circular(2))),
              if (q != null && q != LinkQuality.unknown)
                Padding(padding: const EdgeInsets.only(top: 2), child: Text(linkQualityWord(q), style: AppType.footnote.copyWith(color: c.textMuted))),
            ]),
          ),
        ));
      }
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: kids);
  }

  Widget _vertical(BuildContext context, AppColors c) {
    final kids = <Widget>[];
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final endpoint = i == 0 || i == nodes.length - 1;
      final last = i == nodes.length - 1;
      final q = n.linkToNext;
      kids.add(IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 22,
            child: Column(children: [
              _dot(c, n, endpoint),
              if (!last) Expanded(child: Container(key: Key('hop-link-$i'), width: 3, margin: const EdgeInsets.symmetric(vertical: 2), decoration: BoxDecoration(color: _linkColor(c, q), borderRadius: BorderRadius.circular(2)))),
            ]),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : Gap.m),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n.unknown ? 'Unknown repeater' : n.label, key: Key('hop-label-$i'), style: AppType.body.copyWith(color: c.textPrimary)),
                if (n.detail != null) Text(n.detail!, style: AppType.footnote.copyWith(color: c.textMuted)),
                if (!last && q != null && q != LinkQuality.unknown)
                  Text('${linkQualityWord(q)} link', style: AppType.footnote.copyWith(color: _linkColor(c, q) == c.outline ? c.textMuted : c.textMuted)),
              ]),
            ),
          ),
        ]),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kids);
  }
}
