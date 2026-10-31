import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../channel_secret.dart';
import '../models.dart';
import '../secret_store.dart';
import 'chat_database.dart';

/// Channels. The secret goes to the [SecretStore]; SQLite keeps only the reference and the one-byte on-air hash.
class ChannelRepository {
  final ChatDatabase db;
  final SecretStore secrets;
  ChannelRepository(this.db, this.secrets);

  static Channel fromRow(Row r) => Channel(
        id: r['id'] as int,
        radioId: r['radio_id'] as String,
        slot: r['slot'] as int?,
        name: r['name'] as String,
        kind: ChannelKind.values.firstWhere((k) => k.name == r['kind'], orElse: () => ChannelKind.private),
        secretRef: r['secret_ref'] as String?,
        hashByte: r['hash_byte'] as int?,
        regionScope: r['region_scope'] as String?,
        sortOrder: r['sort_order'] as int,
      );

  /// Creates or updates a channel. Identity: the same (radioId, slot) if a slot is given, else (radioId, name, kind).
  /// [secret] (16 bytes) is written to the SecretStore; pass null to keep the stored one.
  Future<Channel> save(Channel c, {Uint8List? secret}) async {
    if (secret != null && secret.length != 16) throw ArgumentError('channel secret must be 16 bytes');
    final existing = c.id != null ? getById(c.id!) : _find(c);
    var ref = existing?.secretRef ?? c.secretRef;
    if (secret != null) {
      ref ??= 'chan-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_n++}';
      await secrets.write(ref, secret);
    }
    final hash = secret != null ? channelHashByte(secret) : (c.hashByte ?? existing?.hashByte);
    if (existing == null) {
      db.raw.execute(
          'INSERT INTO channels(radio_id, slot, name, kind, secret_ref, hash_byte, region_scope, sort_order) VALUES (?,?,?,?,?,?,?,?)',
          [c.radioId, c.slot, c.name, c.kind.name, ref, hash, c.regionScope, c.sortOrder]);
      return fromRow(db.raw.select('SELECT * FROM channels WHERE id = last_insert_rowid()').first);
    }
    db.raw.execute('UPDATE channels SET slot=?, name=?, kind=?, secret_ref=?, hash_byte=?, region_scope=?, sort_order=? WHERE id = ?',
        [c.slot, c.name, c.kind.name, ref, hash, c.regionScope, c.sortOrder, existing.id]);
    return getById(existing.id!)!;
  }

  static int _n = 0;

  Channel? _find(Channel c) {
    if (c.slot != null) {
      final r = db.raw.select('SELECT * FROM channels WHERE radio_id = ? AND slot = ?', [c.radioId, c.slot]);
      if (r.isNotEmpty) return fromRow(r.first);
    }
    final r = db.raw.select('SELECT * FROM channels WHERE radio_id = ? AND lower(name) = lower(?) AND kind = ? AND slot IS NULL', [c.radioId, c.name, c.kind.name]);
    return r.isEmpty ? null : fromRow(r.first);
  }

  Channel? getById(int id) {
    final r = db.raw.select('SELECT * FROM channels WHERE id = ?', [id]);
    return r.isEmpty ? null : fromRow(r.first);
  }

  Channel? bySlot(String radioId, int slot) {
    final r = db.raw.select('SELECT * FROM channels WHERE radio_id = ? AND slot = ?', [radioId, slot]);
    return r.isEmpty ? null : fromRow(r.first);
  }

  List<Channel> list(String radioId, {bool includeSystem = true}) => db.raw
      .select('SELECT * FROM channels WHERE radio_id = ? ${includeSystem ? '' : "AND kind != 'system'"} ORDER BY sort_order, coalesce(slot, 999), id', [radioId])
      .map(fromRow)
      .toList();

  List<Channel> systemChannels(String radioId) =>
      db.raw.select("SELECT * FROM channels WHERE radio_id = ? AND kind = 'system' ORDER BY id", [radioId]).map(fromRow).toList();

  Future<Uint8List?> secretOf(Channel c) async => c.secretRef == null ? null : secrets.read(c.secretRef!);

  /// Removes the channel row, its secret, its messages and conversation state.
  Future<void> delete(int id) async {
    final c = getById(id);
    if (c == null) return;
    db.transaction(() {
      db.raw.execute('DELETE FROM messages WHERE conv_key = ?', [ConvKey.channel(id)]);
      db.raw.execute('DELETE FROM conversations WHERE conv_key = ?', [ConvKey.channel(id)]);
      db.raw.execute('DELETE FROM drafts WHERE conv_key = ?', [ConvKey.channel(id)]);
      db.raw.execute('DELETE FROM system_stats WHERE channel_id = ?', [id]);
      db.raw.execute('DELETE FROM channels WHERE id = ?', [id]);
    });
    if (c.secretRef != null) await secrets.delete(c.secretRef!);
  }
}
