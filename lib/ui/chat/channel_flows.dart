import 'dart:async';

// Channel flows shared by the New chat sheet (new_chat_sheet.dart holds the forms), the empty states and tapped
// meshcore:// links: the join announcement toast, a join with a plain-language error alert, and what happens to a link.
// Every failure is a plain sentence that says what to do (ChannelAdminException.message).
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/channel_admin.dart';
import '../../chat/channel_secret.dart';
import '../../chat/mesh_links.dart';
import '../../chat/models.dart';
import '../alerts/permission_prompt.dart';
import '../design/app_surfaces.dart';
import 'conversation_screen.dart';
import 'qr_widgets.dart';

/// Replaceable in tests: the camera scanner.
abstract final class ChatUiHooks {
  static QrScanLauncher scanQr = defaultQrScan;
}

void announceJoin(BuildContext context, ChatController controller, ChannelJoin join) {
  // First channel joined: the right moment to explain alerts (once; never at launch).
  if (join.created) unawaited(offerAlertsAfterFirstAction(context));
  showAppToast(
    context,
    join.created ? 'Joined ${join.channel.name}' : 'You already have ${join.channel.name}',
    kind: AppToastKind.success,
    actionLabel: 'Open',
    onAction: () => ConversationScreen.open(context, controller: controller, convKey: join.channel.convKey),
  );
}

/// Runs a join with a progress indicator and shows the plain-language error in a dialog when it fails.
Future<ChannelJoin?> runChannelAction(BuildContext context, ChatController controller, Future<ChannelJoin> Function() action, {String? what}) async {
  if (controller.radioId == null) {
    await _errorDialog(context, 'Connect your radio once first. Channels live in the radio, so MeshSonar needs to see it before it can add one.');
    return null;
  }
  try {
    final j = await action();
    if (context.mounted) announceJoin(context, controller, j);
    return j;
  } on ChannelAdminException catch (e) {
    if (context.mounted) await _errorDialog(context, e.message);
  } catch (e) {
    if (context.mounted) await _errorDialog(context, 'Something went wrong while changing the channel. Nothing was changed. Try again.');
  }
  return null;
}

Future<void> _errorDialog(BuildContext context, String message) => showAppAlert(
      context,
      title: 'Could not do that',
      message: message,
      confirmLabel: 'OK',
      cancelLabel: 'Close',
      dialogKey: const Key('channel-error-dialog'),
    );

/// A tapped or scanned meshcore:// link. Channel: ask, then join. Contact or advert: add it to Contacts. Anything else: say what it is.
Future<void> handleMeshLink(BuildContext context, ChatController controller, String link) async {
  final p = MeshLinks.parse(link);
  switch (p) {
    case LinkParseError():
      await _errorDialog(context, ChannelAdmin.describeLinkError(p.error));
    case ChannelLink():
      final kind = classifyName(p);
      final ok = await showAppAlert(
        context,
        title: 'Join ${p.name}?',
        message:
            '${kind == ChannelKind.private ? 'This is a private channel. Everyone who has this link can read it.' : 'This is an open channel. Anyone who types the same name can read it.'}'
            '${p.regionScope != null ? '\n\nIt is limited to the region "${p.regionScope}".' : ''}'
            '\n\nIt uses one of your radio\'s channel slots.',
        confirmLabel: 'Join',
        cancelLabel: 'Not now',
        dialogKey: const Key('join-link-dialog'),
        confirmKey: const Key('join-link-confirm'),
      );
      if (ok == true && context.mounted) await runChannelAction(context, controller, () => controller.admin.joinFromLink(controller.radioId ?? '', link));
    case ContactLink() || AdvertLink():
      // The contact book (ContactManager) saves it on the phone and puts it on the radio when it can.
      final r = await controller.service.contacts.addFromLink(link);
      if (!context.mounted) return;
      controller.refresh();
      final text = r.ok ? '${r.created ? 'Added' : 'Already in Contacts:'} ${r.contact!.displayName}.${r.note == null ? '' : ' ${r.note}'}' : (r.error ?? 'That contact could not be added.');
      showAppToast(context, text, kind: r.ok ? AppToastKind.success : AppToastKind.error);
  }
}

ChannelKind classifyName(ChannelLink p) => classifyChannel(p.name, p.secret);
