// More > Chat (chat plan 2.2, 4.2, 4.3): quick replies, "Return sends" for a hardware keyboard, "Load photos automatically"
// (photo messages) and the Haptics switch (the same setting as Settings > Units & display). Inset-grouped list, nothing else lives here.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../app/chat_wiring.dart';
import '../../app/photo_controller.dart';
import '../../chat/quick_replies.dart';
import '../app.dart';
import '../design/app_symbols.dart';
import '../design/app_widgets.dart';
import '../design/tokens.dart';
import '../radio/inset_list.dart';
import 'quick_replies_sheet.dart';

class ChatSettingsScreen extends StatefulWidget {
  /// Tests inject a controller; the app reads [ChatWiring.controller].
  final ChatController? controller;

  /// Tests inject a photo controller; the app reads [PhotoWiring.controller].
  final PhotoController? photos;
  const ChatSettingsScreen({super.key, this.controller, this.photos});
  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  ChatController? get _c => widget.controller ?? ChatWiring.controller.value;
  PhotoController? get _p => widget.photos ?? PhotoWiring.controller.value;

  @override
  Widget build(BuildContext context) {
    final col = AppColors.of(context);
    final c = _c;
    final app = AppScope.maybeOf(context);
    final st = app?.settings;
    final replies = c == null ? defaultQuickReplies : loadQuickReplies(c.store);
    return Scaffold(
      backgroundColor: col.bg,
      appBar: AppBar(title: const Text('Chat'), backgroundColor: col.bg),
      body: SafeArea(
        child: ListView(
          key: const Key('chat-settings-list'),
          padding: const EdgeInsets.only(top: Gap.m, bottom: Gap.xl),
          children: [
            InsetGroup(
              header: 'Writing',
              footer: 'With a hardware keyboard, Return sends and Shift-Return starts a new line. Command-Return always sends.',
              rows: [
                InsetRow(
                  key: const Key('chat-quick-replies'),
                  title: 'Quick replies',
                  value: '${replies.length}',
                  onTap: c == null
                      ? null
                      : () async {
                          await showQuickRepliesSheet(context, store: c.store);
                          if (mounted) setState(() {});
                        },
                ),
                AppSwitchTile(
                  switchKey: const Key('chat-return-sends'),
                  symbol: AppSymbols.message,
                  title: 'Return sends',
                  value: c != null && loadReturnSends(c.store),
                  onChanged: c == null
                      ? null
                      : (v) {
                          saveReturnSends(c.store, v);
                          setState(() {});
                        },
                ),
              ],
            ),
            if (_p != null)
              InsetGroup(
                header: 'Photos',
                rows: [
                  AppSwitchTile(
                    switchKey: const Key('chat-photos-autoload'),
                    symbol: AppSymbols.photo,
                    title: 'Load photos automatically',
                    subtitle: 'Shows photos in chats as they arrive. Loading a photo contacts the MeshSonar server, which sees '
                        'your internet address. Off: tap a photo to load it.',
                    value: _p!.autoLoad,
                    onChanged: (v) => setState(() => _p!.autoLoad = v),
                  ),
                ],
              ),
            if (st != null && app != null)
              InsetGroup(
                header: 'Feel',
                rows: [
                  AppSwitchTile(
                    switchKey: const Key('chat-haptics'),
                    symbol: AppSymbols.waveform,
                    title: 'Haptics',
                    subtitle: 'Small taps when you send, toggle or pick something.',
                    value: st.haptics,
                    onChanged: (v) => app.updateSettings(st.copyWith(haptics: v)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
