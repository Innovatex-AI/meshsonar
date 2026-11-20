// The app shell's navigation state: which of the five tabs is showing, which Network section, and the way for any
// screen (the mini drive bar, a deep link, another agent's chat code) to move between tabs.
//
// Tab API for other code:
//   ShellScope.maybeOf(context)?.select(AppTab.drive);  // go to a tab (no-op in isolated widget tests)
//   ShellScope.maybeOf(context)?.openDrive();           // the Drive tab
//   ShellScope.maybeOf(context)?.setImmersive(true);    // Drive only: hide the tab bar / rail (full-screen map)
//   ShellScope.maybeOf(context)?.openNetwork(NetworkRequest.packet(hash)); // the Network tab at a section (see NetworkRequest)
//   ShellScope.maybeOf(context)?.openChatRadio();      // Chat > Radio (the radio's own repeaters, rooms and tools)
//   ShellScope.maybeOf(context)?.openMore(MoreItem.settings);
//   ShellScope.maybeOf(context)?.openPlan(PlanRequest.fromNode(...)); // the Plan tab, with something to plan (see PlanRequest)
import 'package:flutter/material.dart';

import '../../core/network_request.dart';
import '../design/app_symbols.dart';

export '../../core/network_request.dart' show NetworkRequest, NetworkSection;

/// The five top-level tabs, in display order. Persisted by [name] (never by index) so reordering stays safe.
enum AppTab {
  chat('Chat', AppSymbols.message, AppSymbols.messageFill),
  drive('Drive', AppSymbols.car, AppSymbols.carFill),
  /// The network analyzer (AZ-3.1, was "Analyze" until build 71): the viewed region's server data in five sections.
  network('Network', AppSymbols.globe, AppSymbols.globe),
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
enum MoreItem { drives, radio, myRadios, wardriving, notifications, settings, about, legend, privacy, howItWorks, repeaters, trace, discover, adverts, rxLog, noiseFloor, telemetry, radioSetup, observerJoin, method, devices, myReports, leaderboard, chat, observer }

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
        1 => const LegacyTab(AppTab.network, network: NetworkSection.now),
        2 => const LegacyTab(AppTab.more, more: MoreItem.drives),
        3 => const LegacyTab(AppTab.more, more: MoreItem.radio),
        4 => const LegacyTab(AppTab.more, more: MoreItem.settings),
        _ => const LegacyTab(AppTab.drive),
      };
}

class ShellController extends ChangeNotifier {
  AppTab _tab;
  NetworkSection _network;
  ShellController({AppTab initial = AppTab.drive, NetworkSection network = NetworkSection.now})
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
    // The live map belongs to Map (AZ-3.3); until it is built, a live-map link opens the live feed under Packets.
    _network = request.section == NetworkSection.map && request.mapPanel == 'live' ? NetworkSection.packets : request.section;
    final wasNetwork = _tab == AppTab.network;
    select(AppTab.network);
    if (wasNetwork) notifyListeners();
  }

  void setNetworkSection(NetworkSection s) {
    if (s == _network) return;
    _network = s;
    notifyListeners();
  }

  /// Chat tab, Radio segment (the radio's own repeaters, rooms, sensors and the radio tools; "Network" until build 71).
  bool _pendingChatRadio = false;
  bool takePendingChatRadio() {
    final v = _pendingChatRadio;
    _pendingChatRadio = false;
    return v;
  }

  void openChatRadio() {
    _pendingChatRadio = true;
    final wasChat = _tab == AppTab.chat;
    select(AppTab.chat);
    if (wasChat) notifyListeners();
  }

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
