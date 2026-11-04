// A contact handed to a Tool screen (Trace, Discover, Telemetry) so it opens pre-filled (plan 7.16 / bug 1.18).
import '../../chat/models.dart';
import '../../radio/path_tools.dart';

class ContactRef {
  final String keyHex;
  final String name;
  final int type;
  final double? lat, lon;

  /// The saved route's hop hashes (hex), first repeater first. Trace pre-fills the chain from them.
  final List<String> routeHops;
  const ContactRef({required this.keyHex, required this.name, required this.type, this.lat, this.lon, this.routeHops = const []});

  factory ContactRef.of(Contact c) => ContactRef(
        keyHex: c.publicKey,
        name: c.displayName,
        type: c.type.code,
        lat: c.lat,
        lon: c.lon,
        routeHops: decodePath(c.outPathLen, c.outPath ?? const [])?.hexHops ?? const [],
      );
}
