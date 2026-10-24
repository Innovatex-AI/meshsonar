// Reports whether the app is in front (resumed) to [onChange]. Safe to attach where no Flutter binding exists
// (plain unit tests): it then silently does nothing.
import 'package:flutter/widgets.dart';

class AppLifecycleBridge with WidgetsBindingObserver {
  final void Function(bool foreground) onChange;
  AppLifecycleBridge(this.onChange);
  bool _attached = false;

  void attach() {
    if (_attached) return;
    try {
      WidgetsBinding.instance.addObserver(this);
      _attached = true;
    } catch (_) {}
  }

  void detach() {
    if (!_attached) return;
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _attached = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => onChange(state == AppLifecycleState.resumed);
}
