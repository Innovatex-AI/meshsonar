// 0.5.0 server move in AppState (docs/specs/app-0.5.0.md §2): a saved Lovable URL is rewritten at startup with the
// driver key kept; moves between the same server's addresses keep the key; any other change still removes it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';

import '../ui/fakes.dart';

const _key = 'secretkey-abcdef-1234';

Settings _withKey(String url) =>
    Settings(serverUrl: url, driverKey: _key, keyStatus: DriverKeyStatus.approved, display: 'KD8XYZ');

void main() {
  for (final saved in [
    'https://cmh-meshcore.lovable.app',
    'https://cmh-meshcore.lovable.app/',
    'http://cmh-meshcore.lovable.app/api/cmh/',
  ]) {
    test('startup rewrites "$saved" to https://meshsonar.com, keeps the key, and saves it', () async {
      final h = Harness()..settings.saved = _withKey(saved);
      await h.state.init();
      expect(h.state.settings.serverUrl, 'https://meshsonar.com');
      expect(h.state.settings.driverKey, _key);
      expect(h.state.settings.keyStatus, DriverKeyStatus.approved);
      expect(h.state.settings.display, 'KD8XYZ');
      expect(h.settings.saved.serverUrl, 'https://meshsonar.com', reason: 'persisted');
      expect(h.settings.saved.driverKey, _key, reason: 'persisted with the key');
      expect(h.client.baseUrl, Uri.parse('https://meshsonar.com'));
    });
  }

  test('the rewrite is idempotent: a second launch changes and saves nothing', () async {
    final h = Harness()..settings.saved = _withKey('https://cmh-meshcore.lovable.app/');
    await h.state.init();
    final saves = h.settings.saveCount;
    final again = Harness()..settings.saved = h.settings.saved;
    await again.state.init();
    expect(again.settings.saveCount, 0);
    expect(again.state.settings.serverUrl, 'https://meshsonar.com');
    expect(again.state.settings.driverKey, _key);
    expect(saves, 1);
  });

  for (final saved in ['https://meshsonar.com', 'https://cmh.meshsonar.com', 'https://other.example/base']) {
    test('no rewrite for $saved', () async {
      final h = Harness()..settings.saved = _withKey(saved);
      await h.state.init();
      expect(h.state.settings.serverUrl, saved);
      expect(h.state.settings.driverKey, _key);
      expect(h.settings.saveCount, 0);
    });
  }

  test('moves between the Lovable host, meshsonar.com and cmh.meshsonar.com keep the key', () async {
    final h = Harness()..settings.saved = _withKey('https://meshsonar.com');
    await h.state.init();
    for (final url in [
      'https://cmh.meshsonar.com',
      'https://cmh-meshcore.lovable.app',
      'https://meshsonar.com',
      'https://cmh-meshcore.lovable.app',
      'https://cmh.meshsonar.com',
      'https://meshsonar.com',
    ]) {
      await h.state.updateSettings(h.state.settings.copyWith(serverUrl: url));
      expect(h.state.settings.serverUrl, url);
      expect(h.state.settings.driverKey, _key, reason: 'kept moving to $url');
      expect(h.state.settings.keyStatus, DriverKeyStatus.approved);
      expect(h.settings.saved.driverKey, _key);
    }
  });

  for (final from in ['https://meshsonar.com', 'https://cmh.meshsonar.com', 'https://cmh-meshcore.lovable.app']) {
    for (final to in [
      'https://other.example',
      'https://dev.meshsonar.com',
      'http://meshsonar.com', // https → http alias
      'http://cmh.meshsonar.com',
      'https://meshsonar.com:8443',
      'https://user:pw@meshsonar.com',
      'https://cmh.meshsonar.com/api',
      'https://meshsonar.com.evil.example',
    ]) {
      test('an unrelated change ($from → $to) still removes the key', () async {
        final h = Harness()..settings.saved = _withKey(from);
        await h.state.init();
        await h.state.updateSettings(h.state.settings.copyWith(serverUrl: to));
        expect(h.state.settings.serverUrl, to);
        expect(h.state.settings.driverKey, isNull);
        expect(h.state.settings.keyStatus, DriverKeyStatus.none);
        expect(h.state.settings.display, isNull);
        expect(h.settings.saved.driverKey, isNull);
      });
    }
  }

  test('moving back from an unrelated server to meshsonar.com does not bring a key back', () async {
    final h = Harness()..settings.saved = _withKey('https://other.example');
    await h.state.init();
    await h.state.updateSettings(h.state.settings.copyWith(serverUrl: 'https://meshsonar.com'));
    expect(h.state.settings.driverKey, isNull);
  });

  test('the rewrite is in the app log; a failed save is logged and the new address is still used', () async {
    final h = Harness()..settings.saved = _withKey('https://cmh-meshcore.lovable.app');
    h.settings.failSave = const FileSystemException('disk full');
    await h.state.init();
    expect(h.state.settings.serverUrl, 'https://meshsonar.com');
    expect(h.state.settings.driverKey, _key);
    expect(h.settings.saved.serverUrl, 'https://cmh-meshcore.lovable.app', reason: 'nothing written');
    final log = h.state.diagnostics.lines.join('\n');
    expect(log, contains('Server address moved from cmh-meshcore.lovable.app to https://meshsonar.com'));
    expect(log, contains('Saving the moved server address failed'));
    expect(log, contains('disk full'));
  });

  test('a successful rewrite is logged without a failure line', () async {
    final h = Harness()..settings.saved = _withKey('https://cmh-meshcore.lovable.app');
    await h.state.init();
    final log = h.state.diagnostics.lines.join('\n');
    expect(log, contains('Server address moved'));
    expect(log, isNot(contains('Saving the moved server address failed')));
  });
}
