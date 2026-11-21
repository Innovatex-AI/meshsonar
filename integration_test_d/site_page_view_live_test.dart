// On-device check of SitePageView with the REAL web view against the live site (build 71, stream D). Not part of the
// unit suite: it needs a simulator and the network.
//   flutter test integration_test_d/site_page_view_live_test.dart -d <iPhone 17 Pro simulator id>
// For each page: it finishes loading with no error page, the address is on cmh.meshsonar.com with embed=1, the site's
// top bar is absent or hidden, and the page is no wider than the screen. Then a node link in a page is tapped (the
// site's router changes the address without a navigation) and must reach onNativeLink while the page steps back.
// The JavaScript here only READS the page (and clicks one link, as a finger would); nothing of the app goes in.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/ui/network/analytics/site_links.dart';
import 'package:meshsonar/ui/network/analytics/site_page_view.dart';
import 'package:meshsonar/ui/theme.dart';

const base = 'https://cmh.meshsonar.com';

class Probe {
  WebViewSiteEngine? engine;
  int finished = 0;
  final List<String> errors = [];
  final List<String> urls = [];
  final List<String> navigations = [];
  final List<Uri> native = [];

  void install() {
    siteWebEngineFactory = (e, bg) => engine = WebViewSiteEngine(
          SiteWebEvents(
            onNavigate: (u, main) {
              if (main) navigations.add(u.toString());
              return e.onNavigate(u, main);
            },
            onStarted: e.onStarted,
            onFinished: (u) {
              finished++;
              e.onFinished(u);
            },
            onProgress: e.onProgress,
            onMainFrameError: (d) {
              errors.add(d);
              e.onMainFrameError(d);
            },
            onUrlChange: (u) {
              urls.add(u);
              e.onUrlChange(u);
            },
          ),
          bg,
        );
  }

  Future<Object> js(String code) => engine!.controller.runJavaScriptReturningResult(code);
}

/// Real time passes while frames are pumped (the web view loads on the platform side).
Future<void> waitFor(WidgetTester tester, FutureOr<bool> Function() done, {Duration max = const Duration(seconds: 40), String what = ''}) async {
  final end = DateTime.now().add(max);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (await done()) return;
  }
  fail('timed out waiting for $what');
}

bool truthy(Object v) => v == true || v == 1 || '$v' == 'true' || '$v' == '1';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Probe> open(WidgetTester tester, String path, String title) async {
    final probe = Probe()..install();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: SitePageView(
          key: ValueKey(path),
          baseUrl: base,
          path: path,
          title: title,
          onNativeLink: (u) {
            probe.native.add(u);
            return true;
          }),
    ));
    await waitFor(tester, () => probe.finished > 0 || probe.errors.isNotEmpty, what: '$path to finish loading');
    // the site renders on the client: give its content a moment
    await waitFor(tester, () async => truthy(await probe.js("document.readyState === 'complete' && !!document.body && document.body.innerText.length > 40")), what: '$path content');
    return probe;
  }

  Future<void> checkPage(WidgetTester tester, Probe probe, String path) async {
    expect(probe.errors, isEmpty, reason: 'no main-frame error');
    expect(find.byKey(const Key('site-page-error')), findsNothing);
    final url = Uri.parse((await probe.engine!.currentUrl())!);
    // ignore: avoid_print
    print('LIVE $path -> url=$url finished=${probe.finished} urlChanges=${probe.urls.length} navigations=${probe.navigations}');
    expect(url.host, 'cmh.meshsonar.com');
    expect(url.path, path);
    expect(hasEmbed(url), isTrue, reason: 'embed=1 stays in the address');
    final bar = await probe.js("(function(){var e=document.querySelector('.cs-bar');if(!e)return 'absent';var s=getComputedStyle(e);return (s.display==='none'||s.visibility==='hidden')?'hidden':'visible';})()");
    final tabs = await probe.js("(function(){var e=document.querySelector('.anx-tabs');if(!e)return 'absent';return getComputedStyle(e).display==='none'?'hidden':'visible';})()");
    final widths = await probe.js("document.documentElement.scrollWidth + '/' + window.innerWidth");
    final style = await probe.js("!!document.getElementById('ms-app-embed')");
    final dark = await probe.js("getComputedStyle(document.body).backgroundColor");
    // ignore: avoid_print
    print('LIVE $path -> cs-bar=$bar anx-tabs=$tabs scrollWidth/innerWidth=$widths appStyle=$style bodyBackground=$dark');
    expect('$bar'.replaceAll('"', ''), anyOf('absent', 'hidden'));
    expect('$tabs'.replaceAll('"', ''), anyOf('absent', 'hidden'));
    final w = '$widths'.replaceAll('"', '').split('/').map(double.parse).toList();
    expect(w[0], lessThanOrEqualTo(w[1]), reason: 'the page is no wider than the screen');
    expect(truthy(style), isTrue, reason: 'the fallback style sheet was added');
  }

  testWidgets('Analytics > Overview loads in the real web view, embedded, no site bar, no sideways scroll', (tester) async {
    final probe = await open(tester, '/analytics/overview', 'Overview');
    await checkPage(tester, probe, '/analytics/overview');
  });

  testWidgets('Scope Audit loads in the real web view, embedded, no site bar, no sideways scroll', (tester) async {
    final probe = await open(tester, '/scope-audit', 'Scope Audit');
    await checkPage(tester, probe, '/scope-audit');
  });

  testWidgets('tapping a node link inside a page hands it to the app and the page steps back', (tester) async {
    Probe? probe;
    String? found;
    for (final path in ['/analytics/nodes', '/analytics/repeater-metrics', '/scope-audit', '/analytics/overview']) {
      probe = await open(tester, path, 'Page');
      // wait for the data rows (links to a node) to arrive
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 500));
        final n = await probe.js("document.querySelectorAll('a[href*=\"/nodes/\"]').length");
        if ('$n' != '0' && '$n' != '0.0') {
          found = path;
          break;
        }
      }
      if (found != null) break;
    }
    expect(found, isNotNull, reason: 'a page with a node link');
    final p = probe!;
    final before = p.urls.length;
    final href = await p.js("(function(){var a=document.querySelector('a[href*=\"/nodes/\"]');var h=a.href;a.click();return h;})()");
    await waitFor(tester, () => p.native.isNotEmpty, max: const Duration(seconds: 15), what: 'the native hand-off');
    await tester.pump(const Duration(seconds: 2));
    final url = Uri.parse((await p.engine!.currentUrl())!);
    // ignore: avoid_print
    print('LIVE node link on $found -> clicked=$href native=${p.native} urlChangesAfterClick=${p.urls.skip(before).toList()} navigationsSeen=${p.navigations.where((n) => n.contains('/nodes/')).toList()} nowAt=$url');
    expect(p.native.length, 1, reason: 'handed over once, no loop');
    expect(p.native.single.path, startsWith('/nodes/'));
    expect(url.path, found, reason: 'the page stepped back to where it was');
    expect(p.errors, isEmpty);
  });
}
