// The hop resolver for the chat screens (CR4): the radio's repeaters and rooms first, then the network roster the app already
// keeps for the map (AppState.repeaters: MeshSonar's list plus the public MeshCore map, with positions).
import 'package:flutter/widgets.dart';

import '../../chat/hop_resolver.dart';
import '../../chat/models.dart';
import '../../chat/store.dart';
import '../../core/network_request.dart' show NetworkRequest;
import '../app.dart' show AppScope;
import '../nodes/node_actions.dart' show shellControllerFor;

/// The network roster as [RosterNode]s; empty without an [AppScope] (isolated widget tests).
List<RosterNode> rosterOf(BuildContext context) {
  final refs = AppScope.maybeOf(context)?.repeaters ?? const [];
  return [for (final r in refs) RosterNode(key: r.key, name: r.name, lat: r.lat, lon: r.lon)];
}

HopResolver hopResolverFor(ChatStore store, String? radioId, List<RosterNode> roster) => HopResolver(
      contacts: radioId == null ? const <Contact>[] : store.contacts.list(radioId),
      roster: roster,
    );


/// Who a hop of a route stands for, when exactly one known node matches its prefix (round 3 C-U8): the radio's own
/// contact when it is one (a repeater or room on your radio), and the node's full public key either way. A hop two known
/// nodes share, or one nobody knows, has no target.
({Contact? contact, String key})? hopTarget(ChatStore store, String? radioId, List<RosterNode> roster, HopNode n) {
  if (!n.known || n.ambiguous) return null;
  final h = n.hash.toLowerCase();
  if (radioId != null) {
    final onRadio = [
      for (final c in store.contacts.list(radioId))
        if ((c.type == ContactType.repeater || c.type == ContactType.room) && c.publicKey.toLowerCase().startsWith(h)) c,
    ];
    if (onRadio.length == 1) return (contact: onRadio.single, key: onRadio.single.publicKey.toLowerCase());
    if (onRadio.length > 1) return null;
  }
  final inRoster = [for (final r in roster) if (r.key.toLowerCase().startsWith(h)) r];
  return inRoster.length == 1 ? (contact: null, key: inRoster.single.key.toLowerCase()) : null;
}

/// Opens the page of the repeater a named hop stands for: its contact profile when it is on your radio and [onContact] is
/// given, else its node page on the Network tab. False when the hop has no single known node or there is nowhere to
/// open it (an isolated screen without the app shell).
bool openHop(BuildContext context, {required ChatStore store, required String? radioId, required HopNode node, void Function(Contact contact)? onContact}) {
  final t = hopTarget(store, radioId, rosterOf(context), node);
  if (t == null) return false;
  final c = t.contact;
  if (c != null && onContact != null) {
    onContact(c);
    return true;
  }
  if (t.key.length != 64) return false;
  final shell = shellControllerFor(context);
  if (shell == null) return false;
  Navigator.maybeOf(context, rootNavigator: true)?.popUntil((r) => r.isFirst);
  shell.openNetwork(NetworkRequest.node(t.key));
  return true;
}

/// Round 2 N-U3, Chat row: "Work out the likely route" for a route with a hop two known repeaters share. Opens Network >
/// Tools > Path Inspector with the message's hops filled in (the same entry the Tools list and a shared link use).
bool openPathInspector(BuildContext context, List<HopNode> nodes) {
  final shell = shellControllerFor(context);
  if (shell == null || nodes.isEmpty) return false;
  Navigator.maybeOf(context, rootNavigator: true)?.popUntil((r) => r.isFirst);
  shell.openNetwork(NetworkRequest.toolOf('path', arg: [for (final n in nodes) n.hash].join(',')));
  return true;
}
