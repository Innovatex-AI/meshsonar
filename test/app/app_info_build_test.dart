// AC-1 / §3 (spec m1-app-0.4.0): reports carry the build number from package_info_plus (loadAppInfo adds `build`),
// but the Drive Format v1 `app` object stays {name, version, platform} (no new upload fields).
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/platform/app_version.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadAppInfo reports version and build from the platform build', () async {
    PackageInfo.setMockInitialValues(
        appName: 'MeshSonar', packageName: 'meshsonar', version: '0.4.0', buildNumber: '5', buildSignature: '');
    final info = await loadAppInfo(platform: 'iOS');
    expect(info.version, '0.4.0');
    expect(info.build, '5');
  });

  test('an empty or unreadable build number is unknown (null), never guessed', () async {
    final empty = PackageInfo(appName: 'MeshSonar', packageName: 'meshsonar', version: '0.4.0', buildNumber: ' ');
    expect((await loadAppInfo(platform: 'linux', read: () async => empty)).build, isNull);
    expect((await loadAppInfo(platform: 'linux', read: () async => throw StateError('no plugin'))).build, isNull);
  });

  test('build is not part of the v1 upload/export app object', () {
    const app = AppInfo(name: 'MeshSonar', version: '0.4.0', build: '5', platform: 'iOS');
    expect(app.toJson(), {'name': 'MeshSonar', 'version': '0.4.0', 'platform': 'iOS'});
  });
}
