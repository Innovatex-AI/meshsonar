// Radio setup: change this radio's name, advert position, TX power, behaviour and LoRa parameters, with guard rails.
//
//  - Every write goes through RadioSetupTool (lib/radio/tools/radio_setup.dart): limits are checked on the phone first, the
//    radio is asked, then its settings are READ BACK and compared. "Saved" means the radio reports it.
//  - Changing the LoRa parameters (frequency, bandwidth, SF, CR) changes the airwaves at once. It needs a loud confirm that
//    says what that does, never happens by itself, and never comes from the Internet without a person pressing Apply.
//  - While a drive is recording, LoRa and TX power changes are blocked unless the person confirms the survey will contain two
//    settings, and they are offered to stop the drive first.
//  - The last change can be undone.
import 'dart:convert' show utf8;

import 'package:flutter/material.dart' hide Radio;
import 'package:flutter/services.dart';

import '../../../core/model.dart' show Radio;
import '../../../core/radio_presets.dart';
import '../../../radio/protocol.dart' show maxAdvertNameBytesWithPosition, maxNodeNameBytes;
import '../../../radio/tools/radio_setup.dart';
import '../../../radio/tools/radio_tools.dart';
import '../../../radio/tools/tool_frames.dart' show RadioParamLimits;
import '../../radio/radio_screen.dart' show ComparisonTable;
import '../../theme.dart';
import '../../tools/tool_kit.dart';
import '../../tools/tools_host.dart';

class RadioSetupScreen extends StatelessWidget {
  /// Injected in tests; the app uses the community list at api.meshcore.nz.
  final CommunityPresetSource? communitySource;
  const RadioSetupScreen({super.key, this.communitySource});

  @override
  Widget build(BuildContext context) => ToolPage(
        id: 'radio-setup',
        title: 'Radio setup',
        builder: (context, host, tools) => _SetupBody(host: host, tools: tools, communitySource: communitySource),
      );
}

enum _Choice { region, community, custom }

class _SetupBody extends StatefulWidget {
  final ToolsHost host;
  final RadioTools tools;
  final CommunityPresetSource? communitySource;
  const _SetupBody({required this.host, required this.tools, this.communitySource});
  @override
  State<_SetupBody> createState() => _SetupBodyState();
}

class _SetupBodyState extends State<_SetupBody> {
  static final double _txMin = RadioParamLimits.txDbmMin.toDouble();
  RadioSetupTool get setup => widget.tools.setup;

  final _name = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _freq = TextEditingController();
  final _bw = TextEditingController();
  int _sf = 7, _cr = 5;
  int _tx = 0;
  bool _loading = true;
  bool _readFailed = false;
  bool _busy = false;
  SetupResult? _last;
  String? _lastSection;
  bool _drivingOk = false;
  _Choice _choice = _Choice.region;
  CommunityPreset? _community;
  List<CommunityPreset>? _communityList;
  bool _communityLoading = false;
  String? _communityError;
  late final CommunityPresetSource _source = widget.communitySource ?? HttpCommunityPresetSource();

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void dispose() {
    for (final c in [_name, _lat, _lon, _freq, _bw]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _read() async {
    setState(() {
      _loading = true;
      _readFailed = false;
    });
    final c = await setup.read();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _readFailed = c == null;
      if (c != null) _fill(c);
    });
  }

  void _fill(RadioConfig c) {
    _name.text = c.name;
    _lat.text = c.lat?.toStringAsFixed(5) ?? '';
    _lon.text = c.lon?.toStringAsFixed(5) ?? '';
    _tx = c.txDbm;
    _freq.text = c.params.freqMhz.toStringAsFixed(3);
    _bw.text = c.params.bwKhz.toStringAsFixed(c.params.bwKhz % 1 == 0 ? 0 : 1);
    _sf = c.params.sf.clamp(5, 12);
    _cr = c.params.cr.clamp(5, 8);
  }

  Future<void> _run(String section, Future<SetupResult> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final r = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _last = r;
      _lastSection = section;
      final c = setup.config;
      if (c != null) _fill(c);
    });
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(key: Key('setup-loading')));
    }
    final c = setup.config;
    if (_readFailed || c == null) {
      return ListView(padding: const EdgeInsets.all(Gap.l), children: [
        const NoteCard('The radio did not report its settings. Check the Bluetooth link and try again. Nothing was changed.',
            kind: NoteKind.problem, title: 'Could not read the radio'),
        const SizedBox(height: Gap.m),
        FilledButton.icon(
          key: const Key('setup-retry'),
          style: FilledButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
          onPressed: _read,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ]);
    }
    return ToolListener(
      sources: [setup.changed],
      builder: (context) => RefreshIndicator(
        onRefresh: _read,
        child: ListView(
          key: const Key('setup-list'),
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
          children: [
            Text(
              'Changes are written to your radio and kept on it. After each one MeshSonar reads the radio back to check, and you can undo the last change. Nothing here happens by itself.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: Gap.m),
            _nameCard(c),
            _positionCard(c),
            _behaviourCard(c),
            _airwavesCard(c),
          ],
        ),
      ),
    );
  }

  Widget _resultCard() => Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        child: NoteCard(
          _last!.message,
          key: const Key('setup-result'),
          kind: _last!.ok ? NoteKind.good : NoteKind.problem,
          title: _last!.ok ? 'Done' : 'Not changed as asked',
        ),
      );

  Widget _undoRow() => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: OutlinedButton.icon(
          key: const Key('setup-undo'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
          onPressed: _busy ? null : () => _run(_lastSection ?? 'name', setup.undo),
          icon: const Icon(Icons.undo),
          label: Text('Undo: ${setup.undoLabel}'),
        ),
      );

  Widget _card(String id, String title, List<Widget> children, {String? subtitle}) {
    final t = Theme.of(context);
    return Card(
      key: Key('setup-$id'),
      margin: const EdgeInsets.only(bottom: Gap.m),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(container: true, header: true, child: Text(title, style: t.textTheme.titleMedium)),
          if (subtitle != null) ...[
            const SizedBox(height: Gap.xs),
            Text(subtitle, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: Gap.m),
          ...children,
          if (_lastSection == id && _last != null) ...[const SizedBox(height: Gap.m), _resultCard(), if (_last!.ok && setup.canUndo) _undoRow()],
        ]),
      ),
    );
  }

  ButtonStyle get _big => FilledButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget));

  // ------------------------------------------------------------ name

  Widget _nameCard(RadioConfig c) {
    final text = _name.text;
    final bytes = utf8.encode(text.trim()).length;
    final problem = text == c.name ? null : RadioSetupTool.nameProblem(text);
    final cut = RadioSetupTool.nameCutInAdvert(text) && c.advertSharesPosition;
    return _card('name', 'Name', [
      TextField(
        key: const Key('setup-name-field'),
        controller: _name,
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Radio name',
          helperText: '$bytes of $maxNodeNameBytes bytes',
          errorText: problem,
          helperMaxLines: 2,
          errorMaxLines: 3,
        ),
      ),
      if (cut)
        const Padding(
          padding: EdgeInsets.only(top: Gap.s),
          child: NoteCard('Adverts that carry a position cut a name longer than $maxAdvertNameBytesWithPosition bytes.', kind: NoteKind.caution),
        ),
      const SizedBox(height: Gap.m),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton(
          key: const Key('setup-name-save'),
          style: _big,
          onPressed: _busy || text.trim() == c.name || RadioSetupTool.nameProblem(text) != null ? null : () => _run('name', () => setup.setName(text)),
          child: const Text('Save name'),
        ),
      ),
    ], subtitle: 'Shown to others in adverts and as the sender of your chat messages.');
  }

  // ------------------------------------------------------------ position

  double? _num(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  Future<void> _usePhone() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('setup-phone-location-confirm'),
        title: const Text('Use your phone’s location?'),
        content: const Text(
            'Your phone’s position is copied into the boxes below. It only goes to the radio when you press Save position. Once saved, adverts can carry it, and everyone who hears an advert sees where it was set.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(key: const Key('setup-phone-location-ok'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Use my location')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final p = await widget.host.phonePosition();
    if (!mounted) return;
    if (p == null) {
      setState(() {
        _last = const SetupResult(false, 'Your phone did not give a position. Allow location for MeshSonar in Settings, or type the position in.');
        _lastSection = 'position';
      });
      return;
    }
    setState(() {
      _lat.text = p.lat.toStringAsFixed(5);
      _lon.text = p.lon.toStringAsFixed(5);
    });
  }

  Widget _positionCard(RadioConfig c) {
    final lat = _num(_lat.text), lon = _num(_lon.text);
    final edited = c.lat == null ? (_lat.text.isNotEmpty || _lon.text.isNotEmpty) : (lat != c.lat || lon != c.lon);
    final problem = _lat.text.isEmpty && _lon.text.isEmpty ? null : RadioSetupTool.positionProblem(lat, lon);
    return _card('position', 'Position', [
      Text(
        c.lat == null ? 'No position is stored on this radio.' : 'Stored on the radio: ${c.lat!.toStringAsFixed(5)}, ${c.lon!.toStringAsFixed(5)}',
        key: const Key('setup-position-current'),
      ),
      const SizedBox(height: Gap.s),
      OutlinedButton.icon(
        key: const Key('setup-position-phone'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
        onPressed: _busy ? null : _usePhone,
        icon: const Icon(Icons.my_location),
        label: const Text('Use my phone’s location'),
      ),
      const SizedBox(height: Gap.m),
      Wrap(spacing: Gap.m, runSpacing: Gap.s, children: [
        SizedBox(
          width: 170,
          child: TextField(
            key: const Key('setup-lat-field'),
            controller: _lat,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: 'Latitude'),
          ),
        ),
        SizedBox(
          width: 170,
          child: TextField(
            key: const Key('setup-lon-field'),
            controller: _lon,
            onChanged: (_) => setState(() {}),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: 'Longitude'),
          ),
        ),
      ]),
      if (problem != null)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Text(problem, key: const Key('setup-position-problem'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      const SizedBox(height: Gap.m),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton(
          key: const Key('setup-position-save'),
          style: _big,
          onPressed: _busy || !edited || problem != null || lat == null || lon == null ? null : () => _run('position', () => setup.setPosition(lat, lon)),
          child: const Text('Save position'),
        ),
      ),
      const Divider(height: Gap.xl),
      SwitchListTile(
        key: const Key('setup-advert-position'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Include the position in adverts'),
        subtitle: Text(c.advertSharesPosition
            ? 'On: your adverts tell everyone who hears them where this radio is.'
            : 'Off: your adverts carry no position. The stored position stays on the radio.'),
        value: c.advertSharesPosition,
        onChanged: _busy ? null : (on) => _togglePositionPolicy(on),
      ),
    ], subtitle: 'Adverts are public. This is the position your radio announces, not your live location.');
  }

  Future<void> _togglePositionPolicy(bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('setup-advert-position-confirm'),
          title: const Text('Share this radio’s position in adverts?'),
          content: const Text('Every advert will carry the position stored on the radio. Anyone with a radio or a map site that hears it can see it. You can turn this off again.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(key: const Key('setup-advert-position-ok'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Share position')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _run('position', () => setup.setBehaviour(advertLocPolicy: on ? 1 : 0));
  }

  // ------------------------------------------------------------ behaviour

  Widget _behaviourCard(RadioConfig c) => _card('behaviour', 'Contacts and acknowledgements', [
        SwitchListTile(
          key: const Key('setup-manual-add'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Add new contacts myself'),
          subtitle: const Text('On: nodes that advertise are not added to the radio’s contact list until you add them (for example from Discover nearby). Off: the radio adds them by itself.'),
          value: c.manualAdd,
          onChanged: _busy ? null : (v) => _run('behaviour', () => setup.setBehaviour(manualAdd: v)),
        ),
        SwitchListTile(
          key: const Key('setup-multi-acks'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Extra acknowledgements'),
          subtitle: const Text('On: the radio sends a second acknowledgement for direct messages it receives, which helps on weak links and costs a little airtime.'),
          value: c.multiAcks != 0,
          onChanged: _busy ? null : (v) => _run('behaviour', () => setup.setBehaviour(multiAcks: v ? 1 : 0)),
        ),
      ]);

  // ------------------------------------------------------------ airwaves: TX power and LoRa parameters

  bool get _driveBlocks => widget.host.driveRecording && !_drivingOk;

  Widget _driveGuard() {
    if (!widget.host.driveRecording) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const NoteCard(
          'A drive is recording. Changing the frequency settings or the TX power now would split the survey into parts measured with different settings. Stop the drive first, or confirm below.',
          kind: NoteKind.caution,
          title: 'Drive in progress',
        ),
        const SizedBox(height: Gap.s),
        OutlinedButton.icon(
          key: const Key('setup-stop-drive'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
          onPressed: () async {
            await widget.host.stopDrive();
            if (mounted) setState(() {});
          },
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Stop the drive first'),
        ),
        CheckboxListTile(
          key: const Key('setup-drive-ok'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Change it anyway. This survey will contain two settings.'),
          value: _drivingOk,
          onChanged: (v) => setState(() => _drivingOk = v ?? false),
        ),
      ]),
    );
  }

  RadioParams? get _target {
    switch (_choice) {
      case _Choice.region:
        final p = widget.host.regionPreset;
        return p == null ? null : RadioParams.fromMhz(freqMhz: p.freqMhz, bwKhz: p.bwKhz, sf: p.sf, cr: p.cr);
      case _Choice.community:
        final p = _community;
        return p == null ? null : RadioParams.fromMhz(freqMhz: p.freqMhz, bwKhz: p.bwKhz, sf: p.sf, cr: p.cr);
      case _Choice.custom:
        final f = _num(_freq.text), b = _num(_bw.text);
        if (f == null || b == null) return null;
        return RadioParams.fromMhz(freqMhz: f, bwKhz: b, sf: _sf, cr: _cr);
    }
  }

  Future<void> _loadCommunity() async {
    setState(() {
      _communityLoading = true;
      _communityError = null;
    });
    try {
      final list = await _source.fetch();
      if (!mounted) return;
      setState(() {
        _communityList = list;
        _communityLoading = false;
        if (list.isEmpty) _communityError = 'The community list had no usable presets.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _communityLoading = false;
        _communityError = 'Could not load the community list. Check your connection and try again.';
      });
    }
  }

  Widget _airwavesCard(RadioConfig c) {
    final t = Theme.of(context);
    final host = widget.host;
    final preset = host.regionPreset;
    final now = Radio(freqMhz: c.params.freqMhz, bwKhz: c.params.bwKhz, sf: c.params.sf, cr: c.params.cr);
    final matches = preset != null ? compareRegionPreset(now, preset) : null;
    final target = _target;
    final problems = target?.problems() ?? const <String>[];
    final same = target != null && target.matches(c.params);
    final canApply = !_busy && target != null && problems.isEmpty && !same && !_driveBlocks;
    return _card('airwaves', 'The airwaves', [
      _driveGuard(),
      // ---- TX power
      Text('TX power', style: t.textTheme.titleSmall),
      const SizedBox(height: Gap.xs),
      Text('Now ${c.txDbm} dBm. This board’s hardware limit is ${c.maxTxDbm} dBm. Your local rules may allow less.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      Row(children: [
        Expanded(
          child: Slider(
            key: const Key('setup-tx-slider'),
            min: _txMin,
            max: c.maxTxDbm.toDouble().clamp(_txMin + 1, 40),
            divisions: (c.maxTxDbm.clamp(RadioParamLimits.txDbmMin + 1, 40) - RadioParamLimits.txDbmMin),
            value: _tx.toDouble().clamp(_txMin, c.maxTxDbm.toDouble().clamp(_txMin + 1, 40)),
            label: '$_tx dBm',
            semanticFormatterCallback: (v) => '${v.round()} dBm',
            onChanged: _busy ? null : (v) => setState(() => _tx = v.round()),
          ),
        ),
        SizedBox(width: 72, child: Text('$_tx dBm', key: const Key('setup-tx-value'), style: numberStyle(context, size: 18), textAlign: TextAlign.end)),
      ]),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton(
          key: const Key('setup-tx-save'),
          style: _big,
          onPressed: _busy || _tx == c.txDbm || _driveBlocks ? null : () => _run('airwaves', () => setup.setTxPower(_tx)),
          child: const Text('Save TX power'),
        ),
      ),
      const Divider(height: Gap.xl),
      // ---- LoRa parameters
      Text('Frequency settings', style: t.textTheme.titleSmall),
      const SizedBox(height: Gap.xs),
      Text(c.params.label, key: const Key('setup-params-current'), style: numberStyle(context, size: 18)),
      const SizedBox(height: Gap.s),
      if (preset == null)
        const Text('This region has no radio preset on file, so there is nothing to compare with.', key: Key('setup-preset-none'))
      else
        Row(key: const Key('setup-preset-status'), crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(matches!.allMatch ? Icons.check_circle_outline : Icons.error_outline, size: 20),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(
              matches.allMatch
                  ? 'Matches the ${host.regionName ?? 'region'} preset: ${preset.name}.'
                  : matches.anyDiffers
                      ? 'Differs from the ${host.regionName ?? 'region'} preset (${preset.name}) in: ${matches.differing.join(', ')}.'
                      : 'The radio did not report enough to compare with the ${host.regionName ?? 'region'} preset.',
            ),
          ),
        ]),
      const SizedBox(height: Gap.m),
      Text('Choose new settings', style: t.textTheme.titleSmall),
      Text('MeshSonar never applies a preset by itself. Pick one, check the comparison, then press Apply.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      RadioGroup<_Choice>(
        groupValue: _choice,
        onChanged: (v) => setState(() => _choice = v ?? _choice),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          RadioListTile<_Choice>(
            key: const Key('setup-choice-region'),
            contentPadding: EdgeInsets.zero,
            value: _Choice.region,
            enabled: preset != null,
            title: Text(preset == null ? 'The region’s preset' : '${host.regionName ?? 'Region'}: ${preset.name}'),
            subtitle: preset == null
                ? const Text('Not available for this region.')
                : Text(RadioParams.fromMhz(freqMhz: preset.freqMhz, bwKhz: preset.bwKhz, sf: preset.sf, cr: preset.cr).label),
          ),
          RadioListTile<_Choice>(
            key: const Key('setup-choice-community'),
            contentPadding: EdgeInsets.zero,
            value: _Choice.community,
            title: const Text('A community preset'),
            subtitle: const Text('The MeshCore community list (api.meshcore.nz), loaded only when you ask.'),
          ),
          RadioListTile<_Choice>(
            key: const Key('setup-choice-custom'),
            contentPadding: EdgeInsets.zero,
            value: _Choice.custom,
            title: const Text('Enter the values by hand'),
            subtitle: const Text('For experts. A wrong value means your radio cannot hear the radios around it.'),
          ),
        ]),
      ),
      if (_choice == _Choice.community) _communityPicker(),
      if (_choice == _Choice.custom) _customFields(),
      if (target != null && problems.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.m),
          child: ComparisonTable(
            key: const Key('setup-compare'),
            comparison: comparePreset(now, freqMhz: target.freqMhz, bwKhz: target.bwKhz, sf: target.sf, cr: target.cr),
            hasRadio: true,
          ),
        ),
      for (final p in problems)
        Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text(p, key: const Key('setup-params-problem'), style: TextStyle(color: t.colorScheme.error))),
      if (same)
        const Padding(padding: EdgeInsets.only(top: Gap.s), child: Text('Your radio already uses these settings.', key: Key('setup-params-same'))),
      const SizedBox(height: Gap.m),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton.icon(
          key: const Key('setup-apply'),
          style: FilledButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget), backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError),
          onPressed: canApply ? () => _confirmApply(c, target) : null,
          icon: const Icon(Icons.settings_input_antenna),
          label: const Text('Apply radio parameters'),
        ),
      ),
    ], subtitle: 'Frequency, bandwidth, spreading factor and coding rate decide which radios can hear yours.');
  }

  Widget _communityPicker() {
    final list = _communityList;
    if (_communityLoading) {
      return const Padding(
        padding: EdgeInsets.only(top: Gap.s),
        child: Row(children: [SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: Gap.m), Text('Loading')]),
      );
    }
    if (list == null || list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: Gap.s),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_communityError != null) Padding(padding: const EdgeInsets.only(bottom: Gap.s), child: Text(_communityError!, key: const Key('setup-community-error'))),
          OutlinedButton.icon(
            key: const Key('setup-community-load'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
            onPressed: _loadCommunity,
            icon: const Icon(Icons.public),
            label: Text(_communityError == null ? 'Load the community list' : 'Try again'),
          ),
        ]),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: Gap.s),
      child: RadioGroup<CommunityPreset>(
        groupValue: _community,
        onChanged: (v) => setState(() => _community = v),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final p in list)
            RadioListTile<CommunityPreset>(
              key: Key('setup-community-${p.title}'),
              contentPadding: EdgeInsets.zero,
              value: p,
              title: Text(p.title),
              subtitle: Text(RadioParams.fromMhz(freqMhz: p.freqMhz, bwKhz: p.bwKhz, sf: p.sf, cr: p.cr).label),
            ),
        ]),
      ),
    );
  }

  Widget _customFields() => Padding(
        padding: const EdgeInsets.only(top: Gap.s),
        child: Wrap(spacing: Gap.m, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.end, children: [
          SizedBox(
            width: 150,
            child: TextField(
              key: const Key('setup-freq-field'),
              controller: _freq,
              onChanged: (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: const InputDecoration(labelText: 'Frequency (MHz)'),
            ),
          ),
          SizedBox(
            width: 150,
            child: TextField(
              key: const Key('setup-bw-field'),
              controller: _bw,
              onChanged: (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              decoration: const InputDecoration(labelText: 'Bandwidth (kHz)'),
            ),
          ),
          SizedBox(
            width: 130,
            child: DropdownButtonFormField<int>(
              key: const Key('setup-sf-field'),
              initialValue: _sf,
              decoration: const InputDecoration(labelText: 'Spreading factor'),
              items: [for (var i = 5; i <= 12; i++) DropdownMenuItem(value: i, child: Text('SF$i'))],
              onChanged: (v) => setState(() => _sf = v ?? _sf),
            ),
          ),
          SizedBox(
            width: 130,
            child: DropdownButtonFormField<int>(
              key: const Key('setup-cr-field'),
              initialValue: _cr,
              decoration: const InputDecoration(labelText: 'Coding rate'),
              items: [for (var i = 5; i <= 8; i++) DropdownMenuItem(value: i, child: Text('CR$i'))],
              onChanged: (v) => setState(() => _cr = v ?? _cr),
            ),
          ),
        ]),
      );

  Future<void> _confirmApply(RadioConfig c, RadioParams target) async {
    var understood = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          key: const Key('setup-confirm'),
          icon: Icon(Icons.warning_amber_rounded, color: Theme.of(ctx).colorScheme.error, size: 36),
          title: const Text('Change the airwaves your radio uses?'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('From:  ${c.params.label}', key: const Key('setup-confirm-from')),
              Text('To:  ${target.label}', key: const Key('setup-confirm-to'), style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: Gap.m),
              const Text('This takes effect immediately and changes which radios can hear yours.'),
              const SizedBox(height: Gap.s),
              const Text('Your radio will stop hearing, and being heard by, every radio and repeater that is not on the new settings.'),
              const SizedBox(height: Gap.s),
              const Text('It may disconnect you from other devices that use this radio, and from friends who are on the old settings.'),
              const SizedBox(height: Gap.s),
              const Text('MeshSonar will read the radio back to check, and you can undo it straight after.'),
              if (widget.host.driveRecording) ...[
                const SizedBox(height: Gap.s),
                const Text('A drive is recording: it will contain both settings.', style: TextStyle(fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: Gap.m),
              CheckboxListTile(
                key: const Key('setup-confirm-understood'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('I understand'),
                value: understood,
                onChanged: (v) => setD(() => understood = v ?? false),
              ),
            ]),
          ),
          actions: [
            TextButton(key: const Key('setup-confirm-cancel'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              key: const Key('setup-confirm-apply'),
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error, foregroundColor: Theme.of(ctx).colorScheme.onError),
              onPressed: understood ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Apply radio parameters'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await _run('airwaves', () => setup.applyRadioParams(target));
  }
}
