// First-run intro: four short pages, skippable, shown once. Build 76: the radio page is second (one tap to Connect),
// every page is two short sentences, and the tabs page is a list.
// Build 77 (redesign round 5 O1, O3, O4): on a first run "What MeshSonar collects" is the last page and is answered before
// the intro closes; Connect radio, Try a demo, Skip and Get started all lead to it, and the intro then closes the way the
// person chose. The status bar is light on the dark intro in both themes. Page 2's button says Next.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/build_flags.dart';
import '../shell/shell_controller.dart' show AppTab;
import '../telemetry_sheet.dart' show CollectionDisclosure;
import 'illustrations.dart';

/// What the person chose on the last pages, so the app can take them there.
enum OnboardingExit { done, connectRadio, simulator }

class OnboardingScreen extends StatefulWidget {
  final ValueChanged<OnboardingExit> onFinish;

  /// Reopened from More > How it works: skip/finish just closes it, and the connect and simulator buttons are left out.
  final bool replay;

  /// End with the "What MeshSonar collects" page (a first run on a phone that has not answered it). Never on a replay.
  final bool withDisclosure;
  const OnboardingScreen({super.key, required this.onFinish, this.replay = false, this.withDisclosure = false});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  int _page = 0;

  /// Where the intro leads once the disclosure page is answered.
  OnboardingExit _exit = OnboardingExit.done;

  bool get _disclose => widget.withDisclosure && !widget.replay;
  int get _count => _disclose ? 5 : 4;

  /// The disclosure page's index (when there is one).
  int get _disclosurePage => 4;
  bool get _onDisclosure => _disclose && _page == _disclosurePage;

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

  /// Connect radio, Try a demo and Skip: straight out, or first to the disclosure page, then out that way.
  void _leave(OnboardingExit exit) {
    if (!_disclose) {
      widget.onFinish(exit);
      return;
    }
    _exit = exit;
    _pages.animateToPage(_disclosurePage, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final theme = base.copyWith(
      colorScheme: base.colorScheme.copyWith(primary: Brand.glow, onPrimary: Brand.deep),
      textTheme: base.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
    );
    // Light clock and status icons on the dark teal, also in the light theme (round 5 O3).
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
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
                  // The disclosure page is answered with its own two buttons; nothing skips it.
                  child: _onDisclosure
                      ? const SizedBox(height: 48)
                      : TextButton(
                          key: const Key('onboarding-skip'),
                          onPressed: () => _leave(OnboardingExit.done),
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
                        title: 'Map where your mesh reaches',
                        body: 'Drive with your MeshCore radio. MeshSonar sends a ping, listens for the repeaters that '
                            'answer, and colours the map with what it heard.',
                      ),
                      // Second, not third (build 76): one tap from the first page to a connected radio.
                      _Page(
                        key: const Key('onboarding-page-2'),
                        art: const RadioLinkIllustration(),
                        title: 'Connect your radio',
                        body: widget.replay
                            ? 'MeshSonar talks to your radio over Bluetooth. Connect it from the Drive tab.'
                            : 'Turn your radio on and keep it close. Your phone asks to use Bluetooth: tap Allow.',
                        actions: widget.replay
                            ? const []
                            : [
                          FilledButton.icon(
                            key: const Key('onboarding-connect'),
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                            onPressed: () => _leave(OnboardingExit.connectRadio),
                            icon: const Icon(Icons.bluetooth_searching),
                            label: const Text('Connect radio'),
                          ),
                          if (simulatorAvailable)
                          OutlinedButton.icon(
                            key: const Key('onboarding-simulator'),
                            style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
                            onPressed: () => _leave(OnboardingExit.simulator),
                            icon: const Icon(Icons.science),
                            label: const Text('No radio? Try a demo'),
                          ),
                        ],
                      ),
                      const _Page(
                        key: Key('onboarding-page-tabs'),
                        art: SizedBox.shrink(),
                        artHeight: 0,
                        title: 'Find your way around',
                        body: '',
                        below: _TabsList(),
                      ),
                      const _Page(
                        key: Key('onboarding-page-3'),
                        art: KeyCloudIllustration(),
                        title: 'Nothing to sign up for',
                        body: 'No account, no password. Your drives are saved on this phone and added to the shared '
                            'coverage map. Your phone asks for Location when you start your first drive.',
                      ),
                      if (_disclose)
                        Padding(
                          key: const Key('onboarding-page-collects'),
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                          child: Theme(
                            data: base,
                            child: Material(
                              color: base.colorScheme.surface,
                              borderRadius: BorderRadius.circular(20),
                              clipBehavior: Clip.antiAlias,
                              child: CollectionDisclosure(onDone: () => widget.onFinish(_exit)),
                            ),
                          ),
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
                      // The button takes the room the dots leave: at large text on a narrow phone its label shrinks to
                      // fit, it never overflows the row.
                      Expanded(
                        child: Align(
                        alignment: Alignment.centerRight,
                        child: _onDisclosure ? const SizedBox(height: 52) : FilledButton(
                        key: const Key('onboarding-next'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Brand.deep,
                          minimumSize: const Size(140, 52),
                        ),
                        onPressed: _next,
                        // "Next" on page 2 too (it said "Later", which read as leaving; Skip is there for that).
                        child: FittedBox(fit: BoxFit.scaleDown, child: Text(_page == _count - 1 ? 'Get started' : 'Next')),
                      ))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    );
  }
}

/// What each of the five tabs is for: its icon, its name and one short line (build 76: a list that reads at a glance,
/// in place of an icon strip over a centred paragraph).
class _TabsList extends StatelessWidget {
  const _TabsList();

  static String _what(AppTab t) => switch (t) {
        AppTab.network => 'The mesh around you, live',
        AppTab.drive => 'Record a drive and see coverage',
        AppTab.chat => 'Messages through your radio',
        AppTab.plan => 'Work out where to build next',
        AppTab.more => 'Your radio, drives, settings, help',
      };

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in AppTab.values)
            MergeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(14)),
                    child: IconTheme(data: const IconThemeData(color: Brand.glow, size: 24), child: t.iconWidget(selected: true)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.label, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                      Text(_what(t), style: TextStyle(color: Colors.white.withValues(alpha: 0.82), fontSize: 15)),
                    ]),
                  ),
                ]),
              ),
            ),
        ],
      );
}

class _Page extends StatelessWidget {
  final Widget art;
  final String title;
  final String body;
  final List<Widget> actions;

  /// Shown under the title in place of a paragraph (the tab list).
  final Widget? below;
  final double artHeight;
  const _Page({super.key, required this.art, required this.title, required this.body, this.actions = const [], this.below, this.artHeight = 210});

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
                  if (artHeight > 0) ...[
                    SizedBox(height: artHeight, child: ExcludeSemantics(child: Center(child: art))),
                    const SizedBox(height: 28),
                  ],
                  Text(title,
                      textAlign: TextAlign.center,
                      style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                  const SizedBox(height: 14),
                  if (body.isNotEmpty)
                    Text(body,
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodyLarge?.copyWith(color: Colors.white.withValues(alpha: 0.82), height: 1.45)),
                  ?below,
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    // Full width (to 360): a thumb reaches them at either edge.
                    for (final a in actions)
                      Padding(padding: const EdgeInsets.only(bottom: 10), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: SizedBox(width: double.infinity, child: a))),
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
