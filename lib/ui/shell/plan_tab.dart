// The Plan tab (release 0.38): its root is the Planner (lib/ui/plan/planner_screen.dart), a full-screen map with the
// planner sheet and the mode chips Link · Coverage · Find sites · Where to drive. The old tool list (Point-to-point link,
// Coverage painter, the Where-to-drive card on its own) is gone: Link and Coverage are planner modes on the one Plan, and
// Where to drive is the fourth mode.
//
// Requests from anywhere in the app (ShellController.openPlan: a shared plan link, Plan from here, Add to plan, Link to…,
// a point, a saved plan) are taken here with takePendingPlan when the tab is shown, and handed to the planner.
//
// Build 77 (round 4 P-U1): any tab can open a mode directly with [openPlanMode], e.g. the Drive panel's "Where to drive
// next" row: `openPlanMode(context, PlanModeId.whereToDrive)`. It waits here until the planner takes it, whether or not
// the Plan tab was built before.
import 'package:flutter/material.dart';

import '../plan/plan_modes.dart' show PlanModeId;
import '../plan/planner_screen.dart';
import 'shell_controller.dart';

export '../plan/plan_modes.dart' show PlanModeId;

/// The mode another tab asked the Plan tab to open, until the Plan tab takes it.
final ValueNotifier<PlanModeId?> _pendingPlanMode = ValueNotifier<PlanModeId?>(null);

@visibleForTesting
PlanModeId? get pendingPlanModeForTest => _pendingPlanMode.value;

/// Opens the Plan tab at [mode] (Link, Coverage, Find sites or Where to drive), one tap from anywhere. Sheets and screens
/// above the tabs close first. In an isolated widget test without a shell the request still waits for the Plan tab.
void openPlanMode(BuildContext context, PlanModeId mode) {
  _pendingPlanMode.value = mode;
  final shell = ShellController.of(context);
  if (shell == null) return;
  Navigator.maybeOf(context, rootNavigator: true)?.popUntil((r) => r.isFirst);
  // Not select() on the Plan tab itself: a second select is a re-tap, which puts the sheet down.
  if (shell.tab != AppTab.plan) shell.select(AppTab.plan);
}

/// A page on the region's website (or meshsonar.com when the base is not a URL).
Uri planToolUri(String base, String path) {
  final b = Uri.tryParse(base);
  return (b == null || !b.hasScheme) ? Uri.parse('https://meshsonar.com$path') : b.replace(path: path, query: '');
}

class PlanTab extends StatefulWidget {
  const PlanTab({super.key});

  @override
  State<PlanTab> createState() => _PlanTabState();
}

class _PlanTabState extends State<PlanTab> {
  final GlobalKey<PlannerScreenState> _planner = GlobalKey<PlannerScreenState>();

  int _seenReselect = 0;
  ShellController? _shell;

  @override
  void initState() {
    super.initState();
    _pendingPlanMode.addListener(_takeMode);
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeMode());
  }

  @override
  void dispose() {
    _pendingPlanMode.removeListener(_takeMode);
    super.dispose();
  }

  void _takeMode() {
    final m = _pendingPlanMode.value;
    final planner = _planner.currentState;
    if (m == null || planner == null || !mounted) return;
    _pendingPlanMode.value = null;
    planner.openMode(m);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribes to the shell: every openPlan (also while this tab is already showing) lands here.
    final shell = ShellScope.maybeOf(context);
    if (!identical(shell, _shell)) {
      _shell = shell;
      _seenReselect = shell?.reselectCount ?? 0;
    }
    // Tapping the Plan tab again puts the sheet down, so the whole map shows (build 76; More and Chat go back to
    // their lists the same way).
    if (shell != null && shell.reselectCount != _seenReselect) {
      _seenReselect = shell.reselectCount;
      if (shell.tab == AppTab.plan) WidgetsBinding.instance.addPostFrameCallback((_) => _planner.currentState?.collapseSheet());
    }
    final r = shell?.takePendingPlan();
    if (r == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _planner.currentState?.handle(r));
  }

  @override
  Widget build(BuildContext context) => PlannerScreen(key: _planner);
}
