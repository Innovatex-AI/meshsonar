// Building blocks shared by every Settings section: the collapsible section card, the anchors that search and the
// section index jump to, the slider row, the text-edit dialog and the consequence-stating confirmation dialog.
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../app.dart';

// ---------- anchors (search and the section index scroll to these) ----------

/// Shared by the Settings shell and its sections: one [GlobalKey] per anchor id, and which one was jumped to last.
class SettingsAnchors extends InheritedWidget {
  final Map<String, GlobalKey> keys;
  final String? highlighted;
  const SettingsAnchors({super.key, required this.keys, required this.highlighted, required super.child});

  static SettingsAnchors? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SettingsAnchors>();

  @override
  bool updateShouldNotify(SettingsAnchors old) => old.highlighted != highlighted || !identical(old.keys, keys);
}

/// Marks [child] as the target of a search result or index jump with this [id]. The row the person jumped to is tinted
/// until the next jump, so the eye finds it after the scroll.
class SettingsAnchor extends StatelessWidget {
  final String id;
  final Widget child;
  const SettingsAnchor({super.key, required this.id, required this.child});

  @override
  Widget build(BuildContext context) {
    final a = SettingsAnchors.maybeOf(context);
    if (a == null) return child;
    final k = a.keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'settings-anchor-$id'));
    final on = a.highlighted == id;
    // Same widget structure either way, so the row keeps its state (typed text, a revealed key) when tinted.
    return KeyedSubtree(
      key: k,
      child: DecoratedBox(
        decoration: on ? BoxDecoration(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)) : const BoxDecoration(),
        child: child,
      ),
    );
  }
}

// ---------- section card ----------

/// A titled group of settings in one rounded card. With [onToggle] the header is a button that folds the card away
/// (the explanation line folds with it); the header always stays.
class SettingsSection extends StatelessWidget {
  final String id;
  final String title;
  final IconData icon;
  final String? help;
  final List<Widget> children;
  final bool collapsed;
  final VoidCallback? onToggle;
  const SettingsSection({
    super.key,
    required this.id,
    required this.title,
    required this.icon,
    this.help,
    required this.children,
    this.collapsed = false,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final heading = Row(children: [
      Icon(icon, size: 18, color: c.primary),
      const SizedBox(width: 8),
      Expanded(
        child: Text(title.toUpperCase(),
            style: t.textTheme.labelLarge?.copyWith(color: c.primary, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
      ),
      if (onToggle != null) Icon(collapsed ? Icons.expand_more : Icons.expand_less, color: c.primary),
    ]);
    return SettingsAnchor(
      id: 'section-$id',
      child: Padding(
        key: Key('section-$id'),
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (onToggle == null)
            Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 4), child: Semantics(header: true, child: heading))
          else
            Semantics(
              header: true,
              button: true,
              expanded: !collapsed,
              child: InkWell(
                key: Key('section-toggle-$id'),
                borderRadius: BorderRadius.circular(Corners.small),
                onTap: onToggle,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 4), child: heading),
                ),
              ),
            ),
          if (!collapsed) ...[
            if (help != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(help!, style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
              ),
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) Divider(height: 1, indent: 56, color: c.outlineVariant.withValues(alpha: 0.5)),
                  children[i],
                ],
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

/// A plain row with a leading icon, a title and a one-line explanation, optionally tappable.
class InfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  const InfoTile({super.key, required this.icon, required this.title, this.subtitle, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: trailing ?? (onTap == null ? null : const Icon(Icons.chevron_right)),
        onTap: onTap,
      );
}

// ---------- confirmation ----------

/// Asks before a destructive or sharing-related change. The body states the consequence (no "Are you sure?").
/// Returns true only when the person pressed [confirmLabel].
Future<bool> confirmSettingsChange(
  BuildContext context, {
  required String dialogKey,
  required String title,
  required String body,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = Theme.of(ctx).colorScheme;
      return AlertDialog(
        key: Key(dialogKey),
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(key: Key('$dialogKey-cancel'), onPressed: () => Navigator.pop(ctx, false), child: Text(cancelLabel)),
          FilledButton(
            key: Key('$dialogKey-confirm'),
            style: destructive ? FilledButton.styleFrom(backgroundColor: c.error, foregroundColor: c.onError) : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return ok == true;
}

// ---------- sliders ----------

/// Slider stops (values outside these, e.g. from an older settings file, snap to the nearest stop).
const List<int> intervalStops = [10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100, 105, 110, 115, 120];
const List<int> distanceStops = [15, 25, 50, 75, 100, 125, 150, 200, 250, 300, 400, 500];
const List<int> holdStops = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
final List<int> syncEveryStops = [for (var m = Settings.minSyncEveryMin; m <= Settings.maxSyncEveryMin; m++) m];

/// Index of the stop closest to [v].
int nearestStop(List<int> stops, int v) {
  var best = 0;
  for (var i = 1; i < stops.length; i++) {
    if ((stops[i] - v).abs() < (stops[best] - v).abs()) best = i;
  }
  return best;
}

/// A setting with a big value label and a slider over fixed [stops]. Saves when the drag ends (not every frame).
class SliderTile extends StatefulWidget {
  final Key? sliderKey;
  final IconData icon;
  final String title;
  final String? caption;
  final List<int> stops;
  final int value;
  final String Function(int v) label;
  final String? minLabel, maxLabel;
  final bool enabled;
  final ValueChanged<int> onChanged;
  const SliderTile({
    super.key,
    this.sliderKey,
    required this.icon,
    required this.title,
    this.caption,
    required this.stops,
    required this.value,
    required this.label,
    this.minLabel,
    this.maxLabel,
    this.enabled = true,
    required this.onChanged,
  });

  @override
  State<SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<SliderTile> {
  int? _dragIndex;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final idx = _dragIndex ?? nearestStop(widget.stops, widget.value);
    final v = widget.stops[idx];
    final muted = !widget.enabled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Icon(widget.icon, color: muted ? c.outline : c.onSurfaceVariant),
          const SizedBox(width: 16),
          // Title and value share a line when they fit; with large text the value moves under the title.
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Gap.s,
              children: [
                Text(widget.title, style: t.textTheme.titleMedium?.copyWith(color: muted ? c.onSurfaceVariant : null)),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(widget.label(v),
                      key: widget.key is ValueKey<String> ? Key('${(widget.key as ValueKey<String>).value}-value') : null,
                      style: numberStyle(context, size: 22, color: muted ? c.onSurfaceVariant : c.primary)),
                ),
              ],
            ),
          ),
        ]),
        if (widget.caption != null)
          Padding(
            padding: const EdgeInsets.only(left: 40, top: 2, right: 8),
            child: Text(widget.caption!, style: t.textTheme.bodySmall),
          ),
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              tickMarkShape: SliderTickMarkShape.noTickMark,
              showValueIndicator: ShowValueIndicator.never,
            ),
            child: Slider(
              key: widget.sliderKey,
              value: idx.toDouble(),
              min: 0,
              max: (widget.stops.length - 1).toDouble(),
              divisions: widget.stops.length - 1,
              semanticFormatterCallback: (d) => '${widget.title}: ${widget.label(widget.stops[d.round()])}',
              onChanged: widget.enabled ? (d) => setState(() => _dragIndex = d.round()) : null,
              onChangeEnd: widget.enabled
                  ? (d) {
                      final nv = widget.stops[d.round()];
                      setState(() => _dragIndex = null);
                      if (nv != widget.value) widget.onChanged(nv);
                    }
                  : null,
            ),
          ),
        ),
        if (widget.minLabel != null || widget.maxLabel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(48, 0, 24, 6),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Flexible(child: Text(widget.minLabel ?? '', style: t.textTheme.labelSmall)),
              Flexible(child: Text(widget.maxLabel ?? '', style: t.textTheme.labelSmall, textAlign: TextAlign.end)),
            ]),
          ),
      ]),
    );
  }
}

// ---------- edit dialog ----------

Future<String?> editSettingText(
  BuildContext context, {
  required String title,
  required String initial,
  String? hint,
  String? help,
  TextInputType? keyboard,
  String? Function(String)? validate,
}) {
  final c = TextEditingController(text: initial);
  final formKey = GlobalKey<FormState>();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextFormField(
              key: const Key('edit-field'),
              controller: c,
              autofocus: true,
              keyboardType: keyboard,
              decoration: InputDecoration(hintText: hint),
              validator: (v) {
                final s = v ?? '';
                if (s.trim().isEmpty && validate == null) return 'Enter a value';
                return validate?.call(s);
              },
            ),
            if (help != null) ...[const SizedBox(height: 8), Text(help, style: Theme.of(ctx).textTheme.bodySmall)],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          key: const Key('edit-save'),
          onPressed: () {
            if (formKey.currentState?.validate() ?? false) Navigator.pop(ctx, c.text);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
