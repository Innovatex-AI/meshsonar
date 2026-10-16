// Pick a radio: scan Bluetooth for MeshCore companions, or use the Simulator.
// Sections: current radio, nearby radios (signal bars, a spinner on the one being connected), the Simulator, a tip.
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
  bool _permissionProblem = false;
  String? _connectingId;

  /// Some platforms never close the scan stream (no adapter, plugin quirks). Stop showing "Scanning" after this.
  Timer? _scanGuard;
  static const _scanLimit = Duration(seconds: 15);

  void _endScan() {
    _scanGuard?.cancel();
    _scanGuard = null;
    if (!mounted || !_scanning) return;
    unawaited(_sub?.cancel());
    _sub = null;
    setState(() {
      _scanning = false;
      _scannedOnce = true;
    });
  }

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
    _scanGuard?.cancel();
    _scanGuard = Timer(_scanLimit, _endScan);
    try {
      _sub = s.services.bluetoothScanner.scan().listen(
        (list) {
          if (!mounted) return;
          final sorted = List.of(list)..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
          setState(() => _found = sorted);
        },
        onError: (Object e) {
          _scanGuard?.cancel();
          if (!mounted) return;
          setState(() {
            _scanning = false;
            _scannedOnce = true;
            _scanError = _scanMessage(e);
          });
        },
        onDone: () {
          _scanGuard?.cancel();
          if (!mounted) return;
          setState(() {
            _scanning = false;
            _scannedOnce = true;
          });
        },
      );
    } catch (e) {
      _scanGuard?.cancel();
      setState(() {
        _scanning = false;
        _scannedOnce = true;
        _scanError = _scanMessage(e);
      });
    }
  }

  String _scanMessage(Object e) {
    final l = e.toString().toLowerCase();
    _permissionProblem = l.contains('permission');
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
    _scanGuard?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _connect(RadioDevice d, RadioKind kind) async {
    final s = AppScope.read(context);
    unawaited(_sub?.cancel());
    _sub = null;
    _scanGuard?.cancel();
    setState(() {
      _scanning = false;
      _connectingId = d.id;
    });
    final ok = kind == RadioKind.simulator ? await s.connectSimulator() : await s.connect(d, kind);
    if (!mounted) return;
    setState(() => _connectingId = null);
    if (ok) Navigator.of(context).pop();
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
    final busy = s.connecting || _connectingId != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect a radio')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
          children: [
            if (s.connected) _ConnectedCard(state: s),
            if (s.connectError != null) ErrorBanner(s.connectError!),
            SectionLabel(
              'Nearby radios',
              trailing: _scanning
                  ? Padding(
                      padding: const EdgeInsets.all(Gap.s),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              backgroundColor: t.colorScheme.primary.withValues(alpha: 0.18),
                            ),
                          ),
                          const SizedBox(width: Gap.s),
                          Text('Scanning', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
                        ],
                      ),
                    )
                  : TextButton.icon(
                      key: const Key('scan'),
                      onPressed: busy ? null : _scan,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(_scannedOnce ? 'Scan again' : 'Scan'),
                    ),
            ),
            if (_scanError != null) ...[
              ErrorBanner(_scanError!),
              if (_permissionProblem)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs, left: Gap.xs),
                  child: Text(
                    'On iPhone: Settings → MeshSonar → Bluetooth. On Android: Settings → Apps → MeshSonar → Permissions.',
                    style: t.textTheme.bodySmall,
                  ),
                ),
            ],
            if (_found.isEmpty && !_scanning && _scannedOnce && _scanError == null)
              _InfoCard(
                icon: Icons.bluetooth_searching_rounded,
                title: 'No MeshCore radios found',
                body:
                    'Make sure your companion radio is on, has Bluetooth enabled, '
                    'and isn\'t connected to another app (like the MeshCore app), then scan again.',
              ),
            if (_found.isEmpty && _scanning)
              const _InfoCard(
                icon: Icons.radar,
                title: 'Looking for radios…',
                body: 'Keep the radio close to the phone.',
              ),
            for (final d in _found)
              _DeviceCard(
                key: ValueKey('device-${d.id}'),
                device: d,
                subtitle: _rssiLabel(d.rssi),
                connecting: _connectingId == d.id && s.connecting,
                current: s.connected && s.device?.id == d.id,
                enabled: !busy,
                onTap: () => _connect(d, RadioKind.bluetooth),
              ),
            const SectionLabel('No radio?'),
            Card(
              child: ListTile(
                key: const Key('simulator'),
                minTileHeight: 72,
                contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
                leading: _IconBadge(icon: Icons.science_rounded, color: MeshSonarColors.of(context).beacon),
                title: const Text('Simulator (no radio)'),
                subtitle: const Text('A pretend radio and drive around Westerville, for trying the app out.'),
                trailing: _connectingId == 'simulator' && s.connecting
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Icon(Icons.chevron_right_rounded),
                enabled: !busy,
                onTap: () =>
                    _connect(const RadioDevice(id: 'simulator', name: 'MeshSonar Simulator'), RadioKind.simulator),
              ),
            ),
            const SizedBox(height: Gap.l),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 20, color: t.colorScheme.onSurfaceVariant),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Text(
                    'Only one app can talk to the radio at a time. Close the MeshCore app first.',
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectedCard extends StatelessWidget {
  final AppState state;
  const _ConnectedCard({required this.state});
  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final fw = s.selfInfo?.firmware;
    return Card(
      color: t.colorScheme.primaryContainer.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Corners.card),
        side: BorderSide(color: t.colorScheme.primary.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.s, Gap.m),
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: t.colorScheme.primary, size: 32),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Connected: ${s.connectionLabel}', style: t.textTheme.titleMedium),
                  if (fw != null) Text('Firmware $fw', style: t.textTheme.bodySmall),
                  if (s.driving) Text('Stop the drive to change radios.', style: t.textTheme.bodySmall),
                ],
              ),
            ),
            TextButton(
              key: const Key('disconnect'),
              onPressed: s.driving ? null : () => s.disconnect(),
              child: const Text('Disconnect'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final RadioDevice device;
  final String subtitle;
  final bool connecting;
  final bool current;
  final bool enabled;
  final VoidCallback onTap;
  const _DeviceCard({
    super.key,
    required this.device,
    required this.subtitle,
    required this.connecting,
    required this.current,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: ListTile(
        minTileHeight: 72,
        contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
        leading: _IconBadge(icon: Icons.bluetooth_rounded, color: t.colorScheme.primary),
        title: Text(device.name.isEmpty ? 'Unnamed radio' : device.name),
        subtitle: Text(connecting ? 'Connecting…' : (current ? 'Connected' : subtitle)),
        trailing: connecting
            ? const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5))
            : SignalBars(rssi: device.rssi),
        enabled: enabled,
        onTap: onTap,
      ),
    );
  }
}

class _IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _IconBadge({required this.icon, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(Corners.small)),
    child: Icon(icon, color: color, size: 26),
  );
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _InfoCard({required this.icon, required this.title, required this.body});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Corners.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: t.colorScheme.onSurfaceVariant, size: 28),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(body, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
