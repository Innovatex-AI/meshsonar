// Network > Tools (build 71, stream D). One list, three groups:
// - Network tools, native on `/v1`: Path Inspector, Trace Viewer, Prefix Tool, Decode a packet.
// - Site pages shown inside the app ([SitePageView]): Scope Audit, Compare observers, Region definition, Status, and the
//   site tools with no native twin (Airtime and load, Point-to-point link, Coverage painter).
// - Radio tools (lib/ui/tools): Trace path, Discover, Adverts, Rx log, Noise floor, Telemetry. They live here once; each
//   says so itself when no radio is connected. A radio trace's result opens in the native Trace Viewer.
// `initialTool` (from a `/tools/<id>` link) shows that tool in place inside the section with `initialArg`, under a back
// arrow to the list; an unknown id shows the list. A row tapped in the list opens the tool as its own page.
import 'package:flutter/material.dart';

import '../../radio/inset_list.dart';
import '../../tools/adverts_screen.dart';
import '../../tools/discover_screen.dart';
import '../../tools/noise_screen.dart';
import '../../tools/rx_log_screen.dart';
import '../../tools/telemetry_screen.dart';
import '../../tools/trace_screen.dart';
import '../analytics/in_place_header.dart';
import '../analytics/site_page_view.dart';
import '../packets/decode_packet_screen.dart';
import 'path_inspector_screen.dart';
import 'prefix_tool_screen.dart';
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
  ToolEntry('path', 'Path Inspector', 'Hop prefixes to the routes they most likely stand for', ToolGroup.network, aliases: ['path-inspector']),
  ToolEntry('trace', 'Trace Viewer', 'One trace: SNR at each hop and who heard it', ToolGroup.network, aliases: ['trace-viewer']),
  ToolEntry('prefix', 'Prefix Tool', 'Find a free hash prefix for a new repeater', ToolGroup.network, aliases: ['prefix-tool']),
  ToolEntry('decode', 'Decode a packet', 'Paste packet bytes and read every field', ToolGroup.network),
  ToolEntry('scope-audit', 'Scope Audit', 'Which repeaters carry which region scopes', ToolGroup.site),
  ToolEntry('compare', 'Compare observers', 'What two observers both hear, and what only one does', ToolGroup.site, aliases: ['observers-compare']),
  ToolEntry('definition', 'Region definition', 'The regions and scope names covering a point', ToolGroup.site, aliases: ['region', 'region-def']),
  ToolEntry('status', 'Status', 'Whether packets are arriving and the summaries are current', ToolGroup.site),
  // Site tools with no native twin here: the link parser passes `/tools/<name>` through with these ids.
  ToolEntry('airtime', 'Airtime and load', 'Time on air for a packet and how busy the channel is', ToolGroup.site),
  ToolEntry('link', 'Point-to-point link', 'Will two points hear each other: terrain and link budget', ToolGroup.site),
  ToolEntry('painter', 'Coverage painter', 'Estimated coverage from a site you pick', ToolGroup.site),
  ToolEntry('radio-trace', 'Trace path', 'Send a trace from your radio along a chain of repeaters', ToolGroup.radio, aliases: ['trace-path']),
  ToolEntry('discover', 'Discover', 'Ask nearby repeaters to answer your radio', ToolGroup.radio),
  ToolEntry('adverts', 'Adverts', 'Adverts your radio has heard', ToolGroup.radio),
  ToolEntry('rx-log', 'Rx log', 'Every packet your radio hears, live', ToolGroup.radio, aliases: ['rxlog', 'rx_log']),
  ToolEntry('noise', 'Noise floor', 'How quiet the channel is at your radio', ToolGroup.radio, aliases: ['noise-floor']),
  ToolEntry('telemetry', 'Telemetry', 'Battery and sensor readings from a node', ToolGroup.radio),
];

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
    'airtime' || 'link' || 'painter' => '/tools/$id',
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
  /// `compare`, `definition`, `status`, a site tool passed through (`airtime`, `link`, `painter`), or a radio tool (`radio-trace`, `discover`, `adverts`, `rx-log`, `noise`, `telemetry`); null or an
  /// unknown id shows the list.
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

  List<Widget> _rows(ToolGroup g) => [
        for (final e in toolEntries)
          if (e.group == g) InsetRow(key: Key('tool-row-${e.id}'), title: e.title, subtitle: e.about, onTap: () => _open(e)),
      ];

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown != null) {
      return KeyedSubtree(key: ValueKey('tools-in-place-${widget.baseUrl}-${shown.id}-$_shownArg'), child: _page(shown, _shownArg, onClose: _close));
    }
    return ListView(
      key: const Key('tools-section'),
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      children: [
        InsetGroup(header: 'Network tools', rows: _rows(ToolGroup.network)),
        InsetGroup(header: 'Site pages', footer: 'Website pages shown inside the app. They need a connection.', rows: _rows(ToolGroup.site)),
        InsetGroup(header: 'Radio tools', footer: 'These use your connected radio.', rows: _rows(ToolGroup.radio)),
      ],
    );
  }
}
