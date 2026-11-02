// The four surface helpers (D46-D49, popup audit section 5). Every popup in the app goes through these:
//
//   showAppSheet        resizable bottom sheet (medium detent = custom route, large = showCupertinoSheet on Apple)
//   showAppAlert        rare, short, blocking confirmation (CupertinoAlertDialog on Apple, AlertDialog on Android)
//   showAppActionSheet  destructive choice or short choice list (CupertinoActionSheet on Apple)
//   showAppToast        non-blocking message; one visible at a time; bottom by default, top inside an [AppToastHost]
//                       that says so (the Drive tab)
//
// Apple platforms (iOS, macOS) get the Cupertino branch, everything else the Material branch. This file is one of the
// two places allowed to use Material dialogs / sheets / `Icons.` (the Android branch); test/lint/widget_ban_test.dart
// enforces that for the rest of lib/.
//
// Drive guard: a prompt the phone raised on its own (`userInitiated: false`) is queued while a drive is active and shown
// when it ends (drive_guard.dart). A prompt the person asked for is never held.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'app_haptics.dart';
import 'app_symbols.dart';
import 'drive_guard.dart';
import 'tokens.dart';

bool _apple(BuildContext context) {
  final p = Theme.of(context).platform;
  return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
}

// ------------------------------------------------------------------------------------------------ action model

/// One row of an action sheet.
class AppAction<T> {
  final String label;
  final T value;
  final bool destructive;
  final bool isDefault;
  final AppSymbol? symbol;
  final bool checked;
  final Key? key;
  const AppAction(this.label, this.value, {this.destructive = false, this.isDefault = false, this.symbol, this.checked = false, this.key});
}

// ------------------------------------------------------------------------------------------------ sheet

/// Resizable iOS-style sheet. Replaces `showModalBottomSheet` and the "form" AlertDialogs.
///
/// [builder] gets the sheet's [ScrollController]: attach it to the scrollable content so dragging the content hands off
/// to dragging the sheet (use [AppSheetScaffold] for a pinned title and footer). [detents] are fractions of the available
/// height, first = initial. A single detent of 0.9 or more on an Apple platform opens as a native stacked page sheet
/// (`showCupertinoSheet`); everything else uses the custom medium-detent route (spring, dim, velocity snap, keyboard
/// aware, drag-to-dismiss that yields to inner scroll). [modal] false = no barrier, the map behind stays interactive.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, ScrollController controller) builder,
  List<double> detents = const [0.45, 0.92],
  bool grabber = true,
  bool dismissible = true,
  bool modal = true,
  bool keyboardAware = true,
  bool useRootNavigator = true,
  bool userInitiated = true,
}) {
  assert(detents.isNotEmpty && detents.every((d) => d > 0 && d <= 1), 'detents are fractions in (0, 1]');
  final sorted = [...detents]..sort();
  return DriveGuard.instance.run<T>(
    () async {
      if (!context.mounted) return null;
      AppHaptics.light();
      final theme = Theme.of(context);
      final large = sorted.length == 1 && sorted.first >= 0.9 && modal && _apple(context);
      if (large) {
        return showCupertinoSheet<T>(
          context: context,
          enableDrag: dismissible,
          showDragHandle: grabber,
          scrollableBuilder: (ctx, controller) => Theme(
            data: theme,
            child: Material(color: theme.colorScheme.surface, child: builder(ctx, controller)),
          ),
        );
      }
      return Navigator.of(context, rootNavigator: useRootNavigator).push<T>(
        AppSheetRoute<T>(
          theme: theme,
          detents: sorted,
          grabber: grabber,
          dismissible: dismissible,
          modal: modal,
          keyboardAware: keyboardAware,
          builder: builder,
        ),
      );
    },
    userInitiated: userInitiated,
    stillValid: () => context.mounted,
  );
}

/// Header + scrolling body + pinned footer for sheet content, so every sheet looks the same.
class AppSheetScaffold extends StatelessWidget {
  final ScrollController controller;
  final String? title;
  final List<Widget> children;
  final Widget? primaryAction;
  final Widget? secondaryAction;
  final EdgeInsetsGeometry padding;
  const AppSheetScaffold({
    super.key,
    required this.controller,
    this.title,
    required this.children,
    this.primaryAction,
    this.secondaryAction,
    this.padding = const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Column(
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.xs, Layout.screenMargin, Gap.s),
            child: Semantics(header: true, child: Text(title!, style: t.textTheme.titleLarge, textAlign: TextAlign.center)),
          ),
        Expanded(
          child: ListView(controller: controller, padding: padding, children: children),
        ),
        if (primaryAction != null || secondaryAction != null)
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.colorScheme.outlineVariant))),
            padding: EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Layout.screenMargin, Gap.s + bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [?primaryAction, ?secondaryAction],
            ),
          ),
      ],
    );
  }
}

class _SpringCurve extends Curve {
  final SpringSimulation _sim;
  final double _seconds;
  _SpringCurve({double seconds = 0.3, double damping = Motion.sheetDamping})
    : _seconds = seconds,
      // settles in about [seconds]: omega = 4 / (zeta * seconds)
      _sim = SpringSimulation(
        SpringDescription.withDampingRatio(mass: 1, stiffness: _k(seconds, damping), ratio: damping),
        0,
        1,
        0,
      );
  static double _k(double seconds, double zeta) {
    final w = 4 / (zeta * seconds);
    return w * w;
  }

  @override
  double transformInternal(double t) => t >= 1 ? 1 : _sim.x(t * _seconds);
}

/// The custom medium-detent sheet route (spike S7 decision: custom for medium, `showCupertinoSheet` for large).
class AppSheetRoute<T> extends PopupRoute<T> {
  final ThemeData theme;
  final List<double> detents;
  final bool grabber, dismissible, modal, keyboardAware;
  final Widget Function(BuildContext, ScrollController) builder;

  AppSheetRoute({
    required this.theme,
    required this.detents,
    required this.grabber,
    required this.dismissible,
    required this.modal,
    required this.keyboardAware,
    required this.builder,
  });

  @override
  Color? get barrierColor => modal ? Colors.black.withValues(alpha: 0.32) : null;
  @override
  bool get barrierDismissible => modal && dismissible;
  @override
  String? get barrierLabel => 'Dismiss';
  @override
  Duration get transitionDuration => Motion.sheet;
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 220);
  @override
  bool get maintainState => true;

  @override
  Widget buildModalBarrier() => modal ? super.buildModalBarrier() : const SizedBox.shrink();

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return Theme(
      data: theme,
      child: _AppSheetBody(
        detents: detents,
        grabber: grabber,
        dismissible: dismissible,
        keyboardAware: keyboardAware,
        builder: builder,
      ),
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    if (Motion.reduced(context)) return FadeTransition(opacity: animation, child: child);
    final curved = CurvedAnimation(parent: animation, curve: _SpringCurve(), reverseCurve: Curves.easeIn);
    return SlideTransition(position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(curved), child: child);
  }
}

class _AppSheetBody extends StatefulWidget {
  final List<double> detents;
  final bool grabber, dismissible, keyboardAware;
  final Widget Function(BuildContext, ScrollController) builder;
  const _AppSheetBody({
    required this.detents,
    required this.grabber,
    required this.dismissible,
    required this.keyboardAware,
    required this.builder,
  });

  @override
  State<_AppSheetBody> createState() => _AppSheetBodyState();
}

class _AppSheetBodyState extends State<_AppSheetBody> {
  final DraggableScrollableController _dsc = DraggableScrollableController();
  bool _grewForKeyboard = false;

  @override
  void dispose() {
    _dsc.dispose();
    super.dispose();
  }

  void _growForKeyboard(double inset) {
    if (!widget.keyboardAware) return;
    if (inset > 0 && !_grewForKeyboard) {
      _grewForKeyboard = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _dsc.isAttached) {
          _dsc.animateTo(widget.detents.last, duration: Motion.of(context, Motion.sheet), curve: Curves.easeOut);
        }
      });
    } else if (inset == 0) {
      _grewForKeyboard = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    _growForKeyboard(inset);
    final first = widget.detents.first, last = widget.detents.last;
    final dark = t.brightness == Brightness.dark;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: Layout.sheetMaxWidth),
        child: Padding(
          padding: EdgeInsets.only(bottom: widget.keyboardAware ? inset : 0),
          child: SafeArea(
            bottom: false,
            child: DraggableScrollableSheet(
              controller: _dsc,
              initialChildSize: first,
              minChildSize: widget.dismissible ? 0.0 : first,
              maxChildSize: last,
              snap: true,
              snapSizes: widget.detents,
              shouldCloseOnMinExtent: widget.dismissible,
              builder: (context, controller) => Material(
                key: const Key('app-sheet'),
                color: t.colorScheme.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(Corners.card)),
                  side: dark ? BorderSide(color: t.colorScheme.outline) : BorderSide.none,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    if (widget.grabber)
                      SizedBox(
                        height: 20,
                        width: double.infinity,
                        child: Center(
                          child: Container(
                            key: const Key('app-sheet-grabber'),
                            width: 36,
                            height: 5,
                            decoration: BoxDecoration(color: t.colorScheme.outline, borderRadius: BorderRadius.circular(3)),
                          ),
                        ),
                      ),
                    Expanded(child: widget.builder(context, controller)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ alert

/// Rare, short, blocking, 1-2 line confirmation (e.g. discard unsaved text). Everything else is a sheet or a toast.
/// Cancel on the left, the default action in bold; [destructive] draws the confirm in red. Returns true / false, or null
/// when dismissed. Keys are kept so tests keep finding the same buttons.
Future<bool?> showAppAlert(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
  bool userInitiated = true,
  Key? dialogKey,
  Key? confirmKey,
  Key? cancelKey,
}) {
  return DriveGuard.instance.run<bool>(
    () async {
      if (!context.mounted) return null;
      final theme = Theme.of(context);
      if (_apple(context)) {
        return showCupertinoDialog<bool>(
          context: context,
          useRootNavigator: true,
          builder: (ctx) => Theme(
            data: theme,
            child: CupertinoAlertDialog(
              key: dialogKey,
              title: Text(title),
              content: message == null ? null : Text(message),
              actions: [
                CupertinoDialogAction(key: cancelKey, onPressed: () => Navigator.pop(ctx, false), child: Text(cancelLabel)),
                CupertinoDialogAction(
                  key: confirmKey,
                  isDefaultAction: !destructive,
                  isDestructiveAction: destructive,
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(confirmLabel),
                ),
              ],
            ),
          ),
        );
      }
      return showDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) => AlertDialog(
          key: dialogKey,
          title: Text(title),
          content: message == null ? null : Text(message),
          actions: [
            TextButton(key: cancelKey, onPressed: () => Navigator.pop(ctx, false), child: Text(cancelLabel)),
            TextButton(
              key: confirmKey,
              style: destructive ? TextButton.styleFrom(foregroundColor: theme.colorScheme.error) : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      );
    },
    userInitiated: userInitiated,
    stillValid: () => context.mounted,
  );
}

// ------------------------------------------------------------------------------------------------ action sheet

/// A short choice list or a destructive choice. Actions appear in the order given; Cancel is always last and separate.
/// Returns the chosen action's value, or null when cancelled.
Future<T?> showAppActionSheet<T>(
  BuildContext context, {
  String? title,
  String? message,
  required List<AppAction<T>> actions,
  String cancelLabel = 'Cancel',
  Key? sheetKey,
  Key? cancelKey,
  bool userInitiated = true,
}) {
  return DriveGuard.instance.run<T>(
    () async {
      if (!context.mounted) return null;
      final theme = Theme.of(context);
      if (_apple(context)) {
        return showCupertinoModalPopup<T>(
          context: context,
          useRootNavigator: true,
          builder: (ctx) => Theme(
            data: theme,
            child: CupertinoActionSheet(
              key: sheetKey,
              title: title == null ? null : Text(title),
              message: message == null ? null : Text(message),
              actions: [
                for (final a in actions)
                  CupertinoActionSheetAction(
                    key: a.key,
                    isDestructiveAction: a.destructive,
                    isDefaultAction: a.isDefault,
                    onPressed: () => Navigator.pop(ctx, a.value),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (a.symbol != null) ...[AppSymbolIcon(a.symbol!, size: 20), const SizedBox(width: Gap.s)],
                        Flexible(child: Text(a.label, textAlign: TextAlign.center)),
                        if (a.checked) ...[const SizedBox(width: Gap.s), const AppSymbolIcon(AppSymbols.checkmark, size: 18)],
                      ],
                    ),
                  ),
              ],
              cancelButton: CupertinoActionSheetAction(key: cancelKey, onPressed: () => Navigator.pop(ctx), child: Text(cancelLabel)),
            ),
          ),
        );
      }
      return showModalBottomSheet<T>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: Layout.sheetMaxWidth),
        builder: (ctx) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              key: sheetKey,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null || message != null)
                  Padding(
                    padding: const EdgeInsets.all(Gap.l),
                    child: Column(
                      children: [
                        if (title != null) Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                        if (message != null) Text(message, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                for (final a in actions)
                  ListTile(
                    key: a.key,
                    leading: a.symbol == null ? null : AppSymbolIcon(a.symbol!, size: 22),
                    title: Text(
                      a.label,
                      style: TextStyle(
                        color: a.destructive ? theme.colorScheme.error : null,
                        fontWeight: a.isDefault ? FontWeight.w700 : null,
                      ),
                    ),
                    trailing: a.checked ? const AppSymbolIcon(AppSymbols.checkmark, size: 20) : null,
                    onTap: () => Navigator.pop(ctx, a.value),
                  ),
                ListTile(key: cancelKey, title: Text(cancelLabel), onTap: () => Navigator.pop(ctx)),
              ],
            ),
          ),
        ),
      );
    },
    userInitiated: userInitiated,
    stillValid: () => context.mounted,
  );
}

/// Yes / no built on the action sheet. [confirmLabel] is the one action (red when [destructive]); false on cancel.
Future<bool> showAppConfirm(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  bool destructive = false,
  String cancelLabel = 'Cancel',
  Key? confirmKey,
  Key? cancelKey,
  Key? sheetKey,
  bool userInitiated = true,
}) async {
  final r = await showAppActionSheet<bool>(
    context,
    title: title,
    message: message,
    actions: [AppAction(confirmLabel, true, destructive: destructive, isDefault: !destructive, key: confirmKey)],
    cancelLabel: cancelLabel,
    cancelKey: cancelKey,
    sheetKey: sheetKey,
    userInitiated: userInitiated,
  );
  return r == true;
}

// ------------------------------------------------------------------------------------------------ toast

enum AppToastKind { info, success, error }

enum ToastAnchor { bottom, top }

/// Tells toasts shown from below it where to sit. Default (no host) is the bottom; the Drive tab wraps itself in a host
/// with [ToastAnchor.top] because its bottom is the dock, the controls and the attribution.
class AppToastHost extends InheritedWidget {
  final ToastAnchor anchor;

  /// Space to keep clear below the safe area at the top (the chip row) or above the safe area at the bottom (tab bar).
  final double inset;
  const AppToastHost({super.key, this.anchor = ToastAnchor.bottom, this.inset = 0, required super.child});

  static AppToastHost? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppToastHost>();

  @override
  bool updateShouldNotify(AppToastHost old) => old.anchor != anchor || old.inset != inset;
}

/// Space the default bottom toast keeps clear for the tab bar when no [AppToastHost] says otherwise.
const double kDefaultBottomChrome = 72;

class _ActiveToast {
  final OverlayEntry entry;
  final Timer timer;
  _ActiveToast(this.entry, this.timer);
}

_ActiveToast? _activeToast;
final ValueNotifier<String?> appToastMessage = ValueNotifier(null);

/// Removes the toast on screen, if any.
void dismissAppToast() {
  final a = _activeToast;
  _activeToast = null;
  if (a == null) return;
  a.timer.cancel();
  // remove() is a no-op when the overlay is already gone (a toast that outlived its tree, e.g. between tests).
  a.entry.remove();
  a.entry.dispose();
  appToastMessage.value = null;
}

/// Non-blocking toast. At most one is visible: a new one replaces the old. Swipe it away. Does not block touches outside
/// itself. Pass friendly text, never a raw exception string.
void showAppToast(
  BuildContext context,
  String message, {
  AppToastKind kind = AppToastKind.info,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  dismissAppToast();
  final host = AppToastHost.maybeOf(context);
  final anchor = host?.anchor ?? ToastAnchor.bottom;
  final inset = host?.inset ?? (anchor == ToastAnchor.bottom ? kDefaultBottomChrome : 0);
  final theme = Theme.of(context);
  final life = duration ?? (kind == AppToastKind.error || actionLabel != null ? const Duration(seconds: 5) : const Duration(milliseconds: 2500));
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _ToastView(
      theme: theme,
      message: message,
      kind: kind,
      anchor: anchor,
      inset: inset,
      actionLabel: actionLabel,
      onAction: onAction == null
          ? null
          : () {
              dismissAppToast();
              onAction();
            },
      onDismiss: () {
        if (_activeToast?.entry == entry) dismissAppToast();
      },
    ),
  );
  overlay.insert(entry);
  _activeToast = _ActiveToast(entry, Timer(life, () {
    if (_activeToast?.entry == entry) dismissAppToast();
  }));
  appToastMessage.value = message;
  if (kind == AppToastKind.error) AppHaptics.error();
}

class _ToastView extends StatefulWidget {
  final ThemeData theme;
  final String message;
  final AppToastKind kind;
  final ToastAnchor anchor;
  final double inset;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismiss;
  const _ToastView({
    required this.theme,
    required this.message,
    required this.kind,
    required this.anchor,
    required this.inset,
    required this.actionLabel,
    required this.onAction,
    required this.onDismiss,
  });

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.toastIn)..forward();
  double _drag = 0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final top = widget.anchor == ToastAnchor.top;
    final cs = widget.theme.colorScheme;
    final sym = switch (widget.kind) {
      AppToastKind.info => AppSymbols.infoCircle,
      AppToastKind.success => AppSymbols.checkmarkCircleFill,
      AppToastKind.error => AppSymbols.exclamationCircle,
    };
    final reduce = Motion.reduced(context);
    final card = Theme(
      data: widget.theme,
      child: Material(
        key: const Key('app-toast'),
        color: cs.inverseSurface,
        borderRadius: BorderRadius.circular(Corners.chip),
        elevation: 4,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Hit.min, maxWidth: Layout.sheetMaxWidth),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppSymbolIcon(sym, size: 20, color: cs.onInverseSurface),
                const SizedBox(width: Gap.s),
                Flexible(
                  child: Text(widget.message, style: widget.theme.textTheme.bodyMedium?.copyWith(color: cs.onInverseSurface)),
                ),
                if (widget.actionLabel != null)
                  CupertinoButton(
                    key: const Key('app-toast-action'),
                    padding: const EdgeInsets.only(left: Gap.m),
                    minimumSize: const Size(Hit.min, Hit.min),
                    onPressed: widget.onAction,
                    child: Text(widget.actionLabel!, style: TextStyle(color: cs.inversePrimary, fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final animated = AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final v = Curves.easeOut.transform(_c.value);
        if (reduce) return Opacity(opacity: v, child: child);
        final dy = (1 - v) * 24 * (top ? -1 : 1) + _drag;
        return Opacity(opacity: v, child: Transform.translate(offset: Offset(0, dy), child: child));
      },
      child: GestureDetector(
        onVerticalDragUpdate: (d) => setState(() => _drag = top ? (_drag + d.delta.dy).clamp(-80, 0) : (_drag + d.delta.dy).clamp(0, 80)),
        onVerticalDragEnd: (d) {
          if (_drag.abs() > 24 || (d.primaryVelocity ?? 0).abs() > 600) {
            widget.onDismiss();
          } else {
            setState(() => _drag = 0);
          }
        },
        child: card,
      ),
    );
    return Positioned(
      left: Layout.screenMargin,
      right: Layout.screenMargin,
      top: top ? mq.padding.top + widget.inset + Gap.s : null,
      bottom: top ? null : mq.padding.bottom + mq.viewInsets.bottom + widget.inset + Gap.s,
      child: Semantics(liveRegion: true, container: true, label: widget.message, child: Center(child: animated)),
    );
  }
}
