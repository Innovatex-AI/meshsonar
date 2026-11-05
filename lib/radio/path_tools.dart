// Route (path) arithmetic, pure Dart: the packed length byte, encode/decode of a hop list for 1, 2 and 3 byte hashes,
// the hop caps, hash-collision detection for the repeater picker, and the "aa,bb,cc" text form hams type.
//
// Encoding (spike S3, firmware Packet::isValidPathLen): byte = ((hash_size - 1) << 6) | hop_count, then hop_count * hash_size
// bytes; hash_size 1..3 (top bits 11 are reserved), hop_count * hash_size <= 64. 0xFF = no path (the radio floods).
import 'dart:typed_data';

/// "No saved route" in the packed length byte.
const int pathUnknownByte = 0xFF;

/// Longest path the radio stores (MAX_PATH_SIZE).
const int maxPathBytes = 64;

/// Hash sizes a path may use.
const List<int> pathHashSizes = [1, 2, 3];

/// Most hops for [hashSize]: 63, 32 and 21. The plan says 64 for 1-byte hashes, but the hop count is 6 bits (max 63) in the
/// packed length byte, so 63 is what the firmware can hold (S7).
int maxHopsFor(int hashSize) {
  if (!pathHashSizes.contains(hashSize)) throw ArgumentError('a path hash is 1, 2 or 3 bytes');
  final byBytes = maxPathBytes ~/ hashSize;
  return byBytes > 63 ? 63 : byBytes;
}

/// The packed length byte for [hops] hops of [hashSize] bytes.
int packPathLen(int hashSize, int hops) {
  if (hops < 0 || hops > maxHopsFor(hashSize)) throw ArgumentError('too many hops for $hashSize-byte hashes');
  return ((hashSize - 1) << 6) | hops;
}

/// Hops in a packed length byte (0 for the unknown marker).
int hopsOfPathLen(int pathLen) => pathLen == pathUnknownByte || pathLen < 0 ? 0 : pathLen & 63;

/// Hash size in a packed length byte (1 for the unknown marker).
int hashSizeOfPathLen(int pathLen) => pathLen == pathUnknownByte || pathLen < 0 ? 1 : (pathLen >> 6) + 1;

/// True when the byte is a path the firmware accepts (reserved size 4 and overlong paths are not).
bool isValidPathLen(int pathLen) {
  if (pathLen == pathUnknownByte) return true;
  if (pathLen < 0 || pathLen > 255) return false;
  final size = (pathLen >> 6) + 1;
  return size <= 3 && (pathLen & 63) * size <= maxPathBytes;
}

/// A route as hops of equal hash size.
class PathRoute {
  final int hashSize;
  final List<Uint8List> hops;
  PathRoute(this.hashSize, Iterable<List<int>> hops) : hops = [for (final h in hops) Uint8List.fromList(h)] {
    if (!pathHashSizes.contains(hashSize)) throw ArgumentError('a path hash is 1, 2 or 3 bytes');
    for (final h in this.hops) {
      if (h.length != hashSize) throw ArgumentError('every hop must be $hashSize bytes');
    }
    if (this.hops.length > maxHopsFor(hashSize)) throw ArgumentError('too many hops for $hashSize-byte hashes');
  }

  /// Route from hex hop strings ("a1", "a1b2"); all the same length.
  factory PathRoute.fromHex(Iterable<String> hexHops) {
    final list = hexHops.toList();
    if (list.isEmpty) return PathRoute(1, const []);
    final size = list.first.length ~/ 2;
    return PathRoute(size, [for (final h in list) _fromHex(h)]);
  }

  int get length => hops.length;
  bool get isEmpty => hops.isEmpty;

  /// The packed length byte.
  int get pathLenByte => packPathLen(hashSize, hops.length);

  /// The concatenated hop bytes (what goes in `out_path`).
  Uint8List get bytes => Uint8List.fromList([for (final h in hops) ...h]);

  List<String> get hexHops => [for (final h in hops) _hex(h)];

  /// "a1 > b2 > c3" for words and copy.
  String get text => hexHops.join(' > ');

  /// The same route as a reversed list (the way back).
  PathRoute get reversed => PathRoute(hashSize, hops.reversed);

  @override
  bool operator ==(Object other) => other is PathRoute && other.hashSize == hashSize && other.text == text;
  @override
  int get hashCode => Object.hash(hashSize, text);
}

/// Decodes a packed length byte and its path bytes. Null when the byte means "no route", is invalid or the bytes are short.
PathRoute? decodePath(int pathLen, List<int> path) {
  if (pathLen == pathUnknownByte || !isValidPathLen(pathLen)) return null;
  final size = hashSizeOfPathLen(pathLen);
  final n = hopsOfPathLen(pathLen);
  if (path.length < n * size) return null;
  return PathRoute(size, [for (var i = 0; i < n; i++) path.sublist(i * size, (i + 1) * size)]);
}

/// Encodes [route] as (length byte, path bytes) for ADD_UPDATE_CONTACT.
({int pathLen, Uint8List path}) encodePath(PathRoute route) => (pathLen: route.pathLenByte, path: route.bytes);

/// Parses "aa,bb,cc" (commas, spaces, > or arrows; case-insensitive). All hops must have the same 1..3 byte size.
/// Returns null with [error] set when it cannot be read.
({PathRoute? route, String? error}) parsePathText(String text) {
  final parts = text.split(RegExp(r'[\s,;>›→-]+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return (route: null, error: 'Type the repeater hashes, like aa,bb,cc.');
  final re = RegExp(r'^[0-9a-fA-F]+$');
  for (final p in parts) {
    if (!re.hasMatch(p) || p.length.isOdd) return (route: null, error: '"$p" is not a hash. Use whole bytes in hex, like a1 or a1b2.');
  }
  final size = parts.first.length ~/ 2;
  if (!pathHashSizes.contains(size)) return (route: null, error: 'Hashes are 1, 2 or 3 bytes.');
  if (parts.any((p) => p.length ~/ 2 != size)) return (route: null, error: 'Every hash must be the same length.');
  if (parts.length > maxHopsFor(size)) return (route: null, error: 'At most ${maxHopsFor(size)} repeaters with $size-byte hashes.');
  return (route: PathRoute.fromHex(parts), error: null);
}

/// A repeater the picker can offer.
class PathCandidate {
  final String keyHex;
  final String name;
  const PathCandidate(this.keyHex, this.name);
  String hash(int hashSize) => keyHex.substring(0, hashSize * 2).toLowerCase();
}

/// Two or more repeaters that share the same leading bytes: the radio cannot tell them apart.
class HashCollision {
  final String hash;
  final List<PathCandidate> nodes;
  const HashCollision(this.hash, this.nodes);

  /// "2 repeaters share a1; the radio can't tell them apart" (plan 4.7).
  String get warning => '${nodes.length} repeaters share $hash; the radio can\'t tell them apart.';
}

/// Collisions among [known] repeaters for the hashes in [chosen] (only chosen hashes matter). A chosen repeater counts as
/// colliding when ANY other known repeater (chosen or not) has the same [hashSize] bytes. Returned in the order of [chosen].
List<HashCollision> findHashCollisions(Iterable<PathCandidate> chosen, Iterable<PathCandidate> known, int hashSize) {
  final out = <HashCollision>[];
  final seen = <String>{};
  for (final c in chosen) {
    final h = c.hash(hashSize);
    if (!seen.add(h)) continue;
    final sharing = <PathCandidate>[
      for (final k in known)
        if (k.hash(hashSize) == h) k,
    ];
    // The chosen node itself may not be in [known]; make sure it is counted once.
    if (!sharing.any((k) => k.keyHex == c.keyHex)) sharing.add(c);
    // The same repeater twice in the route is not a collision between two nodes.
    final distinct = {for (final n in sharing) n.keyHex.toLowerCase(): n}.values.toList();
    if (distinct.length > 1) out.add(HashCollision(h, distinct));
  }
  return out;
}

/// The smallest hash size (1..3) with no collision among [chosen] relative to [known]; null when even 3 bytes collide.
int? smallestSafeHashSize(Iterable<PathCandidate> chosen, Iterable<PathCandidate> known) {
  for (final s in pathHashSizes) {
    if (findHashCollisions(chosen, known, s).isEmpty) return s;
  }
  return null;
}

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

Uint8List _fromHex(String h) {
  final s = h.toLowerCase();
  return Uint8List.fromList([for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
}

/// Hex helper for callers that hold a stored path (`pinned_path`, `path_history.hops`): "a1,b2" -> hops.
List<String> splitHexHops(String? stored) =>
    stored == null || stored.isEmpty ? const [] : stored.split(',').map((s) => s.trim().toLowerCase()).where((s) => s.isNotEmpty).toList();

/// Stored form of a route: comma separated hex hops.
String joinHexHops(Iterable<String> hops) => hops.join(',');
