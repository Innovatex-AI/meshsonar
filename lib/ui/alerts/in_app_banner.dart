// While MeshSonar is in front, an incoming message shows as a banner at the top of the app instead of an OS notification.
// Tap = open that conversation (AlertCoordinator.pendingOpen). Not shown for the conversation already on screen.
// Compact (48 pt), with an X and a swipe up to dismiss, and it takes no touches for its first 400 ms.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../alerts/alert_coordinator.dart';
import '../../alerts/alerts_runtime.dart';
import '../theme.dart';

/// The banner's height: a navigation header's, so it never covers more than the header it sits on.
const double kInAppBannerHeight = 48;

/// How long a new banner ignores touches (they go to whatever is underneath).
const Duration kInAppBannerArmDelay = Duration(milliseconds: 400);

class InAppBannerHost extends StatefulWidget {
  final Widget child;
  final Duration visibleFor;
  const InAppBannerHost({super.key, required this.child, this.visibleFor = const Duration(seconds: 4)});
  @override
  State<InAppBannerHost> createState() => _InAppBannerHostState();
}

class _InAppBannerHostState extends State<InAppBannerHost> {
  AlertCoordinator? _coord;
  StreamSubscription<InAppBanner>? _sub;
  InAppBanner? _banner;
  Timer? _timer;
  Timer? _armTimer;

  /// False for the first [kInAppBannerArmDelay] after a banner appears: it takes no touches yet.
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    AlertsHost.runtime.addListener(_rebind);
    _rebind();
  }

  void _rebind() {
    final c = AlertsHost.runtime.value?.coordinator;
    if (identical(c, _coord)) return;
    unawaited(_sub?.cancel());
    _coord = c;
    _sub = c?.banners.listen(_show);
  }

  void _show(InAppBanner b) {
    if (!mounted) return;
    setState(() {
      _banner = b;
      _armed = false;
    });
    _armTimer?.cancel();
    _armTimer = Timer(kInAppBannerArmDelay, () {
      if (mounted) setState(() => _armed = true);
    });
    _timer?.cancel();
    _timer = Timer(widget.visibleFor, () {
      if (mounted) setState(() => _banner = null);
    });
  }

  @override
  void dispose() {
    AlertsHost.runtime.removeListener(_rebind);
    unawaited(_sub?.cancel());
    _timer?.cancel();
    _armTimer?.cancel();
    super.dispose();
  }

  void _close() {
    _timer?.cancel();
    _armTimer?.cancel();
    if (mounted) setState(() => _banner = null);
  }

  @override
  Widget build(BuildContext context) {
    final b = _banner;
    final cs = Theme.of(context).colorScheme;
    final ink = cs.onInverseSurface;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (b != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.m, Gap.xs, Gap.m, 0),
                // For the first moments the banner lets touches through: a tap already on its way to the header or the
                // section strip underneath reaches that control instead of opening a chat (build 75 screen-tour bug).
                child: IgnorePointer(
                  ignoring: !_armed,
                  // Flick it up to put it away without opening the conversation (as iOS banners do).
                  child: Dismissible(
                    key: ValueKey('in-app-banner-swipe-${b.convKey}-${b.title}-${b.body}'),
                    direction: DismissDirection.up,
                    onDismissed: (_) => _close(),
                    child: MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.3,
                      child: Material(
                        key: const Key('in-app-banner'),
                        elevation: 6,
                        borderRadius: BorderRadius.circular(12),
                        color: cs.inverseSurface,
                        clipBehavior: Clip.antiAlias,
                        // Compact: one line of sender, one line of text, no taller than a navigation header.
                        child: SizedBox(
                          height: kInAppBannerHeight,
                          child: Row(children: [
                            Expanded(
                              child: Semantics(
                                button: true,
                                hint: 'Opens the conversation',
                                child: InkWell(
                                  key: const Key('in-app-banner-open'),
                                  onTap: () {
                                    _coord?.pendingOpen.value = b.convKey;
                                    _close();
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: Gap.m),
                                    child: Row(children: [
                                      Icon(Icons.chat_bubble_rounded, size: 20, color: ink),
                                      const SizedBox(width: Gap.m),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, height: 1.2, fontWeight: FontWeight.w700, color: ink)),
                                            Text(b.body, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, height: 1.2, color: ink)),
                                          ],
                                        ),
                                      ),
                                    ]),
                                  ),
                                ),
                              ),
                            ),
                            // A clear way to put it away that is not "open the chat".
                            Semantics(
                              button: true,
                              label: 'Dismiss',
                              excludeSemantics: true,
                              child: InkWell(
                                key: const Key('in-app-banner-close'),
                                onTap: _close,
                                child: SizedBox(width: kInAppBannerHeight, height: kInAppBannerHeight, child: Icon(Icons.close_rounded, size: 20, color: ink)),
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
