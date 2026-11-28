// The drive bar under Layers and the Legend on the Drive tab (build 77, Round 1 F5). Those two sheets replace the Drive panel
// on a phone, so while a drive runs this bar takes the Dock's place under them: the shell's own mini drive bar (status,
// time driven, Stop with its usual confirm; lib/ui/shell/mini_drive_bar.dart) with the Dock's Ping button beside it. No third
// Stop surface is built: Stop is the mini bar's. Tapping the bar's body brings the Drive panel back ([onOpen]).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../shell/mini_drive_bar.dart';
import 'panel/panel_dock.dart' show PingCircle, PingDebounce;

/// Height of the bar: the mini drive bar's.
const double kSheetDriveBarHeight = miniDriveBarHeight;

class SheetDriveBar extends StatelessWidget {
  final AppState state;
  final PingDebounce debounce;

  /// The bar's body was tapped: close the sheet, the Drive panel comes back.
  final VoidCallback onOpen;

  /// A Ping tap that passed the debounce (tests inject a fake).
  final Future<void> Function()? onPing;
  const SheetDriveBar({super.key, required this.state, required this.debounce, required this.onOpen, this.onPing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ping = !state.settings.discoveryMode;
    return Material(
      key: const Key('sheet-drive-bar'),
      color: t.colorScheme.surfaceContainerHigh,
      child: SizedBox(
        height: kSheetDriveBarHeight,
        child: Row(
          children: [
            if (ping)
              // The Dock's Ping circle at the bar's height (56 pt, still a 56 x 56 target): same ring, same debounce.
              Padding(
                padding: EdgeInsets.only(left: 8 + MediaQuery.paddingOf(context).left),
                child: SizedBox(
                  width: kSheetDriveBarHeight,
                  height: kSheetDriveBarHeight,
                  child: FittedBox(child: PingCircle(state: state, debounce: debounce, onPing: onPing)),
                ),
              ),
            Expanded(child: MiniDriveBar(onOpen: onOpen)),
          ],
        ),
      ),
    );
  }
}
