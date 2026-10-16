// Pick a radio: scan Bluetooth for MeshCore companions, or use the Simulator.
import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../radio/radio_api.dart';
import 'app.dart';
import 'widgets.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  List<RadioDevice> _found = const [];
  bool _scanning = false;
  bool _scannedOnce = false;
  String? _scanError;
  StreamSubscription<List<RadioDevice>>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !AppScope.read(context).connected) _scan();
    });
  }

  void _scan() {
    final s = AppScope.read(context);
    _sub?.cancel();
    setState(() {
      _scanning = true;
      _scanError = null;
      _found = const [];
    });
    try {
      _sub = s.services.bluetoothScanner.scan().listen(
        (list) {
          if (!mounted) return;
          final sorted = List.of(list)..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
          setState(() => _found = sorted);
        },
        onError: (Object e) {
          if (!mounted) return;
          setState(() {
            _scanning = false;
            _scannedOnce = true;
            _scanError = _scanMessage(e);
          });
        },
        onDone: () {
          if (!mounted) return;
          setState(() {
            _scanning = false;
            _scannedOnce = true;
          });
        },
      );
    } catch (e) {
      setState(() {
        _scanning = false;
        _scannedOnce = true;
        _scanError = _scanMessage(e);
      });
    }
  }

  String _scanMessage(Object e) {
    final l = e.toString().toLowerCase();
    if (l.contains('permission')) {
      return 'MeshSonar needs Bluetooth permission to find your radio. Allow Bluetooth (and Nearby devices on Android) in your phone\'s settings.';
    }
    if (l.contains('off') || l.contains('unavailable') || l.contains('not supported') || l.contains('adapter')) {
      return 'Bluetooth looks off or unavailable. Turn it on and scan again, or use the Simulator.';
    }
    return 'Bluetooth scan didn\'t work. Turn Bluetooth on and try again, or use the Simulator.';
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _connect(RadioDevice d, RadioKind kind) async {
    final s = AppScope.read(context);
    unawaited(_sub?.cancel());
    _sub = null;
    setState(() => _scanning = false);
    final ok = kind == RadioKind.simulator ? await s.connectSimulator() : await s.connect(d, kind);
    if (ok && mounted) Navigator.of(context).pop();
  }

  String _rssiLabel(int? rssi) {
    if (rssi == null) return 'Signal —';
    final q = rssi >= -60 ? 'strong' : (rssi >= -80 ? 'good' : 'weak');
    return '$rssi dBm ($q)';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Connect a radio')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (s.connected)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.check_circle, color: Colors.green, size: 32),
                  title: Text('Connected: ${s.connectionLabel}', style: const TextStyle(fontSize: 18)),
                  subtitle: s.selfInfo?.firmware == null ? null : Text('Firmware ${s.selfInfo!.firmware}'),
                  trailing: TextButton(
                    key: const Key('disconnect'),
                    onPressed: s.driving ? null : () => s.disconnect(),
                    child: const Text('Disconnect'),
                  ),
                ),
              ),
            if (s.connecting)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Row(children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 16),
                  Expanded(child: Text('Connecting to the radio…', style: TextStyle(fontSize: 18))),
                ]),
              ),
            if (s.connectError != null) ErrorBanner(s.connectError!),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text('Bluetooth radios', style: t.textTheme.titleLarge)),
              if (_scanning)
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              else
                TextButton.icon(
                  key: const Key('scan'),
                  onPressed: s.connecting ? null : _scan,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Scan'),
                ),
            ]),
            if (_scanError != null) ErrorBanner(_scanError!),
            if (_found.isEmpty && !_scanning && _scannedOnce && _scanError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No MeshCore radios found. Make sure your companion radio is on, has Bluetooth enabled, '
                  'and isn\'t connected to another app (like the MeshCore app), then scan again.',
                ),
              ),
            if (_found.isEmpty && _scanning)
              const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Looking for radios…')),
            for (final d in _found)
              Card(
                child: ListTile(
                  key: ValueKey('device-${d.id}'),
                  minTileHeight: 64,
                  leading: const Icon(Icons.bluetooth, size: 32),
                  title: Text(d.name.isEmpty ? 'Unnamed radio' : d.name, style: const TextStyle(fontSize: 18)),
                  subtitle: Text(_rssiLabel(d.rssi)),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: !s.connecting,
                  onTap: () => _connect(d, RadioKind.bluetooth),
                ),
              ),
            const SizedBox(height: 16),
            Text('No radio?', style: t.textTheme.titleLarge),
            Card(
              child: ListTile(
                key: const Key('simulator'),
                minTileHeight: 64,
                leading: const Icon(Icons.science, size: 32),
                title: const Text('Simulator (no radio)', style: TextStyle(fontSize: 18)),
                subtitle: const Text('A pretend radio and drive around Westerville, for trying the app out.'),
                enabled: !s.connecting,
                onTap: () => _connect(const RadioDevice(id: 'simulator', name: 'MeshSonar Simulator'), RadioKind.simulator),
              ),
            ),
            const SizedBox(height: 8),
            const EmptyState(
              icon: Icons.info_outline,
              title: 'Tip',
              body: 'Only one app can talk to the radio at a time. Close the MeshCore app first.',
            ),
          ],
        ),
      ),
    );
  }
}
