// MeshTrack in AppState (MT-5): flag off = nothing built; flag on = one wiring, chat bound (tap + arbiter door), radio
// state, drive start/stop, drive fixes routed, Delete my data, dispose.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/app/meshtrack_wiring.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../ui/fakes.dart';
import 'meshtrack_rig.dart' show MemLastKnown;

Future<void> pump([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  tearDown(() {
    AppFlags.debugMeshTrack = null;
    ChatWiring.controller.value = null;
  });

  test('flag off: nothing is constructed (no engine, no group ops)', () async {
    AppFlags.debugMeshTrack = false;
    final h = Harness();
    await h.state.init();
    expect(h.state.meshTrack, isNull);
    expect(h.state.meshTrackGroups, isNull);
    expect(h.state.meshTrackWiring, isNull);
    expect(await h.state.clearMeshTrackLocal(), 0);
    h.state.dispose();
  });

  test('flag on: one wiring; chat bound with the tap and the arbiter door; drive start/stop and fixes reach it', () async {
    AppFlags.debugMeshTrack = true;
    expect(AppFlags.meshTrack, isTrue, reason: 'ON by default in build 67');
    final h = Harness();
    final last = MemLastKnown();
    h.state.meshTrackLastKnownOverride = last;
    await h.state.init();
    final mt = h.state.meshTrack!;
    expect(h.state.meshTrackGroups, isNotNull);

    // Chat opens (ChatWiring.attach does this in the app).
    final store = ChatStore.inMemory();
    final service = ChatService(store: store);
    final ctl = ChatController(store: store, service: service, sink: SwitchableSink(), wardriveChannelName: () => '#wardriving');
    ChatWiring.controller.value = ctl;
    await pump();
    expect(identical(service.trackGate, h.state.radioSessions.arbiter), isTrue);

    expect(await h.state.connectSimulator(), isTrue);
    await pump();
    expect(mt.state.radioConnected, isTrue);

    final radio = h.state.selfInfo!.publicKey.toLowerCase();
    ctl.debugUseRadio(radio);
    final ch = await store.channels.save(Channel(radioId: radio, slot: 1, name: 'Family', kind: ChannelKind.private),
        secret: Uint8List.fromList(List<int>.generate(16, (i) => 0x70 + i)));
    mt.addGroup(ch.id!, 'Family');
    await pump();
    expect(mt.setShare(ch.id!, true), MtResult.ok);
    expect(mt.state.reason, MtShareReason.waitingForDrive);

    await h.state.startDrive();
    expect(h.state.driving, isTrue);
    expect(mt.state.driving, isTrue);
    expect(mt.state.reason, MtShareReason.waitingForGps);
    h.simLocation.fixController.add(GeoFix(lat: 40.1, lon: -82.9, accuracyM: 5, speedMps: 12, courseDeg: 90, at: h.clockNow));
    await pump();
    expect(mt.state.reason, MtShareReason.sharing, reason: 'the drive fix reached MeshTrack and passed the gates');

    h.engines.last.setStatus(const EngineStatus(EngineState.pinging));
    await pump();

    await h.state.stopDrive();
    expect(mt.state.driving, isFalse);
    expect(mt.state.group(ch.id!)!.config.share, isFalse, reason: '"This drive" ended with the drive');

    expect(await h.state.clearMeshTrackLocal(), 1);
    expect(mt.state.groups, isEmpty);
    expect(h.state.settings.meshtrack.groups, isEmpty);

    h.state.dispose();
    await pump();
    expect(service.trackGate, isNull, reason: 'unbound at dispose');
  });

  test('a settings screen saving an older copy never rolls meshtrack.* back', () async {
    AppFlags.debugMeshTrack = true;
    final h = Harness();
    await h.state.init();
    final before = h.state.settings;
    await h.state.meshTrackGroups!.setRate(MtRate.lowTraffic);
    await h.state.updateSettings(before.copyWith(intervalSec: 45));
    expect(h.state.settings.meshtrack.lowTraffic, isTrue);
    expect(h.state.settings.intervalSec, 45);
    h.state.dispose();
  });
}
