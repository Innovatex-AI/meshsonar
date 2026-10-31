// Backup and restore of the user's OWN chat data. Versioned JSON, optionally zipped, optionally encrypted with a passphrase.
//
//  * Channel secrets are NOT included unless the caller opts in ([BackupOptions.includeSecrets]).
//  * Restore merges: nothing existing is overwritten except contact fields the backup has newer data for; messages are
//    inserted by dedupe key, so restoring the same file twice (or onto the device it came from) adds nothing.
//  * Input is untrusted: sizes, counts, types and hex are checked; a bad entry is skipped and counted, never trusted.
//  * Nothing is uploaded. The caller hands the bytes to the share sheet.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'backup_crypto.dart';
import 'channel_secret.dart';
import 'db/contact_repository.dart';
import 'models.dart';
import 'store.dart';

class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);
  @override
  String toString() => message;
}

class BackupTooNew extends BackupFormatException {
  const BackupTooNew(int v) : super('this backup is format version $v; this MeshSonar understands up to ${ChatBackup.formatVersion}');
}

class BackupNeedsPassphrase extends BackupFormatException {
  const BackupNeedsPassphrase() : super('this backup is encrypted: a passphrase is required');
}

class BackupOptions {
  /// Channel secrets are the keys to private channels. Off by default; the UI must warn when turning it on.
  final bool includeSecrets;
  final bool includeMessages;

  /// Wardrive (system channel) traffic is noise; off by default.
  final bool includeSystemTraffic;
  const BackupOptions({this.includeSecrets = false, this.includeMessages = true, this.includeSystemTraffic = false});
}

enum BackupFile { json, zip }

class ImportReport {
  int contacts = 0;
  int channels = 0;
  int messages = 0;
  int duplicateMessages = 0;
  int skipped = 0;
  int secretsRestored = 0;

  /// Names of private channels that came without a secret: they exist but cannot be used until the key is added.
  final List<String> channelsNeedingSecret = [];
  final List<String> warnings = [];
  @override
  String toString() => 'ImportReport(contacts $contacts, channels $channels, messages $messages, duplicates $duplicateMessages, skipped $skipped, secrets $secretsRestored)';
}

class ChatBackup {
  static const String format = 'meshsonar-chat-backup';
  static const int formatVersion = 1;
  static const String _entryName = 'meshsonar-chat-backup.json';

  // Hostile-input limits.
  static const int maxFileBytes = 256 * 1024 * 1024;
  static const int maxJsonBytes = 128 * 1024 * 1024;
  static const int maxMessages = 1000000;
  static const int maxContacts = 100000;
  static const int maxChannels = 5000;
  static const int maxTextChars = 5000;

  final ChatStore store;
  final int Function() nowMs;
  final String appVersion;
  final String Function() newId;

  ChatBackup(this.store, {int Function()? nowMs, this.appVersion = '', required this.newId}) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  // ------------------------------------------------------------------ export

  Future<Map<String, dynamic>> exportMap(BackupOptions o) async {
    final db = store.db.raw;
    final channels = db.select('SELECT * FROM channels ORDER BY id').map((r) => r).toList();
    final chans = <Map<String, dynamic>>[];
    for (final r in channels) {
      final c = store.channels.getById(r['id'] as int)!;
      final m = <String, dynamic>{
        'id': c.id,
        'radioId': c.radioId,
        'slot': c.slot,
        'name': c.name,
        'kind': c.kind.name,
        'regionScope': c.regionScope,
        'sortOrder': c.sortOrder,
        'hashByte': c.hashByte,
      };
      if (o.includeSecrets) {
        final s = await store.channels.secretOf(c);
        if (s != null) m['secret'] = toHex(s);
      }
      chans.add(m);
    }
    final systemKeys = {for (final c in chans) if (c['kind'] == 'system') 'c:${c['id']}'};
    final contacts = db.select('SELECT * FROM contacts ORDER BY radio_id, pubkey').map(ContactRepository.fromRow).map((c) => {
          'radioId': c.radioId,
          'publicKey': c.publicKey,
          'type': c.type.code,
          'name': c.name,
          'customName': c.customName,
          'favourite': c.favourite,
          'blocked': c.blocked,
          'lat': c.lat,
          'lon': c.lon,
          'lastAdvertTs': c.lastAdvertTs,
          'lastMod': c.lastMod,
          'outPath': c.outPath == null ? null : toHex(c.outPath!),
          'outPathLen': c.outPathLen,
          'notes': c.notes,
          'source': c.source.name,
        }).toList();
    final convs = [
      for (final r in db.select('SELECT * FROM conversations'))
        if (o.includeSystemTraffic || !systemKeys.contains(r['conv_key']))
          {
            'convKey': r['conv_key'],
            'radioId': r['radio_id'],
            'notifyMode': r['notify_mode'],
            'mutedUntilMs': r['muted_until_ms'],
            'retentionDays': r['retention_days'],
            'pinned': (r['pinned'] as int) != 0,
          }
    ];
    final messages = <Map<String, dynamic>>[];
    if (o.includeMessages) {
      for (final m in store.messages.allForExport()) {
        if (!o.includeSystemTraffic && systemKeys.contains(m.convKey)) continue;
        messages.add({
          'radioId': m.radioId,
          'convKind': m.convKind.name,
          'convKey': m.convKey,
          'dir': m.isOutgoing ? 'out' : 'in',
          'senderName': m.senderName,
          'senderPrefix': m.senderPrefix,
          'tsSender': m.tsSender,
          'tsLocalMs': m.tsLocalMs,
          'text': m.text,
          'snr': m.snr,
          'pathLen': m.pathLen,
          'route': m.route?.name,
          'state': m.state.name,
          'attempt': m.attempt,
          'ackMs': m.ackMs,
          'repeatsHeard': m.repeatsHeard,
          'failReason': m.failReason?.name,
          'read': m.read,
          'txtType': m.txtType,
        });
      }
    }
    final drafts = store.drafts.all();
    final settings = {for (final r in db.select('SELECT key, value FROM settings')) r['key'] as String: r['value'] as String};
    return {
      'format': format,
      'version': formatVersion,
      'createdAt': DateTime.fromMillisecondsSinceEpoch(nowMs(), isUtc: true).toIso8601String(),
      'app': {'name': 'MeshSonar', 'version': appVersion},
      'includesSecrets': o.includeSecrets,
      'includesMessages': o.includeMessages,
      'settings': settings,
      'contacts': contacts,
      'channels': chans,
      'conversations': convs,
      'messages': messages,
      'drafts': drafts,
    };
  }

  /// Bytes ready for the share sheet. [passphrase] non-empty encrypts the whole file (zip or json inside).
  /// Suggested file names: `.meshsonar-chat.json`, `.meshsonar-chat.zip`, `.meshsonar-chat.enc`.
  Future<Uint8List> export(BackupOptions o, {BackupFile file = BackupFile.zip, String? passphrase, int? kdfIterations, bool useIsolate = true}) async {
    final json = Uint8List.fromList(utf8.encode(jsonEncode(await exportMap(o))));
    Uint8List body = json;
    if (file == BackupFile.zip) {
      final a = Archive()..addFile(ArchiveFile(_entryName, json.length, json));
      body = Uint8List.fromList(ZipEncoder().encode(a));
    }
    if (passphrase != null && passphrase.isNotEmpty) {
      return BackupCrypto.encrypt(body, passphrase, iterations: kdfIterations ?? BackupCrypto.defaultIterations, useIsolate: useIsolate);
    }
    return body;
  }

  // ------------------------------------------------------------------ import

  /// Reads a backup in any of the three forms and merges it into the store.
  Future<ImportReport> import(Uint8List bytes, {String? passphrase, bool useIsolate = true}) async {
    if (bytes.length > maxFileBytes) throw const BackupFormatException('file too large');
    var data = bytes;
    for (var layer = 0; layer < 3; layer++) {
      if (_isZip(data)) {
        data = _unzip(data);
        continue;
      }
      final head = _tryJson(data);
      if (head == null) throw const BackupFormatException('not a MeshSonar chat backup');
      if (BackupCrypto.looksEncrypted(head)) {
        if (passphrase == null || passphrase.isEmpty) throw const BackupNeedsPassphrase();
        try {
          data = await BackupCrypto.decrypt(head, passphrase, useIsolate: useIsolate);
        } on BackupWrongPassphrase {
          rethrow;
        } on BackupCryptoException catch (e) {
          throw BackupFormatException(e.message);
        }
        continue;
      }
      return _apply(head);
    }
    throw const BackupFormatException('not a MeshSonar chat backup');
  }

  static bool _isZip(Uint8List d) => d.length > 4 && d[0] == 0x50 && d[1] == 0x4b;

  static Uint8List _unzip(Uint8List d) {
    final Archive a;
    try {
      a = ZipDecoder().decodeBytes(d);
    } catch (_) {
      throw const BackupFormatException('damaged zip file');
    }
    final f = a.files.where((f) => f.isFile && f.name == _entryName).toList();
    if (f.length != 1) throw const BackupFormatException('the zip does not contain a chat backup');
    if (f.first.size > maxJsonBytes) throw const BackupFormatException('backup too large');
    final content = f.first.content;
    return Uint8List.fromList(content as List<int>);
  }

  static Map<String, dynamic>? _tryJson(Uint8List d) {
    if (d.length > maxJsonBytes) throw const BackupFormatException('backup too large');
    try {
      final j = jsonDecode(utf8.decode(d));
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  // ---- typed readers (hostile input)

  static String? _s(Object? v, [int max = 4096]) => v is String && v.length <= max ? v : null;
  static int? _i(Object? v) => v is int ? v : null;
  static double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
  static bool _b(Object? v) => v == true;
  static List<Map<String, dynamic>> _list(Object? v, int max, String what) {
    if (v == null) return const [];
    if (v is! List) throw BackupFormatException('$what is not a list');
    if (v.length > max) throw BackupFormatException('too many $what');
    return [for (final e in v) if (e is Map<String, dynamic>) e];
  }

  Future<ImportReport> _apply(Map<String, dynamic> j) async {
    if (j['format'] != format) throw const BackupFormatException('not a MeshSonar chat backup');
    final v = j['version'];
    if (v is! int || v < 1) throw const BackupFormatException('bad backup version');
    if (v > formatVersion) throw BackupTooNew(v);
    final report = ImportReport();
    final contacts = _list(j['contacts'], maxContacts, 'contacts');
    final channels = _list(j['channels'], maxChannels, 'channels');
    final messages = _list(j['messages'], maxMessages, 'messages');
    final convs = _list(j['conversations'], maxChannels + maxContacts, 'conversations');

    // Contacts: keep the newer lastMod; never downgrade a favourite/block the user set here.
    store.db.transaction(() {
      for (final m in contacts) {
        final key = _s(m['publicKey'], 64)?.toLowerCase();
        final radio = _s(m['radioId'], 64);
        final type = ContactType.fromCode(_i(m['type']));
        final name = _s(m['name'], 64);
        if (key == null || !isHex(key, 64) || radio == null || radio.isEmpty || type == null || name == null) {
          report.skipped++;
          continue;
        }
        final existing = store.contacts.get(radio, key);
        final inMod = _i(m['lastMod']) ?? 0;
        if (existing != null && (existing.lastMod ?? 0) >= inMod && inMod != 0) {
          continue; // ours is as new or newer
        }
        final pathHex = _s(m['outPath'], 200);
        store.contacts.upsert(Contact(
          radioId: radio,
          publicKey: key,
          type: type,
          name: name,
          customName: _s(m['customName'], 64),
          favourite: _b(m['favourite']) || (existing?.favourite ?? false),
          blocked: _b(m['blocked']) || (existing?.blocked ?? false),
          lat: _d(m['lat']),
          lon: _d(m['lon']),
          lastAdvertTs: _i(m['lastAdvertTs']),
          lastMod: _i(m['lastMod']),
          outPath: pathHex != null && isHex(pathHex) ? fromHex(pathHex) : null,
          outPathLen: _i(m['outPathLen']) ?? -1,
          notes: _s(m['notes'], 2000) ?? '',
          source: ContactSource.imported,
        ));
        report.contacts++;
      }
    });

    // Channels: match an existing one by name + hash, else create. Secrets go to the SecretStore.
    final idMap = <int, int>{};
    for (final m in channels) {
      final oldId = _i(m['id']);
      final radio = _s(m['radioId'], 64);
      final name = _s(m['name'], 64);
      final kind = ChannelKind.values.where((k) => k.name == m['kind']).firstOrNull;
      if (oldId == null || radio == null || radio.isEmpty || name == null || name.isEmpty || kind == null) {
        report.skipped++;
        continue;
      }
      final hashByte = _i(m['hashByte']);
      final secretHex = _s(m['secret'], 32);
      Uint8List? secret = secretHex != null && isHex(secretHex, 32) ? fromHex(secretHex) : null;
      if (secret == null && kind == ChannelKind.public) secret = publicChannelSecret16;
      if (secret == null && kind == ChannelKind.hashtag) secret = hashtagSecret16(name);
      final rows = store.db.raw.select('SELECT id FROM channels WHERE radio_id = ? AND lower(name) = lower(?) AND kind = ? AND coalesce(hash_byte, -1) = coalesce(?, -1)', [radio, name, kind.name, hashByte]);
      Channel? target = rows.isEmpty ? null : store.channels.getById(rows.first['id'] as int);
      var slot = _i(m['slot']);
      if (target == null) {
        if (slot != null && store.channels.bySlot(radio, slot) != null) slot = null; // the slot is taken here: keep it phone-only
        target = await store.channels.save(Channel(radioId: radio, slot: slot, name: name, kind: kind, hashByte: hashByte, regionScope: _s(m['regionScope'], 64), sortOrder: _i(m['sortOrder']) ?? 0), secret: secret);
        report.channels++;
        if (secretHex != null && secret != null) report.secretsRestored++;
      } else if (target.secretRef == null && secret != null) {
        target = await store.channels.save(target, secret: secret);
        report.secretsRestored++;
      }
      if (target.secretRef == null && kind == ChannelKind.private) report.channelsNeedingSecret.add(name);
      idMap[oldId] = target.id!;
    }

    String? mapConv(String? key) {
      if (key == null || key.length < 3 || key.length > 40) return null;
      if (key.startsWith('c:')) {
        final id = int.tryParse(key.substring(2));
        final n = id == null ? null : idMap[id];
        return n == null ? null : ConvKey.channel(n);
      }
      if ((key.startsWith('d:') || key.startsWith('r:')) && isHex(key.substring(2), 12)) return key.toLowerCase();
      return null;
    }

    store.db.transaction(() {
      for (final c in convs) {
        final key = mapConv(_s(c['convKey'], 40));
        final radio = _s(c['radioId'], 64);
        if (key == null || radio == null) {
          report.skipped++;
          continue;
        }
        final mode = NotifyMode.values.where((n) => n.name == c['notifyMode']).firstOrNull ?? NotifyMode.all;
        store.messages.ensureConversation(key, radio);
        // Keep this device's own settings if it already has non-default ones.
        final cur = store.messages.conversation(key)!;
        if (cur.notifyMode == NotifyMode.all && !cur.pinned && cur.retentionDays == null) {
          store.messages.setNotify(key, radio, mode, mutedUntilMs: _i(c['mutedUntilMs']));
          store.messages.setPinned(key, radio, _b(c['pinned']));
          store.messages.setRetentionDays(key, radio, _i(c['retentionDays']));
        }
      }

      for (final m in messages) {
        final conv = mapConv(_s(m['convKey'], 40));
        final radio = _s(m['radioId'], 64);
        final text = _s(m['text'], maxTextChars);
        final tsSender = _i(m['tsSender']);
        final tsLocal = _i(m['tsLocalMs']);
        final kind = ConvKind.values.where((k) => k.name == m['convKind']).firstOrNull;
        if (conv == null || radio == null || text == null || tsSender == null || tsLocal == null || kind == null || ConvKey.kindOf(conv) != kind) {
          report.skipped++;
          continue;
        }
        final outgoing = m['dir'] == 'out';
        final sender = _s(m['senderName'], 64);
        // Recompute the dedupe key against the (possibly renumbered) conversation key so a later live frame still matches.
        final raw = (!outgoing && kind == ConvKind.channel && sender != null) ? '$sender: $text' : text;
        var state = MessageState.values.where((s) => s.name == m['state']).firstOrNull ?? MessageState.received;
        FailReason? fail = FailReason.values.where((f) => f.name == m['failReason']).firstOrNull;
        if (state == MessageState.queued || state == MessageState.sending || state == MessageState.retrying) {
          state = MessageState.failed; // never resend someone's old queue on restore
          fail = FailReason.cancelled;
        }
        final msg = ChatMessage(
          id: newId(),
          radioId: radio,
          convKind: kind,
          convKey: conv,
          direction: outgoing ? Direction.outgoing : Direction.incoming,
          senderName: sender,
          senderPrefix: _s(m['senderPrefix'], 12),
          tsSender: tsSender,
          tsLocalMs: tsLocal,
          text: text,
          snr: _d(m['snr']),
          pathLen: _i(m['pathLen']),
          route: Route.values.where((r) => r.name == m['route']).firstOrNull,
          state: state,
          attempt: _i(m['attempt']) ?? 0,
          ackMs: _i(m['ackMs']),
          repeatsHeard: _i(m['repeatsHeard']) ?? 0,
          failReason: fail,
          dedupeKey: dedupeKeyFor(conv, tsSender, raw),
          read: _b(m['read']),
          txtType: _i(m['txtType']) ?? 0,
        );
        if (store.messages.insert(msg)) {
          report.messages++;
        } else {
          report.duplicateMessages++;
        }
      }
      final drafts = j['drafts'];
      if (drafts is Map<String, dynamic>) {
        for (final e in drafts.entries.take(maxChannels + maxContacts)) {
          final k = mapConv(e.key);
          final t = _s(e.value, maxTextChars);
          if (k != null && t != null && store.drafts.load(k) == null) store.drafts.save(k, t, nowMs());
        }
      }
      final settings = j['settings'];
      if (settings is Map<String, dynamic>) {
        final d = settings['retention_default_days'];
        if (d is String && int.tryParse(d) != null && store.db.setting('retention_default_days') == null) store.db.putSetting('retention_default_days', d);
      }
    });
    return report;
  }
}
