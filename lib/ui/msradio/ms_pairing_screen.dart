// Build 78 (builder A), brief C.1: Pairing. What it is for, "Pair over Wi-Fi" (signed: one tap when the radio is on the same
// Wi-Fi as the phone), "Ask on the radio" (the person taps Allow on the radio), "Enter address", "Forget this radio"
// (unpair + delete the token). Shows the radio's name, key prefix, address and host.
//
// [MsPairingSheet] runs one pairing and shows the flow's progress step by step and every way it can end, in plain words
// (wrongRadio: "This is not the radio you are connected to").
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';

import '../../core/msradio/msradio.dart';
import '../design/app_surfaces.dart';
import '../design/tokens.dart';
import '../radio/inset_list.dart';
import 'ms_common.dart';

class MsPairingScreen extends StatefulWidget {
  final MsRadioController c;
  const MsPairingScreen(this.c, {super.key});

  @override
  State<MsPairingScreen> createState() => _MsPairingScreenState();
}

class _MsPairingScreenState extends State<MsPairingScreen> {
  bool _busy = false;

  MsRadioController get c => widget.c;

  @override
  void initState() {
    super.initState();
    if (c.state.step == MsLinkStep.idle) unawaited(c.connect());
  }

  Future<void> _pair({required bool approval}) async {
    await showMsPairingSheet(context, c, approval: approval);
    if (mounted) setState(() {});
  }

  Future<void> _enterAddress() async {
    final address = await showAppSheet<String>(
      context,
      detents: const [0.6, 0.92],
      builder: (ctx, sc) => _AddressSheet(controller: sc, initial: c.state.address),
    );
    if (address == null || address.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    final st = await c.useAddress(address.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (st.step == MsLinkStep.notOnWifi) {
      showAppToast(context, 'Nothing answered at $address.', kind: AppToastKind.error);
    } else if (st.step == MsLinkStep.wrongRadio) {
      showAppToast(context, 'This is not the radio you are connected to.', kind: AppToastKind.error);
    }
  }

  Future<void> _forget() async {
    final ok = await showAppAlert(
      context,
      title: 'Forget this radio?',
      message: 'This app stops controlling the radio over Wi-Fi until you pair again. Bluetooth is not affected.',
      confirmLabel: 'Forget',
      destructive: true,
      confirmKey: const Key('ms-forget-confirm'),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await c.forget();
    if (!mounted) return;
    setState(() => _busy = false);
    showAppToast(context, 'This radio is forgotten. Pair again to use its Wi-Fi features.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('ms-pairing-screen'),
      appBar: AppBar(title: const Text('Pairing')),
      body: StreamBuilder<MsLinkState>(
        stream: c.states,
        initialData: c.state,
        builder: (context, _) {
          final st = c.state;
          final info = st.info;
          final looking = st.step == MsLinkStep.idle || st.step == MsLinkStep.finding;
          return MsBody(listKey: const Key('ms-pairing-list'), children: [
            const MsNote('Pairing lets this app control the radio\'s Wi-Fi side: sharing and wardrive, its log, map packs, '
                'firmware updates and more. The app and the radio prove to each other that the radio on Wi-Fi is the one '
                'connected over Bluetooth. Nothing about the Bluetooth link changes.'),
            InsetGroup(header: 'This radio', rows: [
              InsetRow(title: 'State', value: st.chip, chevron: false),
              InsetRow(title: 'Name', value: (info?.name?.isNotEmpty ?? false) ? info!.name! : '—', chevron: false),
              InsetRow(title: 'Key', value: msKeyPrefix(c.radioKey), chevron: false),
              InsetRow(title: 'Address', value: info?.ip ?? st.address ?? '—', chevron: false),
              InsetRow(title: 'Host', value: info?.host ?? 'meshsonar-${c.radioKey.substring(0, 8)}.local', chevron: false),
            ]),
            if (st.step == MsLinkStep.notOnWifi || st.step == MsLinkStep.wrongRadio) MsNotReady(c),
            if (st.paired)
              const MsNote('Paired. This app can use the radio\'s Wi-Fi features.')
            else if (looking)
              const Padding(padding: EdgeInsets.only(bottom: Gap.l), child: Center(child: CupertinoActivityIndicator())),
            MsButton(st.paired ? 'Pair again over Wi-Fi' : 'Pair over Wi-Fi',
                key: const Key('ms-pair-signed'),
                icon: Icons.wifi_rounded,
                primary: !st.paired,
                busy: _busy,
                onPressed: looking ? null : () => _pair(approval: false)),
            const MsNote('One tap, nothing to press on the radio. The radio and this phone need the same Wi-Fi, and the '
                'radio must be connected over Bluetooth.'),
            MsButton('Ask on the radio',
                key: const Key('ms-pair-ask'), icon: Icons.touch_app_outlined, busy: _busy, onPressed: looking ? null : () => _pair(approval: true)),
            const MsNote('Works without Bluetooth: the radio asks on its screen, and you tap Allow there.'),
            MsButton('Enter address', key: const Key('ms-enter-address'), icon: Icons.edit_outlined, busy: _busy, onPressed: _enterAddress),
            const MsNote('If the phone cannot find the radio, type the address shown on the radio\'s Wi-Fi screen.'),
            if (st.paired || st.step == MsLinkStep.notPaired)
              MsButton('Forget this radio',
                  key: const Key('ms-forget'), icon: Icons.link_off_rounded, destructive: true, busy: _busy, onPressed: _forget),
          ]);
        },
      ),
    );
  }
}

class _AddressSheet extends StatefulWidget {
  final ScrollController controller;
  final String? initial;
  const _AddressSheet({required this.controller, this.initial});

  @override
  State<_AddressSheet> createState() => _AddressSheetState();
}

class _AddressSheetState extends State<_AddressSheet> {
  late final _text = TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() => Navigator.of(context).pop(_text.text.trim());

  @override
  Widget build(BuildContext context) => AppSheetScaffold(
        controller: widget.controller,
        title: 'Radio address',
        primaryAction: FilledButton(
          key: const Key('ms-address-use'),
          style: FilledButton.styleFrom(minimumSize: Size.fromHeight(Hit.of(context))),
          onPressed: _done,
          child: const Text('Use this address'),
        ),
        children: [
          const Text('The radio shows its address on its Wi-Fi screen, for example 192.168.1.77 or meshsonar-a1b2c3d4.local. '
              'The app checks that it is the radio you are connected to before using it.'),
          const SizedBox(height: Gap.m),
          TextField(
            key: const Key('ms-address-field'),
            controller: _text,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Address', border: OutlineInputBorder()),
            onSubmitted: (_) => _done(),
          ),
        ],
      );
}

// ------------------------------------------------------------------------------------------------ the pairing sheet
/// Runs one pairing ([approval]: "Ask on the radio"; else signed) in a sheet; returns the end state.
Future<MsPairState?> showMsPairingSheet(BuildContext context, MsRadioController c, {required bool approval}) => showAppSheet<MsPairState>(
      context,
      detents: const [0.7, 0.92],
      builder: (ctx, sc) => MsPairingSheet(c: c, approval: approval, controller: sc),
    );

/// The steps the sheet lists, in order.
List<(String, Set<MsPairStep>)> msPairSteps({required bool approval}) => approval
    ? const [
        ('Finding the radio on Wi-Fi', {MsPairStep.idle, MsPairStep.finding}),
        ('Asking the radio', {MsPairStep.asking}),
        ('Waiting for Allow on the radio', {MsPairStep.waiting}),
      ]
    : const [
        ('Finding the radio on Wi-Fi', {MsPairStep.idle, MsPairStep.finding}),
        ('Starting', {MsPairStep.starting}),
        ('Checking it is the radio you are connected to', {MsPairStep.verifyingRadio}),
        ('Signing over Bluetooth', {MsPairStep.signing}),
        ('Finishing', {MsPairStep.finishing}),
      ];

/// The headline of an end state, in plain words.
String msPairEndTitle(MsPairStep s) => switch (s) {
      MsPairStep.paired => 'Paired',
      MsPairStep.wrongRadio => 'This is not the radio you are connected to',
      MsPairStep.signFailed => 'The radio could not sign over Bluetooth',
      MsPairStep.expired => 'That took too long',
      MsPairStep.refused => 'The radio refused',
      MsPairStep.rateLimited => 'Too many tries',
      MsPairStep.notOnWifi => 'Not on Wi-Fi',
      MsPairStep.locked => 'The radio is locked',
      MsPairStep.cancelled => 'Pairing stopped',
      _ => 'Pairing did not work',
    };

String _endDefault(MsPairStep s) => switch (s) {
      MsPairStep.paired => 'This app can now control the radio over Wi-Fi.',
      MsPairStep.wrongRadio => 'The radio on Wi-Fi is a different radio. Nothing was signed or sent to it.',
      MsPairStep.signFailed => 'Make sure the radio is connected over Bluetooth, or use Ask on the radio.',
      MsPairStep.expired => 'Try again.',
      MsPairStep.refused => 'Try again, or use Ask on the radio.',
      MsPairStep.rateLimited => 'Wait a minute and try again.',
      MsPairStep.notOnWifi => 'This phone cannot reach the radio over Wi-Fi. Check that both are on the same network.',
      MsPairStep.locked => 'Unlock the radio and try again.',
      MsPairStep.cancelled => 'Nothing was changed.',
      _ => 'Try again.',
    };

class MsPairingSheet extends StatefulWidget {
  final MsRadioController c;
  final bool approval;
  final ScrollController controller;
  const MsPairingSheet({super.key, required this.c, required this.approval, required this.controller});

  @override
  State<MsPairingSheet> createState() => _MsPairingSheetState();
}

class _MsPairingSheetState extends State<MsPairingSheet> {
  MsPairingFlow? _flow;
  StreamSubscription<MsPairState>? _sub;
  MsPairState _state = const MsPairState(MsPairStep.idle);

  /// The furthest step reached (so a finished flow still shows which steps passed).
  int _reached = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final c = widget.c;
    final run = widget.approval ? c.pairByApproval() : c.pairSigned();
    // the controller makes the flow synchronously when the call starts
    final f = _flow = c.pairing;
    _sub?.cancel();
    _reached = 0;
    _state = f?.state ?? const MsPairState(MsPairStep.finding);
    _note(_state);
    _sub = f?.states.listen((s) {
      if (!mounted) return;
      setState(() {
        _state = s;
        _note(s);
      });
    });
    unawaited(run.then((r) {
      if (!mounted) return;
      setState(() {
        _state = r;
        _note(r);
      });
    }));
  }

  void _note(MsPairState s) {
    final steps = msPairSteps(approval: widget.approval);
    for (var i = 0; i < steps.length; i++) {
      if (steps[i].$2.contains(s.step) && i > _reached) _reached = i;
    }
    if (s.paired) _reached = steps.length;
  }

  @override
  void dispose() {
    if (!_state.finished) _flow?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = _state;
    final steps = msPairSteps(approval: widget.approval);
    final done = s.finished;
    final ok = s.paired;
    return AppSheetScaffold(
      key: const Key('ms-pairing-sheet'),
      controller: widget.controller,
      title: widget.approval ? 'Ask on the radio' : 'Pair over Wi-Fi',
      primaryAction: done
          ? FilledButton(
              key: const Key('ms-pairing-done'),
              style: FilledButton.styleFrom(minimumSize: Size.fromHeight(Hit.of(context))),
              onPressed: () => Navigator.of(context).pop(s),
              child: Text(ok ? 'Done' : 'Close'),
            )
          : OutlinedButton(
              key: const Key('ms-pairing-cancel'),
              style: OutlinedButton.styleFrom(minimumSize: Size.fromHeight(Hit.of(context))),
              onPressed: () => _flow?.cancel(),
              child: const Text('Cancel'),
            ),
      secondaryAction: done && !ok && s.step != MsPairStep.wrongRadio
          ? Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: OutlinedButton(
                key: const Key('ms-pairing-retry'),
                style: OutlinedButton.styleFrom(minimumSize: Size.fromHeight(Hit.of(context))),
                onPressed: () => setState(_start),
                child: const Text('Try again'),
              ),
            )
          : null,
      children: [
        for (var i = 0; i < steps.length; i++)
          _StepLine(
            key: Key('ms-pair-step-$i'),
            text: steps[i].$1,
            state: i < _reached || ok
                ? _StepState.done
                : i == _reached
                    ? (done ? _StepState.failed : _StepState.running)
                    : _StepState.waiting,
          ),
        if (!done && s.step == MsPairStep.waiting)
          Padding(
            padding: const EdgeInsets.only(top: Gap.s),
            child: Text('The radio shows "Allow ${widget.c.appName} … to control this radio over Wi-Fi?". Tap Allow on the radio.',
                style: t.textTheme.bodyMedium),
          ),
        if (done) ...[
          const SizedBox(height: Gap.l),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded, color: ok ? t.colorScheme.primary : t.colorScheme.error),
            const SizedBox(width: Gap.s),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(msPairEndTitle(s.step), key: const Key('ms-pair-end-title'), style: t.textTheme.titleMedium),
                const SizedBox(height: Gap.xs),
                Text(
                  s.message.isEmpty || s.message.replaceAll('.', '') == msPairEndTitle(s.step) ? _endDefault(s.step) : s.message,
                  key: const Key('ms-pair-end-text'),
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ]),
            ),
          ]),
        ],
        const SizedBox(height: Gap.l),
      ],
    );
  }
}

enum _StepState { waiting, running, done, failed }

class _StepLine extends StatelessWidget {
  final String text;
  final _StepState state;
  const _StepLine({super.key, required this.text, required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final lead = switch (state) {
      _StepState.waiting => Icon(Icons.radio_button_unchecked, size: 20, color: c.outline),
      _StepState.running => const SizedBox(width: 20, height: 20, child: CupertinoActivityIndicator()),
      _StepState.done => Icon(Icons.check_circle, size: 20, color: c.primary),
      _StepState.failed => Icon(Icons.cancel, size: 20, color: c.error),
    };
    final word = switch (state) {
      _StepState.waiting => 'not started',
      _StepState.running => 'in progress',
      _StepState.done => 'done',
      _StepState.failed => 'stopped here',
    };
    return Semantics(
      label: '$text, $word',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs + 2),
        child: Row(children: [
          lead,
          const SizedBox(width: Gap.m),
          Expanded(
            child: Text(text,
                style: t.textTheme.bodyLarge?.copyWith(color: state == _StepState.waiting ? c.onSurfaceVariant : c.onSurface)),
          ),
        ]),
      ),
    );
  }
}
