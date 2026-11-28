// MeshSonar radio > Firmware (brief C.6): the running version, board and slot; "Check for update" and the offer (version,
// size, notes, channel, whether it may be installed); "Install over Wi-Fi" (the radio downloads it itself); "Send a firmware
// file" (a `.bin` from Files to `POST /update`); the Beta channel and Daily check switches; Restart after a confirm. While the
// radio is busy its own state text and progress show, polled every 2 s while this screen is open and the app is in front.
import 'package:flutter/material.dart';

import '../../core/msradio/msradio.dart';
import '../../platform/file_pick.dart';
import 'ms_b_common.dart';

class MsBFirmwareScreen extends StatefulWidget {
  final MsRadioController c;
  final FilePick pick;
  const MsBFirmwareScreen({super.key, required this.c, this.pick = const DeviceFilePick()});
  @override
  State<MsBFirmwareScreen> createState() => _MsBFirmwareScreenState();
}

class _MsBFirmwareScreenState extends State<MsBFirmwareScreen> {
  MsOta? _ota;
  String? _error, _note;
  bool _loading = true, _acting = false;

  bool _sending = false;
  int _sent = 0, _total = 0;

  /// Keep polling a little after an action even while the radio still reads idle (a check takes a moment to start).
  int _graceTicks = 0;
  late final MsBPoller _poll = MsBPoller(tick: _load, want: () => mounted && (_busy || _graceTicks > 0));

  MsRadioApi? get _api => widget.c.api;

  /// Poll while the radio works or the new firmware waits to be kept.
  bool get _busy => _working || (_ota?.pendingVerify ?? false);

  /// The radio is checking, downloading, receiving or restarting.
  bool get _working {
    final o = _ota;
    if (o == null) return false;
    return o.busy || switch (o.state) { MsOtaState.checking || MsOtaState.downloading || MsOtaState.receiving || MsOtaState.rebooting => true, _ => false };
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = _api;
    if (api == null) return;
    if (_graceTicks > 0) _graceTicks--;
    MsOta? o;
    final err = await msBTry(() async => o = await api.ota());
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (o != null) _ota = o;
      if (err != null) _error = err;
    });
    _poll.kick();
  }

  Future<void> _act(Future<Object?> Function(MsRadioApi api) job, {String? note, bool follow = true}) async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _acting = true;
      _error = null;
      _note = null;
    });
    final err = await msBTry(() => job(api));
    if (!mounted) return;
    setState(() {
      _acting = false;
      _error = err;
      if (err == null) _note = note;
      if (err == null && follow) _graceTicks = 3;
    });
    await _load();
  }

  Future<void> _restart() async {
    final ok = await msBConfirm(context,
        key: 'restart',
        title: 'Restart the radio?',
        body: 'The radio turns off and on again. Bluetooth and Wi-Fi drop for about half a minute and come back by themselves.',
        confirmLabel: 'Restart');
    if (!ok || !mounted) return;
    await _act((api) => api.otaRestart(), note: 'The radio is restarting.', follow: false);
  }

  Future<void> _sendFile() async {
    final api = _api;
    if (api == null) return;
    PickedFile? f;
    final pickErr = await msBTry(() async => f = await widget.pick.pickFile(extensions: const ['bin']));
    if (!mounted) return;
    if (pickErr != null) {
      setState(() => _error = pickErr);
      return;
    }
    final file = f;
    if (file == null) return;
    final ok = await msBConfirm(context,
        key: 'send-firmware',
        title: 'Send ${file.name}?',
        body: 'The radio checks that this file is MeshSonar firmware for its board, then restarts into it. If the new firmware '
            'does not run for a minute, the radio goes back to the version it has now.',
        confirmLabel: 'Send');
    if (!ok || !mounted) return;
    setState(() {
      _sending = true;
      _sent = 0;
      _total = file.size;
      _error = null;
      _note = null;
    });
    MsUploadResult? r;
    final err = await msBTry(() async => r = await api.uploadFirmware(file.upload, onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _sent = done;
            _total = total ?? file.size;
          });
        }));
    if (!mounted) return;
    setState(() {
      _sending = false;
      _error = err;
      if (err == null) _note = (r?.text.trim().isNotEmpty ?? false) ? r!.text.trim() : 'Sent. The radio restarts into the new firmware.';
      if (err == null) _graceTicks = 3;
    });
    _poll.kick();
  }

  String _stateWords(MsOta o) {
    if (o.stateText.trim().isNotEmpty) return o.stateText.trim();
    return switch (o.state) {
      MsOtaState.checking => 'Checking for an update',
      MsOtaState.downloading => 'Downloading the update',
      MsOtaState.receiving => 'Receiving the firmware file',
      MsOtaState.ready => 'Ready: restart the radio to use it',
      MsOtaState.rebooting => 'Restarting',
      MsOtaState.idle => 'Idle',
      MsOtaState.unknown => o.stateWord,
    };
  }

  List<Widget> _offer(BuildContext context, MsOta o) {
    final f = o.offer;
    if (f == null) {
      return [const MsBBlock(child: NoteCard('No check yet. Tap Check for update to ask the update server.', key: Key('msb-fw-no-offer')))];
    }
    final t = Theme.of(context);
    final busy = _working || _acting || _sending;
    final canInstall = f.newer && f.allowed && !busy;
    return [
      InsetGroup(
        header: f.newer ? 'Update available' : 'Newest version',
        groupKey: const Key('msb-fw-offer'),
        footer: f.checkedSAgo == null ? null : 'Checked ${_ago(f.checkedSAgo!)}.',
        rows: [
          InsetRow(title: 'Version', value: '${f.version ?? 'unknown'}${f.build == null ? '' : ' (build ${f.build})'}', chevron: false),
          InsetRow(title: 'Size', value: msBBytes(f.size), chevron: false),
          InsetRow(title: 'Channel', value: f.channel == null ? 'unknown' : (f.channel == 'beta' ? 'Beta' : 'Stable'), chevron: false),
          if (f.minVersion != null) InsetRow(title: 'Needs at least', value: f.minVersion, chevron: false),
          if (f.notes != null && f.notes!.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('What is new', style: t.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(f.notes!.trim(), key: const Key('msb-fw-notes'), style: t.textTheme.bodyMedium),
              ]),
            ),
        ],
      ),
      if (!f.newer) const MsBBlock(child: NoteCard('This radio already runs the newest version on this channel.', key: Key('msb-fw-current'), kind: NoteKind.good)),
      if (f.newer && !f.allowed)
        MsBBlock(
          child: NoteCard(
            'This update cannot be installed over Wi-Fi on this radio${f.minVersion == null ? '' : ': it needs version ${f.minVersion} or newer first'}.',
            key: const Key('msb-fw-not-allowed'),
            kind: NoteKind.problem,
          ),
        ),
      if (f.newer)
        MsBButtons([
          FilledButton.icon(
            key: const Key('msb-fw-install'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: canInstall ? () => _act((api) => api.otaInstall(), note: 'The radio is downloading the update. It asks on its screen to restart when it is ready.') : null,
            icon: const Icon(Icons.system_update),
            label: const Text('Install over Wi-Fi'),
          ),
        ]),
    ];
  }

  static String _ago(int s) {
    if (s < 60) return '$s s ago';
    if (s < 3600) return '${s ~/ 60} min ago';
    if (s < 86400) return '${s ~/ 3600} h ago';
    return '${s ~/ 86400} days ago';
  }

  List<Widget> _rows(BuildContext context) {
    final o = _ota;
    if (_loading && o == null) return [const MsBBlock(child: Center(child: CircularProgressIndicator()))];
    final busy = _working || _acting || _sending;
    return [
      MsBError(_error),
      if (_note != null) MsBBlock(child: NoteCard(_note!, key: const Key('msb-fw-note'))),
      if (o != null) ...[
        InsetGroup(header: 'Running now', groupKey: const Key('msb-fw-running'), rows: [
          InsetRow(title: 'Version', value: o.fw ?? 'unknown', chevron: false),
          InsetRow(title: 'Board', value: o.board ?? 'unknown', chevron: false),
          InsetRow(title: 'Slot', value: o.slot ?? 'unknown', chevron: false),
          if (o.lastResult.trim().isNotEmpty) InsetRow(key: const Key('msb-fw-last'), title: 'Last result', subtitle: o.lastResult.trim(), chevron: false),
        ]),
        if (o.pendingVerify)
          MsBBlock(
            child: NoteCard(
              'The new firmware is kept after 1 minute of running${o.validInS > 0 ? ' (${o.validInS} s to go)' : ''}. If it stops before then, the radio goes back to the version it had.',
              key: const Key('msb-fw-pending'),
            ),
          ),
        if (_sending)
          MsBProgress('Sending the firmware file: ${msBBytes(_sent)} of ${msBBytes(_total)}', key: const Key('msb-fw-sending'), value: _total <= 0 ? null : _sent / _total)
        else if (o.busy || o.state == MsOtaState.checking || o.state == MsOtaState.downloading || o.state == MsOtaState.receiving)
          MsBProgress(
            '${_stateWords(o)}${o.progress > 0 ? ': ${o.progress}%' : ''}',
            key: const Key('msb-fw-busy'),
            value: o.progress > 0 ? msBPct(o.progress) : null,
          )
        else if (o.state != MsOtaState.idle)
          MsBBlock(child: NoteCard(_stateWords(o), key: const Key('msb-fw-state'))),
        MsBButtons([
          FilledButton.tonalIcon(
            key: const Key('msb-fw-check'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: busy ? null : () => _act((api) => api.otaCheck()),
            icon: const Icon(Icons.refresh),
            label: const Text('Check for update'),
          ),
        ]),
        ..._offer(context, o),
        InsetGroup(header: 'Updates', rows: [
          MsBSwitchRow(
            switchKey: const Key('msb-fw-beta'),
            title: 'Beta channel',
            subtitle: 'Newer firmware, tested less.',
            value: o.beta,
            onChanged: _acting ? null : (v) => _act((api) => api.otaChannel(beta: v), follow: false),
          ),
          MsBSwitchRow(
            switchKey: const Key('msb-fw-auto'),
            title: 'Daily check',
            subtitle: 'The radio looks for an update once a day and tells you on its screen.',
            value: o.autoCheck,
            onChanged: _acting ? null : (v) => _act((api) => api.otaAuto(on: v), follow: false),
          ),
        ]),
        MsBButtons([
          OutlinedButton.icon(
            key: const Key('msb-fw-send'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: busy ? null : _sendFile,
            icon: const Icon(Icons.upload_file),
            label: const Text('Send a firmware file'),
          ),
          OutlinedButton.icon(
            key: const Key('msb-fw-restart'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _acting ? null : _restart,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Restart'),
          ),
        ]),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) => MsBPage(c: widget.c, id: 'firmware', title: 'Firmware', onRefresh: _load, builder: _rows);
}
