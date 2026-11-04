// Route health (chat plan 4.7 / 7.x): a saved route that keeps failing. After [brokenAfter] direct messages in a row to the
// same person that all ended Not delivered, the conversation offers "Find a route now" and "Reset route". Pure reads from
// the local database: the newest outgoing messages of the conversation and their delivery attempts.
import 'models.dart';
import 'store.dart';

const int brokenAfter = 3;

/// True when the newest [brokenAfter] outgoing messages to [contact] all failed after at least one attempt over the saved
/// route, and the contact still has a saved route that was not (re)learned since the first of them. A delivered message
/// anywhere in that window means the route works, so the answer is false.
bool routeLooksBroken(ChatStore store, Contact contact) {
  if (contact.pathMode == PathMode.flood) return false; // "Always search" has no saved route to blame
  final hasRoute = contact.hasPath || (contact.pathMode == PathMode.fixed && (contact.pinnedPath ?? '').isNotEmpty);
  if (!hasRoute) return false;
  final page = store.messages.page(ConvKey.dm(contact.publicKey), limit: 40);
  final out = [for (final m in page.messages) if (m.isOutgoing) m];
  if (out.length < brokenAfter) return false;
  final learned = contact.pathLearnedMs;
  for (final m in out.take(brokenAfter)) {
    if (m.state != MessageState.failed) return false;
    if (learned != null && m.tsLocalMs < learned) return false; // the route changed after this failure
    final usedRoute = store.outbox.attemptsFor(m.id).any((a) => a.route == Route.direct);
    if (!usedRoute) return false;
  }
  return true;
}
