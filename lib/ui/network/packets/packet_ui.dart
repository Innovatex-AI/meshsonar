// Shared bits of the Packets screens (AZ-3.2): byte-group colours (the inspector and its legend), hop-confidence
// badges, plain value formatting, the "website twin" line and small helpers. One typeface (the theme's), the
// monospace style from the design system for hex (AppType.mono).
import 'package:flutter/material.dart';

import '../../../core/v1/packets_api.dart';
import '../../design/app_type.dart';
import '../../theme.dart';

/// The inspector's colour of a byte group. One hue per group, tinted for the theme so text stays readable.
Color byteGroupColor(BuildContext context, ByteGroup g) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final base = switch (g) {
    ByteGroup.header => const Color(0xFF4F8DF7),
    ByteGroup.transport => const Color(0xFFA77BF3),
    ByteGroup.pathLen => const Color(0xFF2EC4D6),
    ByteGroup.path => const Color(0xFF3CC27A),
    ByteGroup.payload => const Color(0xFFE8B33A),
    ByteGroup.mac => const Color(0xFFEF6FA4),
    ByteGroup.ciphertext => const Color(0xFF8C96A3),
    ByteGroup.signature => const Color(0xFFF08A4B),
    ByteGroup.other => const Color(0xFF9E9E9E),
  };
  return base.withValues(alpha: dark ? 0.34 : 0.26);
}

/// The solid colour of a group (outlines and the legend swatch).
Color byteGroupSolid(ByteGroup g) => switch (g) {
      ByteGroup.header => const Color(0xFF4F8DF7),
      ByteGroup.transport => const Color(0xFFA77BF3),
      ByteGroup.pathLen => const Color(0xFF2EC4D6),
      ByteGroup.path => const Color(0xFF3CC27A),
      ByteGroup.payload => const Color(0xFFE8B33A),
      ByteGroup.mac => const Color(0xFFEF6FA4),
      ByteGroup.ciphertext => const Color(0xFF8C96A3),
      ByteGroup.signature => const Color(0xFFF08A4B),
      ByteGroup.other => const Color(0xFF9E9E9E),
    };

String byteGroupLabel(ByteGroup g) => switch (g) {
      ByteGroup.header => 'Header',
      ByteGroup.transport => 'Transport (scope)',
      ByteGroup.pathLen => 'Path length',
      ByteGroup.path => 'Path',
      ByteGroup.payload => 'Payload',
      ByteGroup.mac => 'MAC',
      ByteGroup.ciphertext => 'Encrypted',
      ByteGroup.signature => 'Signature',
      ByteGroup.other => 'Other',
    };

/// A status word or decoded value in plain words for the field table.
String byteValueText(Object? v) {
  if (v == null) return '';
  if (v is String) {
    return switch (v) {
      'decrypted' => 'Decrypted (text shown above)',
      'no_key' => 'Encrypted: the key is not known',
      'encrypted' => 'Encrypted end to end',
      'not_checked' => 'Not checked on the phone',
      'valid' => 'Valid',
      'invalid' => 'Not valid',
      _ => v,
    };
  }
  if (v is double) return v == v.truncateToDouble() ? v.toStringAsFixed(1) : '$v';
  if (v is List) return v.map(byteValueText).join(', ');
  if (v is Map) {
    return [
      for (final e in v.entries)
        if (e.value != null && e.value != false) e.value == true ? '${e.key}' : '${e.key} ${byteValueText(e.value)}'
    ].join(' · ');
  }
  return '$v';
}

/// "4.5 dB", or "no reading". Two decimals at most, trailing zeros trimmed (11.8, 1.75, 10): the server's numbers
/// are 32-bit floats, which print as "11.800000190734863" when left alone.
String snrText(double? v) => v == null ? 'no reading' : '${trimDecimals(v)} dB';

/// A number with at most [places] decimals and no trailing zeros: 11.8, 1.75, 10, -6.8.
String trimDecimals(double v, {int places = 2}) {
  var s = v.toStringAsFixed(places);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s == '-0' ? '0' : s;
}

/// Joins the parts of a one-line row summary with " · " so that a separator never starts a line: each dot is tied
/// to the part before it with a no-break space, and a line can only break after a dot (Round 2 N-V5).
String dotJoin(Iterable<String> parts) => parts.where((p) => p.isNotEmpty).join('\u00A0· ');

/// What a list says when the server marks its data not ready and gives no sentence of its own (Round 2 W7).
const String stillCountingText = 'Some of this is still being counted.';

/// "12s", "5m", "3h", "2d": a compact age for the right-hand column of a list row (no "ago").
String ageText(DateTime at, DateTime now) {
  final s = now.difference(at).inSeconds;
  if (s < 5) return 'now';
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}

Color snrColor(BuildContext context, double snr) {
  final c = MeshSonarColors.of(context);
  if (snr >= 5) return c.snrStrong;
  if (snr >= -5) return c.snrMid;
  return c.snrWeak;
}

/// The hop-confidence badge: what the server (or the phone) knows about a hop, said honestly.
class HopConfidenceBadge extends StatelessWidget {
  final HopConfidence confidence;
  const HopConfidenceBadge(this.confidence, {super.key});

  static String label(HopConfidence c) => switch (c) {
        HopConfidence.unique => 'Unique',
        HopConfidence.likely => 'Likely',
        HopConfidence.ambiguous => 'Ambiguous',
        HopConfidence.unknown => 'Unknown',
        HopConfidence.other => 'Other',
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (bg, fg) = switch (confidence) {
      HopConfidence.unique => (cs.primaryContainer, cs.onPrimaryContainer),
      HopConfidence.likely => (cs.secondaryContainer, cs.onSecondaryContainer),
      HopConfidence.ambiguous => (cs.tertiaryContainer, cs.onTertiaryContainer),
      _ => (cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Text(label(confidence), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg)),
    );
  }
}

/// A short note in a tinted box (missing parts, fallbacks, privacy).
class PacketNote extends StatelessWidget {
  final String text;
  final IconData icon;
  const PacketNote(this.text, {super.key, this.icon = Icons.info_outline});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.s),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text, style: t.textTheme.bodyMedium)),
      ]),
    );
  }
}

/// "On the website: cmh.meshsonar.com/packets" (the parity rule: every screen names its web twin).
class WebTwinLine extends StatelessWidget {
  final Uri web;
  const WebTwinLine(this.web, {super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = '${web.host}${web.path}${web.hasQuery ? '?${web.query}' : ''}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Text('On the website: $s',
          key: const Key('packets-web-twin'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }
}

/// Section heading.
class PacketSectionTitle extends StatelessWidget {
  final String text;
  const PacketSectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.xs),
        child: Semantics(header: true, child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
      );
}

/// Monospace hex text (selectable).
class HexText extends StatelessWidget {
  final String hex;
  final int? maxLines;
  const HexText(this.hex, {super.key, this.maxLines});
  @override
  Widget build(BuildContext context) => Text(hex, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis, style: AppType.mono.copyWith(color: Theme.of(context).colorScheme.onSurface));
}

/// A scope no packet feed covers (`meta.status.code == no_packet_feed`, e.g. phx, swoh): said plainly, in place of
/// an empty list or an error. [reason] is the server's own sentence. Find it by the key `no-packet-feed`.
class NoPacketFeedCard extends StatelessWidget {
  /// The region's name or slug; null says "here".
  final String? regionName;
  final String? reason;

  /// What this screen would have shown, e.g. "packets" or "channel messages".
  final String what;
  const NoPacketFeedCard({super.key, this.regionName, this.reason, this.what = 'packets'});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Container(
      key: const Key('no-packet-feed'),
      margin: const EdgeInsets.all(Gap.l),
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(color: c.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.card)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.portable_wifi_off, color: c.onSurfaceVariant),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(regionName == null ? 'No packet feed here yet' : 'No packet feed for $regionName yet',
                key: const Key('no-packet-feed-title'), style: t.textTheme.titleMedium),
          ),
        ]),
        const SizedBox(height: Gap.s),
        Text(plainServerText(reason) ?? 'No observer or outside feed delivers packets for this region yet.', style: t.textTheme.bodyMedium),
        const SizedBox(height: Gap.s),
        Text('There are no $what to show until one does. Run an observer here, or pick another region at the top.',
            style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
      ]),
    );
  }
}

final RegExp _internalCode = RegExp(r'\b(AZ|OD|MT|WP|V)-\d');

/// A sentence the server wrote, made fit to show: sentences that name an internal work item ("... arrive with AZ-1.5
/// to AZ-1.8.") are dropped, the rest is kept as written. Null when nothing is left (or [text] is null or empty).
String? plainServerText(String? text) {
  if (text == null) return null;
  final kept = [
    for (final s in text.trim().split(RegExp(r'(?<=[.!?])\s+')))
      if (s.trim().isNotEmpty && !_internalCode.hasMatch(s)) s.trim()
  ];
  return kept.isEmpty ? null : kept.join(' ');
}
