// Where a repeater or room password lives between screens. By default it lives ONLY in memory (this object), so it is gone
// when the app closes. If - and only if - the person turns on "Remember passwords on this phone", passwords are also kept in
// the device's secure store (iOS Keychain, this device only, never synced, never uploaded) and turning it off wipes them.
// A password is never written anywhere else: not to logs, not to SQLite, not to the server. Pure Dart.
import 'dart:convert';
import 'dart:typed_data';

import '../chat/secret_store.dart';

class AdminPasswordVault {
  static const String _flagRef = 'admin.remember';
  static String _ref(String keyHex) => 'admin.pw.${keyHex.toLowerCase()}';

  final SecretStore? _store;
  final Map<String, String> _memory = {};
  bool _remember = false;
  bool _loaded = false;

  /// [store] null = memory only, and the "remember" choice is not offered.
  // ignore: prefer_initializing_formals
  AdminPasswordVault({SecretStore? store}) : _store = store;

  /// The person can choose to remember passwords (a secure store exists).
  bool get canRemember => _store != null;

  /// Reads the saved choice. Safe to call more than once.
  Future<bool> remembering() async {
    if (_store == null) return false;
    if (!_loaded) {
      _loaded = true;
      try {
        _remember = (await _store.read(_flagRef)) != null;
      } catch (_) {
        _remember = false;
      }
    }
    return _remember;
  }

  /// Off by default. Turning it off deletes every saved password.
  Future<void> setRemember(bool on, {Iterable<String> knownKeys = const []}) async {
    final s = _store;
    if (s == null) return;
    _loaded = true;
    _remember = on;
    try {
      if (on) {
        await s.write(_flagRef, Uint8List.fromList([1]));
        for (final e in _memory.entries) {
          await s.write(_ref(e.key), Uint8List.fromList(utf8.encode(e.value)));
        }
      } else {
        await s.delete(_flagRef);
        for (final k in {..._memory.keys, ...knownKeys}) {
          await s.delete(_ref(k));
        }
      }
    } catch (_) {
      // a secure store that fails leaves the password in memory only
    }
  }

  /// Keeps [password] for this app run (and in the secure store when remembering is on).
  Future<void> keep(String keyHex, String password) async {
    final k = keyHex.toLowerCase();
    _memory[k] = password;
    if (await remembering()) {
      try {
        await _store!.write(_ref(k), Uint8List.fromList(utf8.encode(password)));
      } catch (_) {}
    }
  }

  /// The saved password, or null.
  Future<String?> recall(String keyHex) async {
    final k = keyHex.toLowerCase();
    final m = _memory[k];
    if (m != null) return m;
    if (await remembering()) {
      try {
        final b = await _store!.read(_ref(k));
        if (b != null) {
          final v = utf8.decode(b);
          _memory[k] = v;
          return v;
        }
      } catch (_) {}
    }
    return null;
  }

  /// Forgets one password everywhere.
  Future<void> forget(String keyHex) async {
    final k = keyHex.toLowerCase();
    _memory.remove(k);
    try {
      await _store?.delete(_ref(k));
    } catch (_) {}
  }

  /// Forgets every password held in memory (the secure store keeps its copies only while remembering is on).
  void clearMemory() => _memory.clear();

  @override
  String toString() => 'AdminPasswordVault(${_memory.length} in memory, remember: $_remember)';
}
