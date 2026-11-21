// More > Radio (build 71): the radio's own network, which was the Chat tab's Radio segment: the radio card, nodes heard
// nearby, and the repeaters, rooms and sensors in its contact book with Trace, Discover, Rx log and Adverts (the chat
// services' own list, ChatTabProvider.networkSliver: nothing in it changed). Under it: Radio settings and region
// preset (the read-only comparison that was More > Radio), Radio setup, Noise floor and Telemetry.
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
          final tools = <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.xs),
              child: Semantics(header: true, child: Text('Radio settings and tools', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary))),
            ),
            MoreRow(MoreItem.radioSettings, Icons.settings_input_antenna, 'Radio settings and region preset',
                s.connected ? 'What your radio reports, compared with this region' : 'Not connected. Connect and see its settings',
                onOpen: widget.onOpen),
            MoreRow(MoreItem.radioSetup, Icons.tune, 'Radio setup', 'Name, position, power and frequency, with checks', onOpen: widget.onOpen),
            MoreRow(MoreItem.noiseFloor, Icons.show_chart, 'Noise floor and health', 'Interference and radio counters, live', onOpen: widget.onOpen),
            MoreRow(MoreItem.telemetry, Icons.thermostat, 'Telemetry', 'Battery, temperature and position of a node', onOpen: widget.onOpen),
            const SizedBox(height: Gap.xl),
          ];
          if (p == null) {
            // No chat services yet (no radio has connected): say so, and keep the settings and tools reachable.
            return ListView(key: const Key('more-radio-list'), children: [
              ListTile(
                key: const Key('more-radio-connect'),
                minVerticalPadding: Gap.s,
                leading: const Icon(Icons.bluetooth_searching),
                title: Text(s.connected ? 'Your radio is connected' : 'Connect a radio'),
                subtitle: Text(s.connected
                    ? 'Its repeaters, rooms and sensors appear here in a moment.'
                    : 'Its repeaters, rooms, sensors and the nodes it hears nearby show up here.'),
                trailing: s.connected ? null : const Icon(Icons.chevron_right),
                onTap: s.connected ? null : () => openConnect(context),
              ),
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
