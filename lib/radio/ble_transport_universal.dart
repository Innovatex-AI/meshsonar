// EXPERIMENTAL second BLE engine on `universal_ble` (BSD-3-Clause, Navideck), for spike S1 (docs/BACKGROUND_BLE_SPIKE.md).
//
// Why it exists: flutter_reactive_ble has no CoreBluetooth state restoration (see the spike doc). universal_ble 3.1.0 documents
// and implements it: with the `bluetooth-central` background mode and Bluetooth permission granted, its CBCentralManager is
// created at launch with a restore identifier, `willRestoreState` re-adopts connected peripherals, and `onConnectionChanged`
// is emitted for them (darwin/.../UniversalBlePlugin.swift:609). That is the piece our current plugin lacks.
//
// Status: OFF by default. Written from the package source and README; NOT run on a device. Andy's device matrix decides
// whether it replaces flutter_reactive_ble (decision D2 in the design doc). Same contract as ble_transport.dart: scan filtered
// on the MeshCore UART service, connect, discover, subscribe to TX, write RX; one notification = one frame.
import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'ble_transport.dart' show MeshCoreBleUuids;
import 'radio_api.dart';

class UniversalBleRadioScanner implements RadioScanner {
  Future<void> _requireReady() async {
    final st = await UniversalBle.getBluetoothAvailabilityState();
    switch (st) {
      case AvailabilityState.unauthorized:
        throw StateError('Bluetooth permission denied');
      case AvailabilityState.poweredOff:
        throw StateError('Bluetooth is off');
      case AvailabilityState.unsupported:
        throw StateError('Bluetooth is not supported on this device');
      default:
        return;
    }
  }

  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) async* {
    await _requireReady();
    final found = <String, RadioDevice>{};
    late final StreamController<List<RadioDevice>> out;
    StreamSubscription<BleDevice>? sub;
    Timer? stop;
    Future<void> finish() async {
      stop?.cancel();
      await sub?.cancel();
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
      if (!out.isClosed) await out.close();
    }

    out = StreamController<List<RadioDevice>>(onCancel: finish);
    sub = UniversalBle.scanStream.listen((d) {
      final name = (d.name ?? '').isNotEmpty ? d.name! : d.deviceId;
      found[d.deviceId] = RadioDevice(id: d.deviceId, name: name, rssi: d.rssi);
      if (!out.isClosed) out.add(found.values.toList());
    }, onError: (Object e) {
      if (!out.isClosed) out.addError(e);
    });
    await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [MeshCoreBleUuids.service]));
    stop = Timer(timeout, finish);
    yield* out.stream;
  }

  @override
  Future<ByteTransport> connect(RadioDevice device) async {
    await _requireReady();
    final id = device.id;
    try {
      await UniversalBle.connect(id, timeout: const Duration(seconds: 20));
      if (Platform.isAndroid) {
        try {
          await UniversalBle.requestMtu(id, 185);
        } catch (_) {}
      }
      final services = await UniversalBle.discoverServices(id);
      BleCharacteristic? rx, tx;
      for (final s in services) {
        if (s.uuid.toLowerCase() != MeshCoreBleUuids.service) continue; // universal_ble normalises to 128-bit lower case
        for (final c in s.characteristics) {
          final u = c.uuid.toLowerCase();
          if (u == MeshCoreBleUuids.rx) rx = c;
          if (u == MeshCoreBleUuids.tx) tx = c;
        }
      }
      if (rx == null || tx == null) throw StateError('Not a MeshCore companion (UART service not found)');
      final t = _UniversalTransport(id, rx.properties.contains(CharacteristicProperty.writeWithoutResponse));
      await t._init();
      return t;
    } catch (_) {
      try {
        await UniversalBle.disconnect(id);
      } catch (_) {}
      rethrow;
    }
  }
}

class _UniversalTransport implements ByteTransport {
  final String _id;
  final bool _noResponse;
  final _incoming = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _valueSub;
  StreamSubscription<bool>? _stateSub;
  bool _connected = true;

  _UniversalTransport(this._id, this._noResponse);

  Future<void> _init() async {
    _valueSub = UniversalBle.characteristicValueStream(_id, MeshCoreBleUuids.tx).listen((v) {
      if (v.isNotEmpty && !_incoming.isClosed) _incoming.add(Uint8List.fromList(v));
    }, onError: (Object _) => _closed());
    _stateSub = UniversalBle.connectionStream(_id).listen((up) {
      if (!up) _closed();
    });
    await UniversalBle.subscribeNotifications(_id, MeshCoreBleUuids.service, MeshCoreBleUuids.tx);
  }

  void _closed() {
    if (!_connected) return;
    _connected = false;
    _valueSub?.cancel();
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
    await UniversalBle.write(_id, MeshCoreBleUuids.service, MeshCoreBleUuids.rx, frame, withoutResponse: _noResponse);
  }

  @override
  Future<void> disconnect() async {
    _closed();
    try {
      await UniversalBle.unsubscribe(_id, MeshCoreBleUuids.service, MeshCoreBleUuids.tx);
    } catch (_) {}
    try {
      await UniversalBle.disconnect(_id);
    } catch (_) {}
  }
}

/// Which BLE engine the next scan/connect uses. A one-word file next to the other app data; read once at start.
/// Default (no file) is flutter_reactive_ble.
class BleEngineChoice {
  BleEngineChoice._();
  static bool universal = false;
  static File? _file;

  static Future<void> load(File file) async {
    _file = file;
    try {
      universal = await file.exists() && (await file.readAsString()).trim() == 'universal';
    } catch (_) {
      universal = false;
    }
  }

  static Future<void> set(bool useUniversal) async {
    universal = useUniversal;
    try {
      final f = _file;
      if (f == null) return;
      if (useUniversal) {
        await f.writeAsString('universal', flush: true);
      } else if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }
}

/// Picks the engine at each scan/connect, so the Diagnostics switch needs no restart. Default is the proven
/// flutter_reactive_ble scanner.
class SwitchableRadioScanner implements RadioScanner {
  final RadioScanner reactive;
  final RadioScanner universal;
  final bool Function() useUniversal;
  SwitchableRadioScanner({required this.reactive, required this.universal, required this.useUniversal});

  RadioScanner get _s => useUniversal() ? universal : reactive;

  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) => _s.scan(timeout: timeout);

  @override
  Future<ByteTransport> connect(RadioDevice device) => _s.connect(device);
}
