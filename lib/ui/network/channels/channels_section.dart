// Network > Channels (build 71 seam; stream C fills this in). The signature is fixed: stream A builds the section strip
// against it. [baseUrl] is the region host (or the hub for "All regions", where [regionSlug] is null).
import 'package:flutter/material.dart';

class ChannelsSection extends StatelessWidget {
  final String baseUrl;
  final String? regionSlug;

  /// A channel to open straight away (from a `/channels/<id>` link); null shows the list.
  final String? initialChannelId;
  const ChannelsSection({super.key, required this.baseUrl, required this.regionSlug, this.initialChannelId});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
