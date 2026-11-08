// The hop resolver for the chat screens (CR4): the radio's repeaters and rooms first, then the network roster the app already
// keeps for the map (AppState.repeaters: MeshSonar's list plus the public MeshCore map, with positions).
import 'package:flutter/widgets.dart';

import '../../chat/hop_resolver.dart';
import '../../chat/models.dart';
import '../../chat/store.dart';
import '../app.dart' show AppScope;

/// The network roster as [RosterNode]s; empty without an [AppScope] (isolated widget tests).
List<RosterNode> rosterOf(BuildContext context) {
  final refs = AppScope.maybeOf(context)?.repeaters ?? const [];
  return [for (final r in refs) RosterNode(key: r.key, name: r.name, lat: r.lat, lon: r.lon)];
}

HopResolver hopResolverFor(ChatStore store, String? radioId, List<RosterNode> roster) => HopResolver(
      contacts: radioId == null ? const <Contact>[] : store.contacts.list(radioId),
      roster: roster,
    );
