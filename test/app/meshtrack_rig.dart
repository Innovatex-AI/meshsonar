// Shared fakes for the MeshTrack wiring tests (test/app/meshtrack_wiring_test.dart): a real chat store + ChatService +
// ChannelAdmin over a fake radio, a real TxArbiter, in-memory Keychain, settings and last-known file, on fake time.

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:meshsonar/app/meshtrack_wiring.dart';
import 'package:meshsonar/chat/channel_admin.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/core/api.dart' show MeshTrackSettings;
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';

import '../chat/support.dart';

const radioB = 'bb00000000000000000000000000000000000000000000000000000000000002';
final mtT0 = DateTime.utc(2026, 11, 16, 12);

class FakeRadioSlots implements ChannelRadio {
  final List<RadioSlot> slotList;
  int writes = 0;
  @override
  final int? maxChannels;
  FakeRadioSlots(int n)
      : slotList = List.generate(n, (i) => RadioSlot(i, '', Uint8List(16))),
        maxChannels = n {
    put(0, 'Public', publicChannelSecret16);
  }

  void put(int i, String name, List<int> secret) => slotList[i] = RadioSlot(i, name, Uint8List.fromList(secret));
  void clearSlot(int i) => slotList[i] = RadioSlot(i, '', Uint8List(16));
  int get used => slotList.where((s) => !s.isEmpty).length;
  RadioSlot? withSecret(List<int> secret) =>
      slotList.where((s) => !s.isEmpty && listEquals(s.secret, Uint8List.fromList(secret))).firstOrNull;

  @override
  Future<List<RadioSlot>> slots() async => List.of(slotList);
  @override
  Future<void> write(int slot, String name, Uint8List secret16) async {
    writes++;
    slotList[slot] = RadioSlot(slot, name, Uint8List.fromList(secret16));
  }

  @override
  Future<void> clear(int slot) async => clearSlot(slot);
}

class MemLastKnown implements MtLastKnownStore {
  String? data;
  int clears = 0;
  @override
  Future<String?> read() async => data;
  @override
  Future<void> write(String json) async => data = json;
  @override
  Future<void> clear() async {
    clears++;
    data = null;
  }
}

class FakeFixes implements LocationSource {
  final List<void Function(GeoFix)> _l = [];
  int listens = 0;
  late final Stream<GeoFix> _s = Stream<GeoFix>.multi((c) {
    listens++;
    void f(GeoFix x) => c.add(x);
    _l.add(f);
    c.onCancel = () => _l.remove(f);
  });
  bool get listening => _l.isNotEmpty;
  void add(GeoFix f) {
    for (final l in List.of(_l)) {
      l(f);
    }
  }

  @override
  Stream<GeoFix> get fixes => _s;
  @override
  Future<GeoFix?> current() async => null;
  @override
  Future<bool> ensurePermission() async => true;
}

class Pulse extends ChangeNotifier {
  void pulse() => notifyListeners();
}

/// The world of one phone. [store] / [keychain] / [settings] can be carried into a second rig (restart, reinstall).
class MtRig {
  final FakeAsync a;
  final Harness h;
  final Map<String, FakeRadioSlots> radios;
  String radioId;
  bool connected = true;
  final Pulse changes = Pulse();
  final SecretStore keychain;
  MeshTrackSettings settings;
  final MemLastKnown lastKnown;
  final FakeFixes phone = FakeFixes();
  PrivacyZones zones = const PrivacyZones([]);
  final logs = <String>[];
  late final TxArbiter arbiter = TxArbiter(clock: now);
  late final ChannelAdmin admin;
  late final MeshTrackWiring w;
  final events = <MtEvent>[];

  MtRig(this.a,
      {Harness? harness,
      Map<String, FakeRadioSlots>? radios,
      this.radioId = radioA,
      SecretStore? keychain,
      MeshTrackSettings? settings,
      MemLastKnown? lastKnown,
      bool start = true})
      : h = harness ?? Harness(),
        radios = radios ?? {radioA: FakeRadioSlots(4)},
        keychain = keychain ?? InMemorySecretStore(),
        settings = settings ?? const MeshTrackSettings(),
        lastKnown = lastKnown ?? MemLastKnown() {
    admin = ChannelAdmin(
        store: h.store, radio: () => connected ? this.radios[radioId] : null, wardriveChannelName: () => '#wardriving', onChanged: changes.pulse);
    w = MeshTrackWiring(
      zones: () => zones,
      readSettings: () => this.settings,
      writeSettings: (s) async => this.settings = s,
      keychain: this.keychain,
      lastKnown: this.lastKnown,
      wardriveChannelName: () => '#wardriving',
      phoneLocation: () => phone,
      log: logs.add,
      now: now,
    );
    w.service.events.listen(events.add);
    if (start) boot();
  }

  DateTime now() => mtT0.add(a.elapsed);
  FakeRadioSlots get radio => radios[radioId]!;
  MeshTrackService get svc => w.service;
  MeshTrackGroupOps get ops => w.groups;

  /// The order AppState uses: wiring start, chat bound, arbiter door, radio state.
  void boot() {
    w.setTrackGate(arbiter);
    w.setRadioConnected(connected);
    w.bindChat(binding());
    w.start();
    settle();
  }

  MtChatBinding binding() => MtChatBinding(
      store: h.store, service: h.service, admin: admin, radioId: () => radioId, radioConnected: () => connected, changes: changes);

  void settle([Duration d = const Duration(milliseconds: 20)]) {
    for (var i = 0; i < 6; i++) {
      a.flushMicrotasks();
      a.elapse(d);
    }
    a.flushMicrotasks();
  }

  /// Syncs the phone's rows with the radio (what ChatController does on connect), then tells the wiring.
  void syncFromRadio() {
    admin.syncFromRadio(radioId);
    settle();
  }

  void connect(String id) {
    radioId = id;
    connected = true;
    admin.syncFromRadio(id);
    settle();
    w.setRadioConnected(true);
    settle();
  }

  void disconnect() {
    connected = false;
    w.setRadioConnected(false);
    settle();
  }

  GeoFix fix({double lat = 40.1, double lon = -82.9, double acc = 5, double speedMps = 15, double course = 90}) =>
      GeoFix(lat: lat, lon: lon, accuracyM: acc, speedMps: speedMps, courseDeg: course, at: now());

  /// Sent MeshTrack texts (slot, text).
  List<({int slot, String text, int ts})> get sent => h.sink.channels;

  Future<int> group(String name) async {
    final r = await ops.createGroup(name);
    if (!r.ok) throw StateError('createGroup: $r ${r.message}');
    return r.channelId!;
  }

  int groupSync(String name) {
    int? id;
    group(name).then((v) => id = v);
    settle();
    return id!;
  }

  void inbound(int slot, String text, {int? ts}) {
    h.clock.ms = now().millisecondsSinceEpoch; // chat's receive clock follows fake time
    h.service.handleInbound(InboundChannelText(radioId: radioId, channelSlot: slot, timestamp: ts ?? now().millisecondsSinceEpoch ~/ 1000, text: text, snr: 6, pathLen: 1, rssi: -90));
  }

  Channel channel(int id) => h.store.channels.getById(id)!;
}
