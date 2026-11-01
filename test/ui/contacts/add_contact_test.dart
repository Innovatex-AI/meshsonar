import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/mesh_links.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/contacts/add_contact_screen.dart';
import 'package:meshsonar/ui/contacts/contacts_settings_sheet.dart';
import 'package:meshsonar/ui/contacts/qr_scan_screen.dart';

import '../../chat/contact_support.dart';
import '../../chat/support.dart';
import 'contacts_ui_support.dart';

Future<ContactsRig> pumpAdd(WidgetTester tester,
    {bool link = true, double w = 390, double h = 844, double scale = 1, Brightness b = Brightness.light, ScannerBuilder? scanner, String? clipboard, List<String>? shared}) async {
  setScreen(tester, w: w, h: h, scale: scale);
  final rig = ContactsRig();
  addTearDown(rig.dispose);
  rig.chat.contacts.attach(rig.port);
  await rig.chat.contacts.syncNow();
  if (!link) rig.chat.contacts.detach();
  await tester.pumpWidget(hostApp(
    Builder(
      builder: (context) => Center(
        child: FilledButton(
          key: const Key('launch'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => AddContactScreen(
                    controller: rig.controller,
                    scannerBuilder: scanner,
                    readClipboard: () async => clipboard,
                    share: (t) async => shared?.add(t),
                  ))),
          child: const Text('go'),
        ),
      ),
    ),
    brightness: b,
  ));
  await tester.tap(find.byKey(const Key('launch')));
  await tester.pumpAndSettle();
  return rig;
}

Future<void> openPaste(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('add-paste-tile')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('add-paste-tile')));
  await tester.pump();
}

String contactLinkFor(int n, {String name = 'Sam K8SAM', int type = 1}) => 'meshcore://contact/add?name=${Uri.encodeQueryComponent(name)}&public_key=${keyN(n)}&type=$type';

void main() {
  group('paste a link or key', () {
    testWidgets('a good contact link adds the contact, goes back and says so', (tester) async {
      final rig = await pumpAdd(tester);
      await openPaste(tester);
      await tester.enterText(find.byKey(const Key('add-text')), contactLinkFor(40));
      await tester.pump();
      await tester.tap(find.byKey(const Key('add-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-contact')), findsNothing, reason: 'back on the previous screen');
      expect(find.textContaining('Added Sam K8SAM'), findsOneWidget);
      expect(rig.store.contacts.get(radioA, keyN(40))!.source, ContactSource.imported);
      expect(rig.port.table.containsKey(keyN(40)), isTrue);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a bad link: the reason in plain words under the field, nothing added', (tester) async {
      final rig = await pumpAdd(tester);
      await openPaste(tester);
      await tester.enterText(find.byKey(const Key('add-text')), 'https://example.com/x');
      await tester.pump();
      await tester.tap(find.byKey(const Key('add-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('not a MeshCore link'), findsOneWidget);
      expect(find.byKey(const Key('add-contact')), findsOneWidget);
      expect(rig.store.contacts.count(radioA), 0);
    });

    testWidgets('a channel link is recognised and the user is told where it belongs', (tester) async {
      await pumpAdd(tester);
      await openPaste(tester);
      await tester.enterText(find.byKey(const Key('add-text')), 'meshcore://channel/add?name=Ohio&secret=${'ab' * 16}');
      await tester.pump();
      await tester.tap(find.byKey(const Key('add-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('channel link'), findsOneWidget);
      expect(find.textContaining('Channels'), findsOneWidget);
    });

    testWidgets('a bare 64-character key shows the optional name field and adds with that name', (tester) async {
      final rig = await pumpAdd(tester);
      await openPaste(tester);
      expect(find.byKey(const Key('add-name')), findsNothing);
      await tester.enterText(find.byKey(const Key('add-text')), keyN(0xab));
      await tester.pump();
      expect(find.byKey(const Key('add-name')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('add-name')), 'Pat');
      await tester.tap(find.byKey(const Key('add-submit')));
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(0xab))!.name, 'Pat');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a key that is too short is explained, not swallowed', (tester) async {
      await pumpAdd(tester);
      await openPaste(tester);
      await tester.enterText(find.byKey(const Key('add-text')), 'abcdef0123');
      await tester.pump();
      await tester.tap(find.byKey(const Key('add-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('not a MeshCore link'), findsOneWidget);
    });

    testWidgets('Paste reads the clipboard; an empty clipboard says so', (tester) async {
      await pumpAdd(tester, clipboard: contactLinkFor(41, name: 'Lee'));
      await openPaste(tester);
      await tester.tap(find.byKey(const Key('add-clipboard')));
      await tester.pump();
      expect(find.text(contactLinkFor(41, name: 'Lee')), findsOneWidget);
    });

    testWidgets('empty clipboard', (tester) async {
      await pumpAdd(tester, clipboard: '');
      await openPaste(tester);
      await tester.tap(find.byKey(const Key('add-clipboard')));
      await tester.pump();
      expect(find.textContaining('clipboard is empty'), findsOneWidget);
    });

    testWidgets('radio away: saved on the phone with the honest note', (tester) async {
      final rig = await pumpAdd(tester, link: false);
      await openPaste(tester);
      await tester.enterText(find.byKey(const Key('add-text')), contactLinkFor(42, name: 'Kim'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('add-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Added Kim'), findsOneWidget);
      expect(find.textContaining('next time it connects'), findsOneWidget);
      expect(rig.store.contacts.get(radioA, keyN(42))!.onRadio, isFalse);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('scan a QR code', () {
    testWidgets('a MeshCore code adds the contact; a stranger\'s QR is refused with a notice and scanning goes on', (tester) async {
      final good = contactLinkFor(43, name: 'Ria');
      final rig = await pumpAdd(tester, scanner: (context, onCode) => _Emit(codes: ['WIFI:S:home;;', 'WIFI:S:home;;', good, good], onCode: onCode));
      await tester.tap(find.byKey(const Key('add-scan')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('scan-notice')), findsOneWidget);
      expect(find.text('That is not a MeshCore code'), findsOneWidget);
      expect(find.byKey(const Key('scan-frame')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      expect(rig.store.contacts.get(radioA, keyN(43))!.name, 'Ria');
      expect(rig.store.contacts.count(radioA), 1, reason: 'the repeated detections made one contact');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('Paste instead leaves the camera and opens the paste field', (tester) async {
      await pumpAdd(tester, scanner: (c, o) => const SizedBox());
      await tester.tap(find.byKey(const Key('add-scan')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scan-paste')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-text')), findsOneWidget);
    });

    testWidgets('Cancel closes the scanner', (tester) async {
      await pumpAdd(tester, scanner: (c, o) => const SizedBox());
      await tester.tap(find.byKey(const Key('add-scan')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scan-frame')), findsNothing);
      expect(find.byKey(const Key('add-contact')), findsOneWidget);
    });
  });

  group('show my contact', () {
    testWidgets('connected: QR of this radio\'s contact link, copy and share', (tester) async {
      final shared = <String>[];
      await pumpAdd(tester, shared: shared);
      await tester.tap(find.byKey(const Key('add-mine')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('my-contact')), findsOneWidget);
      expect(find.byKey(const Key('qr-view')), findsOneWidget);
      await tester.tap(find.byKey(const Key('my-share')));
      await tester.pump();
      final l = MeshLinks.parse(shared.single) as ContactLink;
      expect(l.publicKey, radioA);
      expect(l.type, ContactType.companion);
    });

    testWidgets('no radio: says to connect first, no code', (tester) async {
      await pumpAdd(tester, link: false);
      await tester.tap(find.byKey(const Key('add-mine')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Connect your radio first'), findsOneWidget);
      expect(find.byKey(const Key('qr-view')), findsNothing);
    });
  });

  group('layout and accessibility', () {
    for (final size in [phoneSize, ipadSize]) {
      for (final scale in [1.0, 2.5]) {
        for (final dark in [false, true]) {
          testWidgets('Add contact ${size.w.toInt()}x${size.h.toInt()} x$scale ${dark ? 'dark' : 'light'}', (tester) async {
            await pumpAdd(tester, w: size.w, h: size.h, scale: scale, b: dark ? Brightness.dark : Brightness.light);
            await openPaste(tester);
            await tester.ensureVisible(find.byKey(const Key('add-text')));
            await tester.enterText(find.byKey(const Key('add-text')), 'nonsense that fails');
            await tester.pump();
            await tester.ensureVisible(find.byKey(const Key('add-submit')));
            await tester.tap(find.byKey(const Key('add-submit')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await expectAccessible(tester);
          });
        }
      }
    }

    testWidgets('VoiceOver labels on the three choices', (tester) async {
      final h = tester.ensureSemantics();
      await pumpAdd(tester);
      expect(find.bySemanticsLabel(RegExp('Scan a QR code')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Paste a link or key')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Show my contact')), findsOneWidget);
      h.dispose();
    });
  });

  group('contact settings sheet', () {
    Future<ContactsRig> pumpSettings(WidgetTester tester, {bool link = true, double scale = 1, double w = 390, double h = 844}) async {
      setScreen(tester, w: w, h: h, scale: scale);
      final rig = ContactsRig();
      addTearDown(rig.dispose);
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      if (!link) rig.chat.contacts.detach();
      await tester.pumpWidget(hostApp(Builder(builder: (c) => TextButton(key: const Key('open'), onPressed: () => showContactsSettings(c, rig.controller), child: const Text('open')))));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      return rig;
    }

    testWidgets('switches write to the radio: ask first, then per-type, overwrite and hop limit', (tester) async {
      final rig = await pumpSettings(tester);
      expect(find.byKey(const Key('set-repeaters')), findsNothing, reason: 'per-type switches only matter once the radio asks first');
      await tester.tap(find.byKey(const Key('set-ask')));
      await tester.pumpAndSettle();
      expect(rig.port.policy.askBeforeAdding, isTrue);
      await tester.ensureVisible(find.byKey(const Key('set-repeaters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('set-repeaters')));
      await tester.pumpAndSettle();
      expect(rig.port.policy.autoAddRepeaters, isTrue);
      expect(rig.port.policy.autoAddChat, isFalse);
      await tester.ensureVisible(find.byKey(const Key('set-overwrite')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('set-overwrite')));
      await tester.pumpAndSettle();
      expect(rig.port.policy.overwriteOldest, isTrue);
      await tester.ensureVisible(find.byKey(const Key('set-hops')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('set-hops')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Direct only').last);
      await tester.pumpAndSettle();
      expect(rig.port.policy.maxHops, 1);
    });

    testWidgets('radio away: the switches are off and the sentence says why', (tester) async {
      await pumpSettings(tester, link: false);
      expect(find.text('Connect your radio to change this.'), findsOneWidget);
      final sw = tester.widget<SwitchListTile>(find.byKey(const Key('set-ask')));
      expect(sw.onChanged, isNull);
    });

    testWidgets('ignored nodes can be restored', (tester) async {
      setScreen(tester);
      final rig = ContactsRig();
      addTearDown(rig.dispose);
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      rig.store.adverts.record(AdvertSeen(radioId: radioA, publicKey: keyN(150), name: 'Far Hill', firstTsMs: 1, lastTsMs: 2));
      rig.chat.contacts.ignoreNearby(keyN(150));
      await tester.pumpWidget(hostApp(Builder(builder: (c) => TextButton(key: const Key('open'), onPressed: () => showContactsSettings(c, rig.controller), child: const Text('open')))));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.text('Far Hill'), findsOneWidget);
      await tester.ensureVisible(find.text('Restore'));
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(rig.chat.contacts.nearby().single.name, 'Far Hill');
    });

    for (final size in [phoneSize, ipadSize]) {
      for (final scale in [1.0, 2.5]) {
        testWidgets('layout ${size.w.toInt()} x$scale', (tester) async {
          final rig = await pumpSettings(tester, scale: scale, w: size.w, h: size.h);
          await rig.chat.contacts.setPolicy(rig.port.policy.copyWith(askBeforeAdding: true));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await expectAccessible(tester);
        });
      }
    }
  });
}

/// A camera that "sees" [codes] one after another, one per frame.
class _Emit extends StatefulWidget {
  final List<String> codes;
  final void Function(String) onCode;
  const _Emit({required this.codes, required this.onCode});
  @override
  State<_Emit> createState() => _EmitState();
}

class _EmitState extends State<_Emit> {
  int _i = 0;
  @override
  void initState() {
    super.initState();
    _next();
  }

  void _next() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _i >= widget.codes.length) return;
      widget.onCode(widget.codes[_i++]);
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_i < widget.codes.length) _next();
    return const ColoredBox(color: Colors.black);
  }
}
