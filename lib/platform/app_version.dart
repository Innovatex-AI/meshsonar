// The app's version, read from the platform build (package_info_plus), so pubspec.yaml is the only place it's set.
import 'package:package_info_plus/package_info_plus.dart';

import '../core/model.dart';

/// App name/version/build/platform, sent with uploads, exports and problem reports and shown in About. Anything the
/// platform can't report is left null (unknown) rather than guessed.
Future<AppInfo> loadAppInfo({required String platform, Future<PackageInfo> Function()? read}) async {
  String? version;
  String? build;
  try {
    final info = await (read ?? PackageInfo.fromPlatform)();
    version = _blankToNull(info.version);
    build = _blankToNull(info.buildNumber);
  } catch (_) {}
  return AppInfo(name: 'MeshSonar', version: version, build: build, platform: platform);
}

String? _blankToNull(String s) => s.trim().isEmpty ? null : s.trim();
