// The app version has one source: pubspec.yaml, read at run time through package_info_plus.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/sync_service.dart';
import 'package:meshsonar/platform/app_version.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../ui/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadAppInfo reports the build version from package_info_plus', () async {
    PackageInfo.setMockInitialValues(
        appName: 'MeshSonar', packageName: 'meshsonar', version: '0.3.0', buildNumber: '3', buildSignature: '');
    final info = await loadAppInfo(platform: 'iOS');
    expect(info.name, 'MeshSonar');
    expect(info.version, '0.3.0');
    expect(info.platform, 'iOS');
  });

  test('an unreadable or empty version is left unknown (null), never guessed', () async {
    expect((await loadAppInfo(platform: 'linux', read: () async => throw StateError('no plugin'))).version, isNull);
    final empty = PackageInfo(appName: 'MeshSonar', packageName: 'meshsonar', version: ' ', buildNumber: '');
    expect((await loadAppInfo(platform: 'linux', read: () async => empty)).version, isNull);
  });

  test('pubspec is 0.7.2+10 and no Dart file hard-codes an app version any more', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version: (\S+)$', multiLine: true).firstMatch(pubspec)!.group(1), '0.7.2+10');
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      if (RegExp(r'''version:\s*'\d+\.\d+\.\d+'|String appVersion\s*=''').hasMatch(src)) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
    // Defaults carry no version: the real one is passed in from the build.
    final h = Harness();
    expect(h.services.appInfo.version, isNull);
    final sync = DefaultSyncService(store: h.store, client: FakeCmatClient(Uri.parse('https://x.test')), settings: h.settings);
    expect(sync.app.version, isNull);
  });
}
