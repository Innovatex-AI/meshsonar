// 0.5.0 server move (docs/specs/app-0.5.0.md §2): default server, retired-host rewrite and same-server aliases.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/server_url.dart';

void main() {
  test('the default server is https://meshsonar.com (new installs and a settings file without server_url)', () {
    expect(defaultServerUrl, 'https://meshsonar.com');
    expect(const Settings().serverUrl, 'https://meshsonar.com');
    expect(Settings.fromJson(const {}).serverUrl, 'https://meshsonar.com');
  });

  test('every spelling of the Lovable host is rewritten to https://meshsonar.com', () {
    for (final url in [
      'https://cmh-meshcore.lovable.app',
      'https://cmh-meshcore.lovable.app/',
      'https://cmh-meshcore.lovable.app//',
      'http://cmh-meshcore.lovable.app',
      'HTTPS://CMH-MESHCORE.LOVABLE.APP/',
      'https://cmh-meshcore.lovable.app/api/cmh',
      '  https://cmh-meshcore.lovable.app/me  ',
    ]) {
      expect(migratedServerUrl(url), 'https://meshsonar.com', reason: url);
    }
  });

  test('idempotent, and other hosts are never rewritten', () {
    expect(migratedServerUrl(migratedServerUrl('https://cmh-meshcore.lovable.app/')!), isNull);
    for (final url in [
      'https://meshsonar.com',
      'https://cmh.meshsonar.com',
      'https://other.example',
      'https://lovable.app',
      'https://other-meshcore.lovable.app',
      'https://cmh-meshcore.lovable.app.evil.example',
      'http://localhost:8080',
      'not a url',
      '',
    ]) {
      expect(migratedServerUrl(url), isNull, reason: url);
    }
  });

  test('retired host with userinfo or a non-default port is not rewritten', () {
    expect(migratedServerUrl('https://user:pw@cmh-meshcore.lovable.app'), isNull);
    expect(migratedServerUrl('https://cmh-meshcore.lovable.app:8443'), isNull);
    expect(migratedServerUrl('ftp://cmh-meshcore.lovable.app'), isNull);
    expect(migratedServerUrl('https://@cmh-meshcore.lovable.app'), isNull);
    expect(migratedServerUrl('https://cmh-meshcore.lovable.app:443/'), 'https://meshsonar.com');
    expect(migratedServerUrl('http://cmh-meshcore.lovable.app:80'), 'https://meshsonar.com');
  });

  test('same server: any two plain https addresses of the Lovable host, meshsonar.com and cmh.meshsonar.com', () {
    const same = [
      'https://cmh-meshcore.lovable.app/',
      'https://meshsonar.com',
      'https://CMH.meshsonar.com',
      'HTTPS://MeshSonar.com/',
      'https://meshsonar.com:443',
    ];
    for (final a in same) {
      for (final b in same) {
        expect(isSameServer(a, b), isTrue, reason: '$a ↔ $b');
      }
    }
    expect(sameServerHosts, {'cmh-meshcore.lovable.app', 'meshsonar.com', 'cmh.meshsonar.com'});
  });

  test('not an alias: http, a port, userinfo, a path, query/fragment, other or look-alike hosts', () {
    const notAlias = [
      // https → http (either side)
      'http://meshsonar.com', 'http://cmh.meshsonar.com', 'http://cmh-meshcore.lovable.app',
      // ports
      'https://meshsonar.com:8443', 'https://cmh.meshsonar.com:444', 'https://meshsonar.com:80',
      // userinfo
      'https://user@meshsonar.com', 'https://user:pw@cmh.meshsonar.com', 'https://@meshsonar.com',
      'https://meshsonar.com@evil.example', 'https://evil.example@meshsonar.com',
      // paths, query, fragment
      'https://meshsonar.com/api', 'https://meshsonar.com/other/', 'https://meshsonar.com//',
      'https://meshsonar.com/?x=1', 'https://meshsonar.com/#me',
      // other hosts and look-alikes
      'https://other.example', 'https://dev.meshsonar.com', 'https://www.meshsonar.com',
      'https://meshsonar.com.evil.example', 'https://evilmeshsonar.com', 'https://meshsonar.co',
      'https://meshsonar.com.', 'https://cmh-meshcore.lovable.app.evil.example', 'https://lovable.app',
      'https://xn--meshsnar-0za.com', 'https://meshs0nar.com', 'https://cmh.meshsonar.com.evil.example',
      'meshsonar.com', 'x', '',
    ];
    for (final other in notAlias) {
      expect(isSameServer('https://meshsonar.com', other), isFalse, reason: 'meshsonar.com → $other');
      expect(isSameServer(other, 'https://cmh-meshcore.lovable.app'), isFalse, reason: '$other → lovable');
    }
    expect(isSameServer('https://other.example', 'https://other.example/'), isFalse,
        reason: 'only the listed hosts count as aliases');
  });
}
