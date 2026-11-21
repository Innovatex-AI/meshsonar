// One page of the website shown inside the app (build 71 seam; stream D fills this in). Loads `<baseUrl><path>` with
// `embed=1`, only on meshsonar.com hosts. In-page links to a node, packet, observer or channel are handed to
// [onNativeLink] instead of being followed.
import 'package:flutter/material.dart';

class SitePageView extends StatelessWidget {
  final String baseUrl;

  /// Site path with its query, e.g. `/analytics/rf` or `/scope-audit`.
  final String path;
  final String title;

  /// Returns true when the app opened the link natively (the page then stays where it is).
  final bool Function(Uri link)? onNativeLink;
  const SitePageView({super.key, required this.baseUrl, required this.path, required this.title, this.onNativeLink});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
