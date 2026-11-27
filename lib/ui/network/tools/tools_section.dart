// Network > Tools (build 71, stream D; build 76: a "Find a tool" field, plain descriptions, the radio group second and
// saying whether a radio is connected). One list, three groups:
// - Network tools, native on `/v1`: Path Inspector, Trace Viewer, Prefix Tool, Decode a packet, Status (native since
//   build 77, Round 2 W9).
// - Site pages shown inside the app ([SitePageView]): Scope Audit, Compare observers, Region definition. Build 77
//   (Round 2 W6) removed the rows of the three site tools locked to site admins (Airtime and load, Point-to-point link,
//   Coverage painter): every person saw a "Sign in with email" page there.
// - Radio tools (lib/ui/tools): Send a trace (named "Trace path" until build 77, so it is not mixed up with Trace
//   Viewer), Discover, Adverts, Rx log, Noise floor, Telemetry. They live here once; each says so itself when no
//   radio is connected. A radio trace's result opens in the native Trace Viewer.
// `initialTool` (from a `/tools/<id>` link) shows that tool in place inside the section with `initialArg`, under a back
// arrow to the list; an unknown id shows the list. A row tapped in the list opens the tool as its own page.
import 'package:flutter/material.dart';

import '../../../radio/session.dart' show LinkState;
import '../../app.dart' show AppScope;
import '../../design/tokens.dart';
import '../../radio/inset_list.dart';
import '../../tools/adverts_screen.dart';
import '../../tools/discover_screen.dart';
import '../../tools/noise_screen.dart';
import '../../tools/rx_log_screen.dart';
import '../../tools/telemetry_screen.dart';
import '../../tools/tools_host.dart';
import '../../tools/trace_screen.dart';
import '../analytics/in_place_header.dart';
import '../analytics/site_page_view.dart';
import '../packets/decode_packet_screen.dart';
import 'path_inspector_screen.dart';
import 'prefix_tool_screen.dart';
import 'status_screen.dart';
import 'trace_viewer_screen.dart';

enum ToolGroup { network, site, radio }

/// One row of the Tools list. [id] is what a link names; [aliases] are other spellings of it.
class ToolEntry {
  final String id, title, about;
  final ToolGroup group;
  final List<String> aliases;
  const ToolEntry(this.id, this.title, this.about, this.group, {this.aliases = const []});
}

const List<ToolEntry> toolEntries = [
  ToolEntry('path', 'Path Inspector', 'See which repeaters a packet went through', ToolGroup.network, aliases: ['path-inspector']),
  ToolEntry('trace', 'Trace Viewer', 'How far a trace got and the signal at each repeater', ToolGroup.network, aliases: ['trace-viewer']),
  ToolEntry('prefix', 'Prefix Tool', 'Find an unused ID for a new repeater', ToolGroup.network, aliases: ['prefix-tool']),
  ToolEntry('decode', 'Decode a packet', 'Paste a packet and read what is in it', ToolGroup.network),
  ToolEntry('status', 'Status', 'Is the network data arriving and up to date', ToolGroup.network),
  ToolEntry('scope-audit', 'Scope Audit', 'Which repeaters pass on which regions', ToolGroup.site),
  ToolEntry('compare', 'Compare observers', 'What two observers both hear, and what only one does', ToolGroup.site, aliases: ['observers-compare']),
  ToolEntry('definition', 'Region definition', 'Which regions cover a spot on the map', ToolGroup.site, aliases: ['region', 'region-def']),
  ToolEntry('radio-trace', 'Send a trace', 'Send a test packet along repeaters you choose', ToolGroup.radio, aliases: ['trace-path', 'send-trace']),
  ToolEntry('discover', 'Discover', 'Find repeaters in direct range of your radio', ToolGroup.radio),
  ToolEntry('adverts', 'Adverts', 'Announce your radio and see who else announced', ToolGroup.radio),
  ToolEntry('rx-log', 'Rx log', 'Every packet your radio hears, live', ToolGroup.radio, aliases: ['rxlog', 'rx_log']),
  ToolEntry('noise', 'Noise floor', 'How quiet the channel is at your radio', ToolGroup.radio, aliases: ['noise-floor']),
  ToolEntry('telemetry', 'Telemetry', 'Battery and sensor readings from a node', ToolGroup.radio),
];

/// The tools whose name or description holds every word of [query] (any case), in list order. An empty query = all.
List<ToolEntry> toolsMatching(String query) {
  final words = [for (final w in query.toLowerCase().split(RegExp(r'\s+'))) if (w.isNotEmpty) w];
  if (words.isEmpty) return toolEntries;
  return [
    for (final e in toolEntries)
      if (words.every((w) => '${e.title} ${e.about} ${e.id}'.toLowerCase().contains(w))) e,
  ];
}

ToolEntry? toolEntryOf(String? id) {
  if (id == null) return null;
  final s = id.trim().toLowerCase();
  if (s.isEmpty) return null;
  for (final e in toolEntries) {
    if (e.id == s || e.aliases.contains(s)) return e;
  }
  return null;
}

final _latLon = RegExp(r'^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$');
final _query = RegExp(r'^[A-Za-z0-9_.~%:=&,+-]{1,400}$');

/// The site path of a site-page tool, with its link argument: Region definition takes `lat,lon`, the others a query
/// string (`a=<id>&b=<id>`). An argument of another shape is dropped.
String sitePathOfTool(String id, String? arg) {
  final a = arg?.trim() ?? '';
  final base = switch (id) {
    'scope-audit' => '/scope-audit',
    'compare' => '/observers/compare',
    'definition' => '/tools/region',
    _ => '/status',
  };
  if (a.isEmpty) return base;
  if (id == 'definition') {
    final m = _latLon.firstMatch(a);
    if (m != null) return '$base?lat=${m.group(1)}&lon=${m.group(2)}';
  }
  final q = a.startsWith('?') ? a.substring(1) : a;
  return q.contains('=') && _query.hasMatch(q) ? '$base?$q' : base;
}

class ToolsSection extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;

  /// A tool to open straight away, as the link parser (lib/core/network_request.dart) names it: `path` (argument: the
  /// `?hops=` list), `trace` (the hash of `/tools/trace/<hash>`), `prefix` (`?prefix=`), `decode`, `scope-audit`,
  /// `compare`, `definition`, `status`, or a radio tool (`radio-trace`, `discover`, `adverts`, `rx-log`, `noise`,
  /// `telemetry`); null or an unknown id (the removed `airtime`, `link`, `painter` among them) shows the list.
  final String? initialTool;

  /// The tool's argument from a link (a packet or trace hash, a prefix, a hop list).
  final String? initialArg;
  const ToolsSection({super.key, required this.baseUrl, required this.regionSlug, this.initialTool, this.initialArg});

  @override
  State<ToolsSection> createState() => _ToolsSectionState();
}

class _ToolsSectionState extends State<ToolsSection> {
  /// The tool a link opened, shown in place inside the section (no page is pushed over the Network tab). Null = the
  /// list. Radio tools are never link targets; asked for by id they open as their own page.
  ToolEntry? _shown;
  String? _shownArg;

  /// "Find a tool": what is typed over the list.
  final TextEditingController _find = TextEditingController();

  @override
  void dispose() {
    _find.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _showInitial();
  }

  @override
  void didUpdateWidget(ToolsSection old) {
    super.didUpdateWidget(old);
    if (widget.initialTool != old.initialTool || widget.initialArg != old.initialArg || widget.baseUrl != old.baseUrl) _showInitial();
  }

  /// An unknown id, or none, shows the list.
  void _showInitial() {
    final e = toolEntryOf(widget.initialTool);
    final a = (widget.initialArg ?? '').trim();
    _shown = e == null || e.group == ToolGroup.radio ? null : e;
    _shownArg = a.isEmpty ? null : a;
    if (e != null && e.group == ToolGroup.radio) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(e);
      });
    }
  }

  void _close() => setState(() {
        _shown = null;
        _shownArg = null;
      });

  /// The tool's page: in place under a back arrow when [onClose] is given, else a screen of its own.
  Widget _page(ToolEntry e, String? a, {VoidCallback? onClose}) => switch (e.id) {
        'path' => PathInspectorScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, initialHops: a, onClose: onClose),
        'trace' => TraceViewerScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, initialHash: a, onClose: onClose),
        'prefix' => PrefixToolScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, initialPrefix: a, onClose: onClose),
        'decode' => onClose == null
            ? DecodePacketScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, initialHex: a)
            // The decode screen (lib/ui/network/packets) brings its own app bar; in place the section's header replaces
            // it, so that bar is given no height here.
            : Column(children: [
                InPlaceHeader(title: e.title, onBack: onClose, backLabel: 'Back to Tools'),
                Expanded(
                  child: Theme(
                    data: Theme.of(context).copyWith(appBarTheme: Theme.of(context).appBarTheme.copyWith(toolbarHeight: 0)),
                    child: MediaQuery.removePadding(context: context, removeTop: true, child: DecodePacketScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, initialHex: a)),
                  ),
                ),
              ]),
        'status' => StatusScreen(baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, onClose: onClose),
        'radio-trace' => const TraceScreen(),
        'discover' => const DiscoverScreen(),
        'adverts' => const AdvertsScreen(),
        'rx-log' => const RxLogScreen(),
        'noise' => const NoiseScreen(),
        'telemetry' => const TelemetryScreen(),
        _ => onClose == null
            ? SitePageView(baseUrl: widget.baseUrl, path: sitePathOfTool(e.id, a), title: e.title)
            : SitePageView.inPlace(baseUrl: widget.baseUrl, path: sitePathOfTool(e.id, a), title: e.title, onClose: onClose),
      };

  /// A row tapped in the list opens the tool as its own page.
  void _open(ToolEntry e) {
    Navigator.of(context).push(MaterialPageRoute<void>(settings: RouteSettings(name: '/tools/${e.id}'), builder: (_) => _page(e, null)));
  }

  List<Widget> _rowsOf(Iterable<ToolEntry> entries) => [
        for (final e in entries) InsetRow(key: Key('tool-row-${e.id}'), title: e.title, subtitle: e.about, onTap: () => _open(e)),
      ];

  List<Widget> _rows(ToolGroup g) => _rowsOf(toolEntries.where((e) => e.group == g));

  /// The radio behind the radio tools, when the app (or a test) provides one; null in a bare widget test.
  ToolsHost? _host(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ToolsHostScope>();
    if (scope != null) return scope.host;
    final app = AppScope.maybeOf(context);
    return app == null ? null : AppStateToolsHost.of(app);
  }

  /// The radio group: says whether a radio is connected, and offers Connect as its first row when none is, so a
  /// person does not open six tools to read "Radio not connected" six times.
  Widget _radioGroup(BuildContext context) {
    final host = _host(context);
    final rows = _rows(ToolGroup.radio);
    if (host == null) return InsetGroup(header: 'With your radio', footer: 'These use your connected radio.', rows: rows);
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final ready = host.tools != null;
        final name = host.radioName;
        final waiting = host.linkState == LinkState.connecting || host.linkState == LinkState.reconnecting;
        return InsetGroup(
          header: 'With your radio',
          footer: ready
              ? 'Using ${name == null || name.isEmpty ? 'your connected radio' : name}.'
              : waiting
                  ? 'Connecting to your radio. These work as soon as it is back.'
                  : 'No radio is connected. Connect one to use these.',
          rows: [
            if (!ready && !waiting)
              InsetRow(key: const Key('tools-connect-radio'), title: 'Connect a radio', subtitle: 'Bluetooth, to a MeshCore radio', onTap: () => host.openConnect(context)),
            ...rows,
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown != null) {
      return KeyedSubtree(key: ValueKey('tools-in-place-${widget.baseUrl}-${shown.id}-$_shownArg'), child: _page(shown, _shownArg, onClose: _close));
    }
    final t = Theme.of(context);
    final query = _find.text.trim();
    final found = query.isEmpty ? const <ToolEntry>[] : toolsMatching(query);
    return ListView(
      key: const Key('tools-section'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, 12),
          child: TextField(
            key: const Key('tools-find'),
            controller: _find,
            autocorrect: false,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Find a tool',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      key: const Key('tools-find-clear'),
                      tooltip: 'Clear',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: () => setState(_find.clear),
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
        ),
        if (query.isNotEmpty && found.isEmpty)
          Padding(
            key: const Key('tools-find-none'),
            padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.l, 0, Layout.screenMargin, 0),
            child: Text('No tool matches "$query". Clear the search to see all ${toolEntries.length}.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          )
        else if (query.isNotEmpty)
          InsetGroup(header: '${found.length} of ${toolEntries.length} tools', rows: _rowsOf(found))
        else ...[
          InsetGroup(header: 'Look things up', rows: _rows(ToolGroup.network)),
          _radioGroup(context),
          InsetGroup(header: 'More tools', footer: 'Web pages that open inside the app. They need an internet connection.', rows: _rows(ToolGroup.site)),
        ],
      ],
    );
  }
}
