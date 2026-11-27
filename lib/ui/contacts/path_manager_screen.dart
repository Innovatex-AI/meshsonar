// The Route screen (chat plan 4.7). User-facing title "Route", never "Path". Shows how messages reach a contact (the
// phone's mirror of the route the radio holds) and lets the person find a route now, test it and reset it.
//
// Build 77 (round 3, "Removed"): the radio learns and keeps the route; the app never chooses one. The mode picker
// (Automatic / Keep this route / Always search), "Use this route", the Undo of a reset and "Choose repeaters yourself"
// are gone with the features behind them. Reset route stays (the official app has it).
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoNavigationBar;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/contact_manager.dart';
import '../../chat/models.dart';
import '../../core/time_format.dart' as tf;
import '../../radio/path_tools.dart';
import '../../radio/tools/ping_tool.dart';
import '../../radio/tools/radio_tools.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
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

/// "just now", "2 min ago", "3 h ago", "5 d ago" (the one app time formatter); '' when unknown.
String agoText(int nowMs, int? thenMs) => thenMs == null
    ? ''
    : tf.relativeTime(DateTime.fromMillisecondsSinceEpoch(thenMs), now: DateTime.fromMillisecondsSinceEpoch(nowMs));

class PathManagerScreen extends StatefulWidget {
  final ContactManager manager;
  final String publicKey;

  /// Rebuilds the screen when the contact changes (ContactsController, ChatController...).
  final Listenable changes;

  /// Radio tools override (tests); default = the connected radio's.
  final RadioTools? tools;
  const PathManagerScreen({super.key, required this.manager, required this.publicKey, required this.changes, this.tools});

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
    // A found route goes into the route history. Nothing is written to the radio: it learns the route by itself.
    final out = r.outRoute;
    if (r.ok && out != null) await _m.useDiscoveredRoute(c.publicKey, out, keep: false);
    if (!mounted) return;
    setState(() {
      _finding = false;
      _found = r;
    });
  }

  Future<void> _test(Contact c) async {
    if (!_m.connected) {
      _say('Connect your radio to test the route.');
      return;
    }
    await showPingSheet(context, contact: c, manager: _m, tools: _tools);
  }

  Future<void> _reset(Contact c) async {
    await _m.resetPath(c.publicKey);
    AppHaptics.success();
    if (!mounted) return;
    // No Undo: the app never writes a route to the radio, so a cleared route cannot be put back (build 77).
    showAppToast(context, 'Route cleared. The next message goes to everyone nearby and your radio learns a new route.');
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
    final learned = c.pathLearnedMs;
    final caption = !c.hasPath
        ? 'Your next message goes to everyone nearby, and your radio learns the route from the reply.'
        : (learned == null ? routeCaption(c) : 'Learned ${agoText(now, learned)}');
    return ListView(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      children: [
        ProfileGroup(rows: [
          Padding(
            key: const Key('route-card'),
            padding: const EdgeInsets.all(Layout.screenMargin),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (c.hasPath)
                HopChain(key: const Key('route-chain'), nodes: nodes)
              else
                Text('No route yet', style: AppType.headline.copyWith(color: col.textPrimary)),
              const SizedBox(height: Gap.s),
              Text(caption, key: const Key('route-caption'), style: AppType.footnote.copyWith(color: col.textMuted)),
            ]),
          ),
        ]),
        ProfileGroup(rows: [
          ProfileRow(
            key: const Key('route-find'),
            label: 'Find a route now',
            valueWidget: _finding ? const CupertinoActivityIndicator() : null,
            // Says why it will not work before the tap, like the Test row under it.
            value: _finding || connected ? null : 'Radio not connected',
            chevron: !_finding,
            onTap: _finding ? null : () => _find(c),
          ),
          ProfileRow(key: const Key('route-test'), label: 'Test this route', chevron: true, onTap: connected ? () => _test(c) : null, value: connected ? null : 'Radio not connected'),
          ProfileRow(
            key: const Key('route-reset'),
            label: 'Reset route',
            destructive: c.hasPath,
            onTap: c.hasPath ? () => _reset(c) : null,
            value: c.hasPath ? null : 'No route saved',
          ),
        ],
            footer: connected
                ? 'Your radio picks the route and keeps it up to date. Finding or testing uses a little airtime.'
                : 'Your radio picks the route and keeps it up to date. Connect it to find or test a route.'),
        if (_found != null) _foundCard(c, col, repeaters),
        ProfileGroup(rows: [
          ProfileRow(
            key: const Key('route-advanced'),
            label: 'Advanced',
            chevron: true,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => RouteAdvancedPage(manager: _m, publicKey: c.publicKey, changes: widget.changes, tools: widget.tools))),
          ),
        ]),
      ],
    );
  }

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
      Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Layout.screenMargin),
        child: Text('Your radio learns the route by itself: nothing to save.', key: const Key('found-note'), style: AppType.footnote.copyWith(color: col.textMuted)),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ Advanced

/// Advanced: hash size, copy route, trace and discover, recent deliveries, route history.
class RouteAdvancedPage extends StatelessWidget {
  final ContactManager manager;
  final String publicKey;
  final Listenable changes;
  final RadioTools? tools;
  const RouteAdvancedPage({super.key, required this.manager, required this.publicKey, required this.changes, this.tools});

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
        final size = route?.hashSize;
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
