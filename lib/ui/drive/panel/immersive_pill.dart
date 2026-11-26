// Idle Immersive (Drive plan 4.6, 4.15, R10): the panel and tab bar are hidden; what remains is a 56 pt labelled capsule (the Dock's words: Start drive / Connect radio / Connecting…) at the
// Ping position with a small nub above it. Tap the nub or drag up from the pill to bring the Dock back. The control column and the
// attribution stay where they are. On iPad and in landscape the card collapses to the same pill.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../app/app_state.dart';
import '../../../core/startup_location.dart' show LocationAccess;
import '../../antenna_sheet.dart' show showAntennaSheet;
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
    // Approximate location still starts a drive, as on the Dock (the pill used to refuse it: build 76 fix).
    final locationBlocks = s.locationNote != null && s.locationAccess != LocationAccess.approximate;
    final canStart = !s.busy && !s.connecting && !(s.connected && (s.needsAntennaSetup || locationBlocks));
    // Same words and glyphs as the Dock (RadioLinkStatus): "Connect radio", "Connecting…", "Reconnecting…", "Start drive".
    // Build 76: when Start cannot run the pill says why and does the next step itself, instead of a grey "Start drive"
    // that did nothing: "Set antenna" opens the antenna sheet, "Location is off" brings the Dock back (its strip has the fix).
    final needAntenna = s.connected && !link.working && s.needsAntennaSetup;
    final needLocation = s.connected && !link.working && !needAntenna && locationBlocks;
    final label = needAntenna ? 'Set antenna' : (needLocation ? 'Location is off' : link.label);
    final enabled = link.working ? false : (canStart || !s.connected || needAntenna || needLocation);
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
              // A visible "bring the controls back" chevron on its own chip, 72 x 36 to hit (build 76; it was a faint 36 x 5 bar
              // that vanished on a busy map).
              child: SizedBox(
                width: 72,
                height: 36,
                child: Center(
                  child: Container(
                    width: 48,
                    height: 24,
                    decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.outline)),
                    child: Icon(Icons.keyboard_arrow_up_rounded, size: 22, color: c.textPrimary),
                  ),
                ),
              ),
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
                      if (needAntenna)
                        Icon(Icons.settings_input_antenna_rounded, size: 22, color: c.onAccent)
                      else if (needLocation)
                        Icon(Icons.location_off_rounded, size: 22, color: c.onAccent)
                      else if (s.connected)
                        Icon(Icons.play_arrow_rounded, size: 24, color: c.onAccent)
                      else
                        link.leading(context, size: 22, color: c.onAccent),
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
    } else if (state.needsAntennaSetup) {
      showAntennaSheet(context);
    } else if (state.locationNote != null && state.locationAccess != LocationAccess.approximate) {
      controller.settleTo(PanelDetent.dock);
    } else {
      state.startDrive();
    }
  }
}
