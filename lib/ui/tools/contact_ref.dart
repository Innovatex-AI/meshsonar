// A contact handed to a Tool screen (Trace, Discover, Telemetry) so it opens pre-filled (plan 7.16 / bug 1.18).
// Release 0.38: a thin adapter over the one node object (ui/nodes/node_ref.dart) plus the saved route the tools need.
import '../../chat/models.dart';
import '../../radio/path_tools.dart';
import '../nodes/node_ref.dart';

class ContactRef {
  /// The node this is about.
  final NodeRef node;

  /// The saved route's hop hashes (hex), first repeater first. Trace pre-fills the chain from them.
  final List<String> routeHops;

  const ContactRef._(this.node, this.routeHops);

  factory ContactRef({required String keyHex, required String name, required int type, double? lat, double? lon, List<String> routeHops = const []}) =>
      ContactRef._(
        NodeRef(key: keyHex, name: name, kind: NodeKind.fromAdvType(type) ?? NodeKind.companion, lat: lat, lon: lon, source: NodeSource.contact),
        routeHops,
      );

  factory ContactRef.of(Contact c) =>
      ContactRef._(NodeRef.fromContact(c), decodePath(c.outPathLen, c.outPath ?? const [])?.hexHops ?? const []);

  /// Any node (a map repeater, a drive repeater, the region page) handed to a tool.
  factory ContactRef.fromNode(NodeRef node, {List<String> routeHops = const []}) => ContactRef._(node, routeHops);

  String get keyHex => node.key;
  String get name => node.name;

  /// The MeshCore advert type code (`AdvType`).
  int get type => node.kind.advType;
  double? get lat => node.lat;
  double? get lon => node.lon;
}
