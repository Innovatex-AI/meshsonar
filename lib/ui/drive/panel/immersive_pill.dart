// Idle Immersive (Drive plan 4.6, 4.15, R10): the panel and tab bar are hidden; what remains is a 56 pt labelled capsule (the Dock's words: Start drive / Connect radio / Connecting…) at the
// Ping position with a small nub above it. Tap the nub or drag up from the pill to bring the Dock back. The control column and the
// attribution stay where they are. On iPad and in landscape the card collapses to the same pill.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../app/app_state.dart';
import '../../design/tokens.dart';
import '../drive_controls.dart' show openConnect;
import '../radio_link_status.dart';
import 'drive_panel_controller.dart';
import 'panel_physics.dart' show PanelDetent;

class ImmersivePill extends StatelessWidget {
  final AppState state;
  final DrivePanelController controller;
  const ImmersivePill({super.key, required this.state, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: RadioLinkStatus.listenable(state), builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final s = state;
    final c = AppColors.fromTheme(Theme.of(context));
    final link = RadioLinkStatus.of(s);
    final canStart = !s.busy && !s.connecting && !(s.connected && (s.needsAntennaSetup || s.locationNote != null));
    // Same words and glyphs as the Dock (RadioLinkStatus): "Connect radio", "Connecting…", "Reconnecting…", "Start drive".
    final label = link.label;
    final enabled = link.working ? false : (canStart || !s.connected);
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
              enabled: enabled,
              label: label,
              excludeSemantics: true,
              onTap: enabled ? () => _start(context) : null,
              child: GestureDetector(
                key: const Key('pill-start'),
                behavior: HitTestBehavior.opaque,
                onTap: enabled ? () => _start(context) : null,
                // A labelled capsule, never a lone glyph: the person sees the same words as in the Dock.
                child: Container(
                  height: 56,
                  constraints: const BoxConstraints(minWidth: 56),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(color: enabled ? c.accent : c.outline, borderRadius: BorderRadius.circular(28), boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))]),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (s.connected) Icon(Icons.play_arrow_rounded, size: 24, color: c.onAccent) else link.leading(context, size: 22, color: c.onAccent),
                      const SizedBox(width: 8),
                      Text(label, maxLines: 1, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: c.onAccent)),
                    ],
                  ),
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
