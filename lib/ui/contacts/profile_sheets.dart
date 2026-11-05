// The sheets the contact profile opens: Share. (Route is path_manager_screen.dart, Ping is tools/ping_result_sheet.dart.)
import 'package:flutter/material.dart';

import '../../chat/models.dart';
import '../chat/qr_widgets.dart' show QrView;
import '../design/app_surfaces.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import 'profile_widgets.dart';

/// Share sheet: QR, copy link, copy key, hand over to radios nearby, system share, export as file.
Future<void> showContactShareSheet(
  BuildContext context, {
  required Contact contact,
  required String link,
  required bool connected,
  required VoidCallback onCopyLink,
  required VoidCallback onCopyKey,
  required VoidCallback onShare,
  required VoidCallback onNearby,
  required VoidCallback onExportFile,
}) {
  return showAppSheet<void>(
    context,
    detents: const [0.7, 0.95],
    builder: (ctx, controller) {
      final c = AppColors.of(ctx);
      return AppSheetScaffold(
        controller: controller,
        title: contact.displayName,
        padding: EdgeInsets.zero,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
            child: Text('Scan this with MeshSonar or the MeshCore app to add ${contact.displayName}.',
                textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: c.textMuted)),
          ),
          const SizedBox(height: Gap.l),
          Center(child: QrView(data: link, size: 220, semanticLabel: 'QR code for contact ${contact.displayName}')),
          const SizedBox(height: Gap.l),
          ProfileGroup(rows: [
            ProfileRow(key: const Key('qr-copy-link'), label: 'Copy link', onTap: onCopyLink),
            ProfileRow(key: const Key('share-copy-key'), label: 'Copy key', onTap: onCopyKey),
            ProfileRow(key: const Key('qr-share-link'), label: 'Share link', onTap: onShare),
            ProfileRow(key: const Key('share-export-file'), label: 'Export as file', onTap: onExportFile),
            if (connected) ProfileRow(key: const Key('contact-share-nearby'), label: 'Send to radios nearby', onTap: onNearby),
          ], footer: connected ? 'Radios nearby only hear this within direct range. It uses a little airtime.' : null),
        ],
      );
    },
  );
}
