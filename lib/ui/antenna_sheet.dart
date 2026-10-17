// "How is this radio's antenna set up?": asked once per radio when it first connects, and opened again from the
// drive screen's antenna chip or Settings → Antenna. Mount, gain (or "Don't know") and height above ground.
import 'package:flutter/material.dart';

import '../core/antenna_profile.dart';
import '../core/model.dart';
import 'app.dart';

/// Opens the antenna sheet for [radioKey] (default: the connected radio), prefilled from its saved profile, or for a
/// radio set up for the first time from the antenna setting of MeshSonar 0.3.x.
Future<void> showAntennaSheet(BuildContext context, {String? radioKey}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _AntennaSheet(radioKey: radioKey),
  );
}

const Map<AntennaMount, (IconData, String)> _mountInfo = {
  AntennaMount.handheld: (Icons.back_hand_outlined, 'The radio in your hand or pocket, with its own antenna.'),
  AntennaMount.insideCar: (Icons.directions_car_outlined, 'On the dash or a seat, antenna inside the car.'),
  AntennaMount.roofMagMount: (Icons.settings_input_antenna, 'A magnetic antenna on the car roof.'),
  AntennaMount.fixedMast: (Icons.cell_tower, 'A mast or pole that stays in one place.'),
};

class _AntennaSheet extends StatefulWidget {
  final String? radioKey;
  const _AntennaSheet({this.radioKey});
  @override
  State<_AntennaSheet> createState() => _AntennaSheetState();
}

class _AntennaSheetState extends State<_AntennaSheet> {
  final _gain = TextEditingController();
  final _height = TextEditingController();
  AntennaMount? _mount;
  bool _gainUnknown = false;

  /// The 0.3.x setting this first setup was prefilled from, if any.
  Antenna? _legacy;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final s = AppScope.read(context);
    final key = widget.radioKey;
    final saved = key == null ? s.antennaProfile : s.settings.antennaProfiles[key];
    if (saved != null) {
      _mount = saved.mount;
      _gainUnknown = saved.gainDbi == null;
      _gain.text = saved.gainDbi == null ? '' : formatAntennaNumber(saved.gainDbi!);
      _height.text = formatAntennaNumber(saved.heightM);
    } else if (s.legacyAntenna case final a?) {
      _legacy = a;
      _gainUnknown = a.gainDbi == null;
      _gain.text = a.gainDbi == null ? '' : formatAntennaNumber(a.gainDbi!);
      _height.text = a.heightM == null ? '' : formatAntennaNumber(a.heightM!);
    }
  }

  @override
  void dispose() {
    _gain.dispose();
    _height.dispose();
    super.dispose();
  }

  static double? _number(String text) => double.tryParse(text.trim().replaceAll(',', '.'));

  double? get _gainValue {
    final v = _number(_gain.text);
    return v != null && AntennaProfile.validGain(v) ? v : null;
  }

  double? get _heightValue {
    final v = _number(_height.text);
    return v != null && AntennaProfile.validHeight(v) ? v : null;
  }

  bool get _valid => _mount != null && _heightValue != null && (_gainUnknown || _gainValue != null);

  /// Mounts in the order offered: the ones matching the 0.3.x choice first.
  List<AntennaMount> get _mounts {
    final legacy = _legacy;
    if (legacy == null) return AntennaMount.values;
    return [
      ...AntennaMount.values.where((m) => m.wireType == legacy.type),
      ...AntennaMount.values.where((m) => m.wireType != legacy.type),
    ];
  }

  Future<void> _save() async {
    final s = AppScope.read(context);
    final nav = Navigator.of(context);
    await s.saveAntennaProfile(
      AntennaProfile(
        mount: _mount!,
        gainDbi: _gainUnknown ? null : _gainValue,
        heightM: _heightValue!,
        updatedAt: s.services.clock().toUtc(),
      ),
      radioKey: widget.radioKey,
    );
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final key = widget.radioKey;
    final radio = key == null ? s.selfInfo?.name : s.radioName(key);
    final gainText = _gain.text.trim();
    final heightText = _height.text.trim();
    final legacy = _legacy;
    return Padding(
      key: const Key('antenna-sheet'),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(header: true, child: Text('How is this radio\'s antenna set up?', style: t.textTheme.titleLarge)),
            const SizedBox(height: Gap.xs),
            Text(
              '${radio ?? 'This radio'}: saved for every drive with it, so coverage is compared like '
              'with like. You can change it later in Settings.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            if (legacy != null) ...[
              const SizedBox(height: Gap.s),
              Text(
                'Before 0.4.0 you chose ${legacy.type == 'external' ? 'External' : 'Internal'}. '
                'Pick the mount that matches.',
                key: const Key('antenna-upgrade-note'),
                style: t.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: Gap.m),
            for (final m in _mounts) _mountTile(context, m),
            const SizedBox(height: Gap.m),
            TextField(
              key: const Key('antenna-gain-field'),
              controller: _gain,
              enabled: !_gainUnknown,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: InputDecoration(
                labelText: 'Gain (dBi)',
                helperText: 'From −10 to 20 dBi. Often printed on the antenna.',
                errorText: !_gainUnknown && gainText.isNotEmpty && _gainValue == null ? 'Enter −10 to 20 dBi' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            SwitchListTile(
              key: const Key('antenna-gain-unknown'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Don\'t know'),
              subtitle: const Text('The gain is recorded as unknown.'),
              value: _gainUnknown,
              onChanged: (v) => setState(() => _gainUnknown = v),
            ),
            const SizedBox(height: Gap.s),
            TextField(
              key: const Key('antenna-height-field'),
              controller: _height,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Height above ground (metres)',
                helperText: 'Roughly: about 1 m in a hand or inside a car, 1.5 m on a car roof.',
                errorText: heightText.isNotEmpty && _heightValue == null ? 'Enter 0 to 300 metres' : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Gap.l),
            FilledButton(
              key: const Key('antenna-save'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _valid ? _save : null,
              child: const Text('Save antenna'),
            ),
            if (!_valid) ...[
              const SizedBox(height: Gap.xs),
              Text(
                'Pick a mount, enter the height, and a gain or Don\'t know',
                key: const Key('antenna-save-hint'),
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _mountTile(BuildContext context, AntennaMount m) {
    final t = Theme.of(context);
    final (icon, about) = _mountInfo[m]!;
    final selected = _mount == m;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        child: ListTile(
          key: ValueKey('mount-${m.name}'),
          selected: selected,
          selectedTileColor: t.colorScheme.primaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Corners.chip),
            side: BorderSide(color: selected ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: 1.5),
          ),
          leading: Icon(icon),
          title: Text(m.label),
          subtitle: Text(about),
          trailing: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
          onTap: () => setState(() => _mount = m),
        ),
      ),
    );
  }
}
