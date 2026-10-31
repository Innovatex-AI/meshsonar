// Opens a web page in the system browser (url_launcher).
import 'package:geolocator/geolocator.dart' show Geolocator;
import 'package:url_launcher/url_launcher.dart';

/// True if a browser took the link.
Future<bool> openExternalUrl(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Opens this app's page in the phone's Settings app (where Bluetooth and Location permission are switched back on).
Future<bool> openAppSettingsPage() async {
  try {
    return await Geolocator.openAppSettings();
  } catch (_) {
    return false;
  }
}
