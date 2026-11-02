import 'package:flutter/material.dart';

import '../design/app_surfaces.dart';

/// A confirmation with a paragraph or more of explanation: a sheet with the body and a pinned Confirm / Cancel footer.
/// (Short one or two line confirms use `showAppAlert`; plain yes / no uses `showAppConfirm`.) True only on Confirm.
/// Keys are passed through so tests keep finding the same widgets.
Future<bool> showConfirmSheet(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
  Key? sheetKey,
  Key? confirmKey,
  Key? cancelKey,
}) async {
  final r = await showAppSheet<bool>(
    context,
    detents: const [0.6],
    builder: (ctx, controller) {
      final t = Theme.of(ctx);
      return AppSheetScaffold(
        key: sheetKey,
        controller: controller,
        title: title,

        primaryAction: FilledButton(
          key: confirmKey,
          style: destructive ? FilledButton.styleFrom(backgroundColor: t.colorScheme.error, foregroundColor: t.colorScheme.onError) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
        secondaryAction: TextButton(key: cancelKey, onPressed: () => Navigator.pop(ctx, false), child: Text(cancelLabel)),
        children: [Text(body, style: t.textTheme.bodyMedium)],
      );
    },
  );
  return r == true;
}
