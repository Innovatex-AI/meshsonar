// The phone observer's id (contract meshsonar-infra docs/planning/phone-observer-contract-v2-2026-11-08.md section 2):
// 32 lower-case hex characters, random per app install, never derived from the person, the driver key or the radio. Kept
// in the phone's secure store (iOS Keychain, this device only) so it survives app updates; a new one is made after the
// person erased their shared data, so what is sent afterwards is not linked to what was erased.
//
// Pure Dart: the store is two functions (the app passes the Keychain; tests pass memory).
import 'dart:math';
import 'dart:typed_data';

final RegExp observerIdRe = RegExp(r'^[0-9a-f]{32}$');

/// The secure-store slot the id lives in.
const String observerIdSlot = 'meshsonar.observer_id';

class ObserverIdentity {
  final Future<Uint8List?> Function() read;
  final Future<void> Function(Uint8List bytes) write;
  final Random _random;

  ObserverIdentity({required this.read, required this.write, Random? random}) : _random = random ?? Random.secure();

  /// In memory only (tests, a phone without a secure store): stable for this run.
  factory ObserverIdentity.memory({Random? random}) {
    Uint8List? held;
    return ObserverIdentity(read: () async => held, write: (b) async => held = Uint8List.fromList(b), random: random);
  }

  String? _id;

  /// The id once [load] has run; null before.
  String? get id => _id;

  /// Reads the stored id, or makes and stores a new random one. Safe to call again.
  Future<String> load() async {
    final have = _id;
    if (have != null) return have;
    try {
      final b = await read();
      if (b != null && b.length == 16) return _id = _hex(b);
    } catch (_) {}
    return _make();
  }

  /// A new random id (after an erase): the old one is never used again.
  Future<String> rotate() => _make();

  Future<String> _make() async {
    final b = Uint8List.fromList(List<int>.generate(16, (_) => _random.nextInt(256)));
    final id = _hex(b);
    _id = id;
    try {
      await write(b);
    } catch (_) {
      // Without the secure store the id lasts for this run only; it is still random and still not linked to anything.
    }
    return id;
  }

  static String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
}
