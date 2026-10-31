// First-run intro: three short pages, skippable, shown once.
import 'package:flutter/material.dart';

import '../../app/build_flags.dart';
import '../shell/shell_controller.dart' show AppTab;
import 'illustrations.dart';

/// What the person chose on the last pages, so the app can take them there.
enum OnboardingExit { done, connectRadio, simulator }

class OnboardingScreen extends StatefulWidget {
  final ValueChanged<OnboardingExit> onFinish;

  /// Reopened from More > How it works: skip/finish just closes it, and the connect and simulator buttons are left out.
  final bool replay;
  const OnboardingScreen({super.key, required this.onFinish, this.replay = false});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;
  static const _count = 4;

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
                    style: TextButton.styleFrom(foregroundColor: Colors.white70, minimumSize: const Size(64, 48)),
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
                        title: 'Your MeshCore radio, in one app',
                        body: 'Use one radio to map where your mesh really reaches, plan where to build next, and '
                            'check what you built. MeshSonar pings your channel as you drive and listens for the '
                            'repeaters that echo it. Every ping is saved with GPS, including the ones nobody heard.',
                      ),
                      _Page(
                        key: const Key('onboarding-page-tabs'),
                        art: const _TabsArt(),
                        title: 'Find your way around',
                        body: 'Chat: contacts and channels, once your radio is connected.\n'
                            'Map: the coverage map. Start a drive here.\n'
                            'Analyze: your region and your drives.\n'
                            'Plan: tools for deciding where to build.\n'
                            'More: your radio, settings, privacy and this tour.',
                      ),
                      _Page(
                        key: const Key('onboarding-page-2'),
                        art: const RadioLinkIllustration(),
                        title: 'Connect your radio',
                        body: 'Pair your MeshCore companion radio over Bluetooth. MeshSonar needs a radio to send pings and hear '
                            'repeaters echo them. Your phone asks for Bluetooth permission the first time.',
                        actions: widget.replay
                            ? const []
                            : [
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
                            'upload to the MeshSonar coverage map automatically. When you start a drive your phone asks for Location, '
                            'so each ping can be placed on the map. Add a callsign any time in Settings.',
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: Row(
                    children: [
                      for (var i = 0; i < _count; i++)
                        Semantics(
                          label: 'Page ${i + 1} of $_count${i == _page ? ', current' : ''}',
                          child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: const EdgeInsets.only(right: 8),
                          width: i == _page ? 26 : 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: i == _page ? Brand.glow : Colors.white24,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        )),
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

/// The five tab icons in a row: art for the "find your way around" page.
class _TabsArt extends StatelessWidget {
  const _TabsArt();
  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final t in AppTab.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(16)),
                  child: Icon(t.selectedIcon, color: Brand.glow, size: 26),
                ),
                const SizedBox(height: 6),
                Text(t.label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ]),
            ),
        ],
      );
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
                  SizedBox(height: 210, child: ExcludeSemantics(child: Center(child: art))),
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
