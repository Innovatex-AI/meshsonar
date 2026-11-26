// SitePageView and AnalyticsSection with a fake page engine (dark theme, 375 pt wide): loading, the error page and Retry,
// links (native, another site, a dropped embed), the page router's address changes without a loop, Back inside the page
// first, "Open in browser" without embed, the 17-tab list and initialTab.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/network/analytics/analytics_section.dart';
import 'package:meshsonar/ui/network/analytics/in_place_header.dart';
import 'package:meshsonar/ui/network/analytics/site_links.dart';
import 'package:meshsonar/ui/network/analytics/site_page_view.dart';
import 'package:meshsonar/ui/theme.dart';

const base = 'https://cmh.meshsonar.com';
const node = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';

class FakeEngine implements SiteWebEngine {
  final SiteWebEvents events;
  final List<Uri> loads = [];
  final List<String> scripts = [];
  final List<String> history = [];
  int backs = 0;
  FakeEngine(this.events);

  @override
  Widget build(BuildContext context) => const SizedBox.expand(key: Key('fake-web'));
  @override
  Future<void> load(Uri url) async {
    loads.add(url);
    history.add(url.toString());
  }

  @override
  Future<void> reload() async {}
  @override
  Future<bool> canGoBack() async => history.length > 1;
  @override
  Future<void> goBack() async {
    backs++;
    history.removeLast();
    events.onUrlChange(history.last);
  }

  @override
  Future<String?> currentUrl() async => history.isEmpty ? null : history.last;
  @override
  Future<void> runScript(String script) async => scripts.add(script);

  /// The page's own router moved to [url].
  void push(String url) {
    history.add(url);
    events.onUrlChange(url);
  }

  void finish() {
    events.onStarted(history.last);
    events.onProgress(100);
    events.onFinished(history.last);
  }
}

void main() {
  late FakeEngine engine;
  final opened = <Uri>[];

  setUp(() {
    opened.clear();
    siteWebEngineFactory = (e, _) => engine = FakeEngine(e);
    siteOpenExternal = (u) async {
      opened.add(u);
      return true;
    };
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(375, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: child));
    await tester.pump();
  }

  Future<void> settleTimers(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  }

  testWidgets('loads the page with embed, shows progress, injects the style sheet once per event', (tester) async {
    final native = <Uri>[];
    await pump(tester, SitePageView(baseUrl: base, path: '/analytics/rf-signal', title: 'RF / Signal', onNativeLink: (u) {
      native.add(u);
      return true;
    }));
    expect(engine.loads.single.toString(), '$base/analytics/rf-signal?embed=1');
    expect(find.byKey(const Key('site-page-loading')), findsOneWidget);
    expect(find.text('RF / Signal'), findsOneWidget);
    // Build 76: a first load says what is loading (it was a blank page with a thin bar).
    expect(find.text('Loading RF / Signal…'), findsOneWidget);
    engine.finish();
    await tester.pump();
    expect(find.byKey(const Key('site-page-loading')), findsNothing);
    expect(find.byKey(const Key('site-page-loading-label')), findsNothing);
    expect(engine.scripts, everyElement(siteEmbedScript));
    expect(engine.scripts, isNotEmpty);
    expect(tester.takeException(), isNull);
    await settleTimers(tester);
  });

  testWidgets('links: native ones go to the app, other sites to the browser, a dropped embed is put back once', (tester) async {
    final native = <Uri>[];
    await pump(tester, SitePageView(baseUrl: base, path: '/scope-audit', title: 'Scope Audit', onNativeLink: (u) {
      native.add(u);
      return true;
    }));
    engine.finish();
    expect(await engine.events.onNavigate(Uri.parse('$base/nodes/$node?embed=1'), true), isFalse);
    expect(native.single.path, '/nodes/$node');
    expect(await engine.events.onNavigate(Uri.parse('https://open-meteo.com/'), true), isFalse);
    expect(opened.single.host, 'open-meteo.com');
    expect(await engine.events.onNavigate(Uri.parse('javascript:alert(1)'), true), isFalse);
    expect(opened.length, 1);
    // another region host is fine; embed is added by loading it again
    expect(await engine.events.onNavigate(Uri.parse('https://day.meshsonar.com/scope-audit'), true), isFalse);
    expect(engine.loads.last.toString(), 'https://day.meshsonar.com/scope-audit?embed=1');
    expect(await engine.events.onNavigate(engine.loads.last, true), isTrue);
    // a redirect that strips embed again is let through, not retried for ever
    expect(await engine.events.onNavigate(Uri.parse('https://day.meshsonar.com/scope-audit'), true), isTrue);
    // frames: only meshsonar.com or blank
    expect(await engine.events.onNavigate(Uri.parse('https://ads.example.com/x'), false), isFalse);
    expect(await engine.events.onNavigate(Uri.parse('about:blank'), false), isTrue);
    expect(opened.length, 1);
    await settleTimers(tester);
  });

  testWidgets('the page router moving to a node opens it natively and steps back once, with no loop', (tester) async {
    final native = <Uri>[];
    await pump(tester, SitePageView(baseUrl: base, path: '/analytics/nodes', title: 'Nodes', onNativeLink: (u) {
      native.add(u);
      return true;
    }));
    engine.finish();
    engine.push('$base/nodes/$node?embed=1');
    await tester.pump();
    expect(native.length, 1);
    expect(engine.backs, 1);
    expect(engine.history.last, '$base/analytics/nodes?embed=1');
    // the same address reported again right away is ignored
    engine.history.add('$base/nodes/$node?embed=1');
    engine.events.onUrlChange('$base/nodes/$node?embed=1');
    engine.events.onUrlChange('$base/nodes/$node?embed=1');
    await tester.pump();
    expect(native.length, 2, reason: 'after the page was somewhere else the link works again, once');
    expect(engine.backs, 2);
    await settleTimers(tester);
  });

  testWidgets('with no history a native address change reloads the first page', (tester) async {
    await pump(tester, SitePageView(baseUrl: base, path: '/status', title: 'Status', onNativeLink: (_) => true));
    engine.finish();
    engine.history
      ..clear()
      ..add('$base/packets/c4b06ee8fc39b187');
    engine.events.onUrlChange('$base/packets/c4b06ee8fc39b187');
    await tester.pump();
    expect(engine.backs, 0);
    expect(engine.loads.last.toString(), '$base/status?embed=1');
    await settleTimers(tester);
  });

  testWidgets('error page with Retry; a slow page becomes an error', (tester) async {
    await pump(tester, const SitePageView(baseUrl: base, path: '/status', title: 'Status'));
    engine.events.onMainFrameError('The Internet connection appears to be offline.');
    await tester.pump();
    expect(find.byKey(const Key('site-page-error')), findsOneWidget);
    expect(find.textContaining("Can't reach MeshSonar"), findsOneWidget);
    expect(tester.getSize(find.text('Try again')).height, greaterThan(0));
    // Build 76: the error page also offers the browser.
    await tester.tap(find.byKey(const Key('site-page-error-browser')));
    await tester.pump();
    expect(opened.single.toString(), '$base/status');
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(engine.loads.length, 2);
    expect(find.byKey(const Key('site-page-error')), findsNothing);
    await tester.pump(const Duration(seconds: 26));
    expect(find.byKey(const Key('site-page-error')), findsOneWidget);
    expect(find.text('This page is slow to load'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back goes back in the page first; Open in browser uses the current address without embed', (tester) async {
    await pump(tester, Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SitePageView(baseUrl: base, path: '/analytics/overview', title: 'Overview'))), child: const Text('go')),
    )));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    engine.finish();
    engine.push('https://day.meshsonar.com/analytics/topology?embed=1&window=7d');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('site-page-close')), findsOneWidget);
    await tester.tap(find.byKey(const Key('site-page-browser')));
    await tester.pump();
    expect(opened.single.toString(), 'https://day.meshsonar.com/analytics/topology?window=7d');
    await tester.pageBack();
    await tester.pump();
    await tester.pump();
    expect(engine.backs, 1);
    expect(find.byKey(const Key('site-page')), findsOneWidget, reason: 'the first Back stays on the screen');
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('site-page')), findsNothing);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('an address that is not meshsonar.com is never loaded', (tester) async {
    var made = false;
    siteWebEngineFactory = (e, _) {
      made = true;
      return FakeEngine(e);
    };
    await pump(tester, const SitePageView(baseUrl: 'https://example.org', path: '/status', title: 'Status'));
    expect(made, isFalse);
    expect(find.byKey(const Key('site-page-bad-address')), findsOneWidget);
  });

  testWidgets('a device with no webview offers the browser', (tester) async {
    siteWebEngineFactory = (e, _) => throw UnsupportedError('no webview');
    await pump(tester, const SitePageView(baseUrl: base, path: '/status', title: 'Status'));
    expect(find.byKey(const Key('site-page-no-engine')), findsOneWidget);
    await tester.tap(find.text('Open in browser'));
    await tester.pump();
    expect(opened.single.toString(), '$base/status');
  });

  testWidgets('Analytics lists the 17 tabs in the site order, 44 pt rows, nothing overflowing', (tester) async {
    await pump(tester, const Scaffold(body: AnalyticsSection(baseUrl: base, regionSlug: 'cmh')));
    expect(analyticsTabs.length, 17);
    expect(analyticsTabs.first.slug, 'overview');
    expect(analyticsTabs[1].label, 'RF / Signal');
    expect(analyticsTabs.last.slug, 'prefix-tool');
    // Build 76: the list is shown under plain headings; every page is still there, once.
    final grouped = [analyticsStartSlug, for (final g in analyticsGroups) ...g.$2];
    expect(grouped.toSet().length, grouped.length, reason: 'no page twice');
    expect(grouped.toSet(), {for (final t in analyticsTabs) t.slug}, reason: 'no page lost');
    expect(find.text('START HERE').evaluate().isNotEmpty || find.text('Start here').evaluate().isNotEmpty, isTrue);
    for (final t in analyticsTabs) {
      expect(find.byKey(Key('analytics-tab-${t.slug}')), findsOneWidget, reason: t.slug);
    }
    expect(tester.getSize(find.byKey(const Key('analytics-tab-overview'))).height, greaterThanOrEqualTo(44));
    await tester.ensureVisible(find.byKey(const Key('analytics-tab-prefix-tool')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('analytics-tab-prefix-tool')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(engine.loads.single.toString(), '$base/analytics/prefix-tool?embed=1');
    await settleTimers(tester);
  });

  testWidgets('initialTab opens that tab; an unknown one shows the list', (tester) async {
    await pump(tester, const Scaffold(body: AnalyticsSection(baseUrl: base, regionSlug: 'cmh', initialTab: 'rf-signal')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(engine.loads.single.toString(), '$base/analytics/rf-signal?embed=1');
    expect(find.text('RF / Signal'), findsWidgets);
    await settleTimers(tester);

    var made = 0;
    siteWebEngineFactory = (e, _) {
      made++;
      return FakeEngine(e);
    };
    await pump(tester, const Scaffold(body: AnalyticsSection(baseUrl: base, regionSlug: 'cmh', initialTab: 'nope')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(made, 0);
    expect(find.byKey(const Key('analytics-section')), findsOneWidget);
  });

  testWidgets('a linked tab shows IN PLACE: no page is pushed, the back arrow returns to the list, a new link shows the new tab', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    Widget app(String? tab) => MaterialApp(navigatorKey: nav, theme: meshSonarTheme(Brightness.dark), home: Scaffold(body: AnalyticsSection(baseUrl: base, regionSlug: 'cmh', initialTab: tab)));
    tester.view.physicalSize = const Size(375, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app('rf-signal'));
    await tester.pump();
    expect(nav.currentState!.canPop(), isFalse, reason: 'nothing was pushed over the section');
    expect(find.byType(AnalyticsSection), findsOneWidget);
    expect(engine.loads.single.toString(), '$base/analytics/rf-signal?embed=1');
    expect(tester.getSize(find.byType(InPlaceHeader)).height, greaterThanOrEqualTo(48));
    final first = engine;
    await tester.pumpWidget(app('topology'));
    await tester.pump();
    expect(identical(engine, first), isFalse, reason: 'a new link is a new page');
    expect(engine.loads.single.toString(), '$base/analytics/topology?embed=1');
    expect(find.text('Topology'), findsOneWidget);
    // inside the page: the arrow steps back in the page first
    engine.finish();
    engine.push('$base/analytics/topology?embed=1&window=7d');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('in-place-back')));
    await tester.pump();
    await tester.pump();
    expect(engine.backs, 1);
    expect(find.byKey(const Key('site-page')), findsOneWidget);
    await tester.tap(find.byKey(const Key('in-place-back')));
    await tester.pump();
    expect(find.byKey(const Key('analytics-section')), findsOneWidget);
    expect(find.byKey(const Key('site-page')), findsNothing);
    expect(tester.takeException(), isNull);
    await settleTimers(tester);
  });

  testWidgets('a page in a hidden tab drops its web view and loads again at the same address when shown', (tester) async {
    var made = 0;
    siteWebEngineFactory = (e, _) {
      made++;
      return engine = FakeEngine(e);
    };
    Widget app(bool showing) => MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: TickerMode(enabled: showing, child: Scaffold(body: SitePageView.inPlace(baseUrl: base, path: '/status', title: 'Status', onClose: () {}))));
    await tester.pumpWidget(app(true));
    await tester.pump();
    engine.finish();
    engine.push('$base/status?embed=1&x=1');
    await tester.pump();
    final first = engine;
    expect(find.byKey(const Key('fake-web')), findsOneWidget);
    await tester.pumpWidget(app(false));
    await tester.pump();
    expect(find.byKey(const Key('fake-web')), findsNothing, reason: 'the web view is gone while hidden');
    // a late event from the dropped page changes nothing
    first.events.onMainFrameError('late');
    await tester.pump();
    expect(find.byKey(const Key('site-page-error')), findsNothing);
    await tester.pumpWidget(app(true));
    await tester.pump();
    expect(made, 2);
    expect(engine.loads.single.toString(), '$base/status?embed=1&x=1');
    expect(find.byKey(const Key('fake-web')), findsOneWidget);
    await settleTimers(tester);
  });
}
