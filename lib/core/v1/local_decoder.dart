// The phone's own packet decoder for the inspector (AZ-3.2): raw MeshCore bytes -> the same [PacketDetail] shape the
// `/v1/packets/{hash}` answer has (contract 8.2): hash, byte ranges covering every byte with the contract's colour
// groups and field ids, and `decoded` per type. Used for packets the connected radio heard ("My radio") and for pasted
// hex ("Decode a packet"), with no network.
//
// Wire layout (firmware, see lib/radio/packet.dart and research 04 A1-A2): [header][transport x4 if TRANSPORT_*]
// [path_len][path][payload]. Payloads:
//   ADVERT    pubkey 32 | timestamp u32 | signature 64 | flags | lat i32 lon i32 (0x10) | feat1 u16 (0x20) | feat2 u16 (0x40) | name (0x80)
//   GRP_TXT / GRP_DATA  channel hash 1 | MAC 2 | AES-128-ECB ciphertext
//   TXT_MSG / REQ / RESPONSE / PATH  dest hash 1 | src hash 1 | MAC 2 | ciphertext (pairwise key: never readable here)
//   ANON_REQ  dest hash 1 | sender pubkey 32 | MAC 2 | ciphertext
//   ACK       CRC 4
//   TRACE     tag u32 | auth u32 | flags (hash size = 1 << (flags & 3)) | target hashes; header path bytes = SNR*4 per hop
//   MULTIPART remaining (high nibble) | inner type (low nibble) | inner bytes
//   CONTROL   flags (high nibble subtype: 0x8 discover request, 0x9 discover response) | body
//
// Privacy: only the Public channel and hashtag channels (whose keys are public by name, contract D1) are tried; the
// caller passes the hashtag channels. Text is decoded in memory for the screen, never stored. Direct messages, REQ,
// RESPONSE, PATH and ANON_REQ bodies stay encrypted (only the two ends hold the key).
//
// The Ed25519 signature of an advert is NOT checked here (`signature.checked: false`), and hops are not resolved to
// nodes on the phone (confidence `unknown`, evidence `not_resolved_on_phone`); the screen says both.
// Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:typed_data';

import '../../radio/crypto.dart';
import '../../radio/packet.dart';
import 'packet_models.dart';

/// A channel key to try on group packets: the Public channel, or a hashtag channel (`#wardriving`).
class LocalChannelKey {
  final String name;
  final Uint8List secret16;

  /// `builtin_public` or `hashtag_list` (contract keySource).
  final String keySource;
  const LocalChannelKey(this.name, this.secret16, this.keySource);

  static final LocalChannelKey public = LocalChannelKey('Public', publicChannelSecret, 'builtin_public');
  factory LocalChannelKey.hashtag(String name) {
    final n = name.trim().startsWith('#') ? name.trim() : '#${name.trim()}';
    return LocalChannelKey(n, hashtagChannelSecret(n), 'hashtag_list');
  }

  /// Contract channel id: `public`, `tag:<name>`.
  String get channelId => keySource == 'builtin_public' ? 'public' : 'tag:${name.substring(1)}';
}

/// Why pasted text is not a packet.
class LocalDecodeError implements Exception {
  final String message;
  const LocalDecodeError(this.message);
  @override
  String toString() => message;
}

/// Hex text with spaces, colons, `0x` and new lines allowed; null when it is not whole bytes of hex.
Uint8List? parseHexInput(String text) {
  final t = text.replaceAll(RegExp(r'0x', caseSensitive: false), '').replaceAll(RegExp(r'[\s:,\-]'), '');
  if (t.isEmpty || t.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(t)) return null;
  return fromHex(t);
}

/// True when the phone decodes [type]'s fields (every contract type except RAW_CUSTOM and unknown numbers).
bool localDecoderKnowsType(int type) => packetTypeWireNames.containsKey(type) && type != PayloadType.rawCustom;

String _iso(int unixS) => DateTime.fromMillisecondsSinceEpoch(unixS * 1000, isUtc: true).toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), '.000Z');

/// Decodes [raw]. Throws [LocalDecodeError] when the bytes are not a packet the firmware would accept.
PacketDetail decodePacketLocally(
  Uint8List raw, {
  PacketSource source = PacketSource.pasted,
  List<LocalChannelKey> hashtagKeys = const [],
  DateTime? heardAt,
  double? snr,
  double? rssi,
}) {
  if (raw.length > 255) throw const LocalDecodeError('That is longer than any MeshCore packet (255 bytes at most).');
  final p = MeshPacket.tryParse(raw);
  if (p == null) throw const LocalDecodeError('These bytes are not a MeshCore packet the radio would accept (header, path length or payload is wrong).');
  final type = p.payloadType;
  final typeName = packetTypeWireName(type);
  final route = packetRouteWireName(p.routeType);
  final ranges = <ByteRange>[];
  void add(int start, int end, ByteGroup group, String field, String label, Object? value) {
    if (end <= start) return;
    ranges.add(ByteRange(start: start, end: end, group: group, field: field, label: label, hex: toHex(raw.sublist(start, end)), value: value));
  }

  var i = 0;
  add(0, 1, ByteGroup.header, 'header', 'Header',
      {'routeType': p.routeType, 'route': route, 'payloadType': type, 'type': typeName, 'payloadVersion': p.payloadVersion});
  i = 1;
  if (p.hasTransportCodes) {
    add(1, 3, ByteGroup.transport, 'transportCode1', 'Transport code 1 (scope)', toHex(raw.sublist(1, 3)));
    add(3, 5, ByteGroup.transport, 'transportCode2', 'Transport code 2 (reserved)', toHex(raw.sublist(3, 5)));
    i = 5;
  }
  final isTrace = type == PayloadType.trace;
  if (isTrace) {
    add(i, i + 1, ByteGroup.pathLen, 'pathLen', 'Path length (hops completed)', {'hopsCompleted': p.hopCount});
  } else {
    add(i, i + 1, ByteGroup.pathLen, 'pathLen', 'Path length', {'hashSize': p.pathHashSize, 'hopCount': p.hopCount, 'bytes': p.pathHashSize * p.hopCount});
  }
  i++;
  final traceSnr = <double>[];
  for (var h = 0; h < p.path.length; h++) {
    final size = p.path[h].length;
    if (isTrace) {
      // TRACE: the header path holds one int8 SNR*4 per completed hop, not hashes (contract 13.40).
      final b = raw[i];
      final snrDb = (b > 127 ? b - 256 : b) / 4.0;
      traceSnr.add(snrDb);
      add(i, i + size, ByteGroup.path, 'path[$h]', 'SNR at hop ${h + 1}', snrDb);
    } else {
      add(i, i + size, ByteGroup.path, 'path[$h]', 'Hop ${h + 1}', toHex(p.path[h]));
    }
    i += size;
  }
  final payloadStart = i;
  final pl = p.payload;
  final bd = ByteData.sublistView(pl);
  Map<String, dynamic> decoded = {};
  PacketNode? origin;
  PacketChannel? channel;
  PacketMessage? message;
  var paths = <PacketPath>[];
  final notes = <String>[];
  var consumed = 0; // payload bytes covered by named ranges

  void pAdd(int from, int to, ByteGroup g, String field, String label, Object? value) {
    add(payloadStart + from, payloadStart + to, g, field, label, value);
    if (to > consumed) consumed = to;
  }

  List<PacketHop> unresolved(List<String> prefixes, {List<double>? snrs}) => [
        for (var h = 0; h < prefixes.length; h++)
          PacketHop(
            index: h,
            prefix: prefixes[h],
            confidence: HopConfidence.unknown,
            evidence: const ['not_resolved_on_phone'],
            snrDb: snrs != null && h < snrs.length ? snrs[h] : null,
          )
      ];

  switch (type) {
    case PayloadType.advert:
      if (pl.length < 101) throw const LocalDecodeError('This advert is cut short (it needs at least 101 payload bytes).');
      final key = toHex(pl.sublist(0, 32));
      final ts = bd.getUint32(32, Endian.little);
      pAdd(0, 32, ByteGroup.payload, 'advert.publicKey', 'Public key', key);
      pAdd(32, 36, ByteGroup.payload, 'advert.timestamp', 'Advert time', _iso(ts));
      pAdd(36, 100, ByteGroup.signature, 'advert.signature', 'Ed25519 signature', 'not_checked');
      final flags = pl[100];
      final roleN = flags & 0x0F;
      final role = switch (roleN) { 1 => 'companion', 2 => 'repeater', 3 => 'room', 4 => 'sensor', _ => 'unknown' };
      pAdd(100, 101, ByteGroup.payload, 'advert.flags', 'Flags',
          {'role': role, 'hasLocation': flags & 0x10 != 0, 'hasName': flags & 0x80 != 0, 'feat1': flags & 0x20 != 0, 'feat2': flags & 0x40 != 0});
      var k = 101;
      Map<String, double>? pos;
      if (flags & 0x10 != 0 && pl.length >= k + 8) {
        final la = bd.getInt32(k, Endian.little) / 1e6, lo = bd.getInt32(k + 4, Endian.little) / 1e6;
        pAdd(k, k + 4, ByteGroup.payload, 'advert.lat', 'Latitude', la);
        pAdd(k + 4, k + 8, ByteGroup.payload, 'advert.lon', 'Longitude', lo);
        if ((la != 0 || lo != 0) && la.abs() <= 90 && lo.abs() <= 180) pos = {'lat': la, 'lon': lo};
        k += 8;
      }
      int? feat1, feat2;
      if (flags & 0x20 != 0 && pl.length >= k + 2) {
        feat1 = bd.getUint16(k, Endian.little);
        pAdd(k, k + 2, ByteGroup.payload, 'advert.feat1', 'Feature 1', feat1);
        k += 2;
      }
      if (flags & 0x40 != 0 && pl.length >= k + 2) {
        feat2 = bd.getUint16(k, Endian.little);
        pAdd(k, k + 2, ByteGroup.payload, 'advert.feat2', 'Feature 2', feat2);
        k += 2;
      }
      String? name;
      if (flags & 0x80 != 0 && pl.length > k) {
        name = utf8.decode(pl.sublist(k).takeWhile((b) => b != 0).toList(), allowMalformed: true);
        pAdd(k, pl.length, ByteGroup.payload, 'advert.name', 'Name', name);
      }
      decoded = {
        'advert': {
          'publicKey': key,
          'timestamp': _iso(ts),
          'signature': {'valid': null, 'checked': false},
          'role': role,
          'name': name,
          'position': pos,
          'feat1': feat1,
          'feat2': feat2,
          'battery': null,
          'temperatureC': null,
          'clockSkewS': null,
        }
      };
      origin = PacketNode(key: key, name: name, role: role);
      notes.add('The advert signature is not checked on the phone.');
    case PayloadType.grpTxt:
    case PayloadType.grpData:
      if (pl.length < 3) throw const LocalDecodeError('This channel packet is cut short.');
      final ch = pl[0].toRadixString(16).padLeft(2, '0');
      final mac = toHex(pl.sublist(1, 3));
      String status = 'no_key';
      String? keySource;
      Map<String, dynamic>? plaintext;
      for (final key in [LocalChannelKey.public, ...hashtagKeys]) {
        if (channelHash(key.secret16) != pl[0]) continue;
        final plain = meshMacThenDecrypt(key.secret16, pl.sublist(1));
        if (plain == null || plain.length < 5) continue;
        status = 'decrypted';
        keySource = key.keySource;
        channel = PacketChannel(id: key.channelId, name: key.keySource == 'builtin_public' ? 'Public' : key.name, kind: key.keySource == 'builtin_public' ? 'public' : 'hashtag');
        final ts = ByteData.sublistView(plain).getUint32(0, Endian.little);
        if (type == PayloadType.grpTxt) {
          final gt = decryptGroupText(key.secret16, pl)!;
          plaintext = {'timestamp': _iso(gt.timestamp), 'flags': gt.flags, 'text': gt.text};
          final cut = gt.text.indexOf(': ');
          message = PacketMessage(
            channel: channel,
            sender: cut > 0 ? gt.text.substring(0, cut) : null,
            text: cut > 0 ? gt.text.substring(cut + 2) : gt.text,
            senderTime: DateTime.fromMillisecondsSinceEpoch(gt.timestamp * 1000, isUtc: true),
          );
        } else {
          var end = plain.length;
          while (end > 5 && plain[end - 1] == 0) {
            end--;
          }
          plaintext = {'timestamp': _iso(ts), 'dataType': plain[4], 'dataLen': end - 5, 'data': toHex(plain.sublist(5, end))};
        }
        break;
      }
      channel ??= PacketChannel(id: 'enc:$ch', kind: 'unknown');
      pAdd(0, 1, ByteGroup.payload, 'grp.channelHash', 'Channel hash', ch);
      pAdd(1, 3, ByteGroup.mac, 'grp.mac', 'MAC (HMAC-SHA256, 2 bytes)', mac);
      pAdd(3, pl.length, ByteGroup.ciphertext, 'grp.ciphertext', 'Ciphertext (AES-128-ECB)', status);
      decoded = {
        'group': {
          'channelHash': ch,
          'mac': mac,
          'decodeStatus': status,
          'keySource': keySource,
          'plaintext': plaintext,
          if (status == 'no_key') 'note': 'Not the Public channel or a hashtag channel this phone knows: the text stays encrypted here.',
        }
      };
    case PayloadType.txtMsg:
    case PayloadType.req:
    case PayloadType.response:
    case PayloadType.path:
      if (pl.length < 4) throw const LocalDecodeError('This direct packet is cut short.');
      final dest = pl[0].toRadixString(16).padLeft(2, '0'), src = pl[1].toRadixString(16).padLeft(2, '0');
      final mac = toHex(pl.sublist(2, 4));
      pAdd(0, 1, ByteGroup.payload, 'dm.destHash', 'Destination hash', dest);
      pAdd(1, 2, ByteGroup.payload, 'dm.srcHash', 'Source hash', src);
      pAdd(2, 4, ByteGroup.mac, 'dm.mac', 'MAC', mac);
      pAdd(4, pl.length, ByteGroup.ciphertext, 'dm.ciphertext', 'Ciphertext (pairwise key)', 'encrypted');
      decoded = {
        'direct': {
          'destHash': dest,
          'srcHash': src,
          'mac': mac,
          'encrypted': true,
          'content': null,
          'destCandidates': const [],
          'srcCandidates': const [],
          'note': 'Encrypted end to end; only the two ends can read it.',
        }
      };
    case PayloadType.anonReq:
      if (pl.length < 35) throw const LocalDecodeError('This anonymous request is cut short.');
      final dest = pl[0].toRadixString(16).padLeft(2, '0');
      final sender = toHex(pl.sublist(1, 33));
      final mac = toHex(pl.sublist(33, 35));
      pAdd(0, 1, ByteGroup.payload, 'anon.destHash', 'Destination hash', dest);
      pAdd(1, 33, ByteGroup.payload, 'anon.senderKey', 'Sender public key', sender);
      pAdd(33, 35, ByteGroup.mac, 'anon.mac', 'MAC', mac);
      pAdd(35, pl.length, ByteGroup.ciphertext, 'anon.ciphertext', 'Ciphertext (pairwise key)', 'encrypted');
      decoded = {
        'anonReq': {'destHash': dest, 'senderKey': sender, 'sender': null, 'mac': mac, 'encrypted': true}
      };
      origin = PacketNode(key: sender);
    case PayloadType.ack:
      if (pl.length >= 4) {
        final crc = toHex(pl.sublist(0, 4));
        pAdd(0, 4, ByteGroup.payload, 'ack.crc', 'Checksum (CRC)', crc);
        decoded = {
          'ack': {'crc': crc}
        };
      } else {
        decoded = {
          'ack': {'crc': null}
        };
      }
    case PayloadType.trace:
      if (pl.length < 9) throw const LocalDecodeError('This trace is cut short.');
      final tag = bd.getUint32(0, Endian.little).toRadixString(16).padLeft(8, '0');
      final auth = bd.getUint32(4, Endian.little);
      final hs = 1 << (pl[8] & 3);
      pAdd(0, 4, ByteGroup.payload, 'trace.tag', 'Tag', tag);
      pAdd(4, 8, ByteGroup.payload, 'trace.authCode', 'Auth code', auth);
      pAdd(8, 9, ByteGroup.payload, 'trace.flags', 'Flags', {'hashSize': hs});
      final targets = <String>[
        for (var t = 9; t + hs <= pl.length; t += hs) toHex(pl.sublist(t, t + hs)),
      ];
      if (targets.isNotEmpty) pAdd(9, 9 + targets.length * hs, ByteGroup.payload, 'trace.hops', 'Target hops', targets);
      decoded = {
        'trace': {'tag': tag, 'authCode': auth, 'hashSize': hs, 'targets': targets, 'hopsCompleted': p.hopCount, 'snr': traceSnr}
      };
      paths = [PacketPath(id: 'local', hops: unresolved(targets, snrs: traceSnr), direction: 'remaining')];
    case PayloadType.multipart:
      final remaining = pl[0] >> 4, inner = pl[0] & 0x0F;
      pAdd(0, 1, ByteGroup.payload, 'multipart.header', 'Remaining and inner type', {'remaining': remaining, 'innerType': packetTypeWireName(inner)});
      pAdd(1, pl.length, ByteGroup.payload, 'multipart.inner', 'Inner bytes', toHex(pl.sublist(1)));
      decoded = {
        'multipart': {'remaining': remaining, 'innerType': packetTypeWireName(inner)}
      };
    case PayloadType.control:
      final flags = pl[0];
      final sub = flags >> 4;
      final subtype = sub == 0x8 ? 'discover_req' : (sub == 0x9 ? 'discover_resp' : 'other');
      pAdd(0, 1, ByteGroup.payload, 'control.flags', 'Flags', {'subtype': subtype, 'flags': flags});
      final out = <String, dynamic>{'subtype': subtype, 'flags': flags, 'zeroHop': flags & 0x80 != 0};
      if (subtype == 'discover_req' && pl.length >= 6) {
        pAdd(1, 2, ByteGroup.payload, 'control.filter', 'Type filter', pl[1]);
        final tag = bd.getUint32(2, Endian.little).toRadixString(16).padLeft(8, '0');
        pAdd(2, 6, ByteGroup.payload, 'control.tag', 'Tag', tag);
        out['filter'] = pl[1];
        out['tag'] = tag;
        out['prefixOnly'] = flags & 1 != 0;
        if (pl.length >= 10) {
          final since = bd.getUint32(6, Endian.little);
          pAdd(6, 10, ByteGroup.payload, 'control.since', 'Since', since == 0 ? 0 : _iso(since));
          out['since'] = since == 0 ? null : _iso(since);
        }
      } else if (subtype == 'discover_resp' && pl.length >= 6) {
        final s = pl[1] > 127 ? pl[1] - 256 : pl[1];
        pAdd(1, 2, ByteGroup.payload, 'control.snr', 'SNR', s / 4.0);
        final tag = bd.getUint32(2, Endian.little).toRadixString(16).padLeft(8, '0');
        pAdd(2, 6, ByteGroup.payload, 'control.tag', 'Tag', tag);
        out['snr'] = s / 4.0;
        out['tag'] = tag;
        out['nodeType'] = flags & 0x0F;
        if (pl.length > 6) {
          final key = toHex(pl.sublist(6));
          pAdd(6, pl.length, ByteGroup.payload, 'control.key', 'Public key', key);
          out['key'] = key;
        }
      }
      decoded = {'control': out};
    default:
      decoded = {
        'raw': {'length': pl.length, 'firstByte': pl[0]}
      };
      pAdd(0, pl.length, ByteGroup.payload, 'raw.data', 'Payload', toHex(pl));
      notes.add('The phone has no field decoder for this packet type; the payload is shown as bytes.');
  }
  // Every byte is in a range: whatever the type's fields did not name.
  if (consumed < pl.length) add(payloadStart + consumed, raw.length, ByteGroup.payload, 'payload.rest', 'Other payload bytes', toHex(pl.sublist(consumed)));
  if (paths.isEmpty && p.pathHex.isNotEmpty && !isTrace) {
    final direct = p.routeType == RouteType.direct || p.routeType == RouteType.transportDirect;
    paths = [PacketPath(id: 'local', hops: unresolved(p.pathHex), direction: direct ? 'remaining' : 'travelled')];
  }
  if (paths.isNotEmpty && !isTrace) notes.add('Hops are shown as the codes on the air; the phone does not match them to repeaters.');
  return PacketDetail(
    source: source,
    hash: p.hashHex,
    type: type,
    typeName: typeName,
    route: route,
    payloadVersion: p.payloadVersion,
    hashSize: isTrace ? (decoded['trace'] as Map)['hashSize'] as int : (p.hopCount == 0 && !p.isFlood ? 0 : p.pathHashSize),
    size: raw.length,
    firstSeen: heardAt,
    lastSeen: heardAt,
    raw: toHex(raw),
    rawVerified: true,
    bytes: ranges,
    decoded: decoded,
    origin: origin,
    channel: channel,
    message: message,
    paths: paths,
    missing: notes,
    localSnr: snr,
    localRssi: rssi,
    observationCount: source == PacketSource.myRadio ? 1 : 0,
    observerCount: source == PacketSource.myRadio ? 1 : 0,
  );
}
