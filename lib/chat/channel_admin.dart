// ChannelAdmin: joining, creating, editing, sharing and deleting channels. A channel exists in two places: a slot on the
// radio (name + 16-byte secret; the radio can only hear channels that are in a slot) and a row on the phone (history,
// notify mode, region). Every change here writes the radio first and the phone second, so a failed radio write leaves
// nothing half-done. Pure Dart: the radio is reached through [ChannelRadio] (lib/chat/session_adapter.dart adapts a session).
//
// Every failure is a [ChannelAdminException] whose [message] is plain language for the person using the app.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'channel_secret.dart';
import 'mesh_links.dart';
import 'models.dart';
import 'store.dart';

/// One slot as the radio reports it.
class RadioSlot {
  final int index;
  final String name;
  final Uint8List secret;
  const RadioSlot(this.index, this.name, this.secret);
  bool get isEmpty => name.isEmpty && secret.every((b) => b == 0);
}

abstract interface class ChannelRadio {
  /// DEVICE_INFO max channels; null = not reported.
  int? get maxChannels;

  /// Every slot 0..max-1 (empty ones included).
  Future<List<RadioSlot>> slots();
  Future<void> write(int slot, String name, Uint8List secret16);
  Future<void> clear(int slot);
}

enum ChannelAdminError { invalidName, invalidSecret, notConnected, noFreeSlot, unsupported, radioFailed, duplicateName, notAllowed, notOnRadio, badLink }

class ChannelAdminException implements Exception {
  final ChannelAdminError error;
  final String message;
  const ChannelAdminException(this.error, this.message);
  @override
  String toString() => message;
}

/// Outcome of a join / create / import.
class ChannelJoin {
  final Channel channel;

  /// False when the phone (and radio) already had this channel and nothing was written.
  final bool created;
  const ChannelJoin(this.channel, this.created);
}

class ChannelAdmin {
  final ChatStore store;

  /// The connected radio's channel access, or null with no radio.
  final ChannelRadio? Function() radio;

  /// Name of the wardrive channel (settings): its slot is shown as the System channel, never as chat.
  final String Function() wardriveChannelName;

  /// The set of channels changed (the lists rebuild).
  final void Function() onChanged;
  final Random _rng;

  ChannelAdmin({required this.store, required this.radio, required this.wardriveChannelName, required this.onChanged, Random? random})
      : _rng = random ?? Random.secure();

  static const int maxNameBytes = MeshLinks.maxNameBytes;

  // ------------------------------------------------------------------ names

  /// "#Hamradio " -> "#hamradio". Throws for anything that is not letters, digits and dashes.
  static String normaliseHashtag(String input) {
    var n = input.trim().toLowerCase();
    while (n.startsWith('#')) {
      n = n.substring(1);
    }
    if (n.isEmpty) {
      throw const ChannelAdminException(ChannelAdminError.invalidName, 'Type a name after the #, for example #hamradio.');
    }
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(n)) {
      throw const ChannelAdminException(
          ChannelAdminError.invalidName, 'A # channel name can use letters, numbers and dashes only (no spaces). Capitals are turned into lower case.');
    }
    if (n.length + 1 > maxNameBytes) {
      throw const ChannelAdminException(ChannelAdminError.invalidName, 'That name is too long. Keep it under 30 characters.');
    }
    return '#$n';
  }

  static String checkPrivateName(String input) {
    final n = input.trim();
    if (n.isEmpty) throw const ChannelAdminException(ChannelAdminError.invalidName, 'Give the channel a name.');
    if (utf8.encode(n).length > maxNameBytes) {
      throw const ChannelAdminException(ChannelAdminError.invalidName, 'That name is too long. Keep it under 31 letters.');
    }
    for (final r in n.runes) {
      if (r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0)) {
        throw const ChannelAdminException(ChannelAdminError.invalidName, 'The name has a character the radio cannot store.');
      }
    }
    return n;
  }

  /// A 32-hex-character secret pasted by hand. Spaces and a leading 0x are tolerated.
  static Uint8List parseSecretHex(String input) {
    var s = input.trim().replaceAll(RegExp(r'\s'), '');
    if (s.toLowerCase().startsWith('0x')) s = s.substring(2);
    if (!isHex(s, 32)) {
      throw const ChannelAdminException(ChannelAdminError.invalidSecret, 'A channel secret is 32 letters and numbers from 0-9 and a-f. Check that you copied all of it.');
    }
    return fromHex(s);
  }

  // ------------------------------------------------------------------ joining

  Future<ChannelJoin> joinPublic(String radioId) => _join(radioId, name: 'Public', secret: publicChannelSecret16, kind: ChannelKind.public);

  Future<ChannelJoin> joinHashtag(String radioId, String name, {String? regionScope}) async {
    final n = normaliseHashtag(name);
    return await _join(radioId, name: n, secret: hashtagSecret16(n), kind: ChannelKind.hashtag, regionScope: regionScope);
  }

  /// A private channel from a name and a secret somebody gave you (32 hex characters).
  Future<ChannelJoin> joinPrivate(String radioId, String name, String secretHex, {String? regionScope}) async {
    final n = checkPrivateName(name);
    final secret = parseSecretHex(secretHex);
    return await _join(radioId, name: n, secret: secret, kind: classifyChannel(n, secret), regionScope: regionScope);
  }

  /// A brand new private channel with a random secret. Share it afterwards with [shareLink].
  Future<ChannelJoin> createPrivate(String radioId, String name, {String? regionScope}) async {
    final n = checkPrivateName(name);
    final dup = store.channels.list(radioId, includeSystem: false).any((c) => c.name.toLowerCase() == n.toLowerCase());
    if (dup) {
      throw ChannelAdminException(ChannelAdminError.duplicateName, 'You already have a channel called "$n". Pick another name.');
    }
    final secret = Uint8List.fromList(List<int>.generate(16, (_) => _rng.nextInt(256)));
    return await _join(radioId, name: n, secret: secret, kind: ChannelKind.private, regionScope: regionScope);
  }

  /// A pasted or scanned `meshcore://channel/add?...` link. Contact and advert links are not channels: the caller handles those.
  Future<ChannelJoin> joinFromLink(String radioId, String link) async {
    final p = MeshLinks.parse(link);
    switch (p) {
      case ChannelLink():
        return await _join(radioId, name: p.name, secret: p.secret, kind: classifyChannel(p.name, p.secret), regionScope: p.regionScope);
      case ContactLink():
      case AdvertLink():
        throw const ChannelAdminException(ChannelAdminError.badLink, 'That link is for a person, not a channel. Add it from Contacts.');
      case LinkParseError():
        throw ChannelAdminException(ChannelAdminError.badLink, describeLinkError(p.error));
    }
  }

  static String describeLinkError(LinkError e) => switch (e) {
        LinkError.empty => 'Paste a meshcore:// link first.',
        LinkError.tooLong => 'That text is too long to be a MeshCore link.',
        LinkError.notMeshcore => 'That is not a MeshCore link. It should start with meshcore://',
        LinkError.unknownKind => 'MeshSonar does not know this kind of MeshCore link.',
        LinkError.missingField => 'The link is missing the channel name or secret.',
        LinkError.badSecret => 'The secret in the link is not valid. A channel secret is 32 letters and numbers.',
        LinkError.badPublicKey => 'The key in the link is not valid.',
        LinkError.badName => 'The name in the link has characters the radio cannot store.',
        LinkError.badType => 'The link has a type MeshSonar does not know.',
        LinkError.badScope => 'The region in the link is not valid.',
        LinkError.badAdvert => 'That advert link looks damaged.',
      };

  Future<ChannelJoin> _join(String radioId, {required String name, required Uint8List secret, required ChannelKind kind, String? regionScope}) async {
    final hash = channelHashByte(secret);
    // Already here? The same secret on this radio is the same channel whatever it is called.
    for (final c in store.channels.list(radioId, includeSystem: false)) {
      if (c.hashByte != hash) continue;
      final s = await store.channels.secretOf(c);
      if (s != null && _same(s, secret)) {
        var out = c;
        if (c.slot == null) out = await _placeOnRadio(c, secret); // known on the phone, evicted from the radio: put it back
        if (regionScope != null && out.regionScope != regionScope) out = await store.channels.save(out.copyWith(regionScope: regionScope));
        onChanged();
        return ChannelJoin(out, c.slot == null && out.slot != null);
      }
    }
    final r = _needRadio();
    final slots = await _readSlots(r);
    // The radio may already hold it (set up in another app): adopt that slot instead of writing a second copy.
    for (final s in slots) {
      if (!s.isEmpty && _same(s.secret, secret)) {
        final saved = await store.channels.save(_rowFor(radioId, s.index, s.name.isEmpty ? name : s.name, kind, regionScope, existing: store.channels.bySlot(radioId, s.index)), secret: secret);
        onChanged();
        return ChannelJoin(saved, true);
      }
    }
    final slot = _freeSlot(slots, r);
    await _write(r, slot, name, secret);
    // A stale row that still claims this slot (another app replaced the channel) gives it up.
    final stale = store.channels.bySlot(radioId, slot);
    if (stale != null) await store.channels.save(stale.copyWith(clearSlot: true));
    final saved = await store.channels.save(Channel(radioId: radioId, slot: slot, name: name, kind: kind, regionScope: regionScope), secret: secret);
    onChanged();
    return ChannelJoin(saved, true);
  }

  Channel _rowFor(String radioId, int slot, String name, ChannelKind kind, String? regionScope, {Channel? existing}) =>
      (existing ?? Channel(radioId: radioId, name: name, kind: kind)).copyWith(slot: slot, name: name, kind: kind, regionScope: regionScope ?? existing?.regionScope);

  Future<Channel> _placeOnRadio(Channel c, Uint8List secret) async {
    final r = _needRadio();
    final slots = await _readSlots(r);
    final slot = _freeSlot(slots, r);
    await _write(r, slot, c.name, secret);
    return store.channels.save(c.copyWith(slot: slot));
  }

  // ------------------------------------------------------------------ editing and deleting

  /// Renames a private channel and/or changes its region. Hashtag and Public channels keep their name (it is their key).
  Future<Channel> edit(Channel c, {String? name, Object? regionScope = _keep}) async {
    if (c.isSystem) throw const ChannelAdminException(ChannelAdminError.notAllowed, 'The wardrive channel is managed by MeshSonar and cannot be edited here.');
    var out = c;
    if (name != null && name.trim() != c.name) {
      if (c.kind != ChannelKind.private) {
        throw const ChannelAdminException(ChannelAdminError.notAllowed, 'This channel\'s name is part of its key, so it cannot be renamed. Create a new private channel instead.');
      }
      final n = checkPrivateName(name);
      final dup = store.channels.list(c.radioId, includeSystem: false).any((o) => o.id != c.id && o.name.toLowerCase() == n.toLowerCase());
      if (dup) throw ChannelAdminException(ChannelAdminError.duplicateName, 'You already have a channel called "$n".');
      if (c.slot != null) {
        final secret = await store.channels.secretOf(c);
        if (secret == null) throw const ChannelAdminException(ChannelAdminError.notOnRadio, 'The secret of this channel is missing on this phone, so it cannot be rewritten to the radio.');
        await _write(_needRadio(), c.slot!, n, secret);
      }
      out = out.copyWith(name: n);
    }
    if (!identical(regionScope, _keep)) {
      final s = (regionScope as String?)?.trim();
      out = out.copyWith(regionScope: (s == null || s.isEmpty) ? null : s);
    }
    final saved = await store.channels.save(out);
    onChanged();
    return saved;
  }

  /// Removes the channel from the radio (its slot is emptied) and from the phone, with its history and its secret.
  Future<void> delete(Channel c) async {
    if (c.isSystem) throw const ChannelAdminException(ChannelAdminError.notAllowed, 'The wardrive channel is managed by MeshSonar and cannot be deleted here.');
    if (c.slot != null) {
      final r = _needRadio();
      try {
        await r.clear(c.slot!);
      } catch (e) {
        throw _radioError('remove the channel', e);
      }
    }
    await store.channels.delete(c.id!);
    onChanged();
  }

  // ------------------------------------------------------------------ sharing

  /// The `meshcore://channel/add` link (also the text of the QR code). Needs the secret on this phone.
  Future<String> shareLink(Channel c) async {
    final secret = await store.channels.secretOf(c);
    if (secret == null) throw const ChannelAdminException(ChannelAdminError.notOnRadio, 'The secret of this channel is not on this phone, so it cannot be shared.');
    return MeshLinks.encodeChannel(name: c.name, secret: secret, regionScope: c.regionScope);
  }

  /// The secret as 32 hex characters, for people who paste it by hand.
  Future<String?> secretHex(Channel c) async {
    final s = await store.channels.secretOf(c);
    return s == null ? null : toHex(s);
  }

  // ------------------------------------------------------------------ radio <-> phone

  /// Brings the phone's channel rows in line with the radio's slots (run on every connect). The radio wins for what is on
  /// air: a slot another app rewrote becomes a new row and the old row keeps its history but loses the slot. Channels set
  /// up in another app appear here. The wardrive channel becomes the System channel.
  Future<void> syncFromRadio(String radioId) async {
    final r = radio();
    if (r == null) return;
    final List<RadioSlot> slots;
    try {
      slots = await r.slots();
    } catch (_) {
      return; // best effort: the lists still show what the phone knows
    }
    final wardrive = wardriveChannelName().trim().toLowerCase();
    final wardriveSecret = wardrive.startsWith('#') ? hashtagSecret16(wardrive) : null;
    var changed = false;
    final present = <int>{};
    for (final s in slots) {
      if (s.isEmpty) continue;
      present.add(s.index);
      final existing = store.channels.bySlot(radioId, s.index);
      var kind = classifyChannel(s.name, s.secret);
      final isWardrive = s.name.trim().toLowerCase() == wardrive || (wardriveSecret != null && _same(s.secret, wardriveSecret));
      if (isWardrive) kind = ChannelKind.system;
      if (existing != null) {
        final stored = await store.channels.secretOf(existing);
        final sameKey = stored != null && _same(stored, s.secret);
        if (sameKey || (stored == null && existing.hashByte == null)) {
          final wantKind = existing.isSystem && !isWardrive ? kind : (isWardrive ? ChannelKind.system : existing.kind);
          if (existing.name != s.name || existing.kind != wantKind || stored == null) {
            await store.channels.save(existing.copyWith(name: s.name, kind: wantKind), secret: stored == null ? s.secret : null);
            changed = true;
          }
          continue;
        }
        // Another app put a different channel into this slot.
        await store.channels.save(existing.copyWith(clearSlot: true));
        changed = true;
      }
      // Same channel under another slot on the phone? (moved) else a new row.
      final moved = await _findBySecret(radioId, s.secret);
      if (moved != null) {
        await store.channels.save(moved.copyWith(slot: s.index, name: s.name, kind: isWardrive ? ChannelKind.system : moved.kind));
      } else {
        await store.channels.save(Channel(radioId: radioId, slot: s.index, name: s.name, kind: kind, sortOrder: s.index), secret: s.secret);
      }
      changed = true;
    }
    // Rows that claim a slot the radio no longer has: kept (history), shown as "not on the radio".
    for (final c in store.channels.list(radioId)) {
      if (c.slot != null && !present.contains(c.slot)) {
        await store.channels.save(c.copyWith(clearSlot: true));
        changed = true;
      }
    }
    if (changed) onChanged();
  }

  Future<Channel?> _findBySecret(String radioId, Uint8List secret) async {
    final hash = channelHashByte(secret);
    for (final c in store.channels.list(radioId)) {
      if (c.hashByte != hash) continue;
      final s = await store.channels.secretOf(c);
      if (s != null && _same(s, secret)) return c;
    }
    return null;
  }

  /// How many channel slots the radio has and how many are taken (for the "x of y" line). Null without a radio.
  Future<({int used, int total})?> slotUsage() async {
    final r = radio();
    if (r == null) return null;
    try {
      final s = await r.slots();
      return (used: s.where((e) => !e.isEmpty).length, total: s.length);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ helpers

  ChannelRadio _needRadio() {
    final r = radio();
    if (r == null) {
      throw const ChannelAdminException(
          ChannelAdminError.notConnected, 'Connect your radio first. A channel lives in one of the radio\'s channel slots, so the radio has to be connected to change it.');
    }
    return r;
  }

  Future<List<RadioSlot>> _readSlots(ChannelRadio r) async {
    if (r.maxChannels != null && r.maxChannels! <= 0) {
      throw const ChannelAdminException(ChannelAdminError.unsupported, 'This radio\'s firmware has no channel slots, so channels cannot be added from the app.');
    }
    try {
      return await r.slots();
    } catch (e) {
      throw _radioError('read the channel list', e);
    }
  }

  int _freeSlot(List<RadioSlot> slots, ChannelRadio r) {
    for (final s in slots) {
      if (s.isEmpty) return s.index;
    }
    final total = slots.length;
    throw ChannelAdminException(
        ChannelAdminError.noFreeSlot,
        'Your radio has no free channel slot ($total of $total are used). Delete a channel you do not need, then try again.');
  }

  Future<void> _write(ChannelRadio r, int slot, String name, Uint8List secret) async {
    try {
      await r.write(slot, name, secret);
    } catch (e) {
      throw _radioError('save the channel', e);
    }
  }

  ChannelAdminException _radioError(String what, Object e) {
    final t = e.toString().toLowerCase();
    if (t.contains('unsupported') || t.contains('not supported')) {
      return ChannelAdminException(ChannelAdminError.unsupported, 'This radio\'s firmware does not support changing channels from the app, so it could not $what. Nothing was changed.');
    }
    if (t.contains('not connected') || t.contains('disconnect') || t.contains('closed')) {
      return ChannelAdminException(ChannelAdminError.notConnected, 'The radio disconnected before it could $what. Reconnect and try again. Nothing was changed.');
    }
    return ChannelAdminException(ChannelAdminError.radioFailed, 'The radio did not accept the change, so it could not $what. Nothing was changed. Try again; if it keeps failing, restart the radio.');
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

const Object _keep = Object();
