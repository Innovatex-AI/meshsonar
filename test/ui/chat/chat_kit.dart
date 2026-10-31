// Shared kit for the chat UI tests: an in-memory chat store, a ChatService with a fake clock and no timers, a
// ChatController with no radio (messages wait in the outbox, like an offline phone), and a themed host app.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/outbox.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/store.dart';
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
