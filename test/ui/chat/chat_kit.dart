// Shared kit for the chat UI tests: an in-memory chat store, a ChatService with a fake clock and no timers, a
// ChatController with no radio (messages wait in the outbox, like an offline phone), and a themed host app.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/outbox.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/inbound.dart' as r;
import 'package:meshsonar/radio/radio_api.dart' as r show SelfInfo;
import 'package:meshsonar/radio/session.dart' as r;
import 'package:meshsonar/ui/theme.dart';

const radioA = 'aa00000000000000000000000000000000000000000000000000000000000001';
const bobKey = 'b0b0000000000000000000000000000000000000000000000000000000000001';

/// A sink the tests steer: connected or not, failing or not. Records what was sent.
class KitSink implements OutboundMessageSink {
  bool connected = true;
  Object? failNext;
  final channels = <({int slot, String text, int ts})>[];
  final directs = <({String key, String text})>[];
  @override
  bool get canSend => connected;
  @override
  Future<SendReceipt> sendDirect({required String radioId, required String contactPublicKey, required String text, required int timestamp, required int attempt, required bool forceFlood}) async {
    if (!connected) throw const RadioNotConnected();
    directs.add((key: contactPublicKey, text: text));
    return const SendReceipt(flood: true, expectedAck: 1, estTimeoutMs: 4000);
  }

  @override
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp}) async {
    if (!connected) throw const RadioNotConnected();
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
    channels.add((slot: slot, text: text, ts: timestamp));
    return timestamp;
  }
}

class ChatKit {
  int clockMs = DateTime(2026, 11, 1, 12).millisecondsSinceEpoch;
  final store = ChatStore.inMemory();
  final switchable = SwitchableSink();
  final sink = KitSink();
  late final ChatService service;
  late final ChatController controller;
  int _id = 0;

  ChatKit({bool knownRadio = true}) {
    if (knownRadio) store.db.putSetting('last_radio_id', radioA);
    service = ChatService(
      store: store,
      sink: sink,
      nowMs: () => clockMs,
      selfName: () => 'Me',
      newId: () => 'm${_id++}',
      policy: const RetryPolicy(jitterMs: 0, minGapMs: 0),
      autoTimer: false,
    );
    controller = ChatController(
      store: store,
      service: service,
      sink: switchable,
      wardriveChannelName: () => '#wardriving',
      now: () => DateTime.fromMillisecondsSinceEpoch(clockMs),
    );
  }

  Future<Channel> channel(int slot, String name, {ChannelKind kind = ChannelKind.private, String? region}) =>
      store.channels.save(Channel(radioId: radioA, slot: slot, name: name, kind: kind, regionScope: region), secret: Uint8List.fromList(List.filled(16, slot + 1)));

  Contact bob({ContactType type = ContactType.companion, String name = 'Bob'}) {
    final c = Contact(radioId: radioA, publicKey: bobKey, type: type, name: name);
    store.contacts.upsert(c);
    return c;
  }

  /// An incoming channel message from [sender].
  void incoming(Channel ch, String sender, String text, {int? ts}) {
    service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: ch.slot!, timestamp: ts ?? clockMs ~/ 1000, text: '$sender: $text', snr: 5.5, pathLen: 2));
  }

  /// Binds a fake radio session to the controller, like a connect.
  Future<FakeRadioSession> connect({FakeRadioSession? session}) async {
    final s = session ?? FakeRadioSession();
    await controller.onSession(s);
    return s;
  }

  void dispose() {
    controller.dispose();
    store.close();
  }
}

Widget host(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
      theme: meshSonarTheme(brightness),
      darkTheme: meshSonarTheme(Brightness.dark),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: child,
    );

void setSize(WidgetTester tester, {double w = 390, double h = 844, double scale = 1.0}) {
  tester.view.physicalSize = Size(w * 3, h * 3);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// A radio session with channel slots, for the UI flows. Only what chat touches is implemented.
class FakeRadioSession implements r.RadioSession {
  @override
  String? selfPublicKey = radioA;
  @override
  bool isConnected = true;
  @override
  bool chatActive = false;
  @override
  r.DeviceLimits? limits = const r.DeviceLimits(maxChannels: 4);
  final List<r.RadioChannel> slots;
  Object? failWrite;
  final events_ = StreamController<r.RadioEvent>.broadcast(sync: true);
  final sentChannel = <(int, String, r.FloodScope?)>[];
  int syncs = 0;

  FakeRadioSession({int n = 4}) : slots = List.generate(n, (i) => r.RadioChannel(i, '', Uint8List(16)));

  void put(int i, String name, List<int> secret) => slots[i] = r.RadioChannel(i, name, Uint8List.fromList(secret));

  @override
  Stream<r.RadioEvent> get events => events_.stream;
  @override
  Stream<r.LinkState> get linkStates => const Stream.empty();
  @override
  r.SelfInfo? get selfInfo => null;
  @override
  void setInboundPersister(Future<void> Function(r.InboundMessage message)? persist) {}
  @override
  Future<void> syncMessagesNow() async => syncs++;
  @override
  Future<List<r.RadioChannel>> listChannels() async => List.of(slots);
  @override
  Future<void> setChannel(int index, String name, Uint8List secret16) async {
    if (failWrite != null) throw failWrite!;
    slots[index] = r.RadioChannel(index, name, Uint8List.fromList(secret16));
  }

  @override
  Future<void> deleteChannel(int index) async {
    if (failWrite != null) throw failWrite!;
    slots[index] = r.RadioChannel(index, '', Uint8List(16));
  }

  @override
  Future<r.ContactListing> getContacts({int since = 0}) async => const r.ContactListing(totalOnRadio: 0, contacts: [], mostRecentLastMod: 0);
  @override
  Future<r.SendResult> sendChannelMessage(int channelIndex, String text, {r.FloodScope? scope}) async {
    sentChannel.add((channelIndex, text, scope));
    return const r.SendResult.accepted(1000);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}
