// One node object for every surface that shows a node (release 0.38, plan 4.5 item 2): the map repeater and observer
// sheets, the drive repeater sheet, the region repeater page and the contact profile all describe what they show as a
// [NodeRef], and the same action builder (node_actions.dart) decides what can be done with it.
//
// Privacy rule: a node whose position is not public never yields coordinates for planning. That is a node whose name
// carries the MeshCore "do not share my position" mark (U+1F6AB, the no-entry sign), a node marked
// [NodeRef.positionHidden] by its source (an observer whose owner did not publish the spot), or a node without a usable
// position at all. [NodeRef.planSeed] is null for every one of them, so no plan action can carry the coordinates.
import 'package:flutter/foundation.dart';

import '../../chat/models.dart' show Contact, ContactType;
import '../../core/model.dart' show RepeaterRef;
import '../shell/shell_controller.dart' show PlanNodeSeed;

/// The no-entry sign MeshCore people put in a node's name to say "do not share my position".
const String kNoPositionMark = '\u{1F6AB}';

/// True when [name] carries the "position not public" mark.
bool nameHidesPosition(String? name) => name != null && name.contains(kNoPositionMark);

/// What kind of node it is. The action set depends on it.
enum NodeKind {
  repeater,
  room,

  /// A person's radio (a chat contact).
  companion,
  sensor,

  /// A MeshSonar or CoreScope observer on the map.
  observer;

  /// The kind for a MeshCore advert type code (1 chat, 2 repeater, 3 room, 4 sensor); null for anything else.
  static NodeKind? fromAdvType(int code) => switch (code) {
        1 => NodeKind.companion,
        2 => NodeKind.repeater,
        3 => NodeKind.room,
        4 => NodeKind.sensor,
        _ => null,
      };

  /// The MeshCore advert type code (0 for an observer, which is not a contact type).
  int get advType => switch (this) {
        NodeKind.companion => 1,
        NodeKind.repeater => 2,
        NodeKind.room => 3,
        NodeKind.sensor => 4,
        NodeKind.observer => 0,
      };

  /// A radio node the connected radio can reach by key (ping, trace).
  bool get isRadioNode => this != NodeKind.observer;

  /// A fixed site that makes sense as a plan node (people move; their radios are link ends only).
  bool get isSite => this != NodeKind.companion;
}

/// Which surface the node came from.
enum NodeSource {
  /// The global network layer on a map (map.meshcore.io data).
  network,

  /// The viewed region's roster on a map.
  roster,

  /// Heard on one of this phone's drives.
  drive,

  /// The region repeater page.
  region,

  /// A chat contact.
  contact,

  /// The observers layer on a map.
  observer;

  /// The [PlanNodeSeed.source] word (`repeater`, `observer`, `contact`).
  String get seedSource => switch (this) {
        NodeSource.network || NodeSource.roster || NodeSource.drive || NodeSource.region => 'repeater',
        NodeSource.observer => 'observer',
        NodeSource.contact => 'contact',
      };
}

@immutable
class NodeRef {
  /// The public key, lower-case hex. A full key is 64 characters; a drive can know only a short hash.
  final String key;
  final String name;
  final NodeKind kind;
  final double? lat, lon;
  final NodeSource source;

  /// The source says the position is not public (even when it carries coordinates for drawing).
  final bool positionHidden;

  NodeRef({
    required String key,
    required this.name,
    required this.kind,
    this.lat,
    this.lon,
    required this.source,
    this.positionHidden = false,
  }) : key = key.toLowerCase();

  /// A chat contact. Both the advertised and the custom name are checked for the "position not public" mark.
  factory NodeRef.fromContact(Contact c) => NodeRef(
        key: c.publicKey,
        name: c.displayName,
        kind: switch (c.type) {
          ContactType.companion => NodeKind.companion,
          ContactType.repeater => NodeKind.repeater,
          ContactType.room => NodeKind.room,
          ContactType.sensor => NodeKind.sensor,
        },
        lat: c.lat,
        lon: c.lon,
        source: NodeSource.contact,
        positionHidden: nameHidesPosition(c.name) || nameHidesPosition(c.customName),
      );

  /// A repeater resolved from a drive's repeater list.
  factory NodeRef.fromRepeaterRef(RepeaterRef r, {String? name, NodeSource source = NodeSource.drive}) => NodeRef(
        key: r.key,
        name: name ?? r.name,
        kind: r.isRoom ? NodeKind.room : NodeKind.repeater,
        lat: r.lat,
        lon: r.lon,
        source: source,
        positionHidden: nameHidesPosition(r.name),
      );

  /// A full 64-character public key (claim, admin, ping and the region page need one).
  bool get hasFullKey => key.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(key);

  /// Usable coordinates: present, finite, on the globe, and not the (0, 0) MeshCore sends for "no position".
  bool get hasPosition {
    final a = lat, o = lon;
    if (a == null || o == null || !a.isFinite || !o.isFinite) return false;
    if (a.abs() > 90 || o.abs() > 180) return false;
    return !(a == 0 && o == 0);
  }

  /// The position may be used for planning: usable, and neither the source nor the name says it is private.
  bool get positionPublic => hasPosition && !positionHidden && !nameHidesPosition(name);

  /// What a plan request carries, or null when the position is not public (then no plan action is offered).
  PlanNodeSeed? get planSeed =>
      positionPublic ? PlanNodeSeed(key: hasFullKey ? key : null, name: name, lat: lat!, lon: lon!, source: source.seedSource) : null;

  @override
  bool operator ==(Object other) =>
      other is NodeRef &&
      other.key == key &&
      other.name == name &&
      other.kind == kind &&
      other.lat == lat &&
      other.lon == lon &&
      other.source == source &&
      other.positionHidden == positionHidden;

  @override
  int get hashCode => Object.hash(key, name, kind, lat, lon, source, positionHidden);

  @override
  String toString() => 'NodeRef(${kind.name} $name ${key.length >= 8 ? key.substring(0, 8) : key} ${source.name})';
}
