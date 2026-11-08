// Names the hops of a path (chat + radio round, CR4). A hop on the air is only the first 1-3 bytes of a repeater's public key,
// so a name is a guess that must say how sure it is. Order of trust: the repeaters and rooms your radio holds as contacts,
// then the network roster (MeshSonar's list plus the public MeshCore map, AppState.repeaters). One match = a name; several =
// ambiguous (shown with the candidates, like the official app's red prefix); none = the raw prefix ("?a1"). Positions come
// from whichever source named it, for the path map. Pure Dart.
import 'models.dart';

/// A node the network roster knows: full public key (hex), name and position.
class RosterNode {
  final String key;
  final String name;
  final double lat;
  final double lon;
  const RosterNode({required this.key, required this.name, required this.lat, required this.lon});
}

enum HopSource { radio, roster, unknown }

class HopNode {
  /// The prefix as heard, lower-case hex ("a1", "a1b2").
  final String hash;

  /// The name when exactly one known node matches; null otherwise.
  final String? name;
  final HopSource source;

  /// Names of every node that matches when more than one does (the radio cannot tell them apart).
  final List<String> candidates;
  final double? lat;
  final double? lon;
  const HopNode({required this.hash, this.name, this.source = HopSource.unknown, this.candidates = const [], this.lat, this.lon});

  bool get ambiguous => candidates.length > 1;
  bool get known => name != null;
  bool get hasPosition => lat != null && lon != null;

  /// What a chip shows: the name, or `?a1` when unknown or ambiguous.
  String get label => name ?? '?$hash';

  /// A longer form for details and VoiceOver: "Ridge", "?a1 (2 possible: Ridge, Hill)", "?a1 (unknown repeater)".
  String get description {
    if (name != null) return name!;
    if (ambiguous) return '?$hash (${candidates.length} possible: ${candidates.join(', ')})';
    return '?$hash (unknown repeater)';
  }
}

class HopResolver {
  final List<Contact> _radio;
  final List<RosterNode> _roster;
  final Map<String, HopNode> _cache = {};

  /// [contacts]: the radio's contacts (only repeaters and rooms are used). [roster]: the network roster.
  HopResolver({Iterable<Contact> contacts = const [], Iterable<RosterNode> roster = const []})
      : _radio = [for (final c in contacts) if (c.type == ContactType.repeater || c.type == ContactType.room) c],
        _roster = List.of(roster);

  HopNode resolve(String hash) {
    final h = hash.toLowerCase();
    return _cache.putIfAbsent(h, () {
      final onRadio = [for (final c in _radio) if (c.publicKey.toLowerCase().startsWith(h)) c];
      if (onRadio.length == 1) {
        final c = onRadio.single;
        // The radio contact may have no position; the roster may know it by the full key.
        final pos = c.lat != null && c.lon != null ? (c.lat!, c.lon!) : _rosterPosition(c.publicKey);
        return HopNode(hash: h, name: c.displayName, source: HopSource.radio, lat: pos?.$1, lon: pos?.$2);
      }
      if (onRadio.length > 1) return HopNode(hash: h, candidates: [for (final c in onRadio) c.displayName]);
      final inRoster = [for (final r in _roster) if (r.key.toLowerCase().startsWith(h)) r];
      if (inRoster.length == 1) {
        final r = inRoster.single;
        return HopNode(hash: h, name: r.name.isEmpty ? null : r.name, source: HopSource.roster, lat: r.lat, lon: r.lon);
      }
      if (inRoster.length > 1) return HopNode(hash: h, candidates: [for (final r in inRoster) r.name.isEmpty ? '?' : r.name]);
      return HopNode(hash: h);
    });
  }

  List<HopNode> resolveAll(Iterable<String> hashes) => [for (final h in hashes) resolve(h)];

  (double, double)? _rosterPosition(String key) {
    final k = key.toLowerCase();
    for (final r in _roster) {
      if (r.key.toLowerCase() == k) return (r.lat, r.lon);
    }
    return null;
  }
}
