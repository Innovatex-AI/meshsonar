// Channel key helpers. Same derivations as lib/radio/crypto.dart (cross-checked by a test) but kept here so the
// chat layer has no dependency on the radio layer.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

/// The well-known Public channel key (base64 izOH6cXN6mrJ5e26oRXNcg==, hex 8b3387e9c5cdea6ac9e5edbaa115cd72).
final Uint8List publicChannelSecret16 = Uint8List.fromList(
    [0x8b, 0x33, 0x87, 0xe9, 0xc5, 0xcd, 0xea, 0x6a, 0xc9, 0xe5, 0xed, 0xba, 0xa1, 0x15, 0xcd, 0x72]);

/// Hashtag channels: first 16 bytes of SHA-256 of the lower-cased name including '#'.
Uint8List hashtagSecret16(String name) {
  var n = name.trim().toLowerCase();
  if (!n.startsWith('#')) n = '#$n';
  return Uint8List.fromList(c.sha256.convert(utf8.encode(n)).bytes.sublist(0, 16));
}

/// One-byte on-air channel hash: SHA-256(secret)[0].
int channelHashByte(List<int> secret16) => c.sha256.convert(secret16.sublist(0, 16)).bytes[0];
