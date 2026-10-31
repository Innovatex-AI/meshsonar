// While MeshSonar is in front, an incoming message shows as a banner at the top of the app instead of an OS notification.
// Tap = open that conversation (AlertCoordinator.pendingOpen). Not shown for the conversation already on screen.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../alerts/alert_coordinator.dart';
import '../../alerts/alerts_runtime.dart';
import '../theme.dart';

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
    setState(() => _banner = b);
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = _banner;
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
                padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
                child: Material(
                  key: const Key('in-app-banner'),
                  elevation: 6,
                  borderRadius: BorderRadius.circular(12),
                  color: Theme.of(context).colorScheme.inverseSurface,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () {
                      _coord?.pendingOpen.value = b.convKey;
                      _timer?.cancel();
                      setState(() => _banner = null);
                    },
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
                        child: Row(
                          children: [
                            Icon(Icons.chat_bubble_rounded, color: Theme.of(context).colorScheme.onInverseSurface),
                            const SizedBox(width: Gap.m),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(b.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onInverseSurface)),
                                  Text(b.body,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: Theme.of(context).colorScheme.onInverseSurface)),
                                ],
                              ),
                            ),
                          ],
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
