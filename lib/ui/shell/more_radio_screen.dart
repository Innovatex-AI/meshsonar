// More > Radio (build 71): the radio's own network, which was the Chat tab's Radio segment: the radio card, nodes heard
// nearby, and the repeaters, rooms and sensors in its contact book with Trace, Discover, Rx log and Adverts (the chat
// services' own list, ChatTabProvider.networkSliver: nothing in it changed). Above it: Set up my radio and My radio's
// settings (the read-only comparison with the region's preset).
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../design/tokens.dart';
import '../drive/drive_controls.dart' show openConnect;
import 'chat_tab_host.dart';
import 'more_tab.dart' show MoreRow;

class MoreRadioScreen extends StatefulWidget {
  /// Opens a More page over this one (the More tab's Navigator).
  final void Function(MoreItem) onOpen;
  const MoreRadioScreen({super.key, required this.onOpen});

  @override
  State<MoreRadioScreen> createState() => _MoreRadioScreenState();
}

class _MoreRadioScreenState extends State<MoreRadioScreen> {
  final _search = TextEditingController();
  final _fixture = DebugFixtureChat();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  ChatTabProvider? get _provider => ChatTabHost.provider.value ?? (chatFixturesAllowed && ChatTabHost.debugFixtures.value ? _fixture : null);

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    return Scaffold(
      key: const Key('more-radio-screen'),
      appBar: AppBar(title: const Text('Radio')),
      body: ListenableBuilder(
        listenable: Listenable.merge([ChatTabHost.provider, ChatTabHost.debugFixtures]),
        builder: (context, _) {
          final p = _provider;
          // Build 76: what people change (name, position, frequency) and the region check sit at the TOP, above the
          // list of repeaters (they were under it, a long scroll away). Build 77 (round 5 M3): no "More tools" group at
          // the bottom; Noise floor and Telemetry are under Tools on the radio card and in Device settings.
          final setup = <Widget>[
            MoreRow(MoreItem.radioSetup, Icons.tune, 'Set up my radio', 'Name, position, power, frequency', onOpen: widget.onOpen),
            MoreRow(MoreItem.radioSettings, Icons.fact_check_outlined, 'My radio\'s settings',
                s.connected ? 'Does it match this region?' : 'Connect a radio to check it',
                onOpen: widget.onOpen),
            const Divider(height: Gap.l, indent: Gap.l, endIndent: Gap.l),
          ];
          const tools = <Widget>[SizedBox(height: Gap.xl)];
          if (p == null) {
            // No chat services yet (no radio has connected): say so, and keep the settings and tools reachable.
            return ListView(key: const Key('more-radio-list'), children: [
              if (s.connected)
                const ListTile(
                  key: Key('more-radio-connect'),
                  minVerticalPadding: Gap.s,
                  leading: Icon(Icons.bluetooth_connected),
                  title: Text('Your radio is connected'),
                  subtitle: Text('Its repeaters and rooms appear here in a moment.'),
                )
              else
                // Not connected: one clear button, not a row that looks like the others.
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.s),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('No radio connected', style: t.textTheme.titleMedium),
                    const SizedBox(height: Gap.xs),
                    Text('Connect yours to see its repeaters and rooms here.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: Gap.m),
                    FilledButton.icon(
                      key: const Key('more-radio-connect'),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
                      onPressed: () => openConnect(context),
                      icon: const Icon(Icons.bluetooth_searching),
                      label: const Text('Connect radio'),
                    ),
                  ]),
                ),
              ...setup,
              ...tools,
            ]);
          }
          return ListenableBuilder(
            listenable: p.changes,
            builder: (context, _) => CustomScrollView(
              key: const Key('more-radio-list'),
              physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
              slivers: [
                CupertinoSliverRefreshControl(onRefresh: p.refresh),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
                    child: CupertinoSearchTextField(
                      key: const Key('more-radio-search'),
                      controller: _search,
                      placeholder: 'Search repeaters, rooms and sensors',
                      onChanged: (_) => setState(() {}),
                      onSuffixTap: () => setState(_search.clear),
                    ),
                  ),
                ),
                SliverList(delegate: SliverChildListDelegate(setup)),
                p.networkSliver(context, ChatTabArgs(query: _search.text, onConnect: () => openConnect(context))),
                SliverList(delegate: SliverChildListDelegate(tools)),
              ],
            ),
          );
        },
      ),
    );
  }
}
