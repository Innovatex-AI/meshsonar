import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/ble_transport_universal.dart';
import 'package:meshsonar/radio/radio_api.dart';

class _Scanner implements RadioScanner {
  final String name;
  final calls = <String>[];
  _Scanner(this.name);
  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) {
    calls.add('scan');
    return const Stream.empty();
  }

  @override
  Future<ByteTransport> connect(RadioDevice device) async {
    calls.add('connect ${device.id}');
    throw StateError('stop here');
  }
}

void main() {
  test('the switchable scanner follows the choice at each call, default is the proven engine', () async {
    final a = _Scanner('reactive');
    final b = _Scanner('universal');
    var universal = false;
    final s = SwitchableRadioScanner(reactive: a, universal: b, useUniversal: () => universal);
    await s.scan().toList();
    universal = true;
    await s.scan().toList();
    await s.connect(const RadioDevice(id: 'x', name: 'n')).catchError((Object _) => throw StateError('x')).then((_) {}, onError: (_) {});
    expect(a.calls, ['scan']);
    expect(b.calls, ['scan', 'connect x']);
  });

  test('the engine choice is a file; no file means flutter_reactive_ble; survives a restart', () async {
    final dir = await Directory.systemTemp.createTemp('engine');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/ble_engine.txt');
    await BleEngineChoice.load(f);
    expect(BleEngineChoice.universal, isFalse);
    await BleEngineChoice.set(true);
    expect(f.existsSync(), isTrue);
    BleEngineChoice.universal = false;
    await BleEngineChoice.load(f);
    expect(BleEngineChoice.universal, isTrue);
    await BleEngineChoice.set(false);
    expect(f.existsSync(), isFalse);
    await BleEngineChoice.load(f);
    expect(BleEngineChoice.universal, isFalse);
  });
}
