// Pick a radio: scan Bluetooth for MeshCore companions (and, in debug builds only, the Simulator).
// Sections: current radio, saved radios (tap to connect without a scan, swipe to forget, hold for nickname / auto-connect
// star: saved_radios_screen.dart), nearby radios (signal bars, a spinner on the one being connected), the Simulator, a tip.
// Build 77 (round 5 R2, R3): Bluetooth off says where to turn it on (Control Centre; the app's own settings page cannot)
// and the scan starts again by itself when the person comes back to the app; one Scan again; a failed connect also
// names the wrong-PIN / old-pairing fix.
import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../alerts/alerts_runtime.dart';
import '../alerts/saved_radios_store.dart';
import '../app/app_state.dart';
import '../app/build_flags.dart';
import '../radio/radio_api.dart';
import '../platform/open_url.dart' show openAppSettingsPage;
import 'app.dart';
import 'saved_radios_screen.dart';
import 'widgets.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

/// Under a failed connect: the usual cause first, then the fix for a wrong PIN or an old pairing.
const String connectFailedTip = 'Close the MeshCore app (only one app can use the radio at a time), then tap the radio again.';
const String connectPairingTip =
    'Wrong PIN or paired before? iPhone Settings > Bluetooth > (i) > Forget This Device, then try again.';
const String connectPairingTipAndroid =
    'Wrong PIN or paired before? Android Settings > Connected devices > the radio > Forget, then try again.';

class _ConnectScreenState extends State<ConnectScreen> with WidgetsBindingObserver {
  List<RadioDevice> _found = const [];
  bool _scanning = false;
  bool _scannedOnce = false;
  String? _scanError;
  bool _permissionProblem = false;

  /// The scan failed because Bluetooth is off (not a permission problem).
  bool _bluetoothOff = false;
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

  /// The saved radios list, watched so a forget or a new nickname redraws both sections.
  SavedRadiosStore? _saved;
  void _savedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _saved = AlertsHost.runtime.value?.savedRadios?..addListener(_savedChanged);
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
    _bluetoothOff = false;
    if (l.contains('permission')) {
      return 'MeshSonar is not allowed to use Bluetooth. Allow it in Settings to find your radio.';
    }
    if (l.contains('off') || l.contains('unavailable') || l.contains('not supported') || l.contains('adapter')) {
      _bluetoothOff = true;
      return defaultTargetPlatform == TargetPlatform.android
          ? 'Bluetooth is off. Turn it on in Quick Settings, then come back: the scan starts again by itself.'
          : 'Bluetooth is off. Turn it on in Control Centre, then come back: the scan starts again by itself.';
    }
    return 'Bluetooth scan didn\'t work. Turn Bluetooth on and try again.';
  }

  /// Back from Control Centre or the phone's Settings: a scan that failed runs again by itself.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    if (_scanError == null || _scanning || _connectingId != null) return;
    final s = AppScope.read(context);
    if (s.connecting || s.connected) return;
    _scan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saved?.removeListener(_savedChanged);
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
    if (rssi == null) return 'Signal unknown';
    return rssi >= -60 ? 'Strong signal, very close' : (rssi >= -80 ? 'Good signal' : 'Weak signal, move closer');
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final busy = s.connecting || _connectingId != null;
    final saved = _saved;
    final savedIds = {for (final r in saved?.radios ?? const []) r.id};
    // A saved radio the scan finds is shown once, in Saved radios ("In range"), not again below.
    final others = _found.where((d) => !savedIds.contains(d.id)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Connect a radio')),
      body: SafeArea(
        // Pull down to scan again (build 76), as every iPhone list refreshes.
        child: RefreshIndicator(
          key: const Key('connect-pull-scan'),
          onRefresh: () async {
            if (!busy && !_scanning) _scan();
          },
          child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
          children: [
            if (s.connected) _ConnectedCard(state: s),
            if (s.connectError != null) ...[
              ErrorBanner(s.connectError!),
              // The usual cause, right under the failure (it was a grey footnote at the very bottom of the page).
              Padding(
                key: const Key('connect-error-tip'),
                padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.xs, 0),
                child: Text(connectFailedTip, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ),
              Padding(
                key: const Key('connect-error-pairing'),
                padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.xs, 0),
                child: Text(defaultTargetPlatform == TargetPlatform.android ? connectPairingTipAndroid : connectPairingTip,
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ),
            ],
            if (saved != null && !saved.isEmpty)
              Column(
                key: const Key('saved-radios-section'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionLabel('Saved radios'),
                  SavedRadiosList(
                    store: saved,
                    onConnect: (r) => _connect(r.device, RadioKind.bluetooth),
                    connectingId: s.connecting ? _connectingId : null,
                    connectedId: s.connected ? s.device?.id : null,
                    enabled: !busy && !s.driving,
                    inRange: {for (final d in _found) d.id},
                  ),
                ],
              ),
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
              // Build 77 (round 5 R2): "Open Settings" only where the app's own settings page can fix it (a permission, or
              // a scan that failed for another reason). Bluetooth off is fixed in Control Centre, which the words say, and
              // the scan restarts on coming back. Scan again is the one button in the Nearby radios header.
              if (_permissionProblem)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs, left: Gap.xs),
                  child: Text(
                    defaultTargetPlatform == TargetPlatform.android ? 'Settings → Apps → MeshSonar → Permissions → Nearby devices.' : 'Settings → MeshSonar → Bluetooth.',
                    style: t.textTheme.bodySmall,
                  ),
                ),
              if (!_bluetoothOff)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    key: const Key('open-app-settings'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: () => unawaited(openAppSettingsPage()),
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Open Settings'),
                  ),
                ),
            ],
            if (_found.isEmpty && !_scanning && _scannedOnce && _scanError == null)
              _InfoCard(
                icon: Icons.bluetooth_searching_rounded,
                title: 'No MeshCore radios found',
                body: 'Turn the radio on, keep it close, and close the MeshCore app: only one app can use the radio at a time.',
              ),
            if (_found.isEmpty && _scanning)
              const _InfoCard(
                icon: Icons.radar,
                title: 'Looking for radios…',
                body: 'Keep the radio close to the phone.',
              ),
            if (_found.isNotEmpty && others.isEmpty)
              const _InfoCard(
                key: Key('only-saved-in-range'),
                icon: Icons.bluetooth_connected_rounded,
                title: 'Only your saved radios are in range',
                body: 'They are marked "In range" under Saved radios. Tap one to connect.',
              ),
            for (final d in others)
              _DeviceCard(
                key: ValueKey('device-${d.id}'),
                device: d,
                subtitle: _rssiLabel(d.rssi),
                connecting: _connectingId == d.id && s.connecting,
                current: s.connected && s.device?.id == d.id,
                enabled: !busy,
                onTap: () => _connect(d, RadioKind.bluetooth),
              ),
            if (simulatorAvailable) ...[
                const SectionLabel('No radio yet?'),
                Card(
                  child: ListTile(
                    key: const Key('simulator'),
                    minTileHeight: 72,
                    contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
                    leading: _IconBadge(icon: Icons.science_rounded, color: t.colorScheme.onSurfaceVariant),
                    title: const Text('Simulator (no radio)'),
                    subtitle: const Text('Try the app with a pretend drive. Nothing is uploaded.'),
                    trailing: _connectingId == 'simulator' && s.connecting
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Icon(Icons.chevron_right_rounded),
                    enabled: !busy,
                    onTap: () =>
                        _connect(const RadioDevice(id: 'simulator', name: 'MeshSonar Simulator'), RadioKind.simulator),
                  ),
                ),
            ],
          ],
        ),
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
  const _InfoCard({super.key, required this.icon, required this.title, required this.body});
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
