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

  test('same server: any two of the Lovable host, meshsonar.com and cmh.meshsonar.com; nothing else', () {
    const same = ['https://cmh-meshcore.lovable.app/', 'https://meshsonar.com', 'http://CMH.meshsonar.com/x'];
    for (final a in same) {
      for (final b in same) {
        expect(isSameServer(a, b), isTrue, reason: '$a ↔ $b');
      }
    }
    expect(sameServerHosts, {'cmh-meshcore.lovable.app', 'meshsonar.com', 'cmh.meshsonar.com'});
    for (final other in ['https://other.example', 'https://dev.meshsonar.com', 'https://www.meshsonar.com', 'x']) {
      expect(isSameServer('https://meshsonar.com', other), isFalse, reason: other);
      expect(isSameServer(other, 'https://cmh-meshcore.lovable.app'), isFalse, reason: other);
    }
    expect(isSameServer('https://other.example', 'https://other.example/'), isFalse,
        reason: 'only the listed hosts count as aliases');
  });
}
