// Dart side of the iOS "wake keeper" EXPERIMENT (ios/Runner/BleWakeKeeper.swift). Off by default.
//
// Why it exists (spike S1, docs/BACKGROUND_BLE_SPIKE.md): flutter_reactive_ble creates its CBCentralManager with no
// restore identifier and has no willRestoreState, so iOS can NOT relaunch a closed app for the plugin's connection. The
// keeper is a second, tiny central in the Runner target WITH a restore identifier. It holds a connection to the same
// radio and subscribes to its notify characteristic; if iOS closes the app and the radio sends something, iOS relaunches
// the app for the keeper, Dart starts, and LaunchReconnect brings the real link back. The keeper stores nothing but
// counters and timestamps; it reads no message.
//
// Whether this really relaunches the app is UNPROVEN until Andy's device matrix says so.
import 'package:flutter/services.dart';

abstract class IosWakeKeeper {
  /// Arms the keeper for this radio (CoreBluetooth peripheral identifier = RadioDevice.id on iOS).
  Future<void> arm(String peripheralId);

  /// Releases the keeper's connection. MUST be called whenever the person disconnects or hands the radio over, or the
  /// keeper would keep the radio's single Bluetooth slot busy.
  Future<void> disarm();

  /// Facts the native side recorded, including while Dart was not running: lines of "epoch_ms kind detail".
  Future<KeeperReport> report();
  Future<void> clearReport();
}

class KeeperReport {
  final bool armed;

  /// True when this process was started by iOS state restoration (willRestoreState fired before Dart started).
  final bool launchedByRestore;
  final int notificationsWhileAway;
  final List<String> lines;
  const KeeperReport({this.armed = false, this.launchedByRestore = false, this.notificationsWhileAway = 0, this.lines = const []});
}

class MethodChannelIosWakeKeeper implements IosWakeKeeper {
  static const _c = MethodChannel('app.meshsonar/ble_wake');

  @override
  Future<void> arm(String peripheralId) async {
    try {
      await _c.invokeMethod<void>('arm', peripheralId);
    } on MissingPluginException {
      // not iOS
    }
  }

  @override
  Future<void> disarm() async {
    try {
      await _c.invokeMethod<void>('disarm');
    } on MissingPluginException {
      // not iOS
    }
  }

  @override
  Future<KeeperReport> report() async {
    try {
      final m = await _c.invokeMapMethod<String, Object?>('report');
      if (m == null) return const KeeperReport();
      return KeeperReport(
        armed: m['armed'] == true,
        launchedByRestore: m['launchedByRestore'] == true,
        notificationsWhileAway: (m['notificationsWhileAway'] as int?) ?? 0,
        lines: ((m['lines'] as List?) ?? const []).cast<String>(),
      );
    } on MissingPluginException {
      return const KeeperReport();
    }
  }

  @override
  Future<void> clearReport() async {
    try {
      await _c.invokeMethod<void>('clearReport');
    } on MissingPluginException {
      // not iOS
    }
  }
}

class NoWakeKeeper implements IosWakeKeeper {
  const NoWakeKeeper();
  @override
  Future<void> arm(String peripheralId) async {}
  @override
  Future<void> disarm() async {}
  @override
  Future<KeeperReport> report() async => const KeeperReport();
  @override
  Future<void> clearReport() async {}
}
