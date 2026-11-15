// The Plan tab (release 0.38): its root is the Planner (lib/ui/plan/planner_screen.dart), a full-screen map with the
// planner sheet and the mode chips Link · Coverage · Find sites · Where to drive. The old tool list (Point-to-point link,
// Coverage painter, the Where-to-drive card on its own) is gone: Link and Coverage are planner modes on the one Plan, and
// Where to drive is the fourth mode.
//
// Requests from anywhere in the app (ShellController.openPlan: a shared plan link, Plan from here, Add to plan, Link to…,
// a point, a saved plan) are taken here with takePendingPlan when the tab is shown, and handed to the planner.
import 'package:flutter/material.dart';

import '../plan/planner_screen.dart';
import 'shell_controller.dart';

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribes to the shell: every openPlan (also while this tab is already showing) lands here.
    final shell = ShellScope.maybeOf(context);
    final r = shell?.takePendingPlan();
    if (r == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _planner.currentState?.handle(r));
  }

  @override
  Widget build(BuildContext context) => PlannerScreen(key: _planner);
}
