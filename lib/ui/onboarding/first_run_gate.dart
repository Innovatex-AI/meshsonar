// Shows the first-run intro once, then the app. Where the intro's buttons lead is decided here.
import 'package:flutter/material.dart';

import '../app.dart';
import '../connect_screen.dart';
import 'illustrations.dart';
import 'onboarding_screen.dart';
import 'ui_prefs.dart';

class FirstRunGate extends StatefulWidget {
  /// Builds the app shell; [initialTab] is 0 Drive, 1 Region, 2 Drives, 3 Radio, 4 Settings.
  final Widget Function(int initialTab) builder;
  const FirstRunGate({super.key, required this.builder});
  @override
  State<FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends State<FirstRunGate> {
  int _tab = 0;

  Future<void> _finish(OnboardingExit exit) async {
    final s = AppScope.read(context);
    final prefs = uiPrefsFor(s);
    setState(() => _tab = exit == OnboardingExit.driverKey ? 4 : 0);
    await prefs.markOnboardingSeen();
    if (!mounted) return;
    switch (exit) {
      case OnboardingExit.connectRadio:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen()));
        });
      case OnboardingExit.simulator:
        await s.connectSimulator();
      case OnboardingExit.done:
      case OnboardingExit.driverKey:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = uiPrefsFor(AppScope.of(context));
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        if (!prefs.loaded) return const ColoredBox(color: Brand.deep, child: SizedBox.expand());
        if (!prefs.onboardingSeen) return OnboardingScreen(onFinish: _finish);
        return widget.builder(_tab);
      },
    );
  }
}
