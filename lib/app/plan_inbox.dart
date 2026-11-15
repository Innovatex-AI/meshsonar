// The plan inbox (release 0.38 foundation): shared plan links that reached the app (a universal link, a pasted link, a
// `meshsonar://plan` link) wait here until the Plan tab takes them. AppState feeds it from `AppServices.incomingLinks`;
// HomeShell turns each one into a `PlanRequest` for the Plan tab (lib/ui/shell/shell_controller.dart). Only plan links
// are kept: any other link is ignored here (it is not this inbox's business). The plan itself rides in the link's
// fragment, which never reaches a server; decoding it is the planner's job (lib/core/plan/).
import 'package:flutter/foundation.dart';

/// Web paths a shared plan opens on (`/share/plan` is the site's landing; `/plan` is the Map Definition's share base).
const Set<String> planLinkPaths = {'/share/plan', '/plan'};

/// Is [u] a shared-plan link: `https://<meshsonar.com or a subdomain>/share/plan…`, `…/plan…`, or `meshsonar://plan…`.
bool isPlanLink(Uri u) {
  if (u.scheme == 'meshsonar') return u.host == 'plan';
  if (u.scheme != 'https') return false;
  final h = u.host.toLowerCase();
  if (h != 'meshsonar.com' && !h.endsWith('.meshsonar.com')) return false;
  var p = u.path;
  while (p.length > 1 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return planLinkPaths.contains(p);
}

class PlanInbox extends ChangeNotifier {
  final List<Uri> _pending = [];

  /// The waiting links, oldest first.
  List<Uri> get pending => List.unmodifiable(_pending);
  bool get isEmpty => _pending.isEmpty;

  /// Keeps [u] if it is a plan link (the same link twice in a row is kept once). Returns whether it was kept.
  bool offer(Uri u) {
    if (!isPlanLink(u)) return false;
    if (_pending.isNotEmpty && _pending.last == u) return true;
    _pending.add(u);
    notifyListeners();
    return true;
  }

  /// The oldest waiting link, removed; null when none.
  Uri? take() => _pending.isEmpty ? null : _pending.removeAt(0);
}
