// BLE transport to a MeshCore companion radio using flutter_blue_plus. The only Flutter-dependent radio file.
//
// Mirrors MeshCore Open (MIT, © 2025 zjs81), lib/connector/meshcore_connector.dart + meshcore_uuids.dart:
// scan filtered on the Nordic-UART-style MeshCore service UUID, connect, request MTU 185 where the platform supports it
// (not web/Linux), discover services, subscribe to TX notifications, write frames to RX (without response when the
// characteristic allows it). UUIDs also in MeshCore firmware docs/companion_protocol.md "BLE Connection".
// One BLE write = one companion frame; one notification = one frame.
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'radio_api.dart';

abstract final class MeshCoreBleUuids {
  static const service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // app → radio (write)
  static const tx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // radio → app (notify)
}

class BleRadioScanner implements RadioScanner {
  final Map<String, BluetoothDevice> _seen = {};

  BleRadioScanner();

  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) async* {
    if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    final found = <String, RadioDevice>{};
    final out = StreamController<List<RadioDevice>>();
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        final id = r.device.remoteId.str;
        _seen[id] = r.device;
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : (r.device.platformName.isNotEmpty ? r.device.platformName : id);
        found[id] = RadioDevice(id: id, name: name, rssi: r.rssi);
      }
      if (!out.isClosed) out.add(found.values.toList());
    }, onError: (Object e) {
      if (!out.isClosed) out.addError(e);
    });
    try {
      await FlutterBluePlus.startScan(withServices: [Guid(MeshCoreBleUuids.service)], timeout: timeout);
    } catch (e) {
      await sub.cancel();
      rethrow;
    }
    // startScan completes immediately; the scan stops itself after [timeout].
    unawaited(Future<void>.delayed(timeout + const Duration(milliseconds: 200)).then((_) async {
      await sub.cancel();
      await out.close();
    }));
    yield* out.stream;
  }

  @override
  Future<ByteTransport> connect(RadioDevice device) async {
    final d = _seen[device.id] ?? BluetoothDevice.fromId(device.id);
    if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    // flutter_blue_plus 2.x is NOT MIT: it is under the FlutterBluePlus License (free for personal / nonprofit /
    // educational use; any for-profit use needs a paid licence; it may send build-time licence telemetry). `nonprofit`
    // matches MeshCore Open. Whoever ships MeshSonar must confirm this is the right choice — see THIRD_PARTY_NOTICES.md.
    await d.connect(license: License.nonprofit, timeout: const Duration(seconds: 15), mtu: null);
    try {
      if (!kIsWeb && !Platform.isLinux) {
        try {
          await d.requestMtu(185);
        } catch (_) {
          // keep the default MTU
        }
      }
      final services = await d.discoverServices();
      BluetoothCharacteristic? rx, tx;
      for (final s in services) {
        if (s.uuid.str128.toLowerCase() != MeshCoreBleUuids.service) continue;
        for (final c in s.characteristics) {
          final u = c.uuid.str128.toLowerCase();
          if (u == MeshCoreBleUuids.rx) rx = c;
          if (u == MeshCoreBleUuids.tx) tx = c;
        }
      }
      if (rx == null || tx == null) throw StateError('Not a MeshCore companion (UART service not found)');
      final t = _BleTransport(d, rx, tx);
      await t._init();
      return t;
    } catch (_) {
      try {
        await d.disconnect();
      } catch (_) {}
      rethrow;
    }
  }
}

class _BleTransport implements ByteTransport {
  final BluetoothDevice _device;
  final BluetoothCharacteristic _rx;
  final BluetoothCharacteristic _tx;
  final _incoming = StreamController<Uint8List>.broadcast();
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;
  bool _connected = true;

  _BleTransport(this._device, this._rx, this._tx);

  Future<void> _init() async {
    _notifySub = _tx.onValueReceived.listen((v) {
      if (v.isNotEmpty && !_incoming.isClosed) _incoming.add(Uint8List.fromList(v));
    });
    _device.cancelWhenDisconnected(_notifySub!);
    await _tx.setNotifyValue(true);
    _stateSub = _device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected) _closed();
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
    final noResp = _rx.properties.writeWithoutResponse;
    await _rx.write(frame, withoutResponse: noResp);
  }

  @override
  Future<void> disconnect() async {
    _closed();
    try {
      await _device.disconnect();
    } catch (_) {}
  }
}
