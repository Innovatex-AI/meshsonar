// The sheets the contact profile opens: Share, Route (the working "Always search" switch and "Reset route" until the full
// Route screen of WP7 lands) and the "coming" sheet for tools whose work package has not merged (shown only with the
// chatRedesign flag on, see profile_tiles.dart).
import 'package:flutter/material.dart';

import '../../chat/delivery_text.dart';
import '../../chat/models.dart';
import '../chat/qr_widgets.dart' show QrView;
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/app_widgets.dart';
import '../design/tokens.dart';
import 'contact_widgets.dart';
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

/// Route sheet. Plain words (plan 2.1): "Always search" is the old force-flood switch. The full Route screen replaces
/// this in WP7; until then this is the only place to reset a route or turn searching on.
Future<void> showContactRouteSheet(
  BuildContext context, {
  required Contact Function() current,
  required Listenable changes,
  required void Function(bool) onAlwaysSearch,
  required Future<void> Function() onReset,
  required bool redesign,
}) {
  return showAppSheet<void>(
    context,
    detents: const [0.6, 0.95],
    builder: (ctx, controller) => ListenableBuilder(
      listenable: changes,
      builder: (ctx, _) {
        final c0 = current();
        final c = AppColors.of(ctx);
        final ids = c0.routeIds;
        return AppSheetScaffold(
          controller: controller,
          title: 'Route to ${c0.displayName}',
          padding: EdgeInsets.zero,
          children: [
            ProfileGroup(rows: [
              ProfileRow(label: 'Route', value: routeCaption(c0), key: const Key('route-sheet-caption')),
              if (ids.isNotEmpty)
                ProfileRow(
                  label: 'Repeaters',
                  valueWidget: Text(ids.join(' › '), key: const Key('route-sheet-hops'), textAlign: TextAlign.end, style: monoStyle.copyWith(color: c.textMuted)),
                ),
            ], footer: describeRoute(c0)),
            ProfileGroup(rows: [
              AppSwitchTile(
                switchKey: const Key('contact-force-flood'),
                title: 'Always search',
                subtitle: 'Sends to everyone nearby. Slower and uses more airtime, but works when the saved route breaks.',
                value: c0.forceFlood,
                onChanged: onAlwaysSearch,
              ),
              ProfileRow(
                key: const Key('contact-reset-route'),
                label: 'Reset route',
                destructive: c0.hasPath,
                onTap: c0.hasPath
                    ? () async {
                        final ok = await showAppConfirm(ctx,
                            title: 'Forget the saved route?',
                            message: 'The next message searches again and finds a new route.',
                            confirmLabel: 'Reset route',
                            destructive: true,
                            confirmKey: const Key('reset-route-confirm'));
                        if (ok) await onReset();
                      }
                    : null,
                value: c0.hasPath ? null : 'No route saved',
              ),
            ]),
            if (redesign)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
                child: Text('Coming: choose the repeaters yourself, test a route and see how it changed.',
                    key: const Key('route-sheet-coming'), style: AppType.footnote.copyWith(color: c.textMuted)),
              ),
          ],
        );
      },
    ),
  );
}

/// "Coming" sheet for Ping, Stats and Telemetry until WP7/WP8 land.
Future<void> showComingSoonSheet(BuildContext context, {required String title, required String body}) {
  return showAppSheet<void>(
    context,
    detents: const [0.35],
    builder: (ctx, controller) {
      final c = AppColors.of(ctx);
      return AppSheetScaffold(
        controller: controller,
        title: title,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.l),
            child: Column(children: [
              AppSymbolIcon(AppSymbols.clock, size: 34, color: c.textMuted),
              const SizedBox(height: Gap.m),
              Text('Coming soon', key: const Key('coming-soon-title'), style: AppType.headline.copyWith(color: c.textPrimary)),
              const SizedBox(height: Gap.s),
              Text(body, key: const Key('coming-soon-body'), textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: c.textMuted)),
            ]),
          ),
        ],
      );
    },
  );
}
