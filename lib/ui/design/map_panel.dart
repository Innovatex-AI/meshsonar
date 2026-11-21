// MapPanel: the one panel that sits on a map (build 71 seam; stream B fills this in). Twin of the site's float-panel.
// Rules (meshsonar-infra docs/planning/app-build-71-gateway-plan.md): bottom-anchored above the tab bar; header always
// visible (grabber, title, one status, chevron); tap or drag the header to toggle; never modal; one open panel per map;
// starts collapsed on a phone; the open state is remembered per [id]; only the person moves it.
import 'package:flutter/material.dart';

/// Same state names on every map. [full] is only for work panels (Planner, Drive stats).
enum MapPanelState { collapsed, open, full }

class MapPanel extends StatelessWidget {
  /// Stable id; the remembered state is stored under it.
  final String id;
  final String title;

  /// One status or count of the panel's own content, shown in the header.
  final Widget? status;
  final Widget child;

  /// Work panels may go to [MapPanelState.full]; every other panel stops at open (at most 60 % of the height).
  final bool allowFull;
  const MapPanel({super.key, required this.id, required this.title, required this.child, this.status, this.allowFull = false});

  @override
  Widget build(BuildContext context) => child;
}
