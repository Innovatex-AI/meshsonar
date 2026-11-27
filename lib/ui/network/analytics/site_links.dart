// The rules for a website page shown inside the app ([SitePageView]), with no Flutter or webview in them so they are
// tested on their own:
//   - which hosts the page may move to (https, meshsonar.com or a subdomain of it, nothing else),
//   - which links are a node, packet, observer or channel page the app shows natively instead,
//   - how `embed=1` is added to a link, with the app's look (`theme=light|dark`, the app's theme) and its time
//     setting (`tz=local|utc`, Settings > Map & display > Time zone), and taken off again for "Open in browser"
//     (Round 2 W2: every embedded page gets the three keys; a site that does not read them yet ignores them),
//   - the one fixed style sheet that hides the site's own bars while a page does not honour `embed=1` yet.
// Nothing here reads or sends app data: the style sheet is a constant.
import '../../../core/network_request.dart';

/// What to do with a link a site page wants to go to.
enum SiteLinkAction {
  /// A meshsonar.com page: load it in the page view.
  allow,

  /// A node, packet, observer or channel: open the app's own screen, the page stays where it is.
  native,

  /// Anything else (another site, http, mailto, tel): hand it to the system browser.
  external,
}

/// https on meshsonar.com or one of its subdomains. `evilmeshsonar.com` and `meshsonar.com.evil.io` are not.
bool isMeshSonarHost(Uri u) {
  if (u.scheme != 'https') return false;
  final h = u.host.toLowerCase();
  return h == networkApexHost || h.endsWith('.$networkApexHost');
}

const Set<String> _observerPages = {'compare', 'join', 'setup'};

/// The node / packet / observer / channel a link names (`/nodes/<key>`, `/repeaters/<key>`, `/packets/<hash>`,
/// `/observers/<id>`, `/channels/<id>`), read with the app's own link parser; null for every other link, lists and
/// tool pages included.
NetworkRequest? nativeTargetOf(Uri u) {
  if (!isMeshSonarHost(u)) return null;
  final segs = [for (final s in u.pathSegments) if (s.isNotEmpty) s];
  if (segs.length != 2) return null;
  final head = segs.first.toLowerCase();
  if (head == 'observers' && _observerPages.contains(segs[1].toLowerCase())) return null;
  // Only the path names the target: a list filter in the query (`?node=`) is not a detail page.
  final region = u.queryParameters['region'];
  final r = NetworkRequest.parse(Uri(scheme: u.scheme, host: u.host, path: u.path, queryParameters: region == null ? null : {'region': region}));
  if (r == null) return null;
  return switch (head) {
    'nodes' || 'repeaters' => r.nodeKey == null ? null : r,
    'packets' => r.packetHash == null ? null : r,
    'observers' => r.observerId == null ? null : r,
    'channels' => r.channelId == null ? null : r,
    _ => null,
  };
}

/// The decision for one link. `about:` pages (a blank frame) are allowed; they load nothing from anywhere.
SiteLinkAction decideSiteLink(Uri u) {
  if (u.scheme == 'about') return SiteLinkAction.allow;
  if (!isMeshSonarHost(u)) return SiteLinkAction.external;
  return nativeTargetOf(u) == null ? SiteLinkAction.allow : SiteLinkAction.native;
}

/// Schemes the system may open from a page (a web page, a mail or phone link). Others (javascript:, file:, data:,
/// app schemes) are dropped.
bool isOpenableExternally(Uri u) => const {'https', 'http', 'mailto', 'tel'}.contains(u.scheme);

/// How the app looks right now, passed to every embedded page so the page can match it: the theme (dark or light)
/// and the time setting (the phone's time, or UTC). Nothing personal: two words.
class SiteLook {
  final bool dark, utc;
  const SiteLook({required this.dark, required this.utc});

  /// What a page got before build 77 (the site then draws its embedded pages dark, in its own time).
  static const SiteLook none = SiteLook(dark: true, utc: false);

  String get theme => dark ? 'dark' : 'light';
  String get tz => utc ? 'utc' : 'local';

  @override
  bool operator ==(Object other) => other is SiteLook && other.dark == dark && other.utc == utc;
  @override
  int get hashCode => Object.hash(dark, utc);
}

/// The query keys the app adds to an embedded page and takes off again for the browser.
const Set<String> siteEmbedKeys = {'embed', 'theme', 'tz'};

/// True when [u] carries `embed=1` and, with [look], that look's `theme` and `tz` too.
bool hasEmbed(Uri u, [SiteLook? look]) {
  final q = u.queryParameters;
  if (q['embed'] != '1') return false;
  return look == null || (q['theme'] == look.theme && q['tz'] == look.tz);
}

/// [u] with `embed=1` in its query and, with [look], `theme=` and `tz=` (other keys kept, in their order).
Uri withEmbed(Uri u, [SiteLook? look]) {
  if (hasEmbed(u, look)) return u;
  return u.replace(queryParameters: {
    ...u.queryParametersAll,
    'embed': ['1'],
    if (look != null) 'theme': [look.theme],
    if (look != null) 'tz': [look.tz],
  });
}

/// [u] without `embed`, `theme` and `tz` (the address to open in a browser or share).
Uri withoutEmbed(Uri u) {
  if (!u.queryParametersAll.keys.any(siteEmbedKeys.contains)) return u;
  final q = {...u.queryParametersAll}..removeWhere((k, _) => siteEmbedKeys.contains(k));
  return Uri(
    scheme: u.scheme,
    host: u.host,
    port: u.hasPort ? u.port : null,
    path: u.path,
    queryParameters: q.isEmpty ? null : q,
    fragment: u.hasFragment ? u.fragment : null,
  );
}

/// `<baseUrl><path>` with `embed=1` (and [look]); null when it is not a meshsonar.com https address (the view then
/// shows an error instead of loading it).
Uri? sitePageUri(String baseUrl, String path, [SiteLook? look]) {
  final b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final p = path.startsWith('/') ? path : '/$path';
  final u = Uri.tryParse('$b$p');
  if (u == null || !isMeshSonarHost(u)) return null;
  return withEmbed(u, look);
}

/// The region host a link belongs to (`https://cmh.meshsonar.com`), or [fallbackBaseUrl] when the link names no region.
String regionBaseOf(NetworkRequest r, String fallbackBaseUrl) => r.region == null ? fallbackBaseUrl : 'https://${r.region}.$networkApexHost';

/// The region slug of a region host address (`cmh` for https://cmh.meshsonar.com); null for the hub and other hosts.
String? regionSlugOfBase(String baseUrl) => NetworkRequest.parse(Uri.tryParse(baseUrl.trim().replaceAll(RegExp(r'/+$'), '')) ?? Uri())?.region;

/// The site's own bars and the Analytics page's title and tab strip (the app shows its own). Hidden by this style sheet
/// while a page does not honour `embed=1`; a selector that matches nothing does nothing.
const String siteEmbedCss = '.cs-bar,.cs-bnav,.cs-foot-tools,.report-footer,.site-credits,.print-header,.skip-link,.anx-head,.anx-tabs{display:none!important}';

/// Adds [siteEmbedCss] to the page once (a second run finds the element and stops). A constant: no app data goes in,
/// nothing comes back.
const String siteEmbedScript = "(function(){try{if(document.getElementById('ms-app-embed'))return;var s=document.createElement('style');s.id='ms-app-embed';"
    "s.textContent='$siteEmbedCss';(document.head||document.documentElement).appendChild(s);}catch(e){}})();";
