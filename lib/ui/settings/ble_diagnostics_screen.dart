// Settings > Diagnostics > Background Bluetooth test. The harness for spike S1: a log of the radio link's lifecycle that
// survives the app being closed (lib/alerts/ble_lifecycle_log.dart), a place to drop notes between test steps, and one
// Copy button that puts header + log on the clipboard to paste back. The exact test script is
// docs/BACKGROUND_BLE_SPIKE.md. No message text, no keys and no positions are logged.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../alerts/alerts_runtime.dart';
import '../../radio/ble_transport_universal.dart' show BleEngineChoice;
import '../app.dart';
import '../design/app_surfaces.dart';

const String bleDiagnosticsIntro = 'Do the test steps, then tap Copy log and send it to the developer.';

/// Behind "What is logged" on the screen.
const String bleDiagnosticsDetail = 'This tests whether MeshSonar keeps your radio and your alerts alive in the background. '
    'The log is kept on this phone, also after the app is closed. It holds event names and times only: no messages, '
    'no keys, no positions.';

List<Widget> bleDiagnosticsRows(BuildContext context) => [
      ListTile(
        key: const Key('diagnostics-ble'),
        leading: const Icon(Icons.bluetooth_searching),
        title: const Text('Background Bluetooth test'),
        subtitle: const Text('For testers: a log of the radio link in the background.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BleDiagnosticsScreen())),
      ),
    ];

class BleDiagnosticsScreen extends StatefulWidget {
  const BleDiagnosticsScreen({super.key});
  @override
  State<BleDiagnosticsScreen> createState() => _BleDiagnosticsScreenState();
}

class _BleDiagnosticsScreenState extends State<BleDiagnosticsScreen> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<String> _header(AlertsRuntime rt, {required String version}) async {
    final k = await rt.keeper.report();
    await rt.savedRadios.load();
    final radio = rt.savedRadios.starred;
    return [
      'MeshSonar BLE background test',
      'app $version, ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'exported ${DateTime.now().toIso8601String()}',
      'auto-connect: ${rt.prefs.autoConnect.label}; starred radio: ${radio?.name ?? 'none'}'
          '${rt.savedRadios.autoConnectHeld ? ' (held: released on purpose)' : ''}; saved radios: ${rt.savedRadios.radios.length}',
      'bluetooth engine: ${BleEngineChoice.universal ? 'universal_ble (experiment)' : 'flutter_reactive_ble'}',
      'wake keeper experiment: ${rt.prefs.iosWakeKeeper ? 'ON' : 'off'}; native armed=${k.armed}, started by restoration=${k.launchedByRestore}, '
          'notifications while away=${k.notificationsWhileAway}',
      'alerts: enabled=${rt.prefs.enabled}, permission=${rt.coordinator.permission.name}',
      '--- log (fg = app in front, bg = not) ---',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Background Bluetooth test')),
      body: SafeArea(
          child: ValueListenableBuilder<AlertsRuntime?>(
        valueListenable: AlertsHost.runtime,
        builder: (context, rt, _) {
          if (rt == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('The test log is not ready yet. Go back and open this page again.', key: Key('ble-unavailable'), textAlign: TextAlign.center),
              ),
            );
          }
          final btn = ButtonStyle(minimumSize: WidgetStateProperty.all(const Size(48, 48)));
          return ListenableBuilder(
            listenable: Listenable.merge([rt.log, rt.prefs, ?rt.reconnect]),
            builder: (context, _) {
              final lines = rt.log.entries.reversed.take(300).toList();
              return ListView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(bleDiagnosticsIntro, key: Key('ble-intro')),
                  const SizedBox(height: 12),
                  Text('Now: app ${rt.log.foreground ? 'in front' : 'in background'}, radio ${s.connected ? 'connected' : 'not connected'}'
                      '${rt.reconnect?.statusText != null ? ', ${rt.reconnect!.statusText}' : ''}', key: const Key('ble-now')),
                  ExpansionTile(
                    key: const Key('ble-detail'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 12),
                    expandedAlignment: Alignment.centerLeft,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: const Text('What is logged'),
                    children: const [Text(bleDiagnosticsDetail)],
                  ),
                  if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                    const Divider(height: 32),
                    SwitchListTile(
                      key: const Key('ble-keeper'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Experiment: wake keeper'),
                      subtitle: const Text('May let iOS restart MeshSonar when the radio sends a message. Only for the test script.'),
                      value: rt.prefs.iosWakeKeeper,
                      onChanged: (v) => rt.setIosWakeKeeper(v),
                    ),
                  ],
                  const Divider(height: 32),
                  SwitchListTile(
                    key: const Key('ble-engine'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Experiment: other Bluetooth engine'),
                    subtitle: const Text('Tries a different Bluetooth library. Reconnect the radio to apply; switch back if it connects badly.'),
                    value: BleEngineChoice.universal,
                    onChanged: (v) async {
                      await BleEngineChoice.set(v);
                      if (mounted) setState(() {});
                      rt.log.add('note', 'Bluetooth engine set to ${v ? 'universal_ble' : 'flutter_reactive_ble'}');
                      if (context.mounted) showAppToast(context, 'Disconnect and connect the radio again to apply.');
                    },
                  ),
                  const Divider(height: 32),
                  TextField(
                    key: const Key('ble-note'),
                    controller: _note,
                    // The example was part of the label and was cut off at "Note a test step (for exam…" on a phone.
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: 'Note a test step', hintText: 'A2: locked, sent test message'),
                    onSubmitted: (_) => _addNote(rt),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(key: const Key('ble-add-note'), style: btn, onPressed: () => _addNote(rt), child: const Text('Add note')),
                      FilledButton(
                        key: const Key('ble-copy'),
                        style: btn,
                        onPressed: () async {
                          final text = rt.log.export(header: await _header(rt, version: s.services.appInfo.version ?? '?'));
                          await Clipboard.setData(ClipboardData(text: text));
                          if (!context.mounted) return;
                          showAppToast(context, 'Copied ${rt.log.entries.length} lines.', kind: AppToastKind.success);
                        },
                        child: const Text('Copy log'),
                      ),
                      OutlinedButton(
                        key: const Key('ble-keeper-pull'),
                        style: btn,
                        onPressed: () async {
                          final k = await rt.keeper.report();
                          for (final l in k.lines) {
                            rt.log.add('keeper', l);
                          }
                          if (k.lines.isNotEmpty) await rt.keeper.clearReport();
                          // The button used to do nothing visible when there was nothing to read.
                          if (context.mounted) showAppToast(context, k.lines.isEmpty ? 'No new native events.' : 'Added ${k.lines.length} native event${k.lines.length == 1 ? '' : 's'}.');
                        },
                        child: const Text('Read native events'),
                      ),
                      OutlinedButton(key: const Key('ble-clear'), style: btn, onPressed: rt.log.entries.isEmpty ? null : rt.log.clear, child: const Text('Clear')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (lines.isEmpty)
                    const Text('The log is empty. Connect your radio, or add a note, to start it.', key: Key('ble-empty')),
                  for (final e in lines)
                    Text(e.line, key: const Key('ble-line'), style: const TextStyle(fontFamily: 'Courier', fontSize: 12)),
                ],
              );
            },
          );
        },
      )),
    );
  }

  void _addNote(AlertsRuntime rt) {
    final t = _note.text.trim();
    if (t.isEmpty) {
      showAppToast(context, 'Type the note first.');
      return;
    }
    rt.log.add('note', t);
    _note.clear();
  }
}
