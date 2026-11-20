// The byte inspector (AZ-3.2): the whole packet as colour-coded hex from the contract's byte ranges (8 bytes a row so
// it reads at phone width), and the field table under it. Tap a field to light its bytes; tap a byte to light its field.
// Every byte has an accessible label ("Byte 7 of 73, hex 79, MAC"). Works for every type: ciphertext is shown as bytes
// with its status word ("Encrypted end to end", "Encrypted: the key is not known"); decoded public-channel text sits in
// the detail above, never inside the hex.
import 'package:flutter/material.dart';

import '../../../core/v1/packets_api.dart';
import '../../design/app_type.dart';
import '../../theme.dart';
import 'packet_ui.dart';

class ByteInspector extends StatefulWidget {
  final String raw;
  final List<ByteRange> ranges;

  /// A field to light first (tests, deep links); null = none.
  final String? initialField;
  const ByteInspector({super.key, required this.raw, required this.ranges, this.initialField});

  @override
  State<ByteInspector> createState() => _ByteInspectorState();
}

class _ByteInspectorState extends State<ByteInspector> {
  String? _field;

  static const int perRow = 8;

  @override
  void initState() {
    super.initState();
    _field = widget.initialField;
  }

  List<int> get _bytes => [for (var i = 0; i + 1 < widget.raw.length; i += 2) int.parse(widget.raw.substring(i, i + 2), radix: 16)];

  ByteRange? _rangeAt(int i) {
    for (final r in widget.ranges) {
      if (r.contains(i)) return r;
    }
    return null;
  }

  ByteRange? get _selected {
    for (final r in widget.ranges) {
      if (r.field == _field) return r;
    }
    return null;
  }

  void _select(String? field) => setState(() => _field = field == _field ? null : field);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bytes = _bytes;
    final sel = _selected;
    final groups = <ByteGroup>{for (final r in widget.ranges) r.group};
    final rows = (bytes.length + perRow - 1) ~/ perRow;
    return Column(
      key: const Key('byte-inspector'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: Gap.m, runSpacing: Gap.xs, children: [
          for (final g in ByteGroup.values)
            if (groups.contains(g))
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 12, height: 12, decoration: BoxDecoration(color: byteGroupSolid(g), borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 4),
                Text(byteGroupLabel(g), style: t.textTheme.labelMedium),
              ]),
        ]),
        const SizedBox(height: Gap.s),
        LayoutBuilder(builder: (context, c) {
          const offsetW = 34.0;
          final cell = ((c.maxWidth - offsetW) / perRow).clamp(24.0, 64.0);
          return Column(children: [
            for (var row = 0; row < rows; row++)
              Row(children: [
                SizedBox(
                  width: offsetW,
                  child: ExcludeSemantics(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text((row * perRow).toRadixString(16).padLeft(2, '0'), style: AppType.mono.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    ),
                  ),
                ),
                for (var k = 0; k < perRow; k++)
                  if (row * perRow + k < bytes.length) _cell(context, row * perRow + k, bytes, cell, sel) else SizedBox(width: cell),
              ]),
          ]);
        }),
        const SizedBox(height: Gap.m),
        for (final r in widget.ranges) _fieldRow(context, r, sel),
      ],
    );
  }

  Widget _cell(BuildContext context, int i, List<int> bytes, double w, ByteRange? sel) {
    final t = Theme.of(context);
    final r = _rangeAt(i);
    final lit = sel != null && sel.contains(i);
    final hex = bytes[i].toRadixString(16).padLeft(2, '0');
    final g = r?.group ?? ByteGroup.other;
    return Semantics(
      button: true,
      selected: lit,
      label: 'Byte ${i + 1} of ${bytes.length}, hex $hex, ${r?.label ?? 'not described'}',
      child: InkWell(
        key: Key('inspector-byte-$i'),
        onTap: r == null ? null : () => _select(r.field),
        child: Container(
          width: w,
          height: 30,
          margin: const EdgeInsets.symmetric(vertical: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: lit ? byteGroupSolid(g) : byteGroupColor(context, g),
            border: lit ? Border.all(color: t.colorScheme.onSurface, width: 1.5) : null,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(r != null && r.start == i ? 6 : 0),
              right: Radius.circular(r != null && r.end == i + 1 ? 6 : 0),
            ),
          ),
          child: ExcludeSemantics(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(hex, style: AppType.mono.copyWith(fontSize: 15, color: lit ? Colors.black : t.colorScheme.onSurface)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fieldRow(BuildContext context, ByteRange r, ByteRange? sel) {
    final t = Theme.of(context);
    final lit = sel?.field == r.field;
    final value = byteValueText(r.value);
    final span = r.length == 1 ? 'byte ${r.start + 1}' : 'bytes ${r.start + 1}-${r.end}';
    return Semantics(
      button: true,
      selected: lit,
      label: '${r.label}, $span${value.isEmpty ? '' : ', $value'}',
      child: InkWell(
        key: Key('inspector-field-${r.field}'),
        onTap: () => _select(r.field),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.xs),
          decoration: BoxDecoration(
            color: lit ? byteGroupColor(context, r.group) : null,
            border: Border(left: BorderSide(color: byteGroupSolid(r.group), width: 4)),
          ),
          child: ExcludeSemantics(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(r.label, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                Text(span, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
              if (value.isNotEmpty) Text(value, style: t.textTheme.bodySmall),
              HexText(r.hex, maxLines: lit ? null : 1),
            ]),
          ),
        ),
      ),
    );
  }
}
