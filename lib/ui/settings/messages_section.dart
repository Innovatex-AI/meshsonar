// Settings > Messages (build 77, redesign round 5 S1 and M1; round 3 rule 10). The section that was "Notifications" holds,
// in order: Message delivery (a page), Quick replies, Return sends, Load photos automatically, then the alert rows
// (notifications_section.dart). The chat rows were More > Chat settings until build 76; its "Vibrate on taps" switch was
// the same setting as Map & display > Haptics and is not repeated here.
//
// Message delivery: how many tries a direct message gets, as the official MeshCore app has it (lib/chat/delivery_settings.dart):
// Direct tries 1 to 4, Flood tries 0 to 4, Flood fallback on/off, read and written through ChatController.deliverySettings.
// A message already on its way keeps the plan it started with. The radio's own "Confirm delivery twice" is in Set up my
// radio; one line here points to it.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../app/chat_wiring.dart';
import '../../app/photo_controller.dart';
import '../../chat/delivery_settings.dart';
import '../../chat/quick_replies.dart';
import '../chat/quick_replies_sheet.dart';
import '../radios/radio_setup/radio_setup_screen.dart';
import 'settings_index.dart';
import 'settings_pages.dart' show SettingsPageScreen;
import 'settings_kit.dart';

const String deliveryHelp = 'How hard MeshSonar tries to deliver a direct message. A message already on its way keeps '
    'the tries it started with.';

/// Until a radio has connected once there is no chat database to keep these in.
const String chatNotReadyReason = 'Connect your radio once to set this.';

/// "4 direct tries, then 4 by flood" / "2 direct tries, no flood": the Message delivery row and the page's summary.
String deliveryCaption(DeliverySettings d) {
  final direct = '${d.directTries} direct ${d.directTries == 1 ? 'try' : 'tries'}';
  if (d.effectiveFloodTries == 0) return '$direct, no flood.';
  return '$direct, then ${d.effectiveFloodTries} by flood.';
}

/// The first rows of Messages: the delivery page and the three chat rows (one widget each, so the section draws its line
/// between them).
List<Widget> messagesChatRows(BuildContext context) => [
      for (final row in MessagesChatRows.rows) MessagesChatRows(only: row),
    ];

/// The delivery row and the chat rows, built against the chat controller of the moment (null until a radio connected
/// once). With [only] one of them ([rows]); without, all four in a column (tests).
class MessagesChatRows extends StatelessWidget {
  static const List<String> rows = ['page-delivery', 'chat-quick-replies', 'chat-return-sends', 'chat-photos-autoload'];

  /// Tests inject a controller; the app reads [ChatWiring.controller].
  final ChatController? controller;

  /// Tests inject a photo controller; the app reads [PhotoWiring.controller].
  final PhotoController? photos;
  final String? only;
  const MessagesChatRows({super.key, this.controller, this.photos, this.only});

  Widget _row(BuildContext context, String id, ChatController? c, PhotoController? p) => switch (id) {
        'page-delivery' => SettingsAnchor(
            id: 'page-delivery',
            child: ListTile(
              key: const Key('page-delivery'),
              leading: Icon(settingsPage('delivery').icon),
              title: Text(settingsPage('delivery').title),
              subtitle: Text(c == null ? settingsPage('delivery').summary : deliveryCaption(c.deliverySettings),
                  key: const Key('page-delivery-caption')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPageScreen(pageId: 'delivery'))),
            ),
          ),
        'chat-quick-replies' => SettingsAnchor(id: id, child: _QuickRepliesRow(controller: c)),
        'chat-return-sends' => SettingsAnchor(id: id, child: _ReturnSendsRow(controller: c)),
        _ => SettingsAnchor(id: id, child: _PhotosRow(photos: p)),
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ChatWiring.controller, PhotoWiring.controller]),
      builder: (context, _) {
        final c = controller ?? ChatWiring.controller.value;
        final p = photos ?? PhotoWiring.controller.value;
        return ListenableBuilder(
          listenable: Listenable.merge([?c]),
          builder: (context, _) => only != null
              ? _row(context, only!, c, p)
              : Column(children: [for (final id in rows) _row(context, id, c, p)]),
        );
      },
    );
  }
}

class _QuickRepliesRow extends StatefulWidget {
  final ChatController? controller;
  const _QuickRepliesRow({required this.controller});
  @override
  State<_QuickRepliesRow> createState() => _QuickRepliesRowState();
}

class _QuickRepliesRowState extends State<_QuickRepliesRow> {
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final replies = c == null ? defaultQuickReplies : loadQuickReplies(c.store);
    return ListTile(
      key: const Key('chat-quick-replies'),
      leading: const Icon(Icons.bolt_outlined),
      title: Text(settingsEntry('chat-quick-replies').title),
      subtitle: c == null
          ? const SettingsWhyNot(chatNotReadyReason)
          : Text(replies.isEmpty ? 'None. Tap to add some.' : '${replies.length} saved. Tap one in a chat to send it.'),
      trailing: c == null ? null : const Icon(Icons.chevron_right),
      onTap: c == null
          ? null
          : () async {
              await showQuickRepliesSheet(context, store: c.store);
              if (mounted) setState(() {});
            },
    );
  }
}

class _ReturnSendsRow extends StatefulWidget {
  final ChatController? controller;
  const _ReturnSendsRow({required this.controller});
  @override
  State<_ReturnSendsRow> createState() => _ReturnSendsRowState();
}

class _ReturnSendsRowState extends State<_ReturnSendsRow> {
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return SwitchListTile(
      key: const Key('chat-return-sends'),
      secondary: const Icon(Icons.keyboard_return),
      title: Text(settingsEntry('chat-return-sends').title),
      subtitle: c == null
          ? const SettingsWhyNot(chatNotReadyReason)
          : const Text('Hardware keyboard only. Shift-Return starts a new line; Command-Return always sends.'),
      value: c != null && loadReturnSends(c.store),
      onChanged: c == null
          ? null
          : (v) {
              saveReturnSends(c.store, v);
              setState(() {});
            },
    );
  }
}

class _PhotosRow extends StatefulWidget {
  final PhotoController? photos;
  const _PhotosRow({required this.photos});
  @override
  State<_PhotosRow> createState() => _PhotosRowState();
}

class _PhotosRowState extends State<_PhotosRow> {
  @override
  Widget build(BuildContext context) {
    final p = widget.photos;
    return SwitchListTile(
      key: const Key('chat-photos-autoload'),
      secondary: const Icon(Icons.photo_outlined),
      title: Text(settingsEntry('chat-photos-autoload').title),
      subtitle: p == null
          ? const SettingsWhyNot(chatNotReadyReason)
          : const Text('Off: tap a photo to load it. Loading contacts the MeshSonar server, which sees your internet address.'),
      value: p?.autoLoad ?? false,
      onChanged: p == null ? null : (v) => setState(() => p.autoLoad = v),
    );
  }
}

/// Settings > Messages > Message delivery: the rows of that page (settings_pages.dart puts them on a SettingsPageScreen,
/// so search lands on each row).
class DeliveryRows extends StatelessWidget {
  /// Tests inject a controller; the app reads [ChatWiring.controller].
  final ChatController? controller;
  const DeliveryRows({super.key, this.controller});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: ChatWiring.controller,
      builder: (context, _) {
        final c = controller ?? ChatWiring.controller.value;
        return ListenableBuilder(
          listenable: Listenable.merge([?c]),
          builder: (context, _) {
            final d = c?.deliverySettings ?? DeliverySettings.defaults;
            void set(DeliverySettings v) => c?.deliverySettings = v;
            final why = c == null ? chatNotReadyReason : null;
            final divider = Divider(height: 1, indent: 56, color: t.colorScheme.outlineVariant.withValues(alpha: 0.5));
            return Column(key: const Key('delivery-rows'), children: [
              SettingsAnchor(
                id: 'delivery-direct',
                child: _CountRow(
                  id: 'delivery-direct',
                  icon: Icons.near_me_outlined,
                  caption: 'Sent the way your radio knows to reach the contact. Default 4.',
                  min: DeliverySettings.minDirectTries,
                  max: DeliverySettings.maxDirectTries,
                  value: d.directTries,
                  why: why,
                  onChanged: (v) => set(d.copyWith(directTries: v)),
                ),
              ),
              divider,
              SettingsAnchor(
                id: 'delivery-fallback',
                child: SwitchListTile(
                  key: const Key('delivery-fallback'),
                  secondary: const Icon(Icons.alt_route),
                  title: Text(settingsEntry('delivery-fallback').title),
                  subtitle: why != null
                      ? SettingsWhyNot(why)
                      : Text(d.floodFallback
                          ? 'On: when the direct tries get no confirmation, the route is reset and the message goes out by flood.'
                          : 'Off: after the direct tries the message is marked not delivered.'),
                  value: d.floodFallback,
                  onChanged: c == null ? null : (v) => set(d.copyWith(floodFallback: v)),
                ),
              ),
              divider,
              SettingsAnchor(
                id: 'delivery-flood',
                child: _CountRow(
                  id: 'delivery-flood',
                  icon: Icons.waves_outlined,
                  caption: 'Sent to every repeater in range after the route is reset. Default 4.',
                  min: DeliverySettings.minFloodTries,
                  max: DeliverySettings.maxFloodTries,
                  value: d.floodTries,
                  why: why ?? (d.floodFallback ? null : 'Only used while Flood fallback is on. Turn it on first.'),
                  onChanged: (v) => set(d.copyWith(floodTries: v)),
                ),
              ),
              divider,
              SettingsAnchor(
                id: 'delivery-confirm-twice',
                child: ListTile(
                  key: const Key('delivery-confirm-twice'),
                  leading: const Icon(Icons.done_all),
                  title: Text(settingsEntry('delivery-confirm-twice').title),
                  subtitle: const Text('A setting of your radio itself, in More > Radio > Set up my radio.'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RadioSetupScreen())),
                ),
              ),
              divider,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Text('New messages: ${deliveryCaption(d)} Up to ${d.totalTries} ${d.totalTries == 1 ? 'try' : 'tries'} in all.',
                    key: const Key('delivery-total'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ),
            ]);
          },
        );
      },
    );
  }
}

/// A count from [min] to [max] as one row of buttons (1 2 3 4). Disabled with the reason when [why] is set.
class _CountRow extends StatelessWidget {
  final String id;
  final IconData icon;
  final String caption;
  final int min, max, value;
  final String? why;
  final ValueChanged<int> onChanged;
  const _CountRow(
      {required this.id, required this.icon, required this.caption, required this.min, required this.max, required this.value, required this.why, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final e = settingsEntry(id);
    return ListTile(
      key: Key(id),
      leading: Icon(icon),
      title: Text(e.title),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: SegmentedButton<int>(
            key: Key('$id-selector'),
            showSelectedIcon: false,
            segments: [
              for (var n = min; n <= max; n++) ButtonSegment(value: n, label: segmentLabel('$n', key: Key('$id-$n'))),
            ],
            selected: {value},
            onSelectionChanged: why != null ? null : (v) => onChanged(v.first),
          ),
        ),
        if (why != null) SettingsWhyNot(why!) else Text(caption),
      ]),
    );
  }
}
