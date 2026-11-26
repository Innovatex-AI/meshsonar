// Device settings (chat plan 4.14, WP12): one grouped inset list for everything about the connected radio.
//
//  * Every row either works or is not shown. A row the radio's firmware cannot do is HIDDEN and listed with its reason under
//    "Not available on this radio" (ERR 1 / DISABLED answers add to that list at run time).
//  * Every write goes through DeviceSettingsTool: validate, write, read back from the radio, then "Saved" with Undo, or the
//    mismatch in plain words. Nothing is written without a person pressing a button.
//  * Reboot, restore-with-identity and factory reset are blocked while a drive is recording, and factory reset and identity
//    replacement need a typed word (checked again inside the tool).
//  * Entry: top of the Radio screen whenever a radio is connected.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../radio/protocol.dart' show TelemetryModes;
import '../../radio/tools/device_settings.dart';
import '../../radio/tools/radio_tools.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_widgets.dart';
import '../design/tokens.dart';
import '../radios/radio_setup/radio_setup_screen.dart';
import '../tools/adverts_screen.dart';
import '../tools/discover_screen.dart';
import '../tools/noise_screen.dart';
import '../tools/rx_log_screen.dart';
import '../tools/telemetry_screen.dart';
import '../tools/tool_kit.dart';
import '../tools/tools_host.dart';
import '../tools/trace_screen.dart';
import 'device_console_screen.dart';
import 'device_settings_sheets.dart';
import 'inset_list.dart';

final Uri flasherUrl = Uri.parse('https://flasher.meshcore.io');

Future<void> _defaultShare(Uint8List bytes, String name) async {
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}${Platform.pathSeparator}$name');
  await f.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/json')], subject: 'MeshSonar radio backup'));
  // The file is encrypted, but it is still the key to a radio: do not leave it in the temp folder.
  try {
    await f.delete();
  } catch (_) {}
}

Future<String?> _defaultPaste() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;
Future<void> _defaultCopy(String s) async {
  await Clipboard.setData(ClipboardData(text: s));
}

class DeviceSettingsScreen extends StatelessWidget {
  /// Test seams: where an exported backup goes, where an imported one comes from.
  final Future<void> Function(Uint8List bytes, String name)? shareFile;
  final Future<String?> Function()? pasteText;
  final Future<void> Function(String text)? copyText;
  const DeviceSettingsScreen({super.key, this.shareFile, this.pasteText, this.copyText});

  @override
  Widget build(BuildContext context) => ToolPage(
        id: 'device-settings',
        title: 'Device settings',
        builder: (context, host, tools) => _Body(host: host, tools: tools, shareFile: shareFile ?? _defaultShare, pasteText: pasteText ?? _defaultPaste, copyText: copyText ?? _defaultCopy),
      );
}

class _Body extends StatefulWidget {
  final ToolsHost host;
  final RadioTools tools;
  final Future<void> Function(Uint8List, String) shareFile;
  final Future<String?> Function() pasteText;
  final Future<void> Function(String) copyText;
  const _Body({required this.host, required this.tools, required this.shareFile, required this.pasteText, required this.copyText});
  @override
  State<_Body> createState() => _BodyState();
}

/// How often the open Device settings screen re-reads the radio's battery (in front only).
const Duration batteryReadEvery = Duration(seconds: 60);

class _BodyState extends State<_Body> with WidgetsBindingObserver {
  DeviceSettingsTool get d => widget.tools.device;
  StreamSubscription<void>? _sub;
  Timer? _battery;
  bool _loading = true;
  bool _failed = false;
  int? _contactCount;

  @override
  void initState() {
    super.initState();
    _sub = d.changed.listen((_) {
      if (mounted) setState(() {});
    });
    _load();
    WidgetsBinding.instance.addObserver(this);
    _startBatteryTimer();
  }

  /// The battery line refreshes every 60 s while the screen is open and the app is in front; the timer stops in the
  /// background (battery plan A13) and restarts, with one read, on return.
  void _startBatteryTimer() {
    _battery?.cancel();
    _battery = Timer.periodic(batteryReadEvery, (_) => _readBattery());
  }

  void _readBattery() {
    if (d.available(DeviceFeature.battery) && !widget.host.driveRecording && !d.busy) d.refreshBattery();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_battery == null) {
        _readBattery();
        _startBatteryTimer();
      }
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      _battery?.cancel();
      _battery = null;
    }
  }

  /// True while the 60 s battery read is scheduled (tests).
  @visibleForTesting
  bool get batteryTimerRunning => _battery != null;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _battery?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final s = await d.read();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = s == null;
    });
    if (s != null) {
      final n = await d.contactCount();
      if (mounted) setState(() => _contactCount = n);
    }
  }

  // ------------------------------------------------------------ helpers

  void _toast(DeviceResult r) {
    if (!mounted) return;
    showAppToast(
      context,
      r.message,
      kind: r.ok ? AppToastKind.success : AppToastKind.error,
      actionLabel: r.ok && d.canUndo ? 'Undo' : null,
      onAction: r.ok && d.canUndo
          ? () async {
              final u = await d.undo();
              _toast(u);
            }
          : null,
    );
  }

  bool _driveBlocks(String what) {
    if (!widget.host.driveRecording) return false;
    showAppToast(context, 'A drive is recording. Stop it before $what, so the survey keeps one radio setup.', kind: AppToastKind.error);
    return true;
  }

  Future<void> _write(Future<DeviceResult> Function() w) async {
    final r = await w();
    _toast(r);
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator(key: Key('device-loading')));
    final s = d.snapshot;
    if (_failed || s == null) {
      return ListView(padding: const EdgeInsets.all(Layout.screenMargin), children: [
        const NoteCard('The radio did not report its settings. Check the Bluetooth link and try again. Nothing was changed.', kind: NoteKind.problem, title: 'Could not read the radio'),
        const SizedBox(height: Gap.m),
        FilledButton(key: const Key('device-retry'), onPressed: _load, child: const Text('Try again')),
      ]);
    }
    final cfg = s.config;
    final info = s.info;
    final batt = s.battery;
    final policy = s.policy;
    final tel = s.telemetry;
    final canAutoAdd = d.available(DeviceFeature.autoAdd) && policy != null && policy.autoAddSupported;
    final fw = s.firmwareVersion ?? (info == null ? null : 'code ${info.firmwareVerCode}');
    final battText = batt == null ? null : '${(batt.batteryMv / 1000).toStringAsFixed(2)} V, about ${estimateBatteryPercent(batt.batteryMv)}%';
    final capacity = info?.maxContacts;

    final hidden = <(String, String)>[
      for (final e in d.unavailable.entries) (_featureLabel(e.key), e.value),
      ('Ignored nodes', 'The list of nodes you ignore lives in Contacts, in Contacts settings, because it is kept on this phone and not on the radio.'),
    ];

    return ListView(
      key: const Key('device-list'),
      padding: const EdgeInsets.only(top: Gap.s, bottom: Layout.sectionGap),
      children: [
        _Header(name: cfg.name, line1: 'Connected${battText == null ? '' : ' · $battText'}${fw == null ? '' : ' · fw $fw'}', line2: [
          if (info != null) 'Protocol ${info.firmwareVerCode}',
          if (capacity != null) '$capacity contacts max',
        ].join(' · ')),
        InsetGroup(header: 'This radio', footer: 'Firmware opens the official MeshCore flasher in your browser.', rows: [
          // Build 76: what people change first. Name, then position, power and frequency (it was five groups down).
          InsetRow(key: const Key('row-name'), title: 'Name', value: cfg.name, onTap: () => _push(const RadioSetupScreen())),
          InsetRow(key: const Key('row-setup'), title: 'Position, power and frequency', onTap: () => _push(const RadioSetupScreen())),
          if (d.available(DeviceFeature.battery) && batt != null)
            InsetRow(key: const Key('row-battery'), title: 'Battery & storage', value: battText, onTap: () => _batterySheet()),
          InsetRow(
            key: const Key('row-firmware'),
            title: 'Firmware',
            value: fw,
            onTap: () => widget.host.openUrl(flasherUrl),
          ),
        ]),
        InsetGroup(header: 'Contacts', rows: [
          AppSwitchTile(
            key: const Key('row-ask'),
            title: 'Add new contacts myself',
            subtitle: 'Off: the radio adds every node it hears.',
            value: cfg.manualAdd,
            onChanged: (v) => _write(() => d.setAskBeforeAdding(v)),
            switchKey: const Key('row-ask-switch'),
          ),
          if (canAutoAdd) InsetRow(key: const Key('row-autoadd'), title: 'Auto-add by type', onTap: () => _autoAdd(policy, false)),
          if (canAutoAdd) InsetRow(key: const Key('row-hops'), title: 'Distance limit and a full list', onTap: () => _autoAdd(policy, true)),
          InsetRow(
            key: const Key('row-contact-count'),
            title: 'Contacts on this radio',
            value: _contactCount == null ? 'Counting...' : (capacity == null ? '$_contactCount' : '$_contactCount of $capacity'),
          ),
        ]),
        InsetGroup(header: 'Privacy', rows: [
          AppSwitchTile(
            key: const Key('row-location'),
            title: 'Share location in adverts',
            subtitle: 'Adverts carry the position stored on the radio.',
            value: cfg.advertLocPolicy != 0,
            onChanged: (v) => _write(() => d.setShareLocation(v)),
            switchKey: const Key('row-location-switch'),
          ),
          InsetRow(key: const Key('row-telemetry'), title: 'Who can request my telemetry', value: _telemetrySummary(tel), onTap: () => _telemetry(tel)),
        ]),
        InsetGroup(header: 'Tools', rows: [
          InsetRow(key: const Key('row-tools'), title: 'Radio tools', subtitle: 'Trace path, Discover, Rx log, Noise floor', onTap: () => _push(const _ToolsList())),
        ]),
        InsetGroup(header: 'Security', rows: [
          InsetRow(key: const Key('row-pin'), title: 'Bluetooth PIN', onTap: _pin),
          InsetRow(key: const Key('row-export'), title: 'Export backup', subtitle: 'Encrypted with a passphrase', onTap: _export),
          InsetRow(key: const Key('row-import'), title: 'Import backup', onTap: _import),
        ]),
        // Expert rows together, below everything a new owner needs (build 76: Routing and Console were mixed in above).
        InsetGroup(header: 'Advanced', footer: 'Most people never need these.', rows: [
          if (d.available(DeviceFeature.pathHashMode))
            InsetRow(
                key: const Key('row-hash'),
                title: 'Path hash size',
                value: s.pathHashBytes == null ? null : '${s.pathHashBytes} byte${s.pathHashBytes == 1 ? '' : 's'}',
                onTap: () => _pathHash(s.pathHashBytes)),
          AppSwitchTile(
            key: const Key('row-acks'),
            title: 'Always confirm sends',
            subtitle: 'Extra acknowledgements so you learn sooner whether a message arrived.',
            value: cfg.multiAcks != 0,
            onChanged: (v) => _write(() => d.setMultiAcks(v)),
            switchKey: const Key('row-acks-switch'),
          ),
          if (d.available(DeviceFeature.console)) InsetRow(key: const Key('row-console'), title: 'Console', subtitle: 'Type commands to the radio', onTap: () => _push(DeviceConsoleScreen(tool: d))),
        ]),
        // Build 76: restart and erase are two groups, never one under the other, and both ask first.
        InsetGroup(groupKey: const Key('group-restart'), footer: 'Nothing is erased. The radio disconnects while it restarts.', rows: [
          InsetRow(key: const Key('row-reboot'), title: 'Reboot radio', chevron: false, onTap: _reboot),
        ]),
        InsetGroup(groupKey: const Key('group-erase'), header: 'Erase', footer: 'Erases the identity key, contacts and channels. You type a word to confirm.', rows: [
          InsetRow(key: const Key('row-reset'), title: 'Factory reset', destructive: true, chevron: false, onTap: _reset),
        ]),
        if (hidden.isNotEmpty)
          Padding(
            key: const Key('device-hidden'),
            padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.l, 0, Layout.screenMargin + Gap.l, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('NOT AVAILABLE ON THIS RADIO', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, letterSpacing: 0.4)),
              const SizedBox(height: Gap.xs),
              for (final h in hidden)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.s),
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: '${h.$1}. ', style: t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                    TextSpan(text: h.$2, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ])),
                ),
            ]),
          ),
      ],
    );
  }

  static String _featureLabel(DeviceFeature f) => switch (f) {
        DeviceFeature.battery => 'Battery & storage',
        DeviceFeature.pathHashMode => 'Path hash size',
        DeviceFeature.console => 'Console',
        DeviceFeature.identityKeyExport => 'Identity key in backups',
        DeviceFeature.identityKeyImport => 'Restoring an identity key',
        DeviceFeature.autoAdd => 'Auto-add by type',
      };

  static String _telemetrySummary(TelemetryModes m) {
    if (m.byte == 0) return 'Nobody';
    if (m.base == 2 && m.location == 2 && m.env == 2) return 'Everyone';
    return 'Custom';
  }

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ToolsHostScope(host: widget.host, child: page)));

  // ------------------------------------------------------------ rows

  Future<void> _batterySheet() async {
    await d.refreshBattery();
    if (!mounted) return;
    final b = d.snapshot?.battery;
    if (b == null) return;
    final used = b.storageUsedKb, total = b.storageTotalKb;
    await showAppSheet<void>(
      context,
      detents: const [0.45],
      builder: (ctx, scroll) => AppSheetScaffold(controller: scroll, title: 'Battery & storage', children: [
        InsetGroup(rows: [
          InsetRow(key: const Key('batt-volts'), title: 'Voltage', value: '${(b.batteryMv / 1000).toStringAsFixed(2)} V'),
          InsetRow(key: const Key('batt-percent'), title: 'Charge (estimated)', value: 'about ${estimateBatteryPercent(b.batteryMv)}%'),
          if (used != null && total != null) InsetRow(key: const Key('batt-storage'), title: 'Radio storage', value: '${(used / 1024).toStringAsFixed(1)} of ${(total / 1024).toStringAsFixed(1)} MB used'),
        ]),
        Text('The percentage is a guess from the voltage; the voltage is what the radio measures.', style: Theme.of(ctx).textTheme.bodySmall),
      ]),
    );
  }

  Future<void> _autoAdd(dynamic policy, bool hops) async {
    final p = await showAutoAddSheet(context, policy, hopsAndOverwrite: hops);
    if (p != null) await _write(() => d.setAutoAdd(p));
  }

  Future<void> _telemetry(TelemetryModes cur) async {
    final m = await showTelemetrySheet(context, cur);
    if (m != null) await _write(() => d.setTelemetryModes(m));
  }

  Future<void> _pathHash(int? cur) async {
    if (_driveBlocks('changing the path hash size')) return;
    final n = await showPathHashSheet(context, cur);
    if (n != null) await _write(() => d.setPathHashSize(n));
  }

  Future<void> _pin() async {
    if (_driveBlocks('changing the Bluetooth PIN')) return;
    final pin = await showPinSheet(context);
    if (pin != null) await _write(() => d.setPin(pin, pin));
  }

  Future<void> _export() async {
    await showExportBackupSheet(context, tool: d, shareFile: widget.shareFile, copyText: widget.copyText, identityKnownDisabled: !d.available(DeviceFeature.identityKeyExport));
  }

  Future<void> _import() async {
    final choice = await showImportBackupSheet(context, tool: d, pasteText: widget.pasteText);
    if (choice == null) return;
    if (choice.replaceIdentity && _driveBlocks('replacing the radio\'s identity')) {
      choice.data.wipe();
      return;
    }
    final r = await d.restoreBackup(choice.data, replaceIdentity: choice.replaceIdentity, typed: choice.typed);
    choice.data.wipe();
    _toast(r.result);
  }

  Future<void> _reboot() async {
    if (_driveBlocks('restarting the radio')) return;
    // Build 76: one tap used to restart the radio at once, from a row right above Factory reset.
    final ok = await showAppAlert(
      context,
      title: 'Reboot ${d.snapshot?.config.name ?? 'this radio'}?',
      message: 'Nothing is erased. The radio disconnects while it restarts.',
      confirmLabel: 'Reboot',
      dialogKey: const Key('reboot-confirm'),
      confirmKey: const Key('reboot-confirm-ok'),
    );
    if (ok != true || !mounted) return;
    await _write(d.reboot);
  }

  Future<void> _reset() async {
    if (_driveBlocks('resetting the radio')) return;
    final ok = await showFactoryResetSheet(context, radioName: d.snapshot?.config.name ?? 'this radio', contacts: _contactCount);
    if (!ok) return;
    await _write(() => d.factoryReset(TypedConfirm.factoryReset));
  }
}

class _Header extends StatelessWidget {
  final String name, line1, line2;
  const _Header({required this.name, required this.line1, required this.line2});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Padding(
      key: const Key('device-header'),
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, Layout.sectionGap - 8),
      child: Row(children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(color: c.primary.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(Corners.chip)),
          child: AppSymbolIcon(AppSymbols.antenna, size: 28, color: c.primary),
        ),
        const SizedBox(width: Gap.l),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: t.textTheme.titleLarge),
            Text(line1, style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
            if (line2.isNotEmpty) Text(line2, style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

class _ToolsList extends StatelessWidget {
  const _ToolsList();
  @override
  Widget build(BuildContext context) {
    void open(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ToolsHostScope(host: ToolsHostScope.of(context), child: w)));
    return Scaffold(
      key: const Key('device-tools'),
      appBar: AppBar(title: const Text('Tools')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.only(top: Gap.m), children: [
          InsetGroup(rows: [
            // Build 76: each tool says what it is for, in the same words as Network > Tools (tools_section.dart).
            InsetRow(key: const Key('tool-trace'), title: 'Trace path', subtitle: 'Send a test packet along repeaters you choose', onTap: () => open(const TraceScreen())),
            InsetRow(key: const Key('tool-discover'), title: 'Discover', subtitle: 'Find repeaters in direct range of your radio', onTap: () => open(const DiscoverScreen())),
            InsetRow(key: const Key('tool-adverts'), title: 'Adverts', subtitle: 'Announce your radio and see who else announced', onTap: () => open(const AdvertsScreen())),
            InsetRow(key: const Key('tool-rxlog'), title: 'Rx log', subtitle: 'Every packet your radio hears, live', onTap: () => open(const RxLogScreen())),
            InsetRow(key: const Key('tool-noise'), title: 'Noise floor', subtitle: 'How quiet the channel is at your radio', onTap: () => open(const NoiseScreen())),
            InsetRow(key: const Key('tool-telemetry'), title: 'Telemetry', subtitle: 'Battery and sensor readings from a node', onTap: () => open(const TelemetryScreen())),
          ]),
        ]),
      ),
    );
  }
}
