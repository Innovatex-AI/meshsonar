// Delivery settings for direct messages (build 77, redesign round 3 rule 10), as the official MeshCore app has them since
// v1.51.0 and MeshCore One in DMSendBudget.swift: how many tries go out on the route the radio holds, how many more after
// one reset path, and whether that fallback is on at all. Pure Dart; stored in the chat database's settings table.
import 'db/chat_database.dart';

class DeliverySettings {
  /// Tries before the reset path: 1 to 4. The radio decides whether each goes direct or by flood.
  final int directTries;

  /// Tries after the reset path: 0 to 4. Used only while [floodFallback] is on.
  final int floodTries;

  /// After the direct tries, send one reset path and try again by flood.
  final bool floodFallback;

  const DeliverySettings({this.directTries = defaultDirectTries, this.floodTries = defaultFloodTries, this.floodFallback = true});

  static const int defaultDirectTries = 4;
  static const int defaultFloodTries = 4;
  static const int minDirectTries = 1;
  static const int maxDirectTries = 4;
  static const int minFloodTries = 0;
  static const int maxFloodTries = 4;

  /// 4 direct tries, then one reset path, then 4 flood tries.
  static const DeliverySettings defaults = DeliverySettings();

  /// The values a person can pick, kept inside their ranges.
  factory DeliverySettings.clamped({int? directTries, int? floodTries, bool? floodFallback}) => DeliverySettings(
        directTries: (directTries ?? defaultDirectTries).clamp(minDirectTries, maxDirectTries),
        floodTries: (floodTries ?? defaultFloodTries).clamp(minFloodTries, maxFloodTries),
        floodFallback: floodFallback ?? true,
      );

  /// Flood tries that will really be made: none when the fallback is off.
  int get effectiveFloodTries => floodFallback ? floodTries : 0;

  /// The "m" of "try n of m" for a new message.
  int get totalTries => directTries + effectiveFloodTries;

  DeliverySettings copyWith({int? directTries, int? floodTries, bool? floodFallback}) => DeliverySettings.clamped(
      directTries: directTries ?? this.directTries, floodTries: floodTries ?? this.floodTries, floodFallback: floodFallback ?? this.floodFallback);

  @override
  bool operator ==(Object other) =>
      other is DeliverySettings && other.directTries == directTries && other.floodTries == floodTries && other.floodFallback == floodFallback;

  @override
  int get hashCode => Object.hash(directTries, floodTries, floodFallback);

  @override
  String toString() => 'DeliverySettings(direct $directTries, flood $floodTries, fallback ${floodFallback ? 'on' : 'off'})';
}

/// Reads and writes [DeliverySettings] in the chat database (`settings` table). A new message takes the values of the
/// moment it is sent; a message already on its way keeps the plan it started with.
class DeliverySettingsStore {
  final ChatDatabase db;
  DeliverySettingsStore(this.db);

  static const String directKey = 'delivery.direct_tries';
  static const String floodKey = 'delivery.flood_tries';
  static const String fallbackKey = 'delivery.flood_fallback';

  DeliverySettings load() {
    final fb = db.setting(fallbackKey);
    return DeliverySettings.clamped(
      directTries: int.tryParse(db.setting(directKey) ?? ''),
      floodTries: int.tryParse(db.setting(floodKey) ?? ''),
      floodFallback: fb == null ? null : fb == '1',
    );
  }

  void save(DeliverySettings s) {
    final c = DeliverySettings.clamped(directTries: s.directTries, floodTries: s.floodTries, floodFallback: s.floodFallback);
    db.transaction(() {
      db.putSetting(directKey, '${c.directTries}');
      db.putSetting(floodKey, '${c.floodTries}');
      db.putSetting(fallbackKey, c.floodFallback ? '1' : '0');
    });
  }
}
