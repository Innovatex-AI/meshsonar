// A small radio world for the MeshTrack people flows (test/flows/meshtrack_people_test.dart, plan section 5.0 U1-U7):
// several phones, each with the REAL app objects (chat store + ChatService + ChannelAdmin over its own fake radio, a real
// TxArbiter, the MeshTrackWiring with its MeshTrackService, an in-memory Keychain, settings and last-known file), and
// stock MeshCore clients (a chat stack with no MeshTrack at all). The "air" delivers every channel message a phone's
// radio sent to every other radio that holds the same channel key, as `name: text` (the firmware's sender prefix): a
// radio without the key cannot read it, exactly like MeshCore channel encryption.
//
// Time is one clock for the whole world ([MtWorld.now]); the caller moves it (fakeAsync or a widget tester) and calls
// [MtWorld.air] to carry what was sent.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:meshsonar/app/meshtrack_wiring.dart';
import 'package:meshsonar/chat/channel_admin.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/core/api.dart' show MeshTrackSettings;
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';

import '../app/meshtrack_rig.dart' show FakeFixes, FakeRadioSlots, MemLastKnown, Pulse;
import '../chat/support.dart' show FakeSink, Harness;

export '../app/meshtrack_rig.dart' show FakeRadioSlots, MemLastKnown;

final DateTime worldT0 = DateTime.utc(2026, 11, 16, 12);

/// A radio id (public key hex) for the [n]th radio in the world.
String radioIdOf(int n) => n.toRadixString(16).padLeft(2, '0') * 32;

/// The radio's send path: records the channel KEY each message went out under (the slot's key at that moment; Start
/// fresh puts a new key in the same slot).
class AirSink extends FakeSink {
  FakeRadioSlots Function()? radio;
  final keys = <Uint8List>[];
  @override
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp, int priority = CommandPriority.user}) async {
    final n = channels.length;
    final key = Uint8List.fromList(radio!().slotList[slot].secret);
    final r = super.sendChannel(radioId: radioId, slot: slot, text: text, timestamp: timestamp, priority: priority); // records synchronously
    if (channels.length > n) keys.add(key);
    return r;
  }
}

Harness airHarness(String name, FakeRadioSlots Function() radio) => Harness.withSink(AirSink()..radio = radio, selfName: name);

/// Anything on the air: it has a radio name, a radio with channels and a chat stack that receives.
abstract class MtNode {
  String get name;
  Harness get h;
  FakeRadioSlots get radio;
  String get radioId;
  bool get connected;
  DateTime Function() get now;
  int _delivered = 0;

  /// The firmware received a channel message on [slot]: it goes to chat (and the MeshTrack tap, if this phone has one).
  void hear(int slot, String text, {int pathLen = 1, double snr = 6}) {
    final t = now();
    h.clock.ms = t.millisecondsSinceEpoch;
    h.service.handleInbound(InboundChannelText(
        radioId: radioId, channelSlot: slot, timestamp: t.millisecondsSinceEpoch ~/ 1000, text: text, snr: snr, pathLen: pathLen, rssi: -90));
  }

  /// Texts this radio sent under the channel key [secret], oldest first.
  List<String> sentOn(List<int> secret) {
    final out = h.sink.channels, keys = (h.sink as AirSink).keys;
    return [for (var i = 0; i < out.length; i++) if (listEquals(keys[i], secret)) out[i].text];
  }

  /// Chat texts on the channel with this key (what a person reads in this app's chat).
  List<String> chatTexts(List<int> secret) {
    final slot = radio.withSecret(secret)?.index;
    if (slot == null) return const [];
    final ch = h.store.channels.list(radioId).where((c) => c.slot == slot).firstOrNull;
    if (ch == null) return const [];
    return [for (final m in h.service.page(ch.convKey).messages) m.text];
  }
}

/// One phone with MeshSonar (the real MeshTrack wiring).
class MtPhone extends MtNode {
  @override
  final String name;
  @override
  late final Harness h;
  final Map<String, FakeRadioSlots> radios;
  @override
  String radioId;
  @override
  bool connected = true;
  @override
  final DateTime Function() now;
  final Pulse changes = Pulse();
  final SecretStore keychain;
  MeshTrackSettings settings;
  final MemLastKnown lastKnown;
  final FakeFixes location = FakeFixes();
  PrivacyZones zones = const PrivacyZones([]);
  final logs = <String>[];
  final events = <MtEvent>[];
  late final TxArbiter arbiter = TxArbiter(clock: now);
  late final ChannelAdmin admin;
  late final MeshTrackWiring w;

  MtPhone(this.name,
      {required this.now,
      required this.radioId,
      Map<String, FakeRadioSlots>? radios,
      int slots = 8,
      Harness? harness,
      SecretStore? keychain,
      MeshTrackSettings? settings,
      MemLastKnown? lastKnown,
      bool introSeen = false})
      : radios = radios ?? {radioId: FakeRadioSlots(slots)},
        keychain = keychain ?? InMemorySecretStore(),
        settings = settings ?? MeshTrackSettings(introSeen: introSeen),
        lastKnown = lastKnown ?? MemLastKnown() {
    h = harness ?? airHarness(name, () => radio);
    admin = ChannelAdmin(
        store: h.store, radio: () => connected ? this.radios[radioId] : null, wardriveChannelName: () => '#wardriving', onChanged: changes.pulse);
    w = MeshTrackWiring(
      zones: () => zones,
      readSettings: () => this.settings,
      writeSettings: (s) async => this.settings = s,
      keychain: this.keychain,
      lastKnown: this.lastKnown,
      wardriveChannelName: () => '#wardriving',
      phoneLocation: () => location,
      log: logs.add,
      now: now,
    );
    w.service.events.listen(events.add);
  }

  @override
  FakeRadioSlots get radio => radios[radioId]!;
  MeshTrackService get svc => w.service;
  MeshTrackGroupOps get ops => w.groups;

  /// The order AppState uses: wiring start, chat bound, arbiter door, radio state.
  void boot() {
    w.setTrackGate(arbiter);
    w.setRadioConnected(connected);
    w.bindChat(MtChatBinding(
        store: h.store, service: h.service, admin: admin, radioId: () => radioId, radioConnected: () => connected, changes: changes));
    unawaited(w.start());
  }

  /// What ChatController does on a radio connect: read the radio's channels into the phone, then tell MeshTrack.
  void connectTo(String id) {
    radioId = id;
    connected = true;
    admin.syncFromRadio(id);
    w.setRadioConnected(true);
  }

  void disconnect() {
    connected = false;
    w.setRadioConnected(false);
  }

  /// A good GPS fix (5 m) at [lat], [lon], now.
  GeoFix fix(double lat, double lon, {double speedMps = 15, double course = 90, double acc = 5}) =>
      GeoFix(lat: lat, lon: lon, accuracyM: acc, speedMps: speedMps, courseDeg: course, at: now());

  /// Channel texts this radio put on the air so far, oldest first.
  List<({int slot, String text, int ts})> get sent => h.sink.channels;

  /// The group view for the channel with [secret] on the current radio, or null.
  MtGroupView? groupOf(List<int> secret) {
    final slot = radio.withSecret(secret)?.index;
    if (slot == null) return null;
    for (final g in svc.state.groups) {
      if (h.store.channels.getById(g.channelId)?.slot == slot && h.store.channels.getById(g.channelId)?.radioId == radioId) return g;
    }
    return null;
  }

  Channel channel(int id) => h.store.channels.getById(id)!;
}

/// A phone with only the official MeshCore app: chat, no MeshTrack. It joins with the same link and reads and types text.
class StockClient extends MtNode {
  @override
  final String name;
  @override
  late final Harness h = airHarness(name, () => radio);
  @override
  final FakeRadioSlots radio = FakeRadioSlots(8);
  @override
  final String radioId;
  @override
  final bool connected = true;
  @override
  final DateTime Function() now;
  late final ChannelAdmin admin =
      ChannelAdmin(store: h.store, radio: () => radio, wardriveChannelName: () => '#wardriving', onChanged: () {});
  StockClient(this.name, {required this.now, required this.radioId});

  /// Joins from a `meshcore://channel/add` link, as the official app does.
  Future<void> join(String link) => admin.joinFromLink(radioId, link);

  /// Types [text] into the channel with [secret] (chat send through the radio).
  Future<void> type(List<int> secret, String text) async {
    final slot = radio.withSecret(secret)!.index;
    final ch = h.store.channels.list(radioId).firstWhere((c) => c.slot == slot);
    h.service.send(radioId: radioId, convKey: ch.convKey, text: text);
    await h.service.pump();
  }

  List<({int slot, String text, int ts})> get sent => h.sink.channels;
}

/// The world: every node, one clock, one air.
class MtWorld {
  final DateTime Function() now;
  final List<MtNode> nodes = [];
  MtWorld(this.now);

  MtPhone phone(String name, {int slots = 8, bool introSeen = false, bool boot = true}) {
    final p = MtPhone(name, now: now, radioId: radioIdOf(nodes.length + 1), slots: slots, introSeen: introSeen);
    nodes.add(p);
    if (boot) p.boot();
    return p;
  }

  StockClient stock(String name) {
    final s = StockClient(name, now: now, radioId: radioIdOf(nodes.length + 1));
    nodes.add(s);
    return s;
  }

  /// Every channel message sent since the last call goes to every connected radio that holds that channel's key.
  /// Returns how many were carried.
  int air() {
    var n = 0;
    for (final from in nodes) {
      final out = from.h.sink.channels;
      while (from._delivered < out.length) {
        final i = from._delivered++;
        final m = out[i];
        if (!from.connected) continue;
        final secret = (from.h.sink as AirSink).keys[i];
        n++;
        for (final to in nodes) {
          if (identical(to, from) || !to.connected) continue;
          final slot = to.radio.withSecret(secret)?.index;
          if (slot != null) to.hear(slot, '${from.name}: ${m.text}');
        }
      }
    }
    return n;
  }

  /// Puts `name: text` on the air on the channel with [secret], from a sender that is not a node (a scripted car).
  void say(String name, List<int> secret, String text, {int pathLen = 1}) {
    for (final to in nodes) {
      if (!to.connected) continue;
      final slot = to.radio.withSecret(secret)?.index;
      if (slot != null) to.hear(slot, '$name: $text', pathLen: pathLen);
    }
  }
}

/// The key of the channel row [channelId] on [n]'s phone (synchronously readable in tests after a flush).
Future<Uint8List> keyOf(MtNode n, int channelId) async =>
    Uint8List.fromList((await n.h.store.channels.secretOf(n.h.store.channels.getById(channelId)!))!);

/// The Keychain's MeshTrack group registry, decoded.
Future<List<Map<String, Object?>>> registryOf(MtPhone p) async {
  final raw = await p.keychain.read(MeshTrackWiring.registryRef);
  if (raw == null) return const [];
  return [for (final e in jsonDecode(utf8.decode(raw)) as List) (e as Map).cast<String, Object?>()];
}

/// Two byte lists equal.
bool sameKey(List<int> a, List<int> b) => listEquals(a, b);
