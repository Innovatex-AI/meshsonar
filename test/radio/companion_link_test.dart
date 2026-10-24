import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/simulator.dart';

void main() {
  late SimulatedTransport radio;
  late MeshCoreCompanionLink link;

  setUp(() {
    radio = SimulatedTransport(
      seed: 1,
      timeScale: 50,
      location: SimulatedLocationSource(speedMps: 0), // parked in Uptown, ~200 m from a repeater
    );
    link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
  });

  tearDown(() => link.close());

  test('start: APP_START, DEVICE_QUERY, SET_DEVICE_TIME; SelfInfo from the radio', () async {
    final self = await link.start();
    expect(self.name, 'MeshSonar Sim');
    expect(self.publicKey, toHex(radio.publicKey));
    expect(self.publicKey.length, 64);
    expect(self.radio.freqMhz, closeTo(910.525, 1e-9));
    expect(self.radio.bwKhz, closeTo(62.5, 1e-9));
    expect(self.radio.sf, 7);
    expect(self.radio.cr, 5);
    expect(self.radio.txDbm, 22);
    expect(self.firmware, 'v1.18.0-sim');
    expect(link.firmwareVerCode, 9);
    expect(radio.sentFrames.take(3).map((f) => f[0]).toList(), [Cmd.appStart, Cmd.deviceQuery, Cmd.setDeviceTime]);
  });

  test('ensureChannel installs #wardriving in the first empty slot with sha256 key, then finds it', () async {
    await link.start();
    final idx = await link.ensureChannel('#wardriving');
    expect(idx, 1); // slot 0 is Public
    final set = radio.sentFrames.lastWhere((f) => f[0] == Cmd.setChannel);
    expect(set.length, 50);
    expect(set[1], 1);
    expect(set.sublist(34, 50), hashtagChannelSecret('#wardriving'));
    expect(link.channelSecret(1), hashtagChannelSecret('#wardriving'));

    final before = radio.sentFrames.where((f) => f[0] == Cmd.setChannel).length;
    expect(await link.ensureChannel('#wardriving'), 1);
    expect(radio.sentFrames.where((f) => f[0] == Cmd.setChannel).length, before, reason: 'no second write');
    expect(await link.ensureChannel('Public'), 0);
  });

  test('ensureChannel: unknown private channel name → clear error', () async {
    await link.start();
    expect(() => link.ensureChannel('Family'), throwsA(isA<CompanionException>()));
  });

  test('sendChannelText sends the real frame and RX log pushes arrive as RxPackets', () async {
    await link.start();
    final idx = await link.ensureChannel('#wardriving');
    final heard = <MeshPacket>[];
    final sub = link.rxPackets.listen((rx) {
      expect(rx.snrDb, isNotNull);
      expect(rx.rssiDbm, isNotNull);
      heard.add(MeshPacket.tryParse(rx.raw)!);
    });
    await link.sendChannelText(idx, 'hello mesh');
    final f = radio.sentFrames.last;
    expect(f.sublist(0, 3), [Cmd.sendChannelTxtMsg, 0, idx]);
    expect(String.fromCharCodes(f.sublist(7)), 'hello mesh');
    final ts = ByteData.sublistView(f).getUint32(3, Endian.little);
    expect(link.lastSentTimestamp, ts);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
    final echoes = heard
        .map((p) => matchEcho(p, hashtagChannelSecret('#wardriving'), 'hello mesh', timestamp: ts))
        .whereType<EchoMatch>()
        .toList();
    expect(echoes, isNotEmpty, reason: 'parked 200 m from a repeater');
  });

  test('timestamps of consecutive sends are strictly increasing', () async {
    await link.start();
    await link.sendChannelText(0, 'a');
    final t1 = link.lastSentTimestamp;
    await link.sendChannelText(0, 'b');
    expect(link.lastSentTimestamp, greaterThan(t1));
  });

  test('noiseFloor from STATS radio; null when firmware has no stats', () async {
    await link.start();
    final nf = await link.noiseFloor();
    expect(nf, inInclusiveRange(-114, -110));

    final old = SimulatedTransport(seed: 2, timeScale: 50, noiseFloorDbm: null);
    final l2 = MeshCoreCompanionLink(old);
    await l2.start();
    expect(await l2.noiseFloor(), isNull);
    await l2.close();
  });

  test('radio health: core, radio, packets and battery+storage over the real protocol (simulator)', () async {
    await link.start();
    final idx = await link.ensureChannel('#wardriving');
    await link.sendChannelText(idx, 'MS:abcdefghij');
    final core = await link.coreStats();
    expect(core!.batteryMv, inInclusiveRange(3400, 4100));
    expect(core.errFlags, 0);
    expect(core.queueLen, 0);
    final pk = await link.packetStats();
    expect(pk!.sent, 1);
    expect(pk.floodTx, 1);
    expect(pk.recvErrors, 0);
    final rs = await link.radioStats();
    expect(rs!.noiseFloorDbm, inInclusiveRange(-114, -110));
    final bs = await link.batteryAndStorage();
    expect(bs!.storageUsedKb, 120);
    expect(bs.storageTotalKb, 1984);
    final cmds = radio.sentFrames.map((f) => f[0]).toList();
    expect(cmds.where((c) => c == Cmd.getStats), hasLength(3));
    expect(cmds.last, Cmd.getBattAndStorage);
  });

  test('radio health: firmware without GET_STATS is asked once, then never again; battery still read', () async {
    final old = SimulatedTransport(seed: 2, timeScale: 50, noiseFloorDbm: null);
    final l2 = MeshCoreCompanionLink(old);
    await l2.start();
    expect(await l2.coreStats(), isNull);
    expect(await l2.packetStats(), isNull);
    expect(await l2.radioStats(), isNull);
    expect(await l2.noiseFloor(), isNull);
    expect(old.sentFrames.where((f) => f[0] == Cmd.getStats), hasLength(1));
    expect((await l2.batteryAndStorage())!.batteryMv, greaterThan(0));
    await l2.close();
    expect(await l2.coreStats(), isNull, reason: 'closed link: null, no throw');
  });

  test('a radio that never answers times out', () async {
    radio.responsive = false;
    final quick = MeshCoreCompanionLink(radio, timeout: const Duration(milliseconds: 100));
    await expectLater(quick.start(), throwsA(isA<TimeoutException>()));
  });

  test('disconnect fails the pending command and closes the RX stream', () async {
    await link.start();
    final done = Completer<void>();
    link.rxPackets.listen((_) {}, onDone: done.complete);
    radio.responsive = false;
    final pending = link.getChannel(0);
    radio.simulateDisconnect();
    await expectLater(pending, throwsA(isA<StateError>()));
    await done.future.timeout(const Duration(seconds: 1));
    expect(link.isConnected, isFalse);
    await expectLater(link.sendChannelText(0, 'x'), throwsA(isA<StateError>()));
  });

  test('scanner lists the simulator and connects', () async {
    final s = SimulatedRadioScanner(timeScale: 50);
    final list = await s.scan().first;
    expect(list.single.name, 'MeshSonar Simulator');
    final t = await s.connect(list.single);
    expect(t.isConnected, isTrue);
    await t.disconnect();
  });
}
