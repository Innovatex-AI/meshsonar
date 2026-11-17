// Whether the app is in front (build 70 battery plan, meshsonar-infra docs/planning/battery-efficiency-plan-2026-11-16.md).
// Pure Dart: AppState's lifecycle handler ([AppState._onForeground]) sets it; lib/radio and lib/core read it to pick their
// foreground or background cadence (the BLE safety poll, PowerSettings.radioPollFrontS / radioPollBackS). One value for
// the whole app, so a link opened after a reconnect starts with the right cadence.
abstract final class AppForeground {
  static bool _fg = true;
  static final List<void Function(bool foreground)> _listeners = [];

  /// True while the app is in front (also the start value: the app launches in front).
  static bool get inForeground => _fg;

  /// Called by the app's lifecycle handler. Listeners run only on a change.
  static void set(bool foreground) {
    if (foreground == _fg) return;
    _fg = foreground;
    for (final l in List.of(_listeners)) {
      l(foreground);
    }
  }

  static void addListener(void Function(bool foreground) l) => _listeners.add(l);
  static void removeListener(void Function(bool foreground) l) => _listeners.remove(l);

  /// Tests only.
  static void debugReset() {
    _fg = true;
    _listeners.clear();
  }
}
