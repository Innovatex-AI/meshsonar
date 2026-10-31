// The Chat tab: Contacts | Channels once chat services plug in through [ChatTabHost]; until then an honest empty
// state. Nothing here pretends messages exist.
import 'package:flutter/material.dart';

import '../app.dart';
import '../drive/drive_controls.dart' show openConnect;
import '../drive_screen.dart' show ConnectionChip;
import '../widgets.dart' show EmptyState;
import 'chat_tab_host.dart';

class ChatTab extends StatefulWidget {
  const ChatTab({super.key});
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  ChatSegment _segment = ChatSegment.contacts;
  final _fixture = DebugFixtureChat();

  ChatTabProvider? get _provider =>
      ChatTabHost.provider.value ?? (chatFixturesAllowed && ChatTabHost.debugFixtures.value ? _fixture : null);

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([ChatTabHost.provider, ChatTabHost.debugFixtures]),
      builder: (context, _) {
        final p = _provider;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: Gap.l,
            title: const Text('Chat'),
            actions: [
              if (p != null) ...p.appBarActions(context),
              Padding(
                padding: const EdgeInsets.only(right: Gap.m),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.6),
                  child: ConnectionChip(state: s, onPressed: () => openConnect(context)),
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: p == null ? _noChatYet(context) : _withProvider(context, p),
          ),
        );
      },
    );
  }

  Widget _noChatYet(BuildContext context) {
    final s = AppScope.of(context);
    return EmptyState(
      key: const Key('chat-empty'),
      icon: Icons.chat_bubble_outline_rounded,
      title: s.connected ? 'Chat is coming to this tab' : 'Messages arrive here once you connect a radio',
      body: s.connected
          ? 'Your radio is connected and ready. Contacts and channels will show up here in a coming update. '
              'Driving and mapping work now: open the Map tab.'
          : 'Connect your MeshCore companion radio over Bluetooth. Contacts and channels will show up here; '
              'you can map coverage while you wait.',
      action: s.connected
          ? FilledButton.tonalIcon(
              key: const Key('chat-open-map'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => ShellScope.maybeRead(context)?.select(AppTab.map),
              icon: const Icon(Icons.map_outlined),
              label: const Text('Open the map'),
            )
          : FilledButton.icon(
              key: const Key('chat-connect'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => openConnect(context),
              icon: const Icon(Icons.bluetooth_searching_rounded),
              label: const Text('Connect radio'),
            ),
    );
  }

  Widget _withProvider(BuildContext context, ChatTabProvider p) {
    return ListenableBuilder(
      listenable: p.changes,
      builder: (context, _) {
        final s = AppScope.of(context);
        if (!s.connected && p.isEmpty) return _noChatYet(context);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<ChatSegment>(
                  key: const Key('chat-segments'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ChatSegment.contacts, label: Text('Contacts'), icon: Icon(Icons.person_outline)),
                    ButtonSegment(value: ChatSegment.channels, label: Text('Channels'), icon: Icon(Icons.tag)),
                  ],
                  selected: {_segment},
                  onSelectionChanged: (v) => setState(() => _segment = v.first),
                ),
              ),
            ),
            Expanded(
              child: _segment == ChatSegment.contacts ? p.contactsView(context) : p.channelsView(context),
            ),
          ],
        );
      },
    );
  }
}
