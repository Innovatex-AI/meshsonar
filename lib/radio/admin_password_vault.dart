// Where a repeater or room password lives between screens. By default it lives ONLY in memory (this object), so it is gone
// when the app closes. If - and only if - the person turns on "Remember on this phone", passwords are also kept in the
// device's secure store (iOS Keychain, this device only, never synced, never uploaded) and turning it off wipes them.
// A password is never written anywhere else: not to logs, not to SQLite, not to the server. Pure Dart.
//
// Key scheme (chat plan WP9): `admin.pw.v2.<radio>.<nodeKey>` (admin or room password) and `admin.gpw.v2.<radio>.<nodeKey>`
// (guest password), where <radio> is the first 12 hex of the phone's own radio key and <nodeKey> the repeater's 64-hex key,
// so two radios on one phone never share a saved password. `admin.index` lists every stored ref so a wipe can find them
// without asking the store to enumerate. The first scheme (`admin.pw.<nodeKey>`) is migrated on first read. Optional Face ID:
// when on, a password that comes from the secure store (not one typed in this run) is released only after [authenticate].
import 'dart:convert';
import 'dart:typed_data';

import '../chat/secret_store.dart';

class AdminPasswordVault {
  static const String _flagRef = 'admin.remember';
  static const String _faceRef = 'admin.faceid';
  static const String _indexRef = 'admin.index';

  static String _legacyRef(String keyHex) => 'admin.pw.${keyHex.toLowerCase()}';

  final SecretStore? _store;

  /// Asks the person to prove who they are (Face ID / Touch ID / passcode). Null = this build cannot, so Face ID is not offered.
  final Future<bool> Function()? authenticate;

  /// The phone's own radio (first 12 hex of its key) so saved passwords are per radio. Set when a session opens.
  String radioId;

  final Map<String, String> _memory = {};
  bool _remember = false;
  bool _face = false;
  bool _loaded = false;

  /// [store] null = memory only, and the "remember" choice is not offered.
  // ignore: prefer_initializing_formals
  AdminPasswordVault({SecretStore? store, this.authenticate, this.radioId = 'unknown'}) : _store = store;

  String ref(String keyHex, {bool guest = false}) => '${guest ? 'admin.gpw' : 'admin.pw'}.v2.$radioId.${keyHex.toLowerCase()}';
  String _mem(String keyHex, bool guest) => ref(keyHex, guest: guest);

  /// The person can choose to remember passwords (a secure store exists).
  bool get canRemember => _store != null;

  /// Face ID can guard saved passwords (a secure store and a way to authenticate exist).
  bool get canFaceId => _store != null && authenticate != null;

  /// Reads the saved choices. Safe to call more than once.
  Future<bool> remembering() async {
    if (_store == null) return false;
    if (!_loaded) {
      _loaded = true;
      try {
        _remember = (await _store.read(_flagRef)) != null;
        _face = (await _store.read(_faceRef)) != null;
      } catch (_) {
        _remember = false;
        _face = false;
      }
    }
    return _remember;
  }

  Future<bool> faceIdOn() async {
    await remembering();
    return _face && canFaceId;
  }

  Future<void> setFaceId(bool on) async {
    final s = _store;
    if (s == null || authenticate == null) return;
    await remembering();
    _face = on;
    try {
      on ? await s.write(_faceRef, Uint8List.fromList([1])) : await s.delete(_faceRef);
    } catch (_) {}
  }

  Future<Set<String>> _index() async {
    try {
      final b = await _store?.read(_indexRef);
      if (b == null) return {};
      return utf8.decode(b).split('\n').where((e) => e.isNotEmpty).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _addIndex(String r) async {
    final i = await _index();
    if (i.add(r)) await _store!.write(_indexRef, Uint8List.fromList(utf8.encode(i.join('\n'))));
  }

  /// Off by default. Turning it off deletes every saved password (the index, plus [knownKeys] of the first scheme).
  Future<void> setRemember(bool on, {Iterable<String> knownKeys = const []}) async {
    final s = _store;
    if (s == null) return;
    _loaded = true;
    _remember = on;
    try {
      if (on) {
        await s.write(_flagRef, Uint8List.fromList([1]));
        for (final e in _memory.entries) {
          await s.write(e.key, Uint8List.fromList(utf8.encode(e.value)));
          await _addIndex(e.key);
        }
      } else {
        await wipe(knownKeys: knownKeys);
      }
    } catch (_) {
      // a secure store that fails leaves the password in memory only
    }
  }

  /// Deletes every saved password, the choices, and the index ("Forget saved passwords"). Memory is kept for this run.
  Future<void> wipe({Iterable<String> knownKeys = const []}) async {
    final s = _store;
    if (s == null) return;
    _remember = false;
    _face = false;
    _loaded = true;
    try {
      for (final r in await _index()) {
        await s.delete(r);
      }
      for (final k in _memory.keys) {
        await s.delete(k);
      }
      for (final k in knownKeys) {
        await s.delete(_legacyRef(k));
        await s.delete(ref(k));
        await s.delete(ref(k, guest: true));
      }
      await s.delete(_indexRef);
      await s.delete(_flagRef);
      await s.delete(_faceRef);
    } catch (_) {}
  }

  /// Keeps [password] for this app run (and in the secure store when remembering is on).
  Future<void> keep(String keyHex, String password, {bool guest = false}) async {
    final r = _mem(keyHex, guest);
    _memory[r] = password;
    if (await remembering()) {
      try {
        await _store!.write(r, Uint8List.fromList(utf8.encode(password)));
        await _addIndex(r);
      } catch (_) {}
    }
  }

  /// The saved password, or null. Releases one from the secure store only after Face ID when that is on; a first-scheme
  /// entry is moved to the new key on the way.
  Future<String?> recall(String keyHex, {bool guest = false}) async {
    final r = _mem(keyHex, guest);
    final m = _memory[r];
    if (m != null) return m;
    if (await remembering()) {
      try {
        var b = await _store!.read(r);
        if (b == null && !guest) {
          final old = await _store.read(_legacyRef(keyHex));
          if (old != null) {
            await _store.write(r, old);
            await _addIndex(r);
            await _store.delete(_legacyRef(keyHex));
            b = old;
          }
        }
        if (b != null) {
          if (_face && canFaceId && !await authenticate!()) return null;
          final v = utf8.decode(b);
          _memory[r] = v;
          return v;
        }
      } catch (_) {}
    }
    return null;
  }

  /// A saved password exists in the secure store for this node (does not release it, so no Face ID prompt).
  Future<bool> hasSaved(String keyHex, {bool guest = false}) async {
    if (_memory.containsKey(_mem(keyHex, guest))) return true;
    if (!await remembering()) return false;
    try {
      return await _store!.read(ref(keyHex, guest: guest)) != null || (!guest && await _store.read(_legacyRef(keyHex)) != null);
    } catch (_) {
      return false;
    }
  }

  /// Forgets one node's passwords everywhere.
  Future<void> forget(String keyHex) async {
    for (final g in [false, true]) {
      final r = _mem(keyHex, g);
      _memory.remove(r);
      try {
        await _store?.delete(r);
      } catch (_) {}
    }
    try {
      await _store?.delete(_legacyRef(keyHex));
    } catch (_) {}
  }

  /// Forgets every password held in memory (the secure store keeps its copies only while remembering is on).
  void clearMemory() => _memory.clear();

  @override
  String toString() => 'AdminPasswordVault(${_memory.length} in memory, remember: $_remember, faceId: $_face)';
}
