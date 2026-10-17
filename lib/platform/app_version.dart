// The app's version, read from the platform build (package_info_plus), so pubspec.yaml is the only place it's set.
import 'package:package_info_plus/package_info_plus.dart';

import '../core/model.dart';

/// App name/version/platform sent with every upload and export and shown in About. If the platform can't report a
/// version, it's left null (unknown) rather than guessed.
Future<AppInfo> loadAppInfo({required String platform, Future<PackageInfo> Function()? read}) async {
  String? version;
  try {
    final info = await (read ?? PackageInfo.fromPlatform)();
    version = info.version.trim().isEmpty ? null : info.version.trim();
  } catch (_) {}
  return AppInfo(name: 'MeshSonar', version: version, platform: platform);
}
