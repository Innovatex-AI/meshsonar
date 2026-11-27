// One page of the website shown inside the app (build 71, stream D): Analytics tabs, Scope Audit, Compare observers,
// Region definition. It loads `<baseUrl><path>` with `embed=1` (the site then leaves its own bars out), the app's
// theme (`theme=dark|light`) and its time setting (`tz=local|utc`) on the app's own background, with a progress bar,
// an offline / error page with Retry, and "Open in browser". When the phone changes theme or the person changes the
// time setting, the page is loaded again with the new values (Round 2 W2).
//
// Rules (the decisions are in site_links.dart, tested on their own):
// - The page may only move to https pages on meshsonar.com or a subdomain. Any other link opens in the system browser.
// - A link to a node, packet, observer or channel is handed to [SitePageView.onNativeLink]; when that is absent or says
//   no, the app's own `/v1` screen opens. The page stays where it is.
// - The site is a single-page app, so most taps change the address without a navigation request: the same rules run on
//   every address change, and a native link then steps the page back once (never twice for the same address).
// - Nothing of the app goes into the page: no JavaScript channel, no cookies, no headers, no tokens. The one script the
//   app runs is a constant style sheet that hides the site's bars ([siteEmbedScript]).
// - Back goes back inside the page first, then closes the screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/network_request.dart';
import '../../../core/time_format.dart' show TimeZonePreference, activeTimeZone;
import '../../../platform/open_url.dart';
import '../../design/state_views.dart';
import '../../shell/shell_controller.dart' show ShellScope;
import '../nodes/node_routes.dart';
import '../packets/packet_detail_screen.dart' show openNetworkPacket;
import 'in_place_header.dart';
import 'site_links.dart';

/// What the page engine tells the view.
class SiteWebEvents {
  /// A page wants to load [url]; false stops it.
  final FutureOr<bool> Function(Uri url, bool mainFrame) onNavigate;
  final void Function(String url) onStarted;
  final void Function(String url) onFinished;
  final void Function(int percent) onProgress;

  /// The page itself could not be loaded (no connection, DNS, TLS).
  final void Function(String description) onMainFrameError;

  /// The address changed (a load, or the page's own router).
  final void Function(String url) onUrlChange;
  const SiteWebEvents({
    required this.onNavigate,
    required this.onStarted,
    required this.onFinished,
    required this.onProgress,
    required this.onMainFrameError,
    required this.onUrlChange,
  });
}

/// The web engine behind [SitePageView]: the platform webview in the app, a fake in widget tests.
abstract class SiteWebEngine {
  Widget build(BuildContext context);
  Future<void> load(Uri url);
  Future<void> reload();
  Future<bool> canGoBack();
  Future<void> goBack();
  Future<String?> currentUrl();

  /// Runs a constant script in the page (only [siteEmbedScript]).
  Future<void> runScript(String script);
}

/// Makes the engine; widget tests replace it. Throws on a platform with no webview (the view then offers the browser).
SiteWebEngine Function(SiteWebEvents events, Color background) siteWebEngineFactory = WebViewSiteEngine.new;

/// Test seam for the system browser.
Future<bool> Function(Uri url) siteOpenExternal = openExternalUrl;

/// WKWebView / Android WebView. JavaScript is on because the site is a client-rendered app; no JavaScript channel is
/// added and no cookie or header is set.
class WebViewSiteEngine implements SiteWebEngine {
  final WebViewController _c = WebViewController();

  /// Not failures: a load the app stopped or replaced (NSURLErrorCancelled, WebKit "frame load interrupted").
  static const Set<int> _quiet = {-999, 102};

  WebViewSiteEngine(SiteWebEvents e, Color background) {
    unawaited(_c.setJavaScriptMode(JavaScriptMode.unrestricted).catchError((Object _) {}));
    unawaited(_c.setBackgroundColor(background).catchError((Object _) {}));
    unawaited(_c
        .setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: (r) async {
            final u = Uri.tryParse(r.url);
            if (u == null) return NavigationDecision.prevent;
            return await e.onNavigate(u, r.isMainFrame) ? NavigationDecision.navigate : NavigationDecision.prevent;
          },
          onPageStarted: e.onStarted,
          onPageFinished: e.onFinished,
          onProgress: e.onProgress,
          onUrlChange: (c) {
            final u = c.url;
            if (u != null) e.onUrlChange(u);
          },
          onWebResourceError: (err) {
            if (err.isForMainFrame == false || _quiet.contains(err.errorCode)) return;
            e.onMainFrameError(err.description);
          },
        ))
        .catchError((Object _) {}));
  }

  /// For the on-device check only (integration_test_d): read-only questions to the page. App code does not use it.
  WebViewController get controller => _c;

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _c);
  @override
  Future<void> load(Uri url) => _c.loadRequest(url);
  @override
  Future<void> reload() => _c.reload();
  @override
  Future<bool> canGoBack() => _c.canGoBack();
  @override
  Future<void> goBack() => _c.goBack();
  @override
  Future<String?> currentUrl() => _c.currentUrl();
  @override
  Future<void> runScript(String script) => _c.runJavaScript(script);
}

class SitePageView extends StatefulWidget {
  final String baseUrl;

  /// Site path with its query, e.g. `/analytics/rf-signal` or `/scope-audit`.
  final String path;
  final String title;

  /// Returns true when the app opened the link natively (the page then stays where it is).
  final bool Function(Uri link)? onNativeLink;

  /// Null: a screen of its own (app bar, pushed over the tab). Given: the page sits in place inside a section under a
  /// 48 pt header whose back arrow calls this.
  final VoidCallback? onClose;
  const SitePageView({super.key, required this.baseUrl, required this.path, required this.title, this.onNativeLink}) : onClose = null;

  /// The page in place inside a Network section (a link opened it): no route is pushed, [onClose] returns to the list.
  const SitePageView.inPlace({super.key, required this.baseUrl, required this.path, required this.title, required VoidCallback this.onClose, this.onNativeLink});

  @override
  State<SitePageView> createState() => _SitePageViewState();
}

class _SitePageViewState extends State<SitePageView> {
  /// A page that has shown nothing after this long is treated as not reachable (never an endless bar).
  static const Duration _patience = Duration(seconds: 25);

  static const String _slowText = 'The page took too long to load.';
  bool get _slow => _error == _slowText;

  late final Uri? _start = sitePageUri(widget.baseUrl, widget.path);

  /// The theme and time setting the loaded page was given; null before the first load.
  SiteLook? _look;

  SiteLook _lookNow() => SiteLook(dark: Theme.of(context).brightness == Brightness.dark, utc: activeTimeZone == TimeZonePreference.utc);
  SiteWebEngine? _engine;
  bool _noEngine = false;
  bool _loading = true;
  int _progress = 0;
  String? _error;
  bool _canGoBack = false;
  Uri? _current;

  /// True once a page has finished loading in this view: until then the body says what is loading (a first load used
  /// to be a blank dark page with a 2 px bar).
  bool _shownOnce = false;

  /// The native link last acted on from an address change: the same address is not acted on again until the page has
  /// been somewhere else (stepping back can never loop).
  String? _handled;
  String? _embedAdded;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _current = _start;
  }

  /// Bumped when the engine is dropped, so a late event from the old one is ignored.
  int _gen = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_noEngine || _start == null) return;
    // A hidden tab has its TickerMode off (home_shell): the web view is dropped there, so the page stops loading,
    // polling and running scripts, and is loaded again at the same address when the tab shows.
    final showing = TickerMode.valuesOf(context).enabled;
    if (!showing) {
      if (_engine != null) {
        _gen++;
        _engine = null;
        _timer?.cancel();
        _loading = false;
        _canGoBack = false;
      }
      return;
    }
    if (_engine != null) {
      final look = _look, now = _lookNow();
      if (look == null || look == now) return;
      if (look.dark == now.dark) {
        // The time setting changed: the same page again, with the new value.
        _load(notify: false);
        return;
      }
      // The phone switched theme: a new web view on the new background, at the same address, with the new look.
      _gen++;
      _engine = null;
      _timer?.cancel();
      _canGoBack = false;
      _shownOnce = false;
    }
    final g = ++_gen;
    void on(void Function() f) {
      if (g == _gen) f();
    }

    try {
      _engine = siteWebEngineFactory(
        SiteWebEvents(
          onNavigate: (u, main) => g == _gen ? _onNavigate(u, main) : false,
          onStarted: (u) => on(() => _onStarted(u)),
          onFinished: (u) => on(() => _onFinished(u)),
          onProgress: (p) => on(() => _onProgress(p)),
          onMainFrameError: (d) => on(() => _onError(d)),
          onUrlChange: (u) => on(() => _onUrlChange(u)),
        ),
        Theme.of(context).scaffoldBackgroundColor,
      );
      _load(notify: false);
    } catch (_) {
      _noEngine = true;
      _loading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// [notify] false when called while the widget is being built (the build that follows shows the new state).
  void _load({bool notify = true}) {
    final e = _engine, start = _start;
    if (e == null || start == null) return;
    _timer?.cancel();
    _timer = Timer(_patience, () {
      if (mounted && _loading) _onError(_slowText);
    });
    void set() {
      _error = null;
      _loading = true;
      _progress = 0;
    }

    notify ? setState(set) : set();
    final look = _look = _lookNow();
    // The address is rebuilt from scratch so an older theme or tz on it is replaced, not kept.
    final at = withoutEmbed(_current != null && isMeshSonarHost(_current!) ? _current! : start);
    unawaited(e.load(withEmbed(at, look)).catchError((Object _) => _onError('The page could not be loaded.')));
  }

  FutureOr<bool> _onNavigate(Uri url, bool mainFrame) {
    if (!mainFrame) return url.scheme == 'about' || isMeshSonarHost(url);
    switch (decideSiteLink(url)) {
      case SiteLinkAction.allow:
        // A link that dropped `embed` is loaded again with it, once per address: a server redirect that strips it
        // is then let through instead of being retried for ever.
        final key = '${url.host}${url.path}';
        final look = _look ?? _lookNow();
        if (url.scheme == 'https' && !hasEmbed(url, look) && _embedAdded != key) {
          _embedAdded = key;
          unawaited(_engine?.load(withEmbed(withoutEmbed(url), look)));
          return false;
        }
        if (_embedAdded != key) _embedAdded = null;
        return true;
      case SiteLinkAction.native:
        // A channel with no shell above (an isolated screen) has no native page: the site's own page is shown.
        return !_openNative(url);
      case SiteLinkAction.external:
        if (isOpenableExternally(url)) unawaited(siteOpenExternal(url));
        return false;
    }
  }

  void _onUrlChange(String raw) {
    final url = Uri.tryParse(raw);
    if (url == null || !mounted) return;
    if (nativeTargetOf(url) != null) {
      if (raw == _handled) return;
      _handled = raw;
      if (_openNative(url)) unawaited(_stepBack());
      return;
    }
    _handled = null;
    if (isMeshSonarHost(url)) _current = url;
    _refreshBack();
  }

  /// Leaves the node / packet page the page's router moved to: one step back, or the first page when there is no history.
  Future<void> _stepBack() async {
    final e = _engine, start = _start;
    if (e == null || start == null) return;
    try {
      if (await e.canGoBack()) {
        await e.goBack();
      } else {
        await e.load(start);
      }
    } catch (_) {}
  }

  /// True when the app showed [link] itself.
  bool _openNative(Uri link) {
    if (widget.onNativeLink?.call(link) ?? false) return true;
    final r = nativeTargetOf(link);
    if (r == null || !mounted) return false;
    final base = regionBaseOf(r, widget.baseUrl);
    final slug = r.region ?? regionSlugOfBase(widget.baseUrl) ?? '';
    final head = link.pathSegments.firstWhere((s) => s.isNotEmpty, orElse: () => '').toLowerCase();
    switch (head) {
      case 'nodes' || 'repeaters':
        openNetworkNode(context, baseUrl: base, regionSlug: slug, nodeKey: r.nodeKey!);
        return true;
      case 'packets':
        unawaited(openNetworkPacket(context, baseUrl: base, regionSlug: slug.isEmpty ? null : slug, hash: r.packetHash!));
        return true;
      case 'observers':
        openNetworkObserver(context, baseUrl: base, regionSlug: slug, observerId: r.observerId!);
        return true;
      case 'channels':
        final shell = ShellScope.maybeRead(context);
        if (shell == null) return false;
        Navigator.of(context).popUntil((route) => route.isFirst);
        shell.openNetwork(NetworkRequest.channel(r.channelId!, region: r.region));
        return true;
    }
    return false;
  }

  void _onStarted(String url) {
    unawaited(_engine?.runScript(siteEmbedScript).catchError((Object _) {}));
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
  }

  void _onFinished(String url) {
    _timer?.cancel();
    unawaited(_engine?.runScript(siteEmbedScript).catchError((Object _) {}));
    if (!mounted) return;
    setState(() {
      _loading = false;
      _shownOnce = true;
    });
    _refreshBack();
  }

  void _onProgress(int p) {
    if (mounted && p != _progress) setState(() => _progress = p);
  }

  void _onError(String description) {
    _timer?.cancel();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = description;
    });
  }

  void _refreshBack() {
    final e = _engine;
    if (e == null) return;
    unawaited(e.canGoBack().then((v) {
      if (mounted && v != _canGoBack) setState(() => _canGoBack = v);
    }).catchError((Object _) {}));
  }

  /// The page's address now, without `embed` (falls back to the address it was opened with).
  Future<void> _openInBrowser() async {
    Uri? u;
    try {
      final s = await _engine?.currentUrl();
      u = s == null ? null : Uri.tryParse(s);
    } catch (_) {}
    u = (u != null && isMeshSonarHost(u)) ? u : (_current ?? _start);
    if (u == null) return;
    await siteOpenExternal(withoutEmbed(u));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final e = _engine;
    final Widget body;
    if (_start == null) {
      body = const AppErrorView(key: Key('site-page-bad-address'), title: 'This page is not on MeshSonar', message: 'The app only shows meshsonar.com pages here.');
    } else if (e == null && !_noEngine) {
      // The tab is hidden: the web view is dropped until it shows again.
      body = const SizedBox.expand();
    } else if (e == null) {
      body = AppErrorView(
        key: const Key('site-page-no-engine'),
        title: 'This page opens in your browser',
        message: 'This device cannot show ${widget.title} inside the app.',
        onRetry: _openInBrowser,
        retryLabel: 'Open in browser',
      );
    } else {
      body = Stack(fit: StackFit.expand, children: [
        // Kept in the tree while the error page shows, so Retry reloads the same engine and its history.
        Offstage(offstage: _error != null, child: e.build(context)),
        if (_error != null)
          Positioned.fill(
            child: ColoredBox(
              color: t.scaffoldBackgroundColor,
              // Plain words first; the engine's own text is kept, last and in brackets, for a problem report. The page can
              // still be opened in the browser from here (the header button does the same).
              child: Column(key: const Key('site-page-error'), mainAxisAlignment: MainAxisAlignment.center, children: [
                Flexible(
                  child: AppErrorView(
                    title: _slow ? 'This page is slow to load' : "Can't reach MeshSonar",
                    message: _slow
                        ? 'It did not show after ${_patience.inSeconds} seconds. Try again, or open it in your browser.'
                        : 'Check your connection, then try again. ($_error)',
                    onRetry: _load,
                  ),
                ),
                TextButton.icon(
                  key: const Key('site-page-error-browser'),
                  onPressed: _openInBrowser,
                  icon: const Icon(Icons.open_in_browser, size: 18),
                  label: const Text('Open in browser instead'),
                ),
                const SizedBox(height: 16),
              ]),
            ),
          ),
        if (_loading && _error == null && !_shownOnce)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: t.scaffoldBackgroundColor,
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
                    const SizedBox(height: 12),
                    Text('Loading ${widget.title}…', key: const Key('site-page-loading-label'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ]),
                ),
              ),
            ),
          ),
        if (_loading && _error == null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(key: const Key('site-page-loading'), value: _progress > 0 && _progress < 100 ? _progress / 100 : null, minHeight: 2),
          ),
      ]);
    }
    final actions = [
      if (_canGoBack && widget.onClose == null)
        IconButton(key: const Key('site-page-close'), tooltip: 'Close this page', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
      if (e != null && _start != null) IconButton(key: const Key('site-page-reload'), tooltip: 'Reload this page', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: _load, icon: const Icon(Icons.refresh)),
      if (_start != null)
        IconButton(key: const Key('site-page-browser'), tooltip: 'Open in browser', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: _openInBrowser, icon: const Icon(Icons.open_in_browser)),
    ];
    final close = widget.onClose;
    if (close != null) {
      // In place inside a section: the back arrow steps back inside the page first, then returns to the list. No
      // PopScope here, so the tab's own Back is never held.
      return Material(
        key: const Key('site-page'),
        color: t.scaffoldBackgroundColor,
        child: Column(children: [
          InPlaceHeader(
            title: widget.title,
            backLabel: _canGoBack ? 'Back in this page' : 'Back to the list',
            onBack: () {
              if (_canGoBack) {
                unawaited(_engine?.goBack().then((_) => _refreshBack()).catchError((Object _) {}));
              } else {
                close();
              }
            },
            actions: [
              if (_canGoBack) IconButton(key: const Key('site-page-close'), tooltip: 'Back to the list', constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: close, icon: const Icon(Icons.close)),
              ...actions,
            ],
          ),
          Expanded(child: body),
        ]),
      );
    }
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_engine?.goBack().then((_) => _refreshBack()).catchError((Object _) {}));
      },
      child: Scaffold(
        key: const Key('site-page'),
        backgroundColor: t.scaffoldBackgroundColor,
        appBar: AppBar(title: Text(widget.title, overflow: TextOverflow.ellipsis), actions: actions),
        body: SafeArea(child: body),
      ),
    );
  }
}
