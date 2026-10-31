// The app shell's navigation state: which of the five tabs is showing, which Analyze view, and the way for any
// screen (the mini drive bar, a deep link, another agent's chat code) to move between tabs.
//
// Tab API for other code:
//   ShellScope.maybeOf(context)?.select(AppTab.map);   // go to a tab (no-op in isolated widget tests)
//   ShellScope.maybeOf(context)?.openDrive();          // the Map tab, in Drive mode
//   ShellScope.maybeOf(context)?.openAnalyze(AnalyzeView.drives);
//   ShellScope.maybeOf(context)?.openMore(MoreItem.settings);
import 'package:flutter/material.dart';

/// The five top-level tabs, in display order. Persisted by [name] (never by index) so reordering stays safe.
enum AppTab {
  chat('Chat', Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded),
  map('Map', Icons.map_outlined, Icons.map_rounded),
  analyze('Analyze', Icons.insights_outlined, Icons.insights_rounded),
  plan('Plan', Icons.edit_road_outlined, Icons.edit_road_rounded),
  more('More', Icons.more_horiz_rounded, Icons.more_horiz_rounded);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  const AppTab(this.label, this.icon, this.selectedIcon);

  static AppTab? byName(String? name) {
    for (final t in AppTab.values) {
      if (t.name == name) return t;
    }
    return null;
  }
}

/// What the Analyze tab shows: the viewed region's website data, or this phone's drives and reports.
enum AnalyzeView { region, drives }

/// Rows on the More tab that other code can open directly.
enum MoreItem { radio, myRadios, settings, about, legend, privacy, howItWorks }

/// Where the pre-0.25 five tabs (0 Drive, 1 Region, 2 Drives, 3 Radio, 4 Settings) live now.
class LegacyTab {
  final AppTab tab;
  final AnalyzeView? analyze;
  final MoreItem? more;
  const LegacyTab(this.tab, {this.analyze, this.more});

  /// Maps an old tab index. Anything unknown opens the Map tab.
  factory LegacyTab.fromIndex(int i) => switch (i) {
        1 => const LegacyTab(AppTab.analyze, analyze: AnalyzeView.region),
        2 => const LegacyTab(AppTab.analyze, analyze: AnalyzeView.drives),
        3 => const LegacyTab(AppTab.more, more: MoreItem.radio),
        4 => const LegacyTab(AppTab.more, more: MoreItem.settings),
        _ => const LegacyTab(AppTab.map),
      };
}

class ShellController extends ChangeNotifier {
  AppTab _tab;
  AnalyzeView _analyze;
  ShellController({AppTab initial = AppTab.map, AnalyzeView analyze = AnalyzeView.region})
      : _tab = initial,
        // ignore: prefer_initializing_formals
        _analyze = analyze;

  AppTab get tab => _tab;
  AnalyzeView get analyzeView => _analyze;

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
    notifyListeners();
  }

  int _reselect = 0;

  /// Increments each time the already-selected tab is tapped again (a tab uses it to pop back to its root).
  int get reselectCount => _reselect;

  /// The Map tab, which is where a drive runs and where the mini drive bar leads.
  void openDrive() => select(AppTab.map);

  void openAnalyze(AnalyzeView v) {
    _analyze = v;
    select(AppTab.analyze);
    notifyListeners();
  }

  void openMore(MoreItem item) {
    _pendingMore = item;
    final wasMore = _tab == AppTab.more;
    select(AppTab.more);
    if (wasMore) notifyListeners();
  }

  void setAnalyzeView(AnalyzeView v) {
    if (v == _analyze) return;
    _analyze = v;
    notifyListeners();
  }

  void openLegacy(LegacyTab l) {
    if (l.analyze != null) _analyze = l.analyze!;
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
