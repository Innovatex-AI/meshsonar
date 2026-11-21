// The app shell's navigation state: which of the five tabs is showing, which Network section (and "All regions"), and the way for any
// screen (the mini drive bar, a deep link, another agent's chat code) to move between tabs.
//
// Tab API for other code:
//   ShellScope.maybeOf(context)?.select(AppTab.drive);  // go to a tab (no-op in isolated widget tests)
//   ShellScope.maybeOf(context)?.openDrive();           // the Drive tab
//   ShellScope.maybeOf(context)?.setImmersive(true);    // Drive only: hide the tab bar / rail (full-screen map)
//   ShellScope.maybeOf(context)?.openNetwork(NetworkRequest.packet(hash)); // the Network tab at a section (see NetworkRequest)
//   ShellScope.maybeOf(context)?.openMore(MoreItem.radio); // More > Radio (the radio's own repeaters, rooms and tools)
//   ShellScope.maybeOf(context)?.openMore(MoreItem.settings);
//   ShellScope.maybeOf(context)?.openPlan(PlanRequest.fromNode(...)); // the Plan tab, with something to plan (see PlanRequest)
import 'package:flutter/material.dart';

import '../../core/network_request.dart';
import '../design/app_symbols.dart';

export '../../core/network_request.dart' show NetworkRequest, NetworkSection;

/// The five top-level tabs, in display order (build 71: Network | Drive | Chat | Plan | More). Persisted by [name]
/// (never by index), so the reorder keeps a tab saved by an older build.
enum AppTab {
  /// The network analyzer (AZ-3.1, was "Analyze" until build 71): the site in the app, eight sections. First since
  /// build 71: the app is a gateway to the site data, and a fresh install opens here.
  network('Network', AppSymbols.globe, AppSymbols.globe),
  drive('Drive', AppSymbols.car, AppSymbols.carFill),
  chat('Chat', AppSymbols.message, AppSymbols.messageFill),
  plan('Plan', AppSymbols.map, AppSymbols.mapFill),
  more('More', AppSymbols.ellipsisCircle, AppSymbols.ellipsisCircle);

  final String label;

  /// The tab's symbol (Cupertino on Apple platforms, Material elsewhere: [AppSymbolIcon]) and its selected form.
  final AppSymbol symbol;
  final AppSymbol selectedSymbol;
  const AppTab(this.label, this.symbol, this.selectedSymbol);

  /// The tab's icon as a widget.
  Widget iconWidget({required bool selected}) => AppSymbolIcon(selected ? selectedSymbol : symbol, size: 24);

  /// Looks a tab up by its persisted name. `'map'` is the pre-rename name of the Drive tab and `'analyze'` the
  /// pre-build-71 name of the Network tab; both still restore (UiPrefs.lastTab saved by older builds); new writes use
  /// `'drive'` and `'network'`.
  static AppTab? byName(String? name) {
    if (name == 'map') return AppTab.drive;
    if (name == 'analyze') return AppTab.network;
    for (final t in AppTab.values) {
      if (t.name == name) return t;
    }
    return null;
  }
}

/// Rows on the More tab that other code can open directly.
/// [observer] opens Settings at its Observer section (the Home observer row is gone, release 0.38).
/// [drives] is this phone's drives, reports and progress (moved here from the old Analyze tab, AZ-3.1).
/// Build 71: the More list shows about nine rows; the other values still open their screen (a Settings section, a
/// radio tool) for code that asks for them. [repeaters] and [radio] both open More > Radio; [help] the Help page.
enum MoreItem { drives, radio, myRadios, wardriving, notifications, settings, about, legend, privacy, howItWorks, repeaters, trace, discover, adverts, rxLog, noiseFloor, telemetry, radioSetup, observerJoin, method, devices, myReports, leaderboard, chat, observer, help, radioSettings }

/// What a request to open the Plan tab carries (release 0.38, Master Planner). The Plan tab takes it with
/// [ShellController.takePendingPlan] when it is shown.
enum PlanRequestKind {
  /// A shared plan link (universal link, pasted link): [PlanRequest.link].
  openLink,

  /// "Plan from here": a new plan starting at [PlanRequest.node] (coverage of that spot).
  planFrom,

  /// "Add to plan": [PlanRequest.node] joins the open plan.
  addNode,

  /// "Link to…": a link analysis with [PlanRequest.node] as one end; the person picks the other.
  linkTo,

  /// A point (a long-press, coordinates in a chat message): the planner opens with a pin at [PlanRequest.node].
  point,

  /// A saved plan by id: [PlanRequest.planId].
  openSaved,
}

/// The node or spot a plan request is about. [key] is the network node's public key (lower-case hex) when it is one;
/// null for a dropped pin or a coordinate. [source] says where it came from (`repeater`, `observer`, `contact`, `pin`,
/// `chat`, `suggestion`).
@immutable
class PlanNodeSeed {
  final String? key;
  final String name;
  final double lat, lon;
  final String source;
  const PlanNodeSeed({this.key, required this.name, required this.lat, required this.lon, required this.source});

  @override
  bool operator ==(Object other) =>
      other is PlanNodeSeed && other.key == key && other.name == name && other.lat == lat && other.lon == lon && other.source == source;
  @override
  int get hashCode => Object.hash(key, name, lat, lon, source);
}

@immutable
class PlanRequest {
  final PlanRequestKind kind;
  final Uri? link;
  final PlanNodeSeed? node;
  final String? planId;

  const PlanRequest.openLink(Uri this.link)
      : kind = PlanRequestKind.openLink,
        node = null,
        planId = null;
  const PlanRequest.planFrom(PlanNodeSeed this.node)
      : kind = PlanRequestKind.planFrom,
        link = null,
        planId = null;
  const PlanRequest.addNode(PlanNodeSeed this.node)
      : kind = PlanRequestKind.addNode,
        link = null,
        planId = null;
  const PlanRequest.linkTo(PlanNodeSeed this.node)
      : kind = PlanRequestKind.linkTo,
        link = null,
        planId = null;
  const PlanRequest.point(PlanNodeSeed this.node)
      : kind = PlanRequestKind.point,
        link = null,
        planId = null;
  const PlanRequest.openSaved(String this.planId)
      : kind = PlanRequestKind.openSaved,
        link = null,
        node = null;

  @override
  bool operator ==(Object other) => other is PlanRequest && other.kind == kind && other.link == link && other.node == node && other.planId == planId;
  @override
  int get hashCode => Object.hash(kind, link, node, planId);
  @override
  String toString() => 'PlanRequest(${kind.name})';
}

/// Where the pre-0.25 five tabs (0 Drive, 1 Region, 2 Drives, 3 Radio, 4 Settings) live now.
class LegacyTab {
  final AppTab tab;
  final NetworkSection? network;
  final MoreItem? more;
  const LegacyTab(this.tab, {this.network, this.more});

  /// Maps an old tab index. Anything unknown opens the Drive tab.
  factory LegacyTab.fromIndex(int i) => switch (i) {
        1 => const LegacyTab(AppTab.network, network: NetworkSection.home),
        2 => const LegacyTab(AppTab.more, more: MoreItem.drives),
        3 => const LegacyTab(AppTab.more, more: MoreItem.radio),
        4 => const LegacyTab(AppTab.more, more: MoreItem.settings),
        _ => const LegacyTab(AppTab.drive),
      };
}

class ShellController extends ChangeNotifier {
  /// The running shell, for pages pushed on the root navigator (above ShellScope), such as a packet detail opened from
  /// the Network tab. Set by HomeShell while it is mounted; null in tests that pump a single screen.
  static ShellController? active;

  /// The shell above [context], else the running one.
  static ShellController? of(BuildContext context) => ShellScope.maybeRead(context) ?? active;

  AppTab _tab;
  NetworkSection _network;
  ShellController({AppTab initial = AppTab.network, NetworkSection network = NetworkSection.home})
      : _tab = initial,
        // ignore: prefer_initializing_formals
        _network = network;

  AppTab get tab => _tab;

  bool _immersive = false;

  /// True while the Drive tab shows its full-screen map: the tab bar, the rail and the mini drive bar are hidden.
  /// Only meaningful on the Drive tab; leaving the tab clears it.
  bool get immersive => _immersive && _tab == AppTab.drive;

  void setImmersive(bool v) {
    if (v && _tab != AppTab.drive) return;
    if (v == _immersive) return;
    _immersive = v;
    notifyListeners();
  }

  /// The Network tab's section (kept while the person moves between tabs).
  NetworkSection get networkSection => _network;

  /// Bumped when something asks the More tab to open [pendingMore]; the More tab consumes it.
  MoreItem? _pendingMore;
  MoreItem? takePendingMore() {
    final m = _pendingMore;
    _pendingMore = null;
    return m;
  }

  /// Tabs the person has visited, so a tab's screen is only built once it is first shown.
  final Set<AppTab> visited = {};

  void select(AppTab t) {
    visited.add(t);
    if (t == _tab) {
      // Tapping the current tab again returns More to its list.
      _reselect++;
      notifyListeners();
      return;
    }
    _tab = t;
    _immersive = false;
    notifyListeners();
  }

  int _reselect = 0;

  /// Increments each time the already-selected tab is tapped again (a tab uses it to pop back to its root).
  int get reselectCount => _reselect;

  /// The Drive tab, which is where a drive runs and where the mini drive bar leads.
  void openDrive() => select(AppTab.drive);

  /// Network tab with something to show (a section, a node, a packet, a deep link): kept until the Network tab takes it
  /// ([takePendingNetwork]), like [openPlan]. A newer request replaces one not taken yet. The section switches at once.
  NetworkRequest? _pendingNetwork;
  NetworkRequest? get pendingNetwork => _pendingNetwork;
  NetworkRequest? takePendingNetwork() {
    final r = _pendingNetwork;
    _pendingNetwork = null;
    return r;
  }

  void openNetwork(NetworkRequest request) {
    _pendingNetwork = request;
    _network = request.section;
    // A request for a region, or for a section that needs one, leaves "All regions".
    if (request.region != null || !networkHubSections.contains(request.section)) _allRegions = false;
    final wasNetwork = _tab == AppTab.network;
    select(AppTab.network);
    if (wasNetwork) notifyListeners();
  }

  void setNetworkSection(NetworkSection s) {
    if (s == _network) return;
    _network = s;
    notifyListeners();
  }

  /// "All regions" (the region switcher's entry): the Network tab shows the whole network on the hub (summary, global
  /// search, busiest regions) with the sections that need no region. For the session only; picking a region ends it.
  bool _allRegions = false;
  bool get networkAllRegions => _allRegions;

  void setNetworkAllRegions(bool v) {
    if (v == _allRegions) return;
    _allRegions = v;
    if (v && !networkHubSections.contains(_network)) _network = NetworkSection.home;
    notifyListeners();
  }

  /// The Network tab in "All regions", from anywhere (the switcher sheet).
  void openNetworkAllRegions() {
    _pendingNetwork = null;
    _network = NetworkSection.home;
    _allRegions = true;
    final wasNetwork = _tab == AppTab.network;
    select(AppTab.network);
    if (wasNetwork) notifyListeners();
  }

  /// The radio's own repeaters, rooms, sensors and radio tools. They were the Chat tab's Radio segment until build 71
  /// and live at More > Radio now; this name is kept for callers written before the move.
  void openChatRadio() => openMore(MoreItem.radio);

  /// Plan tab with something to plan: kept until the Plan tab takes it ([takePendingPlan]), so it works whether that tab
  /// is already built or is built by this switch. A newer request replaces one not taken yet.
  PlanRequest? _pendingPlan;
  PlanRequest? get pendingPlan => _pendingPlan;
  PlanRequest? takePendingPlan() {
    final r = _pendingPlan;
    _pendingPlan = null;
    return r;
  }

  void openPlan(PlanRequest request) {
    _pendingPlan = request;
    final wasPlan = _tab == AppTab.plan;
    select(AppTab.plan);
    if (wasPlan) notifyListeners();
  }

  void openMore(MoreItem item) {
    _pendingMore = item;
    final wasMore = _tab == AppTab.more;
    select(AppTab.more);
    if (wasMore) notifyListeners();
  }

  void openLegacy(LegacyTab l) {
    if (l.network != null) _network = l.network!;
    if (l.more != null) {
      openMore(l.more!);
    } else {
      select(l.tab);
    }
  }
}

class ShellScope extends InheritedNotifier<ShellController> {
  const ShellScope({super.key, required ShellController controller, required super.child}) : super(notifier: controller);

  /// The shell controller (rebuilds on change); null in isolated widget tests that pump a single screen.
  static ShellController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellScope>()?.notifier;

  /// Without subscribing (for callbacks).
  static ShellController? maybeRead(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<ShellScope>()?.widget as ShellScope?)?.notifier;
}
