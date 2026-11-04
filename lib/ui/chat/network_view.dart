// The Network segment (chat plan 4.12): the "Your radio" card (name, state, battery, firmware, frequency, Announce and Tools),
// Heard nearby (Add / Ignore, Discover), then Repeaters, Rooms and Sensors from the contact book. Each section shows its five
// most relevant rows (favourites first, then the most recently heard) and a "Show all N" row. Repeaters and rooms swipe to
// Login / Ping. Everything the old More tab offered for repeaters, rooms and the radio tools opens from here.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../app/chat_controller.dart';
import '../../chat/conversation_row.dart';
import '../../chat/models.dart';
import '../../chat/network_model.dart';
import '../app.dart';
import '../contacts/contact_widgets.dart' show contactTypeLabel;
import '../contacts/contacts_grouping.dart';
import '../contacts/contacts_view.dart' show HeardBars, NearbyAdvertRow, NearbyList;
import '../contacts/path_manager_screen.dart' show offerUseRoute;
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../radio/device_settings_screen.dart';
import '../radios/admin_launcher.dart' show openRepeaterAdmin, openRoom;
import '../tools/adverts_screen.dart';
import '../tools/discover_screen.dart';
import '../tools/ping_result_sheet.dart' show showPingSheet;
import '../tools/rx_log_screen.dart';
import '../tools/trace_screen.dart';
import 'chat_navigation.dart';
import 'conversation_tile.dart';
import 'network_radio.dart';

export '../../chat/network_model.dart' show kNetworkSectionRows;

/// Rows of Heard nearby shown before "See all".
const int kNearbyPreviewRows = 3;

/// The radio tools reachable from the Tools button (and nowhere else in Chat).
enum NetworkTool { trace, discover, rxLog, adverts }

class NetworkView extends StatefulWidget {
  final ChatController controller;
  final ChatNavigator navigator;
  final String query;
  final VoidCallback? onConnect;

  /// The connected radio; null = built from the app (no app in a bare widget test means no battery, Announce or Discover).
  final NetworkRadio? radio;

  /// Battery poll period (60 s; tests shorten it).
  final Duration batteryInterval;
  const NetworkView({
    super.key,
    required this.controller,
    required this.navigator,
    this.query = '',
    this.onConnect,
    this.radio,
    this.batteryInterval = const Duration(seconds: 60),
  });

  @override
  State<NetworkView> createState() => _NetworkViewState();
}

class _NetworkViewState extends State<NetworkView> with WidgetsBindingObserver {
  final Set<ContactType> _expanded = {};
  NetworkRadio? _radio;
  BatteryPoller? _poller;
  BatteryChipState _battery = BatteryChipState.none;
  bool _foreground = true;
  bool _discovering = false;
  bool _syncQueued = false;

  ChatController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.navigator.contacts.setQuery(widget.query.trim());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.maybeOf(context);
    final r = widget.radio ?? (app == null ? null : AppNetworkRadio(app));
    if (r != _radio) {
      _poller?.dispose();
      _poller = null;
      _radio = r;
      _battery = BatteryChipState.none;
    }
  }

  @override
  void didUpdateWidget(NetworkView old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) widget.navigator.contacts.setQuery(widget.query.trim());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final fg = state == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    _syncPoller();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poller?.dispose();
    super.dispose();
  }

  /// The battery is read only while the radio is connected, this segment is on screen and the app is in the foreground.
  void _syncPoller() {
    final r = _radio;
    final want = r != null && _foreground && _c.radioConnected && r.connected;
    if (want) {
      _poller ??= BatteryPoller(
        fetch: r.battery,
        interval: widget.batteryInterval,
        onState: (s) {
          if (mounted && s != _battery) setState(() => _battery = s);
        },
      );
      _poller!.start();
    } else {
      _poller?.stop();
      if (_battery != BatteryChipState.none && mounted) setState(() => _battery = BatteryChipState.none);
    }
  }

  void _queueSync() {
    if (_syncQueued) return;
    _syncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncQueued = false;
      if (mounted) _syncPoller();
    });
  }

  // ------------------------------------------------------------------ actions

  void _toast(String text, {bool ok = true}) => showAppToast(context, text, kind: ok ? AppToastKind.success : AppToastKind.error);

  Future<void> _announce() async {
    final r = _radio;
    if (r == null) return;
    final wide = await showAppActionSheet<bool>(
      context,
      sheetKey: const Key('announce-sheet'),
      title: 'Announce myself',
      message: 'Sends your radio’s name and position to other radios so they list you.',
      actions: const [
        AppAction('Nearby only', false, key: Key('announce-nearby'), symbol: AppSymbols.antenna),
        AppAction('Wider, through repeaters', true, key: Key('announce-wide'), symbol: AppSymbols.globe),
      ],
    );
    if (wide == null || !mounted) return;
    if (wide) {
      final ok = await showAppConfirm(
        context,
        title: 'Announce to the whole mesh?',
        message: 'Every repeater that hears it passes it on, so it costs airtime across the mesh. Your radio already announces itself now and then.',
        confirmLabel: 'Announce',
        confirmKey: const Key('announce-wide-confirm'),
      );
      if (!ok || !mounted) return;
    }
    final res = await r.announce(wide: wide);
    if (mounted) _toast(res.message, ok: res.ok);
  }

  Future<void> _discover() async {
    final r = _radio;
    if (r == null || _discovering) return;
    setState(() => _discovering = true);
    try {
      final res = await r.discover();
      if (mounted) _toast(res.message, ok: res.ok);
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _tools() async {
    final t = await showAppActionSheet<NetworkTool>(
      context,
      sheetKey: const Key('tools-sheet'),
      title: 'Radio tools',
      actions: const [
        AppAction('Trace a path', NetworkTool.trace, key: Key('tools-trace'), symbol: AppSymbols.route),
        AppAction('Discover nearby', NetworkTool.discover, key: Key('tools-discover'), symbol: AppSymbols.antenna),
        AppAction('Rx log', NetworkTool.rxLog, key: Key('tools-rxlog'), symbol: AppSymbols.waveform),
        AppAction('Adverts', NetworkTool.adverts, key: Key('tools-adverts'), symbol: AppSymbols.bell),
      ],
    );
    if (t == null || !mounted) return;
    final screen = switch (t) {
      NetworkTool.trace => const TraceScreen(),
      NetworkTool.discover => const DiscoverScreen(),
      NetworkTool.rxLog => const RxLogScreen(),
      NetworkTool.adverts => const AdvertsScreen(),
    };
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  void _openSettings() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DeviceSettingsScreen()));

  Future<void> _seeAllNearby() => showAppSheet<void>(
        context,
        detents: const [0.6, 0.95],
        builder: (ctx, controller) => AppSheetScaffold(
          controller: controller,
          title: 'Heard nearby',
          children: [NearbyList(controller: widget.navigator.contacts)],
        ),
      );

  void _login(Contact c) {
    if (!_c.radioConnected) {
      _toast('Connect your radio first.', ok: false);
      return;
    }
    if (c.type == ContactType.room) {
      unawaited(openRoom(context, keyHex: c.publicKey, name: c.displayName));
    } else {
      unawaited(openRepeaterAdmin(context, keyHex: c.publicKey, name: c.displayName));
    }
  }

  Future<void> _ping(Contact c) async {
    if (!_c.radioConnected) {
      _toast('Connect your radio first.', ok: false);
      return;
    }
    final m = widget.navigator.contacts.manager;
    await showPingSheet(context, contact: c, manager: m, onUseRoute: (r) => offerUseRoute(context, m, c, r));
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    _queueSync();
    return ListenableBuilder(
      listenable: Listenable.merge([_c, widget.navigator.contacts]),
      builder: (context, _) {
        final q = widget.query.trim();
        final groups = groupNetwork(_allNodes(), query: q);
        final nearby = widget.navigator.contacts.nearby;
        final claimed = _claimed(groups);
        final none = groups.values.every((l) => l.isEmpty) && claimed.isEmpty;
        final connected = _c.radioConnected;
        return SliverMainAxisGroup(
          slivers: [
            if (q.isEmpty) SliverToBoxAdapter(child: _radioCard(context)),
            if (q.isEmpty) const SliverToBoxAdapter(child: _Subtitle()),
            if (connected || nearby.isNotEmpty) SliverToBoxAdapter(child: _nearbySection(context, nearby, connected)),
            if (none)
              SliverToBoxAdapter(child: q.isNotEmpty ? _noMatches(q) : _empty(context, connected))
            else ...[
              ..._section('Repeaters', ContactType.repeater, groups[ContactType.repeater]!),
              ..._section('Rooms', ContactType.room, groups[ContactType.room]!),
              ..._section('Sensors', ContactType.sensor, groups[ContactType.sensor]!),
              if (claimed.isNotEmpty) ..._claimedSection(claimed),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: Gap.xl)),
          ],
        );
      },
    );
  }

  Iterable<Contact> _allNodes() {
    final id = _c.radioId;
    if (id == null) return const [];
    return _c.store.contacts.list(id, includeBlocked: false);
  }

  /// Repeaters and rooms the person claimed that the radio does not have as contacts yet (the old Repeaters screen's last section).
  List<({String key, String name, bool room})> _claimed(Map<ContactType, List<Contact>> groups) {
    final app = AppScope.maybeOf(context);
    if (app == null || widget.query.trim().isNotEmpty) return const [];
    final have = {for (final l in groups.values) for (final c in l) c.publicKey.toLowerCase()};
    return [
      for (final c in app.claims.active)
        if (!have.contains(c.pubkey.toLowerCase()) && (c.nodeType.name == 'repeater' || c.nodeType.name == 'room'))
          (key: c.pubkey, name: c.displayName ?? c.nodeName ?? 'Repeater ${c.pubkey.substring(0, 6)}', room: c.nodeType.name == 'room'),
    ];
  }

  Widget _noMatches(String q) => AppEmptyView(
        key: const Key('network-no-results'),
        symbol: AppSymbols.magnifyingglass,
        title: 'No matches for “$q”',
        message: 'Nothing on the network has that name.',
      );

  Widget _empty(BuildContext context, bool connected) => Padding(
        padding: const EdgeInsets.only(top: Gap.l),
        child: Column(children: [
          const AppEmptyView(
            key: Key('network-empty'),
            symbol: AppSymbols.antenna,
            title: 'No repeaters heard yet',
            message: 'They appear after their next advert.',
          ),
          if (connected)
            Wrap(alignment: WrapAlignment.center, spacing: Gap.s, children: [
              CupertinoButton.tinted(
                key: const Key('network-empty-advert'),
                minimumSize: const Size(Hit.min, Hit.min),
                onPressed: () async {
                  final res = await _radio?.announce(wide: false);
                  if (res != null && mounted) _toast(res.message, ok: res.ok);
                },
                child: const Text('Send an advert'),
              ),
              CupertinoButton.tinted(
                key: const Key('network-empty-discover'),
                minimumSize: const Size(Hit.min, Hit.min),
                onPressed: _discovering ? null : _discover,
                child: const Text('Discover nearby'),
              ),
            ])
          else
            CupertinoButton.tinted(
              key: const Key('network-empty-connect'),
              minimumSize: const Size(Hit.min, Hit.min),
              onPressed: widget.onConnect,
              child: const Text('Connect radio'),
            ),
        ]),
      );

  // ------------------------------------------------------------------ your radio

  Widget _radioCard(BuildContext context) {
    final c = AppColors.of(context);
    final connected = _c.radioConnected;
    final name = _radio?.name ?? _c.selfName;
    final title = connected ? (name == null || name.isEmpty ? 'Your radio' : name) : 'Radio not connected';
    final fw = _radio?.firmware;
    final freq = _radio?.frequencyMhz;
    final facts = [
      if (fw != null && fw.isNotEmpty) 'fw $fw',
      if (freq != null) '${freq.toStringAsFixed(freq == freq.roundToDouble() ? 0 : 3)} MHz',
    ];
    void tap() => connected ? _openSettings() : widget.onConnect?.call();
    final b = _battery;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.m, Layout.screenMargin, 0),
      child: Container(
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(color: c.surfaceHigh, borderRadius: BorderRadius.circular(Corners.card)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(
            button: true,
            container: true,
            label: connected ? 'Your radio. $title. Connected. ${b.visible ? '${b.spoken}. ' : ''}${facts.join(', ')}. Radio and device settings' : 'Your radio. $title. Tap to connect over Bluetooth',
            onTap: tap,
            child: ExcludeSemantics(
              child: GestureDetector(
                key: const Key('network-radio-card'),
                behavior: HitTestBehavior.opaque,
                onTap: tap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 52),
                  child: Row(children: [
                    AppSymbolIcon(AppSymbols.antenna, size: 28, color: connected ? c.accent : c.textMuted),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.headline),
                        if (!connected)
                          Text('Tap to connect over Bluetooth', style: AppType.subhead.copyWith(color: c.textMuted))
                        else
                          Wrap(spacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
                            Text('Connected', style: AppType.subhead.copyWith(color: c.textMuted)),
                            if (b.visible) _BatteryChip(state: b),
                            for (final f in facts) Text('· $f', style: AppType.subhead.copyWith(color: c.textMuted)),
                          ]),
                      ]),
                    ),
                    AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: c.textMuted),
                  ]),
                ),
              ),
            ),
          ),
          if (connected)
            Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
                CupertinoButton.tinted(
                  key: const Key('network-announce'),
                  minimumSize: const Size(Hit.min, Hit.min),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                  onPressed: _announce,
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: Text('Announce myself', maxLines: 1, overflow: TextOverflow.ellipsis)), SizedBox(width: 4), AppSymbolIcon(AppSymbols.chevronDown, size: 12)]),
                ),
                CupertinoButton.tinted(
                  key: const Key('network-tools'),
                  minimumSize: const Size(Hit.min, Hit.min),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                  onPressed: _tools,
                  child: const Text('Tools'),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  // ------------------------------------------------------------------ heard nearby

  Widget _nearbySection(BuildContext context, List<AdvertSeen> nearby, bool connected) {
    final c = AppColors.of(context);
    final shown = nearby.take(kNearbyPreviewRows).toList();
    final title = nearby.isEmpty ? 'Heard nearby' : 'Heard nearby (${nearby.length} new)';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.l, Layout.screenMargin - Gap.s, 0),
        child: Row(children: [
          Expanded(child: Semantics(header: true, child: Text(title.toUpperCase(), key: const Key('nearby-heading'), style: AppType.footnote.copyWith(color: c.textMuted, letterSpacing: 0.4)))),
          if (nearby.length > kNearbyPreviewRows)
            CupertinoButton(
              key: const Key('nearby-see-all'),
              padding: const EdgeInsets.symmetric(horizontal: Gap.s),
              minimumSize: const Size(Hit.min, 32),
              onPressed: _seeAllNearby,
              child: const Text('See all'),
            ),
        ]),
      ),
      if (shown.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.xs, Layout.screenMargin, 0),
          child: Text('Nothing new nearby right now.', key: const Key('nearby-none'), style: AppType.subhead.copyWith(color: c.textMuted)),
        )
      else
        for (final a in shown)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
            child: NearbyAdvertRow(key: Key('nearby-${a.publicKey.substring(0, 8)}'), advert: a, controller: widget.navigator.contacts),
          ),
      if (connected)
        Align(
          alignment: Alignment.centerLeft,
          child: CupertinoButton(
            key: const Key('nearby-discover'),
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
            minimumSize: const Size(Hit.min, Hit.min),
            onPressed: _discovering ? null : _discover,
            child: _discovering
                ? const Row(mainAxisSize: MainAxisSize.min, children: [CupertinoActivityIndicator(radius: 8), SizedBox(width: Gap.s), Text('Discovering…')])
                : const Text('Discover nearby'),
          ),
        ),
    ]);
  }

  // ------------------------------------------------------------------ sections

  List<Widget> _section(String title, ContactType type, List<Contact> items) {
    if (items.isEmpty) return const [];
    final open = _expanded.contains(type);
    final shown = open ? items : items.take(kNetworkSectionRows).toList();
    final more = items.length - shown.length;
    final swipe = type != ContactType.sensor;
    return [
      SliverToBoxAdapter(child: _Header(title)),
      SliverList.builder(
        itemCount: shown.length,
        itemBuilder: (context, i) {
          final c = shown[i];
          final row = _NodeRow(
            key: Key('network-row-${c.prefix}'),
            contact: c,
            now: _c.now(),
            onTap: () => widget.navigator.openProfile(context, c),
            actions: swipe
                ? {
                    const CustomSemanticsAction(label: 'Log in'): () => _login(c),
                    const CustomSemanticsAction(label: 'Ping'): () => unawaited(_ping(c)),
                  }
                : const {},
          );
          return Column(children: [
            swipe
                ? Slidable(
                    key: ValueKey('network-slide-${c.publicKey}'),
                    endActionPane: ActionPane(motion: const DrawerMotion(), extentRatio: 0.5, children: [
                      _SwipeAction(key: Key('network-swipe-login-${c.prefix}'), color: AppColors.of(context).accent, symbol: AppSymbols.lock, label: 'Log in', onTap: () => _login(c)),
                      _SwipeAction(key: Key('network-swipe-ping-${c.prefix}'), color: AppColors.of(context).textMuted, symbol: AppSymbols.antenna, label: 'Ping', onTap: () => unawaited(_ping(c))),
                    ]),
                    child: row,
                  )
                : row,
            const RowDivider(),
          ]);
        },
      ),
      if (more > 0 || open && items.length > kNetworkSectionRows)
        SliverToBoxAdapter(
          child: _ShowAll(
            key: Key('network-showall-${type.name}'),
            label: open ? 'Show fewer' : 'Show all ${items.length}',
            onTap: () => setState(() => open ? _expanded.remove(type) : _expanded.add(type)),
          ),
        ),
    ];
  }

  List<Widget> _claimedSection(List<({String key, String name, bool room})> items) => [
        const SliverToBoxAdapter(child: _Header('Claimed by you, not on your radio yet')),
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final it = items[i];
            final c = AppColors.of(context);
            void open() => it.room ? unawaited(openRoom(context, keyHex: it.key, name: it.name)) : unawaited(openRepeaterAdmin(context, keyHex: it.key, name: it.name));
            return Column(children: [
              Semantics(
                button: true,
                container: true,
                label: '${it.name}, ${it.room ? 'room' : 'repeater'}, claimed, not on your radio yet',
                onTap: open,
                child: ExcludeSemantics(
                  child: GestureDetector(
                    key: Key('network-claimed-${it.key.substring(0, 8)}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: open,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 56),
                      padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
                      child: Row(children: [
                        AppSymbolIcon(it.room ? AppSymbols.bubbles : AppSymbols.antenna, size: 24, color: c.textMuted),
                        const SizedBox(width: Gap.m),
                        Expanded(child: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.headline)),
                        AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: c.textMuted),
                      ]),
                    ),
                  ),
                ),
              ),
              const RowDivider(),
            ]);
          },
        ),
      ];
}

/// Under the radio card: says what this page is, for the first visit.
class _Subtitle extends StatelessWidget {
  const _Subtitle();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, 0),
        child: Text('Your radio, repeaters, rooms and sensors', key: const Key('network-subtitle'), style: AppType.footnote.copyWith(color: AppColors.of(context).textMuted)),
      );
}

class _BatteryChip extends StatelessWidget {
  final BatteryChipState state;
  const _BatteryChip({required this.state});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final low = state.kind == BatteryChipKind.low;
    final col = low ? c.danger : c.textMuted;
    return Semantics(
      label: state.spoken,
      excludeSemantics: true,
      child: Row(key: Key('battery-chip-${state.kind.name}'), mainAxisSize: MainAxisSize.min, children: [
        AppSymbolIcon(AppSymbols.battery, size: 15, color: col),
        const SizedBox(width: 3),
        Text(state.label, style: AppType.subhead.copyWith(color: col, fontWeight: low ? FontWeight.w600 : FontWeight.w400)),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Semantics(
        header: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.l, Layout.screenMargin, Gap.xs),
          child: Text(text.toUpperCase(), style: AppType.footnote.copyWith(color: AppColors.of(context).textMuted, letterSpacing: 0.4)),
        ),
      );
}

String agoText(int? ms, DateTime now) {
  if (ms == null) return 'Not heard yet';
  final s = (now.millisecondsSinceEpoch - ms) ~/ 1000;
  if (s < 90) return 'Heard just now';
  if (s < 5400) return 'Heard ${(s / 60).round()} min ago';
  if (s < 129600) return 'Heard ${(s / 3600).round()} h ago';
  return 'Heard ${(s / 86400).round()} d ago';
}

class _NodeRow extends StatelessWidget {
  final Contact contact;
  final DateTime now;
  final VoidCallback onTap;
  final Map<CustomSemanticsAction, VoidCallback> actions;
  const _NodeRow({super.key, required this.contact, required this.now, required this.onTap, this.actions = const {}});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final kind = switch (contact.type) {
      ContactType.repeater => RowKind.repeater,
      ContactType.room => RowKind.room,
      ContactType.sensor => RowKind.sensor,
      ContactType.companion => RowKind.person,
    };
    final hops = contact.pathHops;
    final route = hops == null ? null : (hops == 0 ? 'Direct' : '$hops ${hops == 1 ? 'hop' : 'hops'}');
    final sub = [agoText(contact.lastHeardMs, now), ?route].join(' · ');
    final avatar = ConversationRow(
      key: contact.prefix,
      convKind: contact.type == ContactType.room ? ConvKind.room : ConvKind.dm,
      kind: kind,
      title: contact.displayName,
      avatarSeed: contact.publicKey,
    );
    return Semantics(
      button: true,
      container: true,
      label: '${contact.displayName}, ${contactTypeLabel(contact.type)}. $sub',
      customSemanticsActions: actions,
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            color: c.bg,
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
            child: Row(children: [
              ConversationAvatar(row: avatar, size: 44),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(contact.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.headline),
                  Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.subhead.copyWith(color: c.textMuted)),
                ]),
              ),
              HeardBars(bars: heardBars(contact, now.millisecondsSinceEpoch)),
              const SizedBox(width: Gap.s),
              AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: c.textMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SwipeAction extends StatelessWidget {
  final Color color;
  final AppSymbol symbol;
  final String label;
  final VoidCallback onTap;
  const _SwipeAction({super.key, required this.color, required this.symbol, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => CustomSlidableAction(
        onPressed: (_) => onTap(),
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Semantics(
          label: label,
          button: true,
          excludeSemantics: true,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            AppSymbolIcon(symbol, size: 22, color: Colors.white),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, style: AppType.footnote.copyWith(color: Colors.white, fontWeight: FontWeight.w600), textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3)),
          ]),
        ),
      );
}

class _ShowAll extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ShowAll({super.key, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
          minimumSize: const Size(Hit.min, Hit.min),
          onPressed: onTap,
          child: Text(label),
        ),
      );
}
