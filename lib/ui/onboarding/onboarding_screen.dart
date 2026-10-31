// First-run intro: three short pages, skippable, shown once.
import 'package:flutter/material.dart';

import '../../app/build_flags.dart';
import 'illustrations.dart';

/// What the person chose on the last pages, so the app can take them there.
enum OnboardingExit { done, connectRadio, simulator }

class OnboardingScreen extends StatefulWidget {
  final ValueChanged<OnboardingExit> onFinish;
  const OnboardingScreen({super.key, required this.onFinish});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  static const _count = 3;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _count - 1) {
      widget.onFinish(OnboardingExit.done);
    } else {
      _pages.nextPage(duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final theme = base.copyWith(
      colorScheme: base.colorScheme.copyWith(primary: Brand.glow, onPrimary: Brand.deep),
      textTheme: base.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
    );
    return Theme(
      data: theme,
      child: Scaffold(
        key: const Key('onboarding'),
        backgroundColor: Brand.deep,
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Brand.teal, Brand.deep],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const Key('onboarding-skip'),
                    onPressed: () => widget.onFinish(OnboardingExit.done),
                    style: TextButton.styleFrom(foregroundColor: Colors.white70),
                    child: const Text('Skip', style: TextStyle(fontSize: 16)),
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pages,
                    onPageChanged: (i) => setState(() => _page = i),
                    children: [
                      _Page(
                        key: const Key('onboarding-page-1'),
                        art: const SonarIllustration(),
                        title: 'Map your mesh by driving it',
                        body: 'MeshSonar pings your MeshCore channel as you drive and listens for the repeaters '
                            'that echo it. Every ping is saved with GPS — including the ones nobody heard — '
                            'so your community can see where coverage really is.',
                      ),
                      _Page(
                        key: const Key('onboarding-page-2'),
                        art: const RadioLinkIllustration(),
                        title: 'Connect your radio',
                        body: 'Pair your MeshCore companion radio over Bluetooth. MeshSonar needs a radio to send pings and hear '
                            'repeaters echo them.',
                        actions: [
                          FilledButton.icon(
                            key: const Key('onboarding-connect'),
                            onPressed: () => widget.onFinish(OnboardingExit.connectRadio),
                            icon: const Icon(Icons.bluetooth_searching),
                            label: const Text('Connect radio'),
                          ),
                          if (simulatorAvailable)
                          OutlinedButton.icon(
                            key: const Key('onboarding-simulator'),
                            style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
                            onPressed: () => widget.onFinish(OnboardingExit.simulator),
                            icon: const Icon(Icons.science),
                            label: const Text('Try the Simulator'),
                          ),
                        ],
                      ),
                      _Page(
                        key: const Key('onboarding-page-3'),
                        art: const KeyCloudIllustration(),
                        title: 'Nothing to sign up for',
                        body: 'MeshSonar sets up your driver key by itself. Drives are always saved on this phone and '
                            'upload to the MeshSonar coverage map automatically. Add a callsign any time in Settings.',
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: Row(
                    children: [
                      for (var i = 0; i < _count; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: const EdgeInsets.only(right: 8),
                          width: i == _page ? 26 : 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: i == _page ? Brand.glow : Colors.white24,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      const Spacer(),
                      FilledButton(
                        key: const Key('onboarding-next'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Brand.deep,
                          minimumSize: const Size(140, 52),
                        ),
                        onPressed: _next,
                        child: Text(_page == _count - 1 ? 'Get started' : 'Next'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  final Widget art;
  final String title;
  final String body;
  final List<Widget> actions;
  const _Page({super.key, required this.art, required this.title, required this.body, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(height: 210, child: Center(child: art)),
                  const SizedBox(height: 28),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                  const SizedBox(height: 14),
                  Text(body,
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyLarge?.copyWith(color: Colors.white.withValues(alpha: 0.82), height: 1.45)),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    for (final a in actions) Padding(padding: const EdgeInsets.only(bottom: 10), child: SizedBox(width: 280, child: a)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
