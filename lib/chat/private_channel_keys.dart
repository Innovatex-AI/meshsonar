// The private channel keys this phone holds, for the observer's third gate (MeshTrack plan section 15, WS-OUT): a group
// packet whose MAC verifies under any of them never goes to an outside MQTT feed or to MeshSonar, MeshTrack group or not.
//
// Secrets live in the SecretStore (the Keychain), which is read asynchronously, while the observer decides per packet
// synchronously. So the keys are cached here, keyed by their SecretStore reference, and the channel list is read fresh on
// every lookup: a channel added, removed or re-keyed is seen at once. A private channel whose key has not been read yet
// makes [keysFor] answer null for its on-air hash, and the observer then drops the packet (fail closed) while the key loads.
import 'dart:async';
import 'dart:typed_data';

import 'channel_secret.dart';
import 'models.dart';

class PrivateChannelKeys {
  /// The channels on the current radio (every kind; only private and system ones are used).
  final List<Channel> Function() channels;

  /// Reads one channel's 16-byte secret (null when the store has none).
  final Future<Uint8List?> Function(Channel c) secretOf;

  PrivateChannelKeys({required this.channels, required this.secretOf});

  /// SecretStore reference -> the key read for it, or null when that key is not private (Public, or a # channel's own
  /// derived key) or the store had none.
  final Map<String, Uint8List?> _cache = {};
  final Map<String, Future<void>> _loading = {};

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// A key anyone can know is not private: the Public key, or a # name's derived key on that # channel (the drive
  /// channel's own gate covers the wardrive channel).
  static bool _isPrivateKey(Channel c, List<int> key) {
    if (key.length < 16) return false;
    if (_same(key.sublist(0, 16), publicChannelSecret16)) return false;
    final n = c.name.trim();
    if (n.startsWith('#') && _same(key.sublist(0, 16), hashtagSecret16(n))) return false;
    return true;
  }

  static bool _candidate(Channel c) =>
      (c.kind == ChannelKind.private || c.kind == ChannelKind.system) && c.secretRef != null;

  /// The private keys whose one-byte on-air hash is [hash]. Empty when the phone holds none with that hash (the cheap
  /// path: no MAC is tried). Null when a private channel that may have this hash has a key not read yet: the caller
  /// must treat the packet as private.
  List<Uint8List>? keysFor(int hash) {
    final out = <Uint8List>[];
    var pending = false;
    for (final c in channels()) {
      if (!_candidate(c)) continue;
      if (c.hashByte != null && c.hashByte != hash) continue;
      final ref = c.secretRef!;
      if (!_cache.containsKey(ref)) {
        _load(c);
        pending = true;
        continue;
      }
      final k = _cache[ref];
      if (k == null) continue;
      final kh = channelHashByte(k);
      if (c.hashByte != null && kh != c.hashByte) {
        // Re-keyed under the same reference: read it again, fail closed meanwhile.
        _cache.remove(ref);
        _load(c);
        pending = true;
        continue;
      }
      if (kh == hash) out.add(k);
    }
    return pending ? null : out;
  }

  void _load(Channel c) {
    final ref = c.secretRef!;
    _loading[ref] ??= () async {
      await Future<void>.value(); // registered in _loading before the body can finish
      try {
        final k = await secretOf(c);
        _cache[ref] = k != null && _isPrivateKey(c, k) ? Uint8List.fromList(k.sublist(0, 16)) : null;
      } catch (_) {
        // Not cached: the next lookup tries again (and fails closed until then).
      } finally {
        _loading.remove(ref);
      }
    }();
  }

  /// Forgets every key and reads the current channels' keys again (a channel list change, a new radio).
  Future<void> refresh() async {
    _cache.clear();
    for (final c in channels()) {
      if (_candidate(c)) _load(c);
    }
    await Future.wait(_loading.values.toList());
  }

  /// Drops every cached key (detach, a wipe of chat data).
  void clear() => _cache.clear();
}
