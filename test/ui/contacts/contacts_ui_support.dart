// Shared rig for the Contacts widget tests: a real ChatStore and ChatService, the in-memory radio table from
// test/chat/contact_support.dart behind ContactManager, and helpers to show a widget at phone / iPad size, large text and
// dark mode.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/outbox.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/ui/contacts/contacts_controller.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../chat/contact_support.dart';
import '../../chat/support.dart';

class ContactsRig {
  final FakeClock clock = FakeClock();
  final ChatStore store = ChatStore.inMemory();
  final FakeRadioPort port = FakeRadioPort(capacity: 100);
  final FakeSink sink = FakeSink();
  late final ChatService chat;
  late final ContactsController controller;
  final List<Contact> opened = [];
  final List<Contact> adminOpened = [];

  ContactsRig({bool admin = true, bool canOpenRooms = false}) {
    chat = ChatService(
        store: store, sink: sink, nowMs: clock.call, selfName: () => 'Me', policy: const RetryPolicy(jitterMs: 0, minGapMs: 0), autoTimer: false);
    controller = ContactsController(
      chat: chat,
      nowMs: clock.call,
      openConversation: (context, c) => opened.add(c),
      openAdmin: admin ? (context, c) => adminOpened.add(c) : null,
      canOpenRooms: canOpenRooms,
    );
  }

  /// [n] companions, repeaters and rooms on the radio and in the book, linked.
  Future<void> withContacts(int n, {bool link = true}) async {
    for (var i = 1; i <= n; i++) {
      port.radioAdd(radioContact(i, type: i % 5 == 0 ? ContactType.repeater : (i % 7 == 0 ? ContactType.room : ContactType.companion)));
    }
    if (link) {
      chat.contacts.attach(port);
      await chat.contacts.syncNow();
    } else {
      chat.contacts.attach(port);
      await chat.contacts.syncNow();
      chat.contacts.detach();
    }
  }

  void dispose() {
    controller.dispose();
    chat.dispose();
  }
}

/// Phone or iPad size, text scale, brightness. Resets itself when the test ends.
void setScreen(WidgetTester tester, {double w = 390, double h = 844, double scale = 1.0}) {
  tester.view.physicalSize = Size(w * 3, h * 3);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

const phoneSize = (w: 390.0, h: 844.0);
const ipadSize = (w: 834.0, h: 1194.0);

Widget hostApp(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
      theme: meshSonarTheme(Brightness.light),
      darkTheme: meshSonarTheme(Brightness.dark),
      themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(body: SafeArea(child: child)),
    );

/// The three accessibility rules every screen must pass: tap targets of 48 dp, labels on tappable things, readable contrast.
Future<void> expectAccessible(WidgetTester tester) async {
  final handle = tester.ensureSemantics();
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(textContrastGuideline));
  handle.dispose();
}
