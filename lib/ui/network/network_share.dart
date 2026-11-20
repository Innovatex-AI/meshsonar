// Share links for Network views (AZ-3.5): node, packet, observer and region views (and list states), built from
// NetworkRequest in the region-host form (`https://cmh.meshsonar.com/nodes/<key>`), which the website opens and, with
// the associated domain `applinks:*.meshsonar.com`, opens this app on a phone that has it.
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/network_request.dart';

/// Test seam: replaces the system share sheet (text, subject).
void Function(String text, String subject)? debugNetworkShare;

/// The link a share sends for [r] (the website's address for that view).
String networkShareText(NetworkRequest r) => r.toWebUri().toString();

/// Opens the share sheet with the web link of [r]. [subject] names it ("Hilltop RPT on MeshSonar").
Future<void> shareNetworkLink(BuildContext context, NetworkRequest r, {required String subject}) async {
  final text = networkShareText(r);
  final seam = debugNetworkShare;
  if (seam != null) {
    seam(text, subject);
    return;
  }
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(ShareParams(
    text: text,
    subject: subject,
    sharePositionOrigin: box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size,
  ));
}

/// A share button for an app bar.
class NetworkShareButton extends StatelessWidget {
  final NetworkRequest request;
  final String subject;
  const NetworkShareButton({super.key, required this.request, required this.subject});

  @override
  Widget build(BuildContext context) => Builder(
        builder: (ctx) => IconButton(
          key: const Key('network-share'),
          tooltip: 'Share link',
          icon: const Icon(Icons.ios_share),
          onPressed: () => shareNetworkLink(ctx, request, subject: subject),
        ),
      );
}
