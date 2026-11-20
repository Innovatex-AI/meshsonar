// The Network inbox (AZ-3.1): Network links that reached the app (a universal link, a pasted link, a
// `meshsonar://network/...` link) wait here as NetworkRequests until HomeShell hands them to the Network tab
// (ShellController.openNetwork). AppState offers every incoming link to the plan inbox first (plan_inbox.dart) and then
// here; anything that is not a Network route (lib/core/network_request.dart) is ignored.
import 'package:flutter/foundation.dart';

import '../core/network_request.dart';

class NetworkInbox extends ChangeNotifier {
  final List<NetworkRequest> _pending = [];

  List<NetworkRequest> get pending => List.unmodifiable(_pending);
  bool get isEmpty => _pending.isEmpty;

  /// Keeps [u] when it is a Network link (the same request twice in a row is kept once). Returns whether it was one.
  bool offer(Uri u) {
    final r = NetworkRequest.parse(u);
    if (r == null) return false;
    if (_pending.isNotEmpty && _pending.last == r) return true;
    _pending.add(r);
    notifyListeners();
    return true;
  }

  /// The oldest waiting request, removed; null when none.
  NetworkRequest? take() => _pending.isEmpty ? null : _pending.removeAt(0);
}
