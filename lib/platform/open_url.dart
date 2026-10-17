// Opens a web page in the system browser (url_launcher).
import 'package:url_launcher/url_launcher.dart';

/// True if a browser took the link.
Future<bool> openExternalUrl(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
