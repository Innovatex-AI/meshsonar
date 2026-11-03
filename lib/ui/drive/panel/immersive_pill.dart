// Idle Immersive (Drive plan 4.6, 4.15, R10): the panel and tab bar are hidden; what remains is a 56 pt circular Start button at the
// Ping position with a small nub above it. Tap the nub or drag up from the pill to bring the Dock back. The control column and the
// attribution stay where they are. On iPad and in landscape the card collapses to the same pill.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../app/app_state.dart';
import '../../design/tokens.dart';
import '../drive_controls.dart' show openConnect;
import 'drive_panel_controller.dart';
import 'panel_physics.dart' show PanelDetent;

class ImmersivePill extends StatelessWidget {
  final AppState state;
  final DrivePanelController controller;
  const ImmersivePill({super.key, required this.state, required this.controller});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final c = AppColors.fromTheme(Theme.of(context));
    final canStart = !s.busy && !s.connecting && !(s.connected && (s.needsAntennaSetup || s.locationNote != null));
    final label = s.connected ? 'Start drive' : 'Connect radio';
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Drive controls hidden',
      customSemanticsActions: {const CustomSemanticsAction(label: 'Show controls'): () => controller.settleTo(PanelDetent.dock)},
      child: GestureDetector(
        key: const Key('immersive-pill'),
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (_) => controller.dragStart(),
        onVerticalDragUpdate: (d) => controller.dragUpdate(d.delta.dy),
        onVerticalDragEnd: (d) => controller.dragEnd(d.velocity.pixelsPerSecond.dy),
        onVerticalDragCancel: controller.dragCancel,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              key: const Key('pill-nub'),
              behavior: HitTestBehavior.opaque,
              onTap: () => controller.settleTo(PanelDetent.dock),
              child: SizedBox(width: 64, height: 24, child: Center(child: Container(width: 36, height: 5, decoration: BoxDecoration(color: c.textMuted.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(3))))),
            ),
            Semantics(
              button: true,
              enabled: canStart || !s.connected,
              label: label,
              excludeSemantics: true,
              onTap: canStart || !s.connected ? () => _start(context) : null,
              child: GestureDetector(
                key: const Key('pill-start'),
                behavior: HitTestBehavior.opaque,
                onTap: canStart || !s.connected ? () => _start(context) : null,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(color: canStart || !s.connected ? c.accent : c.outline, shape: BoxShape.circle, boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))]),
                  child: Icon(s.connected ? Icons.play_arrow_rounded : Icons.bluetooth_searching_rounded, size: 28, color: c.onAccent),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _start(BuildContext context) {
    if (!state.connected) {
      openConnect(context);
    } else {
      state.startDrive();
    }
  }
}
