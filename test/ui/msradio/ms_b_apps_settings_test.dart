// Builder B: Lua apps and Radio screen and sounds against the fake radio.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/msradio/ms_b_lua_apps_screen.dart';
import 'package:meshsonar/ui/msradio/ms_b_screen_sounds_screen.dart';
import 'package:meshsonar/ui/msradio/ms_sections.dart';

import 'ms_b_test_kit.dart';

void main() {
  group('Lua apps', () {
    forBothThemes((b) {
      testWidgets('renders the installed apps (${b.name})', (t) async {
        msBPhone(t);
        final rig = await MsBRig.paired(t);
        await msBPump(t, msSectionScreen(MsSection.luaApps, rig.c)!, b: b);
        expect(find.byKey(const Key('msb-apps')), findsOneWidget);
        expect(find.text('Clock'), findsOneWidget);
        expect(find.text('Weather'), findsOneWidget);
        expect(find.text('CL'), findsOneWidget);
        expect(find.textContaining('Version 1.0.0 · Built in'), findsOneWidget);
        expect(find.textContaining('Version 1.1.0 · From the catalog'), findsOneWidget);
        // built-in apps cannot be removed
        expect(find.byKey(const Key('msb-app-remove-clock')), findsNothing);
        expect(find.byKey(const Key('msb-app-remove-weather')), findsOneWidget);
        await msBEnd(t, rig);
      });
    });

    testWidgets('Run, then Stop; Remove asks first', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBLuaAppsScreen(c: rig.c));
      await msBTap(t, find.byKey(const Key('msb-app-run-clock')));
      expect(rig.api, contains('POST /apps/run'));
      expect(rig.bodies, contains('id=clock'));
      expect(find.byKey(const Key('msb-app-stop-clock')), findsOneWidget);
      await msBTap(t, find.byKey(const Key('msb-app-stop-clock')));
      expect(rig.api, contains('POST /apps/stop'));
      await msBTap(t, find.byKey(const Key('msb-app-remove-weather')));
      expect(find.byKey(const Key('msb-confirm-remove-app')), findsOneWidget);
      await msBTap(t, find.byKey(const Key('msb-confirm-remove-app-cancel')));
      expect(rig.api, isNot(contains('POST /apps/remove')));
      await msBTap(t, find.byKey(const Key('msb-app-remove-weather')));
      await msBTap(t, find.byKey(const Key('msb-confirm-remove-app-ok')));
      expect(rig.api, contains('POST /apps/remove'));
      expect(rig.bodies, contains('id=weather'));
      expect(find.text('Weather'), findsNothing);
      await msBEnd(t, rig);
    });

    testWidgets('Browse catalog: loads, then Install / Update / Installed per entry', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBLuaAppsScreen(c: rig.c));
      // the radio is still loading it when the screen reads /apps after the tap
      rig.overrides['GET /api/app/v1/apps'] = (200, '{"installed":[],"catalog":{"state":"loading","entries":[]}}');
      await msBTap(t, find.byKey(const Key('msb-apps-browse')));
      expect(rig.api, contains('POST /apps/catalog'));
      expect(find.byKey(const Key('msb-cat-loading')), findsOneWidget);
      rig.overrides['GET /api/app/v1/apps'] = (
        200,
        '{"installed":[{"id":"weather","name":"Weather","version":"1.1.0","source":"catalog"},{"id":"snake","name":"Snake","version":"0.3.0","source":"catalog"}],'
            '"catalog":{"state":"ok","entries":[{"id":"weather","name":"Weather","version":"1.2.0","installed_version":"1.1.0"},'
            '{"id":"snake","name":"Snake","version":"0.3.0","installed_version":"0.3.0"},{"id":"radar","name":"Radar","version":"1.0.0"}]}}'
      );
      await t.pump(const Duration(seconds: 2));
      await msBSettle(t);
      expect(find.byKey(const Key('msb-cat')), findsOneWidget);
      expect(find.byKey(const Key('msb-cat-update-weather')), findsOneWidget);
      expect(find.byKey(const Key('msb-cat-installed-snake')), findsOneWidget);
      expect(find.byKey(const Key('msb-cat-install-radar')), findsOneWidget);
      final polls = rig.api.where((q) => q == 'GET /apps').length;
      await t.pump(const Duration(seconds: 6));
      expect(rig.api.where((q) => q == 'GET /apps').length, polls, reason: 'polling stops once the catalog is ok');
      await msBTap(t, find.byKey(const Key('msb-cat-install-radar')));
      expect(rig.api, contains('POST /apps/install'));
      expect(rig.bodies, contains('id=radar'));
      await msBEnd(t, rig);
    });

    testWidgets('Upload an app: main.lua with the fields goes to POST /apps/upload', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      final pick = FakeFilePick(file: FakeFilePick.bytes('main.lua', 'function on_open() end'.codeUnits));
      await msBPump(t, MsBLuaAppsScreen(c: rig.c, pick: pick));
      await msBTap(t, find.byKey(const Key('msb-apps-upload')));
      expect(find.byKey(const Key('msb-apps-upload-screen')), findsOneWidget);
      await msBTap(t, find.byKey(const Key('msb-upload-pick')));
      expect(pick.lastExtensions, ['lua']);
      expect(find.text('main.lua, 22 bytes'), findsOneWidget);
      await t.enterText(find.byKey(const Key('msb-upload-id')), 'hello_1');
      await t.enterText(find.byKey(const Key('msb-upload-name')), 'Hello');
      await t.enterText(find.byKey(const Key('msb-upload-icon')), 'HI');
      await msBTap(t, find.byKey(const Key('msb-upload-internet')));
      await msBTap(t, find.byKey(const Key('msb-upload-send')));
      final up = rig.r.requests.firstWhere((q) => q.startsWith('POST /apps/upload'));
      expect(up, contains('id=hello_1'));
      expect(up, contains('name=Hello'));
      expect(up, contains('icon=HI'));
      expect(up, contains('http=1'));
      expect(up, contains('mem=64'));
      expect(up, contains('size=22'));
      expect(find.byKey(const Key('msb-apps-upload-screen')), findsNothing);
      expect(find.text('The app was uploaded.'), findsOneWidget);
      await msBEnd(t, rig);
    });

    testWidgets('a main.lua over 32 KB is refused before anything is sent; a bad id is refused', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      final pick = FakeFilePick(file: FakeFilePick.bytes('main.lua', List.filled(40000, 0x20)));
      await msBPump(t, MsBLuaUploadScreen(c: rig.c, pick: pick));
      await msBTap(t, find.byKey(const Key('msb-upload-pick')));
      expect(find.textContaining('main.lua can be at most 32 KB'), findsOneWidget);
      await msBTap(t, find.byKey(const Key('msb-upload-send')));
      expect(find.text('Pick main.lua first.'), findsOneWidget);
      pick.file = FakeFilePick.bytes('main.lua', [0x20]);
      await msBTap(t, find.byKey(const Key('msb-upload-pick')));
      await t.enterText(find.byKey(const Key('msb-upload-name')), 'X');
      await msBTap(t, find.byKey(const Key('msb-upload-send'))); // id empty
      expect(find.text('1 to 10 characters: a-z, 0-9 or _.'), findsOneWidget);
      expect(rig.r.requests.where((q) => q.startsWith('POST /apps/upload')), isEmpty);
      await msBEnd(t, rig);
    });

    testWidgets('the radio\'s refusal text is shown', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['POST /api/app/v1/apps/run'] = (409, '{"error":"Not enough memory to open Clock.","status":409}');
      await msBPump(t, MsBLuaAppsScreen(c: rig.c));
      await msBTap(t, find.byKey(const Key('msb-app-run-clock')));
      expect(find.text('Not enough memory to open Clock.'), findsOneWidget);
      await msBEnd(t, rig);
    });
  });

  group('Radio screen and sounds', () {
    forBothThemes((b) {
      testWidgets('renders the fixture settings with plain labels (${b.name})', (t) async {
        msBPhone(t);
        final rig = await MsBRig.paired(t);
        await msBPump(t, msSectionScreen(MsSection.screenSounds, rig.c)!, b: b);
        expect(find.byKey(const Key('msb-screen')), findsOneWidget);
        expect(find.widgetWithText(TextField, 'KE4BFI Mobile'), findsOneWidget);
        expect(find.text('Brightness: 80%'), findsOneWidget);
        expect(find.text('2 min'), findsOneWidget);
        for (final l in ['Direct messages', 'Channel messages', 'Mentions', 'Delivered', 'Not delivered', 'Low battery']) {
          expect(find.text(l), findsOneWidget, reason: l);
        }
        // events 61 = 0b111101: channel (bit 1) off, the rest on
        expect(t.widget<SwitchListTile>(find.byKey(const Key('msb-set-event-dm'))).value, isTrue);
        expect(t.widget<SwitchListTile>(find.byKey(const Key('msb-set-event-channel'))).value, isFalse);
        expect(t.widget<SwitchListTile>(find.byKey(const Key('msb-set-event-low_battery'))).value, isTrue);
        expect(find.text('Medium'), findsOneWidget);
        expect(find.byKey(const Key('msb-set-lock')), findsOneWidget);
        await msBEnd(t, rig);
      });
    });

    test('timeout labels', () {
      expect([for (final ms in [30000, 60000, 120000, 300000, 600000, 0]) msBTimeoutLabel(ms)], ['30 s', '1 min', '2 min', '5 min', '10 min', 'Never']);
    });

    testWidgets('each control sends one POST /settings with the right field', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBScreenSoundsScreen(c: rig.c));
      await msBTap(t, find.byKey(const Key('msb-set-event-channel')));
      expect(rig.bodies.last, 'events=63');
      expect(rig.r.events, 63);
      await msBTap(t, find.byKey(const Key('msb-set-event-dm')));
      expect(rig.bodies.last, 'events=62');
      await msBTap(t, find.text('High'));
      expect(rig.bodies.last, 'volume=3');
      await msBTap(t, find.byKey(const Key('msb-set-flash')));
      expect(rig.bodies.last, 'flash=false');
      await msBTap(t, find.byKey(const Key('msb-set-quiet')));
      expect(rig.bodies.last, 'quiet_on=true');
      await msBTap(t, find.byKey(const Key('msb-set-buzzer')));
      expect(rig.bodies.last, 'buzzer_fitted=false');
      expect(find.byKey(const Key('msb-set-volume')), findsNothing, reason: 'no volume without a buzzer');
      // screen timeout
      await msBTap(t, find.byKey(const Key('msb-set-timeout')));
      await t.tap(find.text('5 min').last);
      await msBSettle(t);
      expect(rig.bodies.last, 'screen_timeout_ms=300000');
      // name
      await t.enterText(find.byKey(const Key('msb-set-name')), 'Truck');
      await msBTap(t, find.byKey(const Key('msb-set-name-save')));
      expect(rig.bodies.last, 'name=Truck');
      expect(rig.r.name, 'Truck');
      // quiet hours start: start and end go together
      await msBTap(t, find.byKey(const Key('msb-set-quiet-start')));
      await t.tap(find.text('OK'));
      await msBSettle(t);
      expect(rig.bodies.last, 'quiet_start=1320&quiet_end=420');
      expect(rig.api.where((q) => q == 'POST /settings').length, 9);
      await msBEnd(t, rig);
    });

    testWidgets('brightness slider sends the value when let go', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      await msBPump(t, MsBScreenSoundsScreen(c: rig.c));
      final s = find.byKey(const Key('msb-set-brightness'));
      await t.ensureVisible(s);
      await t.drag(s, const Offset(-2000, 0));
      await msBSettle(t);
      expect(rig.bodies.last, 'brightness=5');
      expect(find.text('Brightness: 5%'), findsOneWidget);
      await msBEnd(t, rig);
    });

    testWidgets('the radio\'s refusal text is shown and nothing changes', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      rig.overrides['POST /api/app/v1/settings'] = (400, '{"error":"Value out of range.","status":400}');
      await msBPump(t, MsBScreenSoundsScreen(c: rig.c));
      await msBTap(t, find.byKey(const Key('msb-set-flash')));
      expect(find.text('Value out of range.'), findsOneWidget);
      expect(t.widget<SwitchListTile>(find.byKey(const Key('msb-set-flash'))).value, isTrue);
      await msBEnd(t, rig);
    });

    testWidgets('PIN: Set, Lock now, Remove with a wrong PIN shows "Wrong PIN"; the PIN is only ever in a request body', (t) async {
      msBPhone(t);
      final rig = await MsBRig.paired(t);
      final prints = await msBCapturePrints(() async {
        await msBPump(t, MsBScreenSoundsScreen(c: rig.c));
        expect(t.widget<FilledButton>(find.byKey(const Key('msb-lock-now'))).onPressed, isNull, reason: 'Lock now needs a PIN');
        await msBTap(t, find.byKey(const Key('msb-pin-set')));
        expect(find.byKey(const Key('msb-pin-dialog-set-pin')), findsOneWidget);
        expect(t.widget<TextField>(find.byKey(const Key('msb-pin-field'))).obscureText, isTrue);
        await t.enterText(find.byKey(const Key('msb-pin-field')), '12');
        await msBTap(t, find.byKey(const Key('msb-pin-ok')));
        expect(find.text('The PIN is 4 to 8 digits.'), findsOneWidget);
        await t.enterText(find.byKey(const Key('msb-pin-field')), '4826');
        await msBTap(t, find.byKey(const Key('msb-pin-ok')));
        expect(rig.r.lockSet, isTrue);
        await msBTap(t, find.byKey(const Key('msb-lock-now')));
        expect(rig.r.locked, isTrue);
        await msBTap(t, find.byKey(const Key('msb-pin-clear')));
        await t.enterText(find.byKey(const Key('msb-pin-field')), '9137');
        await msBTap(t, find.byKey(const Key('msb-pin-ok')));
        expect(find.text('Wrong PIN'), findsOneWidget);
        expect(rig.r.lockSet, isTrue);
      });
      expect(rig.bodies, contains('action=set&pin=4826'));
      expect(rig.bodies, contains('action=lock_now'));
      expect(rig.bodies, contains('action=clear&pin=9137'));
      final logText = [...rig.r.requests, ...prints].join('\n');
      expect(logText, isNot(contains('4826')));
      expect(logText, isNot(contains('9137')));
      expect(find.textContaining('4826'), findsNothing);
      expect(find.textContaining('9137'), findsNothing);
      await msBEnd(t, rig);
    });
  });
}
