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

/// "4.5 dB", or "no reading".
String snrText(double? v) => v == null ? 'no reading' : '${v == v.truncateToDouble() ? v.toStringAsFixed(0) : v.toString()} dB';

/// "12s", "5m", "3h", "2d" ago.
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
