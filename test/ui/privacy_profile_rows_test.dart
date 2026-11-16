// Settings > Privacy > "How you appear" (callsign, display name, anonymous, leaderboard): shown only with driverSettings and
// a key, edits go to the server, a key with no account gets a disabled leaderboard with the reason.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/driver_settings.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/privacy_profile_rows.dart';

import 'fakes.dart';

class PClient extends FakeCmatClient {
  PClient(super.baseUrl);
  Map<String, Object?> row = {'scope': 'account', 'callsign': 'KE4BFI', 'display': null, 'anonymous': false, 'leaderboardOptIn': false, 'trimM': 500, 'privacyZones': <Object>[], 'updatedAt': <String, Object?>{}};
  final posts = <Map<String, Object?>>[];
  @override
  Future<DriverSettings> driverSettings(String driverKey) async => DriverSettings.tryParse({'settings': row})!;
  @override
  Future<DriverSettings> setDriverSettings(String driverKey, Map<String, Object?> fields) async {
    posts.add(fields);
    row = {...row, ...fields};
    return DriverSettings.tryParse({'settings': row})!;
  }
}

class PHarness extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => PClient(u);
  PClient get c => client as PClient;
}

Future<PHarness> pump(WidgetTester tester, {bool capable = true, bool withKey = true, void Function(PHarness)? setup}) async {
  tester.view.physicalSize = const Size(780, 1800);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final h = PHarness();
  if (withKey) h.approveKey();
  h.client.siteConfigResult = SiteConfig(
    region: const RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'),
    capabilities: {if (capable) 'driverSettings'},
  );
  setup?.call(h);
  await h.state.init();
  await tester.pumpAndSettle();
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(theme: meshSonarTheme(Brightness.dark), home: const Scaffold(body: SingleChildScrollView(child: PrivacyProfileRows()))),
  ));
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('the four rows show the server values, and a toggle is sent as just that field', (tester) async {
    final h = await pump(tester);
    expect(find.text('KE4BFI'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-anonymous')));
    await tester.pumpAndSettle();
    expect(h.c.posts.single, {'anonymous': true});
    await tester.tap(find.byKey(const Key('profile-leaderboard')));
    await tester.pumpAndSettle();
    expect(h.c.posts.last, {'leaderboardOptIn': true});
  });

  testWidgets('display name: edit sheet saves a trimmed name', (tester) async {
    final h = await pump(tester);
    await tester.tap(find.byKey(const Key('profile-display')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('edit-field')), '  Andy  ');
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(h.c.posts.single, {'display': 'Andy'});
    expect(find.text('Andy'), findsOneWidget);
  });

  testWidgets('callsign refuses a bad value in the dialog', (tester) async {
    final h = await pump(tester);
    await tester.tap(find.byKey(const Key('profile-callsign')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('edit-field')), 'a!');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-field')), findsOneWidget);
    expect(h.c.posts, isEmpty);
  });

  testWidgets('a key with no account: leaderboard is disabled and says why', (tester) async {
    final h = await pump(tester, setup: (h) => h.c.row = {...h.c.row, 'scope': 'driver', 'leaderboardOptIn': null});
    expect(find.textContaining('Sign in on the website'), findsOneWidget);
    final sw = tester.widget<SwitchListTile>(find.byKey(const Key('profile-leaderboard')));
    expect(sw.onChanged, isNull);
    expect(h.c.posts, isEmpty);
  });

  testWidgets('an older server: no rows at all, no call', (tester) async {
    final h = await pump(tester, capable: false);
    expect(find.byKey(const Key('profile-anonymous')), findsNothing);
    expect(h.c.posts, isEmpty);
  });

  testWidgets('no driver key yet: no rows', (tester) async {
    await pump(tester, withKey: false);
    expect(find.byKey(const Key('profile-anonymous')), findsNothing);
  });
}
