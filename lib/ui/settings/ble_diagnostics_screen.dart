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

const String bleDiagnosticsIntro = 'For testing whether MeshSonar keeps your radio and your alerts alive while it is in the '
    'background. Do the steps in the test script, then press Copy and paste the result to the developer. '
    'The log is kept on this phone, also after the app is closed. It holds event names and times only: no messages, '
    'no keys, no positions.';

List<Widget> bleDiagnosticsRows(BuildContext context) => [
      ListTile(
        key: const Key('diagnostics-ble'),
        leading: const Icon(Icons.bluetooth_searching),
        title: const Text('Background Bluetooth test'),
        subtitle: const Text('A log of the radio link while the app is in the background, closed or restarted. For testing alerts.'),
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
    final radio = await rt.lastRadio.load();
    return [
      'MeshSonar BLE background test',
      'app $version, ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'exported ${DateTime.now().toIso8601String()}',
      'remembered radio: ${radio?.name ?? 'none'}',
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
      body: ValueListenableBuilder<AlertsRuntime?>(
        valueListenable: AlertsHost.runtime,
        builder: (context, rt, _) {
          if (rt == null) return const Center(child: Text('Not available in this build.', key: Key('ble-unavailable')));
          return ListenableBuilder(
            listenable: Listenable.merge([rt.log, rt.prefs, ?rt.reconnect]),
            builder: (context, _) {
              final lines = rt.log.entries.reversed.take(300).toList();
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(bleDiagnosticsIntro, key: Key('ble-intro')),
                  const SizedBox(height: 12),
                  Text('Now: app ${rt.log.foreground ? 'in front' : 'in background'}, radio ${s.connected ? 'connected' : 'not connected'}'
                      '${rt.reconnect?.statusText != null ? ', ${rt.reconnect!.statusText}' : ''}'),
                  if (defaultTargetPlatform == TargetPlatform.iOS) ...[
                    const Divider(height: 32),
                    SwitchListTile(
                      key: const Key('ble-keeper'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Experiment: wake keeper'),
                      subtitle: const Text('Holds a second Bluetooth link so iOS may start MeshSonar again after it closed it, '
                          'when the radio sends a message. Not proven to work. Turn it on only for the test script; '
                          'it is released whenever you disconnect.'),
                      value: rt.prefs.iosWakeKeeper,
                      onChanged: (v) => rt.setIosWakeKeeper(v),
                    ),
                  ],
                  const Divider(height: 32),
                  SwitchListTile(
                    key: const Key('ble-engine'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Experiment: other Bluetooth engine'),
                    subtitle: const Text('Uses a different Bluetooth library that supports being started again by iOS after '
                        'it closed the app. Not proven. Applies at the next connect: disconnect and connect again. '
                        'Switch it back if the radio connects badly.'),
                    value: BleEngineChoice.universal,
                    onChanged: (v) async {
                      await BleEngineChoice.set(v);
                      if (mounted) setState(() {});
                      rt.log.add('note', 'Bluetooth engine set to ${v ? 'universal_ble' : 'flutter_reactive_ble'}');
                    },
                  ),
                  const Divider(height: 32),
                  TextField(
                    key: const Key('ble-note'),
                    controller: _note,
                    decoration: const InputDecoration(labelText: 'Note a test step (for example "A2: locked, sent test message")'),
                    onSubmitted: (_) => _addNote(rt),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonal(key: const Key('ble-add-note'), onPressed: () => _addNote(rt), child: const Text('Add note')),
                      FilledButton(
                        key: const Key('ble-copy'),
                        onPressed: () async {
                          final text = rt.log.export(header: await _header(rt, version: s.services.appInfo.version ?? '?'));
                          await Clipboard.setData(ClipboardData(text: text));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied ${rt.log.entries.length} lines.')));
                        },
                        child: const Text('Copy log'),
                      ),
                      OutlinedButton(
                        key: const Key('ble-keeper-pull'),
                        onPressed: () async {
                          final k = await rt.keeper.report();
                          for (final l in k.lines) {
                            rt.log.add('keeper', l);
                          }
                          if (k.lines.isNotEmpty) await rt.keeper.clearReport();
                        },
                        child: const Text('Read native events'),
                      ),
                      OutlinedButton(key: const Key('ble-clear'), onPressed: rt.log.clear, child: const Text('Clear')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final e in lines)
                    Text(e.line, key: const Key('ble-line'), style: const TextStyle(fontFamily: 'Courier', fontSize: 12)),
                ],
              );
            },
          );
        },
      ),
    );
  }

  void _addNote(AlertsRuntime rt) {
    final t = _note.text.trim();
    if (t.isEmpty) return;
    rt.log.add('note', t);
    _note.clear();
  }
}
