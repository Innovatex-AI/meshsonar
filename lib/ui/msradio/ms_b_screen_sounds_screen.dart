// MeshSonar radio > Radio screen and sounds (brief C.8): the node name, brightness, screen timeout, buzzer, volume, screen
// flash, the six alert events (one bit mask), quiet hours; and the lock screen PIN: Lock now, Set PIN, Remove PIN.
// Every change is one `POST /settings` and the screen shows what the radio answers. A PIN is typed into an obscured field in
// a dialog, sent once in the request body and forgotten: it is never stored, logged or shown.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/msradio/msradio.dart';
import 'ms_b_common.dart';

/// Plain labels for the radio's event bits (APP-INTEGRATION.md: `event_bits`).
const Map<String, String> kMsEventLabels = {
  'dm': 'Direct messages',
  'channel': 'Channel messages',
  'mention': 'Mentions',
  'delivered': 'Delivered',
  'not_delivered': 'Not delivered',
  'low_battery': 'Low battery',
};

/// "30 s", "1 min", "Never".
String msBTimeoutLabel(int ms) {
  if (ms <= 0) return 'Never';
  final s = ms ~/ 1000;
  if (s < 60) return '$s s';
  if (s % 60 == 0) return '${s ~/ 60} min';
  return '${(s / 60).toStringAsFixed(1)} min';
}

String msBVolumeLabel(int v) => switch (v) { 1 => 'Low', 2 => 'Medium', 3 => 'High', _ => '$v' };

class MsBScreenSoundsScreen extends StatefulWidget {
  final MsRadioController c;
  const MsBScreenSoundsScreen({super.key, required this.c});
  @override
  State<MsBScreenSoundsScreen> createState() => _MsBScreenSoundsScreenState();
}

class _MsBScreenSoundsScreenState extends State<MsBScreenSoundsScreen> {
  MsSettings? _s;
  String? _error, _note;
  bool _loading = true, _saving = false;
  double? _brightness; // while dragging
  final _name = TextEditingController();
  bool _nameDirty = false;

  MsRadioApi? get _api => widget.c.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _adopt(MsSettings s) {
    _s = s;
    _brightness = null;
    if (!_nameDirty) _name.text = s.name ?? '';
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null) return;
    MsSettings? s;
    final err = await msBTry(() async => s = await api.settings());
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (s != null) _adopt(s!);
      if (err != null) _error = err;
    });
  }

  /// One POST /settings; the reply is the new state. On a refusal the radio's text shows and nothing changed.
  Future<void> _set(Future<MsSettings> Function(MsRadioApi api) job, {String? note}) async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _saving = true;
      _error = null;
      _note = null;
    });
    MsSettings? s;
    final err = await msBTry(() async => s = await job(api));
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = err;
      if (s != null) {
        _adopt(s!);
        _note = note;
      } else {
        _brightness = null;
      }
    });
  }

  Future<void> _lockAction(Future<MsActionResult> Function(MsRadioApi api) job, String note) async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _saving = true;
      _error = null;
      _note = null;
    });
    final err = await msBTry(() => job(api));
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = err;
      if (err == null) _note = note;
    });
    if (err == null) await _load();
  }

  Future<void> _saveName() async {
    final n = _name.text.trim();
    if (n.isEmpty || n.length > 31) {
      setState(() => _error = 'The name is 1 to 31 characters.');
      return;
    }
    _nameDirty = false;
    await _set((api) => api.setSettings(name: n), note: 'Name saved.');
  }

  Future<void> _pickQuiet(bool start) async {
    final snd = _s?.sounds;
    if (snd == null) return;
    final cur = (start ? snd.quietStart : snd.quietEnd) ?? (start ? 22 * 60 : 7 * 60);
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
      helpText: start ? 'Quiet hours start' : 'Quiet hours end',
    );
    if (t == null || !mounted) return;
    final m = t.hour * 60 + t.minute;
    final qs = start ? m : (snd.quietStart ?? 22 * 60);
    final qe = start ? (snd.quietEnd ?? 7 * 60) : m;
    await _set((api) => api.setSettings(quietStart: qs, quietEnd: qe));
  }

  /// Asks for a PIN in an obscured field. The text never leaves this dialog except as the return value.
  Future<String?> _askPin({required String key, required String title, required String body, required String confirm}) async {
    return showDialog<String>(context: context, builder: (_) => _PinDialog(dialogKey: key, title: title, body: body, confirmLabel: confirm));
  }

  Future<void> _setPin() async {
    final pin = await _askPin(
        key: 'set-pin',
        title: 'Set a PIN',
        body: 'The radio asks for this PIN to unlock its screen. 4 to 8 digits. MeshSonar does not keep it.',
        confirm: 'Set PIN');
    if (pin == null || !mounted) return;
    await _lockAction((api) => api.setPin(pin), 'PIN set. Lock now locks the radio\'s screen.');
  }

  Future<void> _clearPin() async {
    final pin = await _askPin(key: 'clear-pin', title: 'Remove the PIN', body: 'Type the radio\'s current PIN.', confirm: 'Remove PIN');
    if (pin == null || !mounted) return;
    await _lockAction((api) => api.clearPin(pin), 'PIN removed.');
  }

  String _minutes(BuildContext context, int? m) {
    if (m == null) return 'not set';
    return TimeOfDay(hour: (m ~/ 60) % 24, minute: m % 60).format(context);
  }

  List<Widget> _rows(BuildContext context) {
    final s = _s;
    if (_loading && s == null) return [const MsBBlock(child: Center(child: CircularProgressIndicator()))];
    if (s == null) return [MsBError(_error)];
    final t = Theme.of(context);
    final snd = s.sounds;
    final lock = s.lock ?? const MsLockState();
    final timeouts = [...s.screenTimeouts];
    if (s.screenTimeoutMs != null && !timeouts.contains(s.screenTimeoutMs)) timeouts.add(s.screenTimeoutMs!);
    final bright = (_brightness ?? (s.brightness ?? 80).toDouble()).clamp(5.0, 100.0);
    final off = _saving;
    return [
      MsBError(_error),
      if (_note != null) MsBBlock(child: NoteCard(_note!, key: const Key('msb-set-note'), kind: NoteKind.good)),
      InsetGroup(header: 'Name', footer: 'The radio\'s MeshCore node name, 1 to 31 characters.', rows: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: TextField(
                key: const Key('msb-set-name'),
                controller: _name,
                inputFormatters: [LengthLimitingTextInputFormatter(31)],
                decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                onChanged: (_) => setState(() => _nameDirty = true),
                onSubmitted: (_) => _saveName(),
              ),
            ),
            FilledButton.tonal(
              key: const Key('msb-set-name-save'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: off || !_nameDirty ? null : _saveName,
              child: const Text('Save'),
            ),
          ]),
        ),
      ]),
      InsetGroup(header: 'Screen', rows: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text('Brightness: ${bright.round()}%', style: t.textTheme.bodyLarge),
        ),
        Slider.adaptive(
          key: const Key('msb-set-brightness'),
          min: 5,
          max: 100,
          divisions: 19,
          value: bright,
          label: '${bright.round()}%',
          semanticFormatterCallback: (v) => '${v.round()} percent',
          onChanged: off ? null : (v) => setState(() => _brightness = v),
          onChangeEnd: off ? null : (v) => _set((api) => api.setSettings(brightness: v.round())),
        ),
        if (timeouts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: DropdownButtonFormField<int>(
              key: const Key('msb-set-timeout'),
              initialValue: s.screenTimeoutMs,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Screen turns off after', border: OutlineInputBorder()),
              items: [for (final ms in timeouts) DropdownMenuItem(value: ms, child: Text(msBTimeoutLabel(ms)))],
              onChanged: off ? null : (v) => v == null ? null : _set((api) => api.setSettings(screenTimeoutMs: v)),
            ),
          ),
      ]),
      if (snd != null) ...[
        InsetGroup(header: 'Sounds and alerts', rows: [
          if (snd.buzzerBuilt)
            MsBSwitchRow(
              switchKey: const Key('msb-set-buzzer'),
              title: 'Buzzer fitted',
              subtitle: 'Turn off when no buzzer is connected.',
              value: snd.buzzerFitted,
              onChanged: off ? null : (v) => _set((api) => api.setSettings(buzzerFitted: v)),
            ),
          if (snd.buzzerBuilt && snd.buzzerFitted)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Volume', style: t.textTheme.bodyLarge),
                const SizedBox(height: 6),
                SegmentedButton<int>(
                  key: const Key('msb-set-volume'),
                  segments: [for (final v in const [1, 2, 3]) ButtonSegment(value: v, label: Text(msBVolumeLabel(v)))],
                  selected: {(snd.volume ?? 2).clamp(1, 3)},
                  onSelectionChanged: off ? null : (v) => _set((api) => api.setSettings(volume: v.first)),
                ),
              ]),
            ),
          MsBSwitchRow(
            switchKey: const Key('msb-set-flash'),
            title: 'Screen flash',
            subtitle: 'The screen flashes for an alert.',
            value: snd.flash,
            onChanged: off ? null : (v) => _set((api) => api.setSettings(flash: v)),
          ),
        ]),
        if (snd.eventBits.isNotEmpty)
          InsetGroup(header: 'Alert for', groupKey: const Key('msb-set-events'), rows: [
            for (final e in snd.eventBits)
              MsBSwitchRow(
                switchKey: Key('msb-set-event-$e'),
                title: kMsEventLabels[e] ?? e,
                value: snd.eventOn(e),
                onChanged: off ? null : (v) => _set((api) => api.setSettings(events: snd.eventsWith(e, v))),
              ),
          ]),
        InsetGroup(header: 'Quiet hours', footer: 'No sound in this time. The screen still lights up.', rows: [
          MsBSwitchRow(
            switchKey: const Key('msb-set-quiet'),
            title: 'Quiet hours',
            value: snd.quietOn,
            onChanged: off ? null : (v) => _set((api) => api.setSettings(quietOn: v)),
          ),
          InsetRow(key: const Key('msb-set-quiet-start'), title: 'Start', value: _minutes(context, snd.quietStart), onTap: off ? null : () => _pickQuiet(true)),
          InsetRow(key: const Key('msb-set-quiet-end'), title: 'End', value: _minutes(context, snd.quietEnd), onTap: off ? null : () => _pickQuiet(false)),
        ]),
      ],
      InsetGroup(
        header: 'Lock screen',
        groupKey: const Key('msb-set-lock'),
        footer: lock.set ? 'Lock now needs the PIN on the radio to unlock it.' : 'Set a PIN to be able to lock the radio\'s screen.',
        rows: [
          InsetRow(title: 'PIN', value: lock.set ? 'Set' : 'Not set', chevron: false),
          InsetRow(title: 'Screen', value: lock.locked ? 'Locked' : 'Not locked', chevron: false),
        ],
      ),
      MsBButtons([
        FilledButton.tonalIcon(
          key: const Key('msb-lock-now'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: off || !lock.set ? null : () => _lockAction((api) => api.lockNow(), 'The radio\'s screen is locked.'),
          icon: const Icon(Icons.lock_outline),
          label: const Text('Lock now'),
        ),
        if (!lock.set)
          OutlinedButton(
            key: const Key('msb-pin-set'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: off ? null : _setPin,
            child: const Text('Set PIN'),
          )
        else
          OutlinedButton(
            key: const Key('msb-pin-clear'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: t.colorScheme.error),
            onPressed: off ? null : _clearPin,
            child: const Text('Remove PIN'),
          ),
      ]),
    ];
  }

  @override
  Widget build(BuildContext context) => MsBPage(c: widget.c, id: 'screen', title: 'Radio screen and sounds', onRefresh: _load, builder: _rows);
}

class _PinDialog extends StatefulWidget {
  final String dialogKey, title, body, confirmLabel;
  const _PinDialog({required this.dialogKey, required this.title, required this.body, required this.confirmLabel});
  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _pin = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _pin.clear();
    _pin.dispose();
    super.dispose();
  }

  void _ok() {
    final p = _pin.text;
    if (!RegExp(r'^\d{4,8}$').hasMatch(p)) {
      setState(() => _problem = 'The PIN is 4 to 8 digits.');
      return;
    }
    Navigator.pop(context, p);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        key: Key('msb-pin-dialog-${widget.dialogKey}'),
        title: Text(widget.title),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.body),
            const SizedBox(height: 12),
            TextField(
              key: const Key('msb-pin-field'),
              controller: _pin,
              autofocus: true,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              keyboardType: TextInputType.number,
              autofillHints: const <String>[],
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
              decoration: InputDecoration(labelText: 'PIN', errorText: _problem, border: const OutlineInputBorder()),
              onSubmitted: (_) => _ok(),
            ),
          ]),
        ),
        actions: [
          TextButton(key: const Key('msb-pin-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(key: const Key('msb-pin-ok'), onPressed: _ok, child: Text(widget.confirmLabel)),
        ],
      );
}
