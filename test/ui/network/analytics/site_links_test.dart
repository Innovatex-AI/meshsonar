// The rules of a site page inside the app (site_links.dart): which hosts it may go to, which links open natively,
// embed on and off.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/network/analytics/site_links.dart';

const node = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';

void main() {
  SiteLinkAction d(String u) => decideSiteLink(Uri.parse(u));

  test('only https meshsonar.com hosts are allowed', () {
    expect(d('https://cmh.meshsonar.com/analytics/rf-signal?embed=1'), SiteLinkAction.allow);
    expect(d('https://meshsonar.com/status'), SiteLinkAction.allow);
    expect(d('https://day.meshsonar.com/scope-audit'), SiteLinkAction.allow);
    expect(d('about:blank'), SiteLinkAction.allow);
    expect(d('http://cmh.meshsonar.com/analytics/overview'), SiteLinkAction.external);
    expect(d('https://evilmeshsonar.com/analytics/overview'), SiteLinkAction.external);
    expect(d('https://meshsonar.com.evil.io/x'), SiteLinkAction.external);
    expect(d('https://meshsonar.com@evil.io/x'), SiteLinkAction.external);
    expect(d('https://open-meteo.com/'), SiteLinkAction.external);
    expect(d('mailto:someone@example.org'), SiteLinkAction.external);
    expect(d('javascript:alert(1)'), SiteLinkAction.external);
  });

  test('schemes the system may open', () {
    expect(isOpenableExternally(Uri.parse('https://open-meteo.com/')), isTrue);
    expect(isOpenableExternally(Uri.parse('mailto:someone@example.org')), isTrue);
    expect(isOpenableExternally(Uri.parse('javascript:alert(1)')), isFalse);
    expect(isOpenableExternally(Uri.parse('file:///etc/hosts')), isFalse);
    expect(isOpenableExternally(Uri.parse('meshsonar://network/packets')), isFalse);
  });

  test('node, packet, observer and channel pages open natively', () {
    expect(d('https://cmh.meshsonar.com/nodes/$node?embed=1'), SiteLinkAction.native);
    expect(d('https://cmh.meshsonar.com/repeaters/$node'), SiteLinkAction.native);
    expect(d('https://cmh.meshsonar.com/packets/c4b06ee8fc39b187?embed=1'), SiteLinkAction.native);
    expect(d('https://cmh.meshsonar.com/observers/$node'), SiteLinkAction.native);
    expect(d('https://cmh.meshsonar.com/channels/public'), SiteLinkAction.native);
    final r = nativeTargetOf(Uri.parse('https://day.meshsonar.com/nodes/$node?embed=1'))!;
    expect(r.nodeKey, node);
    expect(r.region, 'day');
    expect(regionBaseOf(r, 'https://cmh.meshsonar.com'), 'https://day.meshsonar.com');
    final hub = nativeTargetOf(Uri.parse('https://meshsonar.com/packets/c4b06ee8fc39b187'))!;
    expect(regionBaseOf(hub, 'https://cmh.meshsonar.com'), 'https://cmh.meshsonar.com');
  });

  test('lists, tool pages and wrong ids stay in the page', () {
    expect(d('https://cmh.meshsonar.com/nodes'), SiteLinkAction.allow);
    expect(d('https://cmh.meshsonar.com/packets?node=$node'), SiteLinkAction.allow);
    expect(d('https://cmh.meshsonar.com/observers/compare?a=x&b=y'), SiteLinkAction.allow);
    expect(d('https://cmh.meshsonar.com/observers/setup'), SiteLinkAction.allow);
    expect(d('https://cmh.meshsonar.com/nodes/not-a-key'), SiteLinkAction.allow);
    expect(d('https://cmh.meshsonar.com/tools/region?lat=1&lon=2'), SiteLinkAction.allow);
    expect(d('https://cmh.meshsonar.com/analytics/nodes'), SiteLinkAction.allow);
  });

  test('embed is added once and taken off for the browser', () {
    final u = sitePageUri('https://cmh.meshsonar.com/', '/analytics/rf-signal?window=7d')!;
    expect(u.toString(), 'https://cmh.meshsonar.com/analytics/rf-signal?window=7d&embed=1');
    expect(withEmbed(u), u);
    expect(sitePageUri('https://cmh.meshsonar.com', 'scope-audit').toString(), 'https://cmh.meshsonar.com/scope-audit?embed=1');
    expect(withoutEmbed(u).toString(), 'https://cmh.meshsonar.com/analytics/rf-signal?window=7d');
    expect(withoutEmbed(Uri.parse('https://cmh.meshsonar.com/status?embed=1')).toString(), 'https://cmh.meshsonar.com/status');
    expect(withoutEmbed(Uri.parse('https://cmh.meshsonar.com/status?embed=1#x')).toString(), 'https://cmh.meshsonar.com/status#x');
    expect(sitePageUri('https://example.org', '/status'), isNull);
    expect(sitePageUri('http://cmh.meshsonar.com', '/status'), isNull);
  });

  test('build 77 (Round 2 W2): the app look rides with embed as theme= and tz=, and comes off again for the browser', () {
    const light = SiteLook(dark: false, utc: false), utcDark = SiteLook(dark: true, utc: true);
    final u = sitePageUri('https://cmh.meshsonar.com', '/analytics/rf-signal?window=7d', light)!;
    expect(u.toString(), 'https://cmh.meshsonar.com/analytics/rf-signal?window=7d&embed=1&theme=light&tz=local');
    expect(hasEmbed(u, light), isTrue);
    expect(hasEmbed(u, utcDark), isFalse, reason: 'another look is not this page');
    expect(withEmbed(u, light), u);
    // A new look replaces the old keys once the address is rebuilt from scratch.
    expect(withEmbed(withoutEmbed(u), utcDark).toString(), 'https://cmh.meshsonar.com/analytics/rf-signal?window=7d&embed=1&theme=dark&tz=utc');
    expect(withoutEmbed(u).toString(), 'https://cmh.meshsonar.com/analytics/rf-signal?window=7d');
    expect(siteEmbedKeys, {'embed', 'theme', 'tz'});
  });

  test('region slug of a base address', () {
    expect(regionSlugOfBase('https://cmh.meshsonar.com'), 'cmh');
    expect(regionSlugOfBase('https://cmh.meshsonar.com/'), 'cmh');
    expect(regionSlugOfBase('https://meshsonar.com'), isNull);
  });

  test('the injected script is a constant style sheet and carries no app data', () {
    expect(siteEmbedScript, contains('ms-app-embed'));
    expect(siteEmbedScript, contains('.cs-bar'));
    expect(siteEmbedScript, contains('.anx-tabs'));
    expect(siteEmbedScript, isNot(contains('postMessage')));
    expect(siteEmbedScript, isNot(contains('cookie')));
  });
}
