// Home screen: connection, big Start/Stop, Ping now, live counters, recent pings.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../radio/radio_api.dart';
import 'app.dart';
import 'connect_screen.dart';
import 'widgets.dart';

class DriveScreen extends StatelessWidget {
  const DriveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final driving = s.driving;
    final pct = s.heardPercent;
    final pings = s.recentPings;

    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshSonar'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              key: const Key('connection-chip'),
              avatar: Icon(
                s.connected
                    ? (s.radioKind == RadioKind.simulator ? Icons.science : Icons.bluetooth_connected)
                    : Icons.bluetooth_disabled,
                size: 20,
              ),
              label: Text(s.connectionLabel),
              onPressed: () => openConnect(context),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(children: [
                StatTile(label: 'Pings', value: '${s.pingCount}', valueKey: const Key('stat-pings')),
                StatTile(label: 'Heard', value: '${s.heardCount}', valueKey: const Key('stat-heard')),
                StatTile(label: 'Heard %', value: pct == null ? '—' : '$pct%', valueKey: const Key('stat-pct')),
                StatTile(label: 'Synced', value: '${s.syncedCount}', valueKey: const Key('stat-synced')),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(children: [
                if (s.status.state == EngineState.pinging || s.busy)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Expanded(
                  child: Text(s.statusLine,
                      key: const Key('status-line'),
                      style: t.textTheme.titleMedium?.copyWith(
                          color: s.status.state == EngineState.error ? t.colorScheme.error : null)),
                ),
              ]),
            ),
            if (s.unsavedCount > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ErrorBanner('${s.unsavedCount} ping(s) not yet saved to this device. Retrying.'),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Row(children: [
                Expanded(
                  flex: 3,
                  child: SizedBox(
                    height: 72,
                    child: FilledButton.icon(
                      key: const Key('start-stop'),
                      style: FilledButton.styleFrom(
                        backgroundColor: driving ? t.colorScheme.error : null,
                        foregroundColor: driving ? t.colorScheme.onError : null,
                        textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      onPressed: s.busy
                          ? null
                          : () {
                              if (driving) {
                                s.stopDrive();
                              } else if (!s.connected) {
                                openConnect(context);
                              } else {
                                s.startDrive();
                              }
                            },
                      icon: Icon(driving ? Icons.stop : Icons.play_arrow, size: 32),
                      label: Text(driving ? 'Stop drive' : (s.connected ? 'Start drive' : 'Connect radio')),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 72,
                    child: OutlinedButton.icon(
                      key: const Key('ping-now'),
                      onPressed: (driving && !s.pinging && !s.busy) ? () => s.pingNow() : null,
                      icon: const Icon(Icons.wifi_tethering, size: 28),
                      label: const Text('Ping now', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: pings.isEmpty
                  ? EmptyState(
                      icon: Icons.radar,
                      title: driving ? 'Waiting for the first ping' : 'No pings yet',
                      body: driving
                          ? 'Pings appear here as soon as each listen window closes.'
                          : s.connected
                              ? 'Press Start drive. Every ping is saved on this phone right away.'
                              : 'Tap Connect radio to pick your MeshCore companion radio, or try the Simulator.',
                    )
                  : ListView.separated(
                      key: const Key('recent-pings'),
                      itemCount: pings.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, i) => PingTile(ping: pings[i], state: s),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

void openConnect(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen()));
}
