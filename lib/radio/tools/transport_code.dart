// The transport-code (region scope) check. A scoped flood travels as TRANSPORT_FLOOD with a 2-byte code in the header
// (packet.dart transportCode1). The sender computes it as
//
//   code = HMAC-SHA256(key = SHA256(region name)[0:16], message = payload type byte + payload)[0:2]
//
// (firmware src/helpers/TransportKeyStore.cpp calcTransportCode: key length 16; a code of 0 becomes 1 and 0xFFFF becomes
// 0xFFFE). The two bytes are stored as the first transport word, little endian. So anyone holding a captured packet can
// tell offline whether it was sent under a given region name. VERIFIED on hardware (Nov 1 2026): INNO-OB-2's flood
// advert, header 0x10, bytes 41 7a, matches region "#cmh" (code 0x7a41); "cmh" and "#CMH" give other codes.
// Pure Dart.
import 'dart:convert';
import 'dart:typed_data';

import '../crypto.dart';
import '../packet.dart';

/// The region key for [name] ("#cmh"): first 16 bytes of SHA-256 of the name as written. A name without a leading '#' is
/// used as given (region names in MeshCore are literal text, the hashtag form is the convention).
Uint8List regionTransportKey(String name) => Uint8List.sublistView(sha256(utf8.encode(name.trim())), 0, 16);

/// The 16-bit transport code a packet with [payloadType] and [payload] carries under region key [key16].
int transportCodeFor(List<int> key16, int payloadType, List<int> payload) {
  final mac = hmacSha256(key16, [payloadType & 0x0F, ...payload]);
  var code = mac[0] | (mac[1] << 8);
  if (code == 0) code = 1;
  if (code == 0xFFFF) code = 0xFFFE;
  return code;
}

enum ScopeVerdict {
  /// A TRANSPORT_* packet whose code matches the region asked about.
  inScope,

  /// A TRANSPORT_* packet, but not under any region asked about.
  otherScope,

  /// A plain flood or direct packet: no region code at all.
  unscoped,
}

class ScopeResult {
  final ScopeVerdict verdict;

  /// The region that matched (inScope only).
  final String? region;
  const ScopeResult(this.verdict, [this.region]);

  /// Words for the UI.
  String get label => switch (verdict) {
        ScopeVerdict.inScope => 'in scope: $region',
        ScopeVerdict.otherScope => 'scoped to another region',
        ScopeVerdict.unscoped => 'unscoped',
      };
}

/// Does [p] carry the transport code of region [name]? False for a packet with no transport codes.
bool packetInScope(MeshPacket p, String name) {
  final c = p.transportCode1;
  if (!p.hasTransportCodes || c == null) return false;
  return transportCodeFor(regionTransportKey(name), p.payloadType, p.payload) == c;
}

/// The first of [regions] that [p] is scoped to. A scoped flood is only ever checked against names the caller offers
/// (the viewed region's scope, the channels' scopes); a code cannot be reversed to a name.
ScopeResult checkScope(MeshPacket p, Iterable<String> regions) {
  if (!p.hasTransportCodes || p.transportCode1 == null) return const ScopeResult(ScopeVerdict.unscoped);
  for (final r in regions) {
    if (packetInScope(p, r)) return ScopeResult(ScopeVerdict.inScope, r);
  }
  return const ScopeResult(ScopeVerdict.otherScope);
}
