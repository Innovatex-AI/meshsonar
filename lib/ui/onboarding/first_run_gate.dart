// Shows the first-run intro once, then the app. Where the intro's buttons lead is decided here.
// Build 77 (round 5 O1, O2): the intro ends with "What MeshSonar collects" when the phone has not answered it; a radio
// connected from the intro (or the demo) lands on the Drive tab. The app still opens on Network otherwise (build 71).
import 'package:flutter/material.dart';

import '../app.dart';
import '../connect_screen.dart';
import 'illustrations.dart';
import 'onboarding_screen.dart';
import 'ui_prefs.dart';

class FirstRunGate extends StatefulWidget {
  /// Builds the app shell (it restores the last open tab itself).
  final Widget Function() builder;
  const FirstRunGate({super.key, required this.builder});
  @override
  State<FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends State<FirstRunGate> {
  Future<void> _finish(OnboardingExit exit) async {
    final s = AppScope.read(context);
    final prefs = uiPrefsFor(s);
    await prefs.markOnboardingSeen();
    if (!mounted) return;
    switch (exit) {
      case OnboardingExit.connectRadio:
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen()));
          if (mounted && s.connected) _toDrive();
        });
      case OnboardingExit.simulator:
        final ok = await s.connectSimulator();
        if (ok && mounted) _toDrive();
      case OnboardingExit.done:
        break;
    }
  }

  /// The shell is built after the intro closes: select the Drive tab once it is there.
  void _toDrive() {
    void go(int triesLeft) {
      final shell = ShellController.active;
      if (shell != null) {
        shell.openDrive();
      } else if (triesLeft > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => go(triesLeft - 1));
      }
    }

    go(3);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = uiPrefsFor(AppScope.of(context));
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        if (!prefs.loaded) return const ColoredBox(color: Brand.deep, child: SizedBox.expand());
        if (!prefs.onboardingSeen) return OnboardingScreen(onFinish: _finish, withDisclosure: !prefs.telemetryDisclosed);
        return widget.builder();
      },
    );
  }
}
