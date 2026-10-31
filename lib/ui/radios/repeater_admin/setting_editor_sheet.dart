// The one sheet every repeater setting is changed in: edit -> review (current -> new, consequences, typed confirmation when
// the change is dangerous) -> sending and reading back -> result (Verified / Could not verify / Not applied / Refused) with
// Undo and Re-check. Nothing is sent before the review step is confirmed. Passwords are typed here, masked, and are only
// ever passed to the controller; they are not kept in this widget's state after the sheet closes.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../radio/repeater_admin.dart';
import '../../../radio/repeater_cli.dart' show utf8Length;
import '../../../radio/repeater_settings.dart';
import '../../theme.dart';
import 'admin_common.dart';
import 'admin_controller.dart';

/// Opens the editor for [def]. [initial] pre-fills the value (for example the region preset). Returns when the sheet closes.
Future<void> showSettingEditor(BuildContext context, RepeaterAdminController c, SettingDef def, {String? initial, ChangePlan? startAtReview}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => SettingEditorSheet(controller: c, def: def, initial: initial, startAtReview: startAtReview),
  );
}

enum _Phase { edit, review, applying, result }

class SettingEditorSheet extends StatefulWidget {
  final RepeaterAdminController controller;
  final SettingDef def;
  final String? initial;

  /// Start on the review step of an existing plan (an undo, or a console write).
  final ChangePlan? startAtReview;
  const SettingEditorSheet({super.key, required this.controller, required this.def, this.initial, this.startAtReview});

  @override
  State<SettingEditorSheet> createState() => _SettingEditorSheetState();
}

class _SettingEditorSheetState extends State<SettingEditorSheet> {
  _Phase _phase = _Phase.edit;
  final _text = TextEditingController();
  final _text2 = TextEditingController(); // repeat password
  final _typed = TextEditingController();
  final List<TextEditingController> _radio = List.generate(4, (_) => TextEditingController());
  String _toggle = 'on';
  String _choice = '';
  String? _error;
  ChangePlan? _plan;
  AppliedChange? _result;
  bool _busy = false;

  SettingDef get def => widget.def;
  RepeaterAdminController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    final cur = c.settings[def.key]?.value;
    final start = widget.initial ?? cur ?? '';
    switch (def.kind) {
      case SettingKind.toggle:
        _toggle = (widget.initial ?? cur) == 'off' ? 'off' : 'on';
      case SettingKind.choice:
        _choice = def.choices.contains(widget.initial ?? cur) ? (widget.initial ?? cur)! : def.choices.first;
      case SettingKind.radio:
        final p = parseRadioParams(start);
        if (p != null) {
          _radio[0].text = p.freqMhz.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
          _radio[1].text = p.bwKhz.toString().replaceFirst(RegExp(r'\.0$'), '');
          _radio[2].text = '${p.sf}';
          _radio[3].text = '${p.cr}';
        }
      case SettingKind.secret:
        break;
      default:
        _text.text = start.endsWith('%') ? start.substring(0, start.length - 1) : start;
    }
    if (widget.startAtReview != null) {
      _plan = widget.startAtReview;
      _phase = _Phase.review;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _text2.dispose();
    _typed.dispose();
    for (final r in _radio) {
      r.dispose();
    }
    super.dispose();
  }

  String get _raw => switch (def.kind) {
        SettingKind.toggle => _toggle,
        SettingKind.choice => _choice,
        SettingKind.radio => _radio.map((e) => e.text.trim()).join(','),
        _ => _text.text,
      };

  Future<void> _review() async {
    if (def.kind == SettingKind.secret && _text.text != _text2.text) {
      setState(() => _error = 'The two entries are different.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await c.plan(def, def.kind == SettingKind.secret ? _text.text : _raw);
      if (!mounted) return;
      setState(() {
        _plan = p;
        _phase = _Phase.review;
        _busy = false;
        _typed.clear();
      });
    } on AdminException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  bool get _confirmed {
    final p = _plan;
    if (p == null || p.noChange) return false;
    final phrase = p.typedPhrase;
    return phrase == null || _typed.text.trim() == phrase;
  }

  Future<void> _apply() async {
    final p = _plan!;
    setState(() {
      _phase = _Phase.applying;
      _error = null;
    });
    try {
      final r = await c.apply(p, Confirmation(acknowledged: true, typed: _typed.text));
      if (!mounted) return;
      setState(() {
        _result = r;
        _phase = _Phase.result;
        _text.clear();
        _text2.clear();
      });
    } on AdminException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _phase = _Phase.review;
      });
    }
  }

  Future<void> _recheck() async {
    setState(() => _busy = true);
    try {
      final r = await c.recheck(_result!);
      if (!mounted) return;
      setState(() {
        _result = r;
        _busy = false;
      });
    } on AdminException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _undo() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await c.session.planUndo(_result!);
      if (!mounted) return;
      setState(() {
        _plan = p;
        _result = null;
        _phase = _Phase.review;
        _busy = false;
        _typed.clear();
      });
    } on AdminException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
            child: Column(
              key: Key('editor-${def.key}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(header: true, child: Text(def.label, style: t.textTheme.titleLarge)),
                const SizedBox(height: Gap.xs),
                Text(def.help, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                const SizedBox(height: Gap.l),
                switch (_phase) {
                  _Phase.edit => _editStep(context),
                  _Phase.review => _reviewStep(context),
                  _Phase.applying => _applying(context),
                  _Phase.result => _resultStep(context),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ edit

  Widget _editStep(BuildContext context) {
    final t = Theme.of(context);
    final cur = c.settings[def.key];
    final field = switch (def.kind) {
      SettingKind.toggle => SwitchListTile(
          key: const Key('editor-toggle'),
          contentPadding: EdgeInsets.zero,
          title: Text(_toggle == 'on' ? 'On' : 'Off'),
          value: _toggle == 'on',
          onChanged: (v) => setState(() => _toggle = v ? 'on' : 'off'),
        ),
      SettingKind.choice => RadioGroup<String>(
          groupValue: _choice,
          onChanged: (v) => setState(() => _choice = v ?? _choice),
          child: Column(children: [
            for (final o in def.choices) RadioListTile<String>(key: Key('editor-choice-$o'), contentPadding: EdgeInsets.zero, title: Text(o), value: o),
          ]),
        ),
      SettingKind.radio => _radioFields(context),
      SettingKind.secret => Column(children: [
          TextField(
            key: const Key('editor-secret'),
            controller: _text,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 15,
            inputFormatters: [LengthLimitingTextInputFormatter(15)],
            decoration: InputDecoration(labelText: 'New ${def.key == 'password' ? 'admin' : 'guest'} password', helperText: 'Up to 15 characters'),
          ),
          TextField(
            key: const Key('editor-secret-repeat'),
            controller: _text2,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Type it again'),
          ),
        ]),
      _ => TextField(
          key: const Key('editor-text'),
          controller: _text,
          autocorrect: false,
          enableSuggestions: false,
          maxLines: def.key == 'owner.info' ? 3 : 1,
          keyboardType: def.kind == SettingKind.integer
              ? TextInputType.number
              : def.kind == SettingKind.decimal
                  ? const TextInputType.numberWithOptions(decimal: true, signed: true)
                  : TextInputType.text,
          decoration: InputDecoration(labelText: def.label, suffixText: def.unit, helperText: cur?.ok == true ? 'Now: ${def.display(cur!.value)}' : null),
          onChanged: (_) => setState(() {}),
        ),
    };
    final len = def.kind == SettingKind.text && def.maxBytes != null ? _byteCounter(t) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      field,
      ?len,
      if (_error != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: _errorText(context, _error!)),
      const SizedBox(height: Gap.l),
      Row(children: [
        Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: kTarget), onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))),
        const SizedBox(width: Gap.m),
        Expanded(
          child: FilledButton(
            key: const Key('editor-review'),
            style: FilledButton.styleFrom(minimumSize: kTarget),
            onPressed: _busy ? null : _review,
            child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Review change'),
          ),
        ),
      ]),
    ]);
  }

  Widget _byteCounter(ThemeData t) {
    final n = utf8Length(_text.text);
    final limit = def.maxBytes!;
    final over = n > limit;
    final warn = def.key == 'name' && n > 23;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text('$n of $limit bytes${def.key == 'name' ? ' (23 fit in an advert that carries a position)' : ''}',
          key: const Key('editor-bytes'), style: t.textTheme.bodySmall?.copyWith(color: over ? t.colorScheme.error : (warn ? const Color(0xFFB26A00) : t.colorScheme.onSurfaceVariant))),
    );
  }

  Widget _radioFields(BuildContext context) {
    final t = Theme.of(context);
    final preset = c.regionPreset;
    Widget f(int i, String label, String? suffix, {bool decimal = true}) => TextField(
          key: Key('radio-field-$i'),
          controller: _radio[i],
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          decoration: InputDecoration(labelText: label, suffixText: suffix),
          onChanged: (_) => setState(() {}),
        );
    final cur = c.settings['radio']?.value;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        key: const Key('radio-warning'),
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(color: t.colorScheme.errorContainer, borderRadius: BorderRadius.circular(Corners.chip)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.warning_amber_rounded, color: t.colorScheme.onErrorContainer),
          const SizedBox(width: Gap.s),
          Expanded(
              child: Text(
                  'Wrong radio settings take this repeater off the air. Nobody, including you, can reach it again until someone changes it on site. Only change these to the settings of the region you are in.',
                  style: TextStyle(color: t.colorScheme.onErrorContainer, height: 1.3))),
        ]),
      ),
      const SizedBox(height: Gap.m),
      if (cur != null) Text('Now: ${parseRadioParams(cur) ?? cur}', style: t.textTheme.bodyMedium),
      if (preset != null) ...[
        const SizedBox(height: Gap.xs),
        Text('Region preset (${preset.name}): ${preset.freqMhz} MHz, ${preset.bwKhz} kHz, SF${preset.sf}, CR${preset.cr}', key: const Key('radio-preset-line'), style: t.textTheme.bodyMedium),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('radio-use-preset'),
            style: TextButton.styleFrom(minimumSize: kTarget),
            onPressed: () => setState(() {
              _radio[0].text = '${preset.freqMhz}';
              _radio[1].text = '${preset.bwKhz}'.replaceFirst(RegExp(r'\.0$'), '');
              _radio[2].text = '${preset.sf}';
              _radio[3].text = '${preset.cr}';
            }),
            child: const Text('Fill in the region preset'),
          ),
        ),
      ] else
        Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text('This region has no preset on file to compare with.', style: t.textTheme.bodySmall)),
      const SizedBox(height: Gap.s),
      f(0, 'Frequency', 'MHz'),
      f(1, 'Bandwidth', 'kHz'),
      f(2, 'Spreading factor', null, decimal: false),
      f(3, 'Coding rate', null, decimal: false),
    ]);
  }

  // ------------------------------------------------------------------ review

  Widget _errorText(BuildContext context, String s) =>
      Text(s, key: const Key('editor-error'), style: TextStyle(color: Theme.of(context).colorScheme.error, height: 1.3));

  Widget _reviewStep(BuildContext context) {
    final t = Theme.of(context);
    final p = _plan!;
    final shownNow = def.secret ? '••••' : def.display(p.current);
    final shownNext = def.secret ? '••••' : def.display(p.next);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        key: const Key('review-change'),
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Corners.chip)),
        child: Semantics(
          label: 'Change from $shownNow to $shownNext',
          excludeSemantics: true,
          child: Wrap(spacing: Gap.s, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(def.secret ? 'New password' : shownNow, style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            if (!def.secret) const Icon(Icons.arrow_forward, size: 18),
            if (!def.secret) Text(shownNext, key: const Key('review-new'), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
      const SizedBox(height: Gap.m),
      if (p.noChange)
        Text('It is already set to this value. Nothing to change.', key: const Key('review-nochange'), style: t.textTheme.bodyLarge)
      else ...[
        Text(p.consequence, key: const Key('review-consequence'), style: t.textTheme.bodyLarge?.copyWith(height: 1.35)),
        const SizedBox(height: Gap.s),
        Row(children: [
          Icon(dangerIcon(p.danger), size: 18, color: dangerColor(context, p.danger)),
          const SizedBox(width: 6),
          Expanded(child: Text(dangerWords(p.danger), key: const Key('review-danger'), style: t.textTheme.bodyMedium?.copyWith(color: dangerColor(context, p.danger), fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 4),
        Text(p.effect == TakesEffect.live ? 'Takes effect as soon as it is saved.' : 'Saved now, used after the repeater reboots.',
            key: const Key('review-effect'), style: t.textTheme.bodyMedium),
        for (final w in p.warnings)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.warning_amber_rounded, size: 18, color: Color(0xFFB26A00)),
              const SizedBox(width: 6),
              Expanded(child: Text(w, style: t.textTheme.bodyMedium)),
            ]),
          ),
        if (p.typedPhrase != null) ...[
          const SizedBox(height: Gap.m),
          Text('To go on, type ${p.typedPhrase}', key: const Key('review-typed-prompt'), style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
          TextField(
            key: const Key('review-typed'),
            controller: _typed,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(hintText: p.typedPhrase),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: _errorText(context, _error!)),
      const SizedBox(height: Gap.l),
      Row(children: [
        Expanded(
          child: OutlinedButton(
            key: const Key('review-back'),
            style: OutlinedButton.styleFrom(minimumSize: kTarget),
            onPressed: () => widget.startAtReview != null ? Navigator.of(context).pop() : setState(() => _phase = _Phase.edit),
            child: Text(widget.startAtReview != null ? 'Cancel' : 'Back'),
          ),
        ),
        const SizedBox(width: Gap.m),
        Expanded(
          child: FilledButton(
            key: const Key('review-apply'),
            style: FilledButton.styleFrom(minimumSize: kTarget, backgroundColor: p.danger.index >= Danger.disruptive.index ? t.colorScheme.error : null),
            onPressed: _confirmed ? _apply : null,
            child: const Text('Apply'),
          ),
        ),
      ]),
    ]);
  }

  // ------------------------------------------------------------------ applying / result

  Widget _applying(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xl),
        child: Semantics(
          liveRegion: true,
          label: 'Sending the change, then reading it back',
          child: Column(children: const [
            CircularProgressIndicator(key: Key('editor-applying')),
            SizedBox(height: Gap.l),
            Text('Sending, then reading it back from the repeater. This takes a few seconds.', textAlign: TextAlign.center),
          ]),
        ),
      );

  Widget _resultStep(BuildContext context) {
    final t = Theme.of(context);
    final r = _result!;
    final (IconData icon, Color color, String title, String body) = switch (r.outcome) {
      ApplyOutcome.verified => (
          Icons.check_circle,
          t.colorScheme.primary,
          'Verified',
          def.secret
              ? (def.key == 'password'
                  ? 'The repeater reported the new password. Test it with a fresh login before you close the app.'
                  : 'The repeater now has the new password.')
              : 'The repeater now reports ${def.display(r.readBack)}.'
        ),
      ApplyOutcome.unverified => (
          Icons.help_outline,
          const Color(0xFFB26A00),
          'Could not verify',
          'The repeater did not answer when MeshSonar asked for the value back. The change may or may not have been saved. Tap Check again.'
        ),
      ApplyOutcome.notApplied => (
          Icons.error_outline,
          t.colorScheme.error,
          'Not applied',
          'The repeater still has its old value, so the change did not arrive. Nothing was sent twice. You can try again.'
        ),
      ApplyOutcome.rejected => (
          Icons.block,
          t.colorScheme.error,
          'The repeater refused',
          r.replyText == null || r.replyText!.isEmpty ? 'It answered with an error.' : 'It said: ${r.replyText}'
        ),
      ApplyOutcome.mismatch => (
          Icons.error_outline,
          t.colorScheme.error,
          'Saved, but different',
          'The repeater reports ${def.secret ? 'a different value' : def.display(r.readBack)} instead of ${def.secret ? 'the one you typed' : def.display(r.plan.next)}.'
        ),
    };
    final canRecheck = r.outcome == ApplyOutcome.unverified || r.outcome == ApplyOutcome.mismatch;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        liveRegion: true,
        child: Row(children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: Gap.s),
          Expanded(child: Text(title, key: Key('result-${r.outcome.name}'), style: t.textTheme.titleLarge?.copyWith(color: color))),
        ]),
      ),
      const SizedBox(height: Gap.s),
      Text(body, style: t.textTheme.bodyLarge?.copyWith(height: 1.35)),
      if (r.needsReboot) ...[
        const SizedBox(height: Gap.s),
        Text('This is saved but not used yet. It takes effect when the repeater reboots (Advanced, on the Settings tab). Until then it keeps its old radio settings.',
            key: const Key('result-reboot'), style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: Gap.s), child: _errorText(context, _error!)),
      const SizedBox(height: Gap.l),
      Wrap(spacing: Gap.m, runSpacing: Gap.s, children: [
        if (canRecheck)
          OutlinedButton.icon(
            key: const Key('result-recheck'),
            style: OutlinedButton.styleFrom(minimumSize: kTarget),
            onPressed: _busy ? null : _recheck,
            icon: const Icon(Icons.refresh),
            label: const Text('Check again'),
          ),
        if (r.outcome == ApplyOutcome.notApplied)
          OutlinedButton(
            key: const Key('result-retry'),
            style: OutlinedButton.styleFrom(minimumSize: kTarget),
            onPressed: () => setState(() => _phase = _Phase.review),
            child: const Text('Try again'),
          ),
        if (r.canUndo)
          OutlinedButton.icon(
            key: const Key('result-undo'),
            style: OutlinedButton.styleFrom(minimumSize: kTarget),
            onPressed: _busy ? null : _undo,
            icon: const Icon(Icons.undo),
            label: Text('Put back ${def.display(r.plan.current)}'),
          ),
        FilledButton(key: const Key('result-done'), style: FilledButton.styleFrom(minimumSize: kTarget), onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      ]),
    ]);
  }
}
