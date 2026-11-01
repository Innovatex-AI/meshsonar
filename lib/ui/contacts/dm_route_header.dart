// The strip above a direct-message conversation: how the next message will travel and whether the radio can take it now.
// Passed to the shared conversation screen as its `header` (ConversationScreen.header). Tap = the contact's detail.
import 'package:flutter/material.dart';

import '../../chat/delivery_text.dart';
import '../theme.dart';
import 'contact_detail_screen.dart';
import 'contact_widgets.dart';
import 'contacts_controller.dart';

class DmRouteHeader extends StatelessWidget {
  final ContactsController controller;
  final String publicKey;
  const DmRouteHeader({super.key, required this.controller, required this.publicKey});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller.contact(publicKey);
        if (c == null) return const SizedBox.shrink();
        final t = Theme.of(context);
        final linked = controller.connected;
        final String line;
        final IconData icon;
        if (!linked) {
          line = 'Radio not connected. Messages wait here and send when it is back.';
          icon = Icons.bluetooth_disabled_rounded;
        } else if (c.forceFlood) {
          line = 'Always sent by flood (set in this contact\'s details).';
          icon = Icons.waves_rounded;
        } else if (c.hasPath) {
          line = '${describeRoute(c)}. ${heardText(c.lastHeardMs, controller.nowMs())}.';
          icon = Icons.route_rounded;
        } else {
          line = 'No saved route yet. The first message floods; the radio learns the route from the reply.';
          icon = Icons.waves_rounded;
        }
        return Semantics(
          button: true,
          label: 'Route to ${c.displayName}. $line Opens contact details.',
          child: InkWell(
            key: const Key('dm-route-header'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactDetailScreen(controller: controller, publicKey: c.publicKey))),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Container(
                width: double.infinity,
                color: t.colorScheme.surfaceContainerHigh,
                padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: t.colorScheme.onSurfaceVariant),
                    const SizedBox(width: Gap.s),
                    // Capped like the mini drive bar: at the largest text sizes the conversation below keeps its room; the
                    // full sentence is in the screen reader label and in the contact's details.
                    Expanded(
                      child: ExcludeSemantics(
                        child: MediaQuery.withClampedTextScaling(
                          maxScaleFactor: 1.3,
                          child: Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: t.colorScheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
