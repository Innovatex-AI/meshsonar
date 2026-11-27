// BLE transport to a MeshCore companion radio using flutter_reactive_ble (BSD-3-Clause). The only Flutter-dependent
// radio file.
//
// Mirrors MeshCore Open (MIT, © 2025 zjs81), lib/connector/meshcore_connector.dart + meshcore_uuids.dart:
// scan filtered on the Nordic-UART-style MeshCore service UUID, connect, request MTU 185 where the platform supports it,
// discover services, subscribe to TX notifications, write frames to RX with response (confirmed) whenever the
// characteristic allows it (radio_api.dart planBleWrite). UUIDs also in MeshCore firmware docs/companion_protocol.md "BLE Connection".
// One BLE write = one companion frame; one notification = one frame.
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'radio_api.dart';

abstract final class MeshCoreBleUuids {
  static const service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rx =
      '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // app → radio (write)
  static const tx =
      '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // radio → app (notify)
}

class BleRadioScanner implements RadioScanner {
  final FlutterReactiveBle _ble;

  BleRadioScanner([FlutterReactiveBle? ble])
    : _ble = ble ?? FlutterReactiveBle();

  /// The phone's Bluetooth state, or throws a message the Connect screen understands (permission / off / unsupported).
  Future<void> _requireReady() async {
    final st = await _ble.statusStream
        .firstWhere((s) => s != BleStatus.unknown)
        .timeout(const Duration(seconds: 3), onTimeout: () => BleStatus.ready);
    switch (st) {
      case BleStatus.unauthorized:
        throw StateError('Bluetooth permission denied');
      case BleStatus.poweredOff:
        throw StateError('Bluetooth is off');
      case BleStatus.unsupported:
        throw StateError('Bluetooth is not supported on this device');
      case BleStatus.locationServicesDisabled:
        throw StateError(
          'Location services are off (Android needs them to scan for Bluetooth devices)',
        );
      case BleStatus.ready:
      case BleStatus.unknown:
        return;
    }
  }

  @override
  Stream<List<RadioDevice>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async* {
    await _requireReady();
    final found = <String, RadioDevice>{};
    late final StreamController<List<RadioDevice>> out;
    StreamSubscription<DiscoveredDevice>? sub;
    Timer? stop;
    Future<void> finish() async {
      stop?.cancel();
      await sub?.cancel();
      if (!out.isClosed) await out.close();
    }

    out = StreamController<List<RadioDevice>>(onCancel: finish);
    sub = _ble
        .scanForDevices(
          withServices: [Uuid.parse(MeshCoreBleUuids.service)],
          scanMode: ScanMode.lowLatency,
        )
        .listen(
          (d) {
            found[d.id] = RadioDevice(
              id: d.id,
              name: d.name.isNotEmpty ? d.name : d.id,
              rssi: d.rssi,
            );
            if (!out.isClosed) out.add(found.values.toList());
          },
          onError: (Object e) {
            if (!out.isClosed) out.addError(e);
          },
        );
    // The scan runs until cancelled; it stops itself after [timeout].
    stop = Timer(timeout, finish);
    yield* out.stream;
  }

  @override
  Future<ByteTransport> connect(RadioDevice device) async {
    await _requireReady();
    final connected = Completer<void>();
    final state =
        StreamController<bool>.broadcast(); // true = connected, false = gone
    final sub = _ble
        .connectToDevice(
          id: device.id,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen(
          (u) {
            switch (u.connectionState) {
              case DeviceConnectionState.connected:
                if (!connected.isCompleted) connected.complete();
                state.add(true);
              case DeviceConnectionState.disconnected:
                if (!connected.isCompleted) {
                  connected.completeError(StateError('Could not connect to ${device.name}'));
                }
                state.add(false);
              case DeviceConnectionState.connecting:
              case DeviceConnectionState.disconnecting:
                break;
            }
          },
          onError: (Object e) {
            if (!connected.isCompleted) connected.completeError(e);
            state.add(false);
          },
        );
    Future<void> abort() async {
      await sub.cancel(); // cancelling the connection stream is how reactive_ble disconnects
      await state.close();
    }

    try {
      await connected.future.timeout(const Duration(seconds: 20));
      // The size one write may have. Android: ask for a large MTU (the radio offers 176, MAX_FRAME_SIZE); a write carries
      // MTU - 3 bytes. iOS negotiates by itself; the plugin's requestMtu then only REPORTS the largest write it allows.
      int? maxWrite;
      try {
        final got = await _ble.requestMtu(deviceId: device.id, mtu: 185);
        if (got > 0) maxWrite = Platform.isAndroid ? got - 3 : got;
      } catch (_) {
        // unknown: frames go out as they are
      }
      await _ble.discoverAllServices(device.id);
      final services = await _ble.getDiscoveredServices(device.id);
      Characteristic? rx, tx;
      for (final s in services) {
        if (s.id.toString().toLowerCase() != MeshCoreBleUuids.service) continue;
        for (final c in s.characteristics) {
          final u = c.id.toString().toLowerCase();
          if (u == MeshCoreBleUuids.rx) rx = c;
          if (u == MeshCoreBleUuids.tx) tx = c;
        }
      }
      if (rx == null || tx == null) {
        throw StateError('Not a MeshCore companion (UART service not found)');
      }
      final t = _BleTransport(rx, tx, sub, state, maxWrite);
      t._init();
      return t;
    } catch (_) {
      await abort();
      rethrow;
    }
  }
}

class _BleTransport implements ByteTransport {
  final Characteristic _rx;
  final Characteristic _tx;
  final StreamSubscription<ConnectionStateUpdate> _connection;
  final StreamController<bool> _state;
  final _incoming = StreamController<Uint8List>.broadcast();
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<bool>? _stateSub;
  bool _connected = true;

  /// Largest frame one write carries on this link; null when the platform did not say.
  final int? _maxWrite;

  _BleTransport(this._rx, this._tx, this._connection, this._state, this._maxWrite);

  void _init() {
    _notifySub = _tx.subscribe().listen((v) {
      if (v.isNotEmpty && !_incoming.isClosed) _incoming.add(Uint8List.fromList(v));
    }, onError: (Object _) => _closed());
    _stateSub = _state.stream.listen((up) {
      if (!up) _closed();
    });
  }

  void _closed() {
    if (!_connected) return;
    _connected = false;
    _notifySub?.cancel();
    _stateSub?.cancel();
    _incoming.close();
  }

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> send(Uint8List frame) async {
    if (!_connected) throw StateError('radio disconnected');
    // Confirmed writes (round 3 rule 3): build 76 wrote without response whenever the radio allowed it, so a frame the
    // link dropped was never noticed. A frame longer than the link carries is refused here instead of vanishing.
    final confirmed = planBleWrite(
        frameBytes: frame.length,
        canWriteWithResponse: _rx.isWritableWithResponse,
        canWriteWithoutResponse: _rx.isWritableWithoutResponse,
        maxWriteBytes: _maxWrite);
    await _rx.write(frame, withResponse: confirmed);
  }

  @override
  Future<void> disconnect() async {
    _closed();
    try {
      await _connection.cancel();
      await _state.close();
    } catch (_) {}
  }
}
