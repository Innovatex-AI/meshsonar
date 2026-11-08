// The inline card a conversation shows after three direct messages in a row failed over a saved route (chat plan 4.7).
// Two actions: look for a new route now (a route search with the Ping sheet, whose "Use this route" adopts it) and reset the
// route (forget it; the next message searches again). Calm wording, no jargon.
import 'package:flutter/cupertino.dart';

import '../../chat/contact_manager.dart';
import '../../chat/models.dart';
import '../contacts/path_manager_screen.dart' show offerUseRoute;
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import '../tools/ping_result_sheet.dart' show showPingSheet;

class RouteBrokenCard extends StatelessWidget {
  final Contact contact;
  final ContactManager manager;
  final VoidCallback? onChanged;
  const RouteBrokenCard({super.key, required this.contact, required this.manager, this.onChanged});

  Future<void> _find(BuildContext context) async {
    await showPingSheet(context, contact: contact, manager: manager, onUseRoute: (r) => offerUseRoute(context, manager, contact, r));
    onChanged?.call();
  }

  Future<void> _reset(BuildContext context) async {
    final ok = await showAppConfirm(context,
        title: 'Reset the route to ${contact.displayName}?',
        message: 'The saved route is forgotten and the next message searches again.',
        confirmLabel: 'Reset route',
        destructive: true,
        confirmKey: const Key('broken-reset-confirm'));
    if (!ok) return;
    await manager.resetPath(contact.publicKey);
    AppHaptics.success();
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      container: true,
      label: 'This route may be broken. The last three messages to ${contact.displayName} were not delivered.',
      child: Container(
        key: const Key('route-broken-card'),
        margin: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.card)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: AppSymbolIcon(AppSymbols.exclamationTriangle, size: 20, color: c.warning)),
            const SizedBox(width: Gap.s),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('This route may be broken.', style: AppType.headline.copyWith(color: c.textPrimary)),
                const SizedBox(height: 2),
                Text('The last three messages to ${contact.displayName} were not delivered.', style: AppType.subhead.copyWith(color: c.textMuted)),
              ]),
            ),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(alignment: WrapAlignment.end, children: [
            CupertinoButton(
              key: const Key('broken-find'),
              minimumSize: Size.square(Hit.min),
              padding: const EdgeInsets.symmetric(horizontal: Gap.m),
              onPressed: () => _find(context),
              child: const Text('Find a route now'),
            ),
            CupertinoButton(
              key: const Key('broken-reset'),
              minimumSize: Size.square(Hit.min),
              padding: const EdgeInsets.symmetric(horizontal: Gap.m),
              onPressed: () => _reset(context),
              child: Text('Reset route', style: TextStyle(color: c.danger)),
            ),
          ]),
        ]),
      ),
    );
  }
}
