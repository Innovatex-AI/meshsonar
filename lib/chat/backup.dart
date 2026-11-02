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

import '../radio/inbound.dart' show RadioChannel, RadioContact;
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

// ---------------------------------------------------------------------------------------------------------------------
// Radio backup (WP12): the radio's own identity key, contact table and channel slots, in ONE passphrase-encrypted file.
//
//  * The file only ever exists encrypted (PBKDF2-HMAC-SHA256 600k -> AES-256-GCM, [BackupCrypto]); there is no function that
//    writes the key in clear. The identity key is the radio: whoever opens the file and has the passphrase can BE this radio.
//  * The key is never logged: [RadioBackupData.toString] redacts it, and callers zero the bytes ([RadioBackupData.wipe]) when done.
//  * Input is untrusted: sizes, counts and hex are checked on the way in; a bad entry is dropped and counted.
//  * The inner JSON has its own `format`, so a radio backup is not mistaken for a chat backup (and the reverse).

class RadioBackupData {
  final String radioName;
  final String publicKeyHex;
  final int createdMs;

  /// 64 bytes, or null when the firmware refused to export it (the backup then holds contacts and channels only).
  Uint8List? identityKey;
  final List<RadioContact> contacts;
  final List<RadioChannel> channels;

  /// Entries dropped as invalid when this was read from a file.
  final int skipped;
  RadioBackupData({
    required this.radioName,
    required this.publicKeyHex,
    required this.createdMs,
    this.identityKey,
    this.contacts = const [],
    this.channels = const [],
    this.skipped = 0,
  });

  bool get hasIdentity => identityKey != null;

  /// Overwrites the key in memory. Call when the backup has been written or restored.
  void wipe() {
    identityKey?.fillRange(0, identityKey!.length, 0);
    identityKey = null;
  }

  @override
  String toString() => 'RadioBackupData($radioName, identity: ${hasIdentity ? '<redacted>' : 'none'}, contacts ${contacts.length}, channels ${channels.length})';
}

abstract final class RadioBackup {
  static const String format = 'meshsonar-radio-backup';
  static const int formatVersion = 1;
  static const int minPassphraseChars = 10;
  static const int maxContacts = 20000;
  static const int maxChannels = 256;

  /// Why [p] cannot protect a radio identity, or null.
  static String? passphraseProblem(String p) {
    if (p.trim() != p) return 'The passphrase cannot start or end with a space.';
    if (p.length < minPassphraseChars) return 'Use at least $minPassphraseChars characters. Three or four random words work well.';
    if (RegExp(r'^(.)\1+$').hasMatch(p)) return 'That is one character repeated. Use a real passphrase.';
    return null;
  }

  /// The encrypted file bytes (JSON envelope, see [BackupCrypto]). Set [useIsolate] false in tests and pass few [iterations].
  static Future<Uint8List> seal(RadioBackupData d, String passphrase, {int iterations = BackupCrypto.defaultIterations, bool useIsolate = true}) {
    final problem = passphraseProblem(passphrase);
    if (problem != null) throw ArgumentError(problem);
    final k = d.identityKey;
    if (k != null && k.length != 64) throw ArgumentError('an identity key is 64 bytes');
    final plain = utf8.encode(jsonEncode({
      'format': format,
      'version': formatVersion,
      'createdMs': d.createdMs,
      'radio': {'name': d.radioName, 'publicKey': d.publicKeyHex},
      if (k != null) 'identity': {'privateKey': base64.encode(k)},
      'contacts': [
        for (final c in d.contacts)
          {
            'key': c.publicKeyHex,
            'type': c.type,
            'flags': c.flags,
            'outPathLen': c.outPathLen,
            'outPath': c.outPath.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
            'name': c.name,
            'lastAdvert': c.lastAdvert,
            if (c.lat != null && c.lon != null) 'lat': c.lat,
            if (c.lat != null && c.lon != null) 'lon': c.lon,
            'lastMod': c.lastMod,
          }
      ],
      'channels': [
        for (final ch in d.channels)
          if (!ch.isEmpty) {'index': ch.index, 'name': ch.name, 'secret': ch.secret.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}
      ],
    }));
    return BackupCrypto.encrypt(Uint8List.fromList(plain), passphrase, iterations: iterations, useIsolate: useIsolate);
  }

  /// Decrypts and validates [file]. Throws [BackupWrongPassphrase] for a wrong passphrase or damage, [BackupFormatException]
  /// for something that is not a radio backup (including a chat backup).
  static Future<RadioBackupData> open(Uint8List file, String passphrase, {bool useIsolate = true}) async {
    if (file.length > ChatBackup.maxFileBytes) throw const BackupFormatException('this file is too large to be a radio backup');
    final Object? env;
    try {
      env = jsonDecode(utf8.decode(file));
    } catch (_) {
      throw const BackupFormatException('this is not a MeshSonar backup file');
    }
    if (env is! Map<String, dynamic> || !BackupCrypto.looksEncrypted(env)) {
      throw const BackupFormatException('this is not an encrypted MeshSonar backup. Radio backups are always encrypted.');
    }
    final Uint8List plain;
    try {
      plain = await BackupCrypto.decrypt(env, passphrase, useIsolate: useIsolate);
    } on BackupCryptoException catch (e) {
      if (e is BackupWrongPassphrase) rethrow;
      throw BackupFormatException(e.message);
    }
    try {
      return _parse(plain);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  static Uint8List _unhex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

  static RadioBackupData _parse(Uint8List plain) {
    final Object? j;
    try {
      j = jsonDecode(utf8.decode(plain));
    } catch (_) {
      throw const BackupFormatException('the backup is damaged');
    }
    if (j is! Map<String, dynamic>) throw const BackupFormatException('the backup is damaged');
    if (j['format'] == ChatBackup.format) throw const BackupFormatException('this is a chat backup, not a radio backup');
    if (j['format'] != format) throw const BackupFormatException('this is not a radio backup');
    final v = j['version'];
    if (v is! int || v > formatVersion) throw const BackupFormatException('this backup was made by a newer MeshSonar');
    final radio = j['radio'];
    if (radio is! Map<String, dynamic>) throw const BackupFormatException('the backup is damaged');
    final pk = radio['publicKey'];
    if (pk is! String || !_hex64.hasMatch(pk)) throw const BackupFormatException('the backup has no valid radio key');
    var skipped = 0;
    Uint8List? key;
    final id = j['identity'];
    if (id is Map<String, dynamic>) {
      try {
        final b = base64.decode(id['privateKey'] as String);
        if (b.length != 64) throw const FormatException();
        key = Uint8List.fromList(b);
      } catch (_) {
        throw const BackupFormatException('the identity key in the backup is damaged');
      }
    }
    final contacts = <RadioContact>[];
    final cj = j['contacts'];
    if (cj is List) {
      for (final e in cj.take(maxContacts)) {
        if (e is! Map<String, dynamic>) {
          skipped++;
          continue;
        }
        final k = e['key'], t = e['type'], name = e['name'], path = e['outPath'];
        final pl = e['outPathLen'];
        if (k is! String || !_hex64.hasMatch(k) || t is! int || t < 0 || t > 4 || name is! String || path is! String || pl is! int || pl < 0 || pl > 0xFF) {
          skipped++;
          continue;
        }
        if (path.length > 128 || path.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(path)) {
          skipped++;
          continue;
        }
        final lat = e['lat'], lon = e['lon'];
        contacts.add(RadioContact(
          publicKeyHex: k,
          type: t,
          flags: (e['flags'] is int ? e['flags'] as int : 0) & 0xFF,
          outPathLen: pl,
          outPath: _unhex(path),
          name: name.length > 64 ? name.substring(0, 64) : name,
          lastAdvert: e['lastAdvert'] is int ? e['lastAdvert'] as int : 0,
          lat: lat is num && lon is num ? lat.toDouble() : null,
          lon: lat is num && lon is num ? lon.toDouble() : null,
          lastMod: e['lastMod'] is int ? e['lastMod'] as int : 0,
        ));
      }
    }
    final channels = <RadioChannel>[];
    final chj = j['channels'];
    if (chj is List) {
      for (final e in chj.take(maxChannels)) {
        if (e is! Map<String, dynamic>) {
          skipped++;
          continue;
        }
        final i = e['index'], n = e['name'], s = e['secret'];
        if (i is! int || i < 0 || i >= maxChannels || n is! String || s is! String || !_hex32.hasMatch(s)) {
          skipped++;
          continue;
        }
        channels.add(RadioChannel(i, n.length > 31 ? n.substring(0, 31) : n, _unhex(s)));
      }
    }
    return RadioBackupData(
      radioName: radio['name'] is String ? radio['name'] as String : '',
      publicKeyHex: pk,
      createdMs: j['createdMs'] is int ? j['createdMs'] as int : 0,
      identityKey: key,
      contacts: contacts,
      channels: channels,
      skipped: skipped,
    );
  }
}
