// The Route screen (chat plan 4.7). User-facing title "Route", never "Path". Shows how messages reach a contact, lets the
// person pick Automatic / Keep this route / Always search, find a route now, test it, reset it, and (Advanced) choose
// repeaters themselves. Reading the route, choosing the mode, discovery, testing and reset are live; the radio WRITE of a
// chosen route is behind AppFlags.routeWriteVerified (see route_picker_page.dart).
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoNavigationBar;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_flags.dart';
import '../../chat/contact_manager.dart';
import '../../chat/models.dart';
import '../../radio/path_tools.dart';
import '../../radio/tools/ping_tool.dart';
import '../../radio/tools/radio_tools.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/hop_chain.dart';
import '../design/tokens.dart';
import '../tools/contact_ref.dart';
import '../tools/discover_screen.dart';
import '../tools/ping_result_sheet.dart';
import '../tools/trace_screen.dart';
import 'contact_widgets.dart' show routeCaption;
import 'profile_widgets.dart';
import 'route_nodes.dart';
import 'route_picker_page.dart';

/// "just now", "2 min ago", "3 h ago", "5 days ago".
String agoText(int nowMs, int? thenMs) {
  if (thenMs == null) return '';
  final d = nowMs - thenMs;
  if (d < 90 * 1000) return 'just now';
  final min = d ~/ 60000;
  if (min < 60) return '$min min ago';
  final h = d ~/ 3600000;
  if (h < 24) return '$h h ago';
  return '${d ~/ 86400000} days ago';
}

/// One line per mode, in the app-wide words.
String pathModeTitle(PathMode m) => switch (m) { PathMode.auto => 'Automatic', PathMode.fixed => 'Keep this route', PathMode.flood => 'Always search' };
String pathModeSentence(PathMode m) => switch (m) {
      PathMode.auto => 'Learns the best route; searches again if it breaks.',
      PathMode.fixed => 'Always uses this route, even if it fails.',
      PathMode.flood => 'Sends to everyone nearby. Slower, uses more airtime.',
    };

/// "Use this route": Keep this route or Automatic, from an action sheet; says what happened in a toast.
Future<void> offerUseRoute(BuildContext context, ContactManager m, Contact c, PathRoute route) async {
  dismissAppToast();
  final keep = await showAppActionSheet<bool>(
    context,
    title: 'Use this route',
    message: route.isEmpty ? 'Direct, no repeater in between.' : route.text,
    actions: const [AppAction('Keep this route', true, key: Key('use-keep')), AppAction('Automatic', false, key: Key('use-auto'))],
  );
  if (keep == null) return;
  final err = await m.useDiscoveredRoute(c.publicKey, route, keep: keep);
  if (err == null) AppHaptics.success(); // route set (plan 2.2)
  if (context.mounted) showAppToast(context, err ?? (keep ? 'Keeping this route.' : 'Automatic: MeshSonar picks the route.'));
}

class PathManagerScreen extends StatefulWidget {
  final ContactManager manager;
  final String publicKey;

  /// Rebuilds the screen when the contact changes (ContactsController, ChatController...).
  final Listenable changes;

  /// Radio tools override (tests); default = the connected radio's.
  final RadioTools? tools;

  /// Whether choosing repeaters (a radio write) is offered. Default AppFlags.routeWriteVerified; tests force it.
  final bool routeWrite;
  const PathManagerScreen({super.key, required this.manager, required this.publicKey, required this.changes, this.tools, this.routeWrite = AppFlags.routeWriteVerified});

  static Future<void> open(BuildContext context, {required ContactManager manager, required String publicKey, required Listenable changes}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PathManagerScreen(manager: manager, publicKey: publicKey, changes: changes)));

  @override
  State<PathManagerScreen> createState() => _PathManagerScreenState();
}

class _PathManagerScreenState extends State<PathManagerScreen> {
  bool _finding = false;
  PingResult? _found;
  bool _gone = false;

  ContactManager get _m => widget.manager;
  Contact? get _contact => _m.store.contacts.get(_m.radioId ?? '', widget.publicKey);
  RadioTools? get _tools => widget.tools ?? radioToolsOf(context);

  void _say(String s) {
    if (mounted) showAppToast(context, s);
  }

  Future<void> _pickMode(Contact stale, PathMode mode) async {
    final c = _contact ?? stale;
    if (c.pathMode == mode) return;
    if (mode == PathMode.fixed) {
      if (!c.hasPath) return;
      if (!_m.keepCurrentRoute(c.publicKey)) {
        _say('Could not keep this route.');
        return;
      }
    } else {
      _m.setRouteMode(c.publicKey, mode);
    }
    AppHaptics.selection();
    _say(switch (mode) {
      PathMode.auto => 'Automatic: MeshSonar picks the route.',
      PathMode.fixed => 'Keeping this route.',
      PathMode.flood => 'Always search: every message goes to everyone nearby.',
    });
  }

  Future<void> _find(Contact c) async {
    final tools = _tools;
    if (tools == null || !_m.connected) {
      _say('Connect your radio to look for a route.');
      return;
    }
    setState(() {
      _finding = true;
      _found = null;
    });
    final r = await tools.ping.discover(c.publicKey);
    if (r.status != PingStatus.tooSoon && r.status != PingStatus.notConnected && r.status != PingStatus.unsupported) {
      _m.recordPing(c.publicKey,
          kind: 'discovery', ok: r.ok, rttMs: r.rttMs, hops: r.outRoute?.length, out: r.outRoute?.text, back: r.backRoute?.text, failReason: r.failReason);
    }
    if (!mounted) return;
    setState(() {
      _finding = false;
      _found = r;
    });
  }

  Future<void> _useFound(Contact c, PathRoute route) => offerUseRoute(context, _m, c, route);

  Future<void> _test(Contact c) async {
    if (!_m.connected) {
      _say('Connect your radio to test the route.');
      return;
    }
    await showPingSheet(context, contact: c, manager: _m, tools: _tools);
  }

  Future<void> _reset(Contact c) async {
    dismissAppToast(); // a toast from the last choice must not sit over the confirm sheet
    final ok = await showAppConfirm(context,
        title: 'Reset the route to ${c.displayName}?',
        message: 'The saved route is forgotten and the next message searches again.',
        confirmLabel: 'Reset route',
        destructive: true,
        confirmKey: const Key('reset-route-confirm'));
    if (!ok) return;
    await _m.resetPath(c.publicKey);
    AppHaptics.success();
    _say('Route cleared. The next message searches again.');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.changes,
      builder: (context, _) {
        final c = _contact;
        final col = AppColors.of(context);
        if (c == null) {
          if (!_gone) {
            _gone = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
            });
          }
          return Scaffold(backgroundColor: col.bg, appBar: CupertinoNavigationBar(backgroundColor: col.bg, border: null));
        }
        return Scaffold(
          backgroundColor: col.bg,
          appBar: CupertinoNavigationBar(
            backgroundColor: col.bg,
            border: null,
            middle: Text('Route to ${c.displayName}', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: _content(context, c, col)),
            ),
          ),
        );
      },
    );
  }

  Widget _content(BuildContext context, Contact c, AppColors col) {
    final now = _m.nowMs();
    final repeaters = _m.store.contacts.list(_m.radioId ?? '');
    final route = decodePath(c.outPathLen, c.outPath ?? const []);
    final nodes = routeNodes(targetName: c.displayName, route: route, repeaters: repeaters);
    final connected = _m.connected;
    final searching = c.pathMode == PathMode.flood;
    final learned = c.pathLearnedMs;
    final caption = searching
        ? 'Messages go to everyone nearby.'
        : (!c.hasPath ? 'No route yet. The first message searches and learns one.' : (learned == null ? routeCaption(c) : 'Learned ${agoText(now, learned)}'));
    return ListView(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      children: [
        ProfileGroup(rows: [
          Padding(
            key: const Key('route-card'),
            padding: const EdgeInsets.all(Layout.screenMargin),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (c.hasPath || searching)
                HopChain(key: const Key('route-chain'), nodes: nodes)
              else
                Text('No route yet', style: AppType.headline.copyWith(color: col.textPrimary)),
              const SizedBox(height: Gap.s),
              Text(caption, key: const Key('route-caption'), style: AppType.footnote.copyWith(color: col.textMuted)),
            ]),
          ),
        ]),
        _sectionLabel(col, 'HOW MESSAGES TRAVEL'),
        ProfileGroup(rows: [
          for (final m in PathMode.values)
            _ChoiceRow(
              key: Key('mode-${m.name}'),
              title: pathModeTitle(m),
              sentence: m == PathMode.fixed && !c.hasPath && c.pathMode != PathMode.fixed ? 'No route learned yet. Find a route first.' : pathModeSentence(m),
              selected: c.pathMode == m,
              enabled: m != PathMode.fixed || c.hasPath || c.pathMode == PathMode.fixed,
              onTap: () => _pickMode(c, m),
            ),
        ]),
        ProfileGroup(rows: [
          ProfileRow(
            key: const Key('route-find'),
            label: 'Find a route now',
            valueWidget: _finding ? const CupertinoActivityIndicator() : null,
            chevron: !_finding,
            onTap: _finding ? null : () => _find(c),
          ),
          ProfileRow(key: const Key('route-test'), label: 'Test this route', chevron: true, onTap: connected ? () => _test(c) : null, value: connected ? null : 'Radio not connected'),
          ProfileRow(
            key: const Key('route-reset'),
            label: 'Reset route',
            destructive: c.hasPath,
            onTap: c.hasPath || c.pathMode == PathMode.fixed ? () => _reset(c) : null,
            value: c.hasPath ? null : 'No route saved',
          ),
        ], footer: connected ? 'Finding or testing a route uses a little airtime.' : null),
        if (_found != null) _foundCard(c, col, repeaters),
        ProfileGroup(rows: [
          ProfileRow(
            key: const Key('route-advanced'),
            label: 'Advanced',
            chevron: true,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => RouteAdvancedPage(manager: _m, publicKey: c.publicKey, changes: widget.changes, tools: widget.tools, routeWrite: widget.routeWrite))),
          ),
        ]),
      ],
    );
  }

  Widget _sectionLabel(AppColors col, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.l, 0, Layout.screenMargin, Gap.xs),
        child: Semantics(header: true, child: Text(t, style: AppType.footnote.copyWith(color: col.textMuted))),
      );

  Widget _foundCard(Contact c, AppColors col, List<Contact> repeaters) {
    final r = _found!;
    if (!r.ok) {
      return ProfileGroup(rows: [
        Padding(
          key: const Key('found-card'),
          padding: const EdgeInsets.all(Layout.screenMargin),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pingHeadline(r), style: AppType.headline.copyWith(color: col.warning)),
            const SizedBox(height: Gap.xs),
            Text(pingFailureBody(r), style: AppType.subhead.copyWith(color: col.textMuted)),
          ]),
        ),
      ]);
    }
    final out = r.outRoute ?? PathRoute(1, const []);
    final nodes = routeNodes(targetName: c.displayName, route: out, repeaters: repeaters);
    return ProfileGroup(rows: [
      Padding(
        key: const Key('found-card'),
        padding: const EdgeInsets.all(Layout.screenMargin),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Found a route${r.rttMs == null ? '' : ' · ${formatRtt(r.rttMs!)}'}', style: AppType.headline.copyWith(color: col.textPrimary)),
          const SizedBox(height: Gap.s),
          HopChain(nodes: nodes, semanticsLabel: describeHopChain(nodes, prefix: 'Route out')),
        ]),
      ),
      ProfileRow(key: const Key('found-use'), label: 'Use this route', chevron: true, onTap: () => _useFound(c, out)),
    ]);
  }
}

/// A checkmark list row: title, one sentence, check on the leading edge when selected.
class _ChoiceRow extends StatelessWidget {
  final String title;
  final String sentence;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  const _ChoiceRow({super.key, required this.title, required this.sentence, required this.selected, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: '$title. $sentence',
      onTap: enabled ? onTap : null,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Hit.minAndroid),
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s + 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 26, child: selected ? AppSymbolIcon(AppSymbols.checkmark, size: 18, color: c.accent) : null),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title, style: AppType.body.copyWith(color: c.textPrimary)),
                      Text(sentence, style: AppType.footnote.copyWith(color: c.textMuted)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Advanced

/// Advanced: choose repeaters yourself (write; flag), hash size, recent deliveries, route history, copy route.
class RouteAdvancedPage extends StatelessWidget {
  final ContactManager manager;
  final String publicKey;
  final Listenable changes;
  final RadioTools? tools;
  final bool routeWrite;
  const RouteAdvancedPage({super.key, required this.manager, required this.publicKey, required this.changes, this.tools, required this.routeWrite});

  /// The last [limit] outgoing messages to the contact that ended (acked or failed), newest first.
  static List<ChatMessage> recentDeliveries(ContactManager m, Contact c, {int limit = 5}) {
    final conv = c.type == ContactType.room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix);
    final out = <ChatMessage>[];
    for (final msg in m.store.messages.page(conv, limit: 100).messages) {
      if (msg.direction != Direction.outgoing) continue;
      if (msg.state == MessageState.acked || msg.state == MessageState.failed) out.add(msg);
      if (out.length >= limit) break;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: changes,
      builder: (context, _) {
        final col = AppColors.of(context);
        final c = manager.store.contacts.get(manager.radioId ?? '', publicKey);
        if (c == null) return Scaffold(backgroundColor: col.bg, appBar: CupertinoNavigationBar(backgroundColor: col.bg, border: null));
        final route = decodePath(c.outPathLen, c.outPath ?? const []);
        final now = manager.nowMs();
        final deliveries = recentDeliveries(manager, c);
        final history = manager.store.pathHistory.list(c.publicKey, limit: 5);
        final size = route?.hashSize ?? c.pinnedHashSize;
        return Scaffold(
          backgroundColor: col.bg,
          appBar: CupertinoNavigationBar(backgroundColor: col.bg, border: null, middle: const Text('Advanced')),
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(padding: const EdgeInsets.only(bottom: Gap.xl), children: [
                  ProfileGroup(rows: [
                    if (routeWrite)
                      ProfileRow(
                        key: const Key('adv-choose'),
                        label: 'Choose repeaters yourself',
                        chevron: true,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                            fullscreenDialog: true, builder: (_) => RoutePickerPage(manager: manager, publicKey: c.publicKey, tools: tools))),
                      ),
                    ProfileRow(key: const Key('adv-hash'), label: 'Hash size', value: size == null ? '1 byte (radio default)' : '$size ${size == 1 ? 'byte' : 'bytes'}'), // copy-ok: Advanced
                    ProfileRow(
                      key: const Key('adv-copy'),
                      label: 'Copy route as text',
                      onTap: route == null
                          ? null
                          : () async {
                              await Clipboard.setData(ClipboardData(text: 'Route to ${c.displayName}: You > ${route.isEmpty ? '' : '${route.text} > '}${c.displayName}'));
                              AppHaptics.selection();
                              if (context.mounted) showAppToast(context, 'Route copied');
                            },
                      value: route == null ? 'No route saved' : null,
                    ),
                  ], footer: 'The hash size is set in Radio settings.'), // copy-ok: Advanced
                  if (manager.connected)
                    ProfileGroup(rows: [
                      ProfileRow(
                        key: const Key('adv-trace'),
                        label: 'Trace along this route',
                        chevron: true,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TraceScreen(contact: ContactRef.of(c)))),
                      ),
                      ProfileRow(
                        key: const Key('adv-discover'),
                        label: 'Look for it nearby',
                        chevron: true,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiscoverScreen(contact: ContactRef.of(c)))),
                      ),
                    ]),
                  _label(col, 'RECENT DELIVERIES'),
                  ProfileGroup(rows: [
                    if (deliveries.isEmpty) const ProfileRow(label: 'Nothing delivered yet', key: Key('adv-no-deliveries')),
                    for (final m in deliveries)
                      ProfileRow(
                        label: agoText(now, m.tsLocalMs),
                        value: '${m.state == MessageState.acked ? 'Delivered' : 'Failed'}${m.state == MessageState.acked && m.ackMs != null ? ' · ${formatRtt(m.ackMs!)}' : ''}${m.pathLen != null ? ' · via ${m.pathLen! & 63} ${(m.pathLen! & 63) == 1 ? 'repeater' : 'repeaters'}' : ''}',
                      ),
                  ]),
                  if (history.isNotEmpty) ...[
                    _label(col, 'ROUTE HISTORY'),
                    ProfileGroup(rows: [
                      for (final h in history)
                        ProfileRow(
                          label: '${_kind(h.kind)} · ${agoText(now, h.tsMs)}',
                          value: h.hops.isEmpty ? (h.kind == 'reset' ? '' : 'Direct') : h.hops.join(' › '),
                        ),
                    ]),
                  ],
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  static String _kind(String k) => switch (k) {
        'learned' => 'Learned',
        'set' => 'Set by you',
        'reset' => 'Reset',
        'discovered' => 'Found',
        'test' => 'Tested',
        _ => k,
      };

  Widget _label(AppColors col, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.l, 0, Layout.screenMargin, Gap.xs),
        child: Semantics(header: true, child: Text(t, style: AppType.footnote.copyWith(color: col.textMuted))),
      );
}
