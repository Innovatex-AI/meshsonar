// A minimal change notifier for the pure-Dart tool controllers (lib/radio has no Flutter imports). The UI listens with a
// StreamBuilder or its own subscription; notifications are coalesced so a burst of packets is one rebuild.
import 'dart:async';

mixin ToolChanges {
  final StreamController<void> _changes = StreamController<void>.broadcast();
  bool _pending = false;
  bool _disposed = false;

  /// Fires after the state changed (at most once per event-loop turn).
  Stream<void> get changed => _changes.stream;

  void notifyChanged() {
    if (_disposed || _pending) return;
    _pending = true;
    scheduleMicrotask(() {
      _pending = false;
      if (!_disposed && !_changes.isClosed) _changes.add(null);
    });
  }

  void disposeChanges() {
    _disposed = true;
    unawaited(_changes.close());
  }
}
