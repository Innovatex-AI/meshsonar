// meshcore:// links and QR payloads (a QR code carries exactly the link text).
//
// Formats, from MeshCore docs/qr_codes.md (MIT) and MeshCore Open lib/utils/contact_qr.dart (MIT), re-implemented here:
//   meshcore://channel/add?name=<name>&secret=<32 hex>[&region_scope=<scope>]
//   meshcore://contact/add?name=<name>&public_key=<64 hex>&type=<1..4>
//   meshcore://<hex>   legacy: a raw advert packet, 98..171 bytes
// Input is hostile (it comes from a camera or clipboard): every field is length, charset and range checked and
// nothing throws; failures come back as [LinkParseError].
import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

sealed class MeshLink {
  const MeshLink();
}

class ChannelLink extends MeshLink {
  final String name;
  final Uint8List secret; // 16 bytes
  final String? regionScope;
  const ChannelLink({required this.name, required this.secret, this.regionScope});
}

class ContactLink extends MeshLink {
  final String name;
  final String publicKey; // 64 lowercase hex
  final ContactType? type;
  const ContactLink({required this.name, required this.publicKey, this.type});
}

class AdvertLink extends MeshLink {
  final Uint8List packet;
  const AdvertLink(this.packet);
}

enum LinkError { empty, tooLong, notMeshcore, unknownKind, missingField, badSecret, badPublicKey, badName, badType, badScope, badAdvert }

class LinkParseError extends MeshLink {
  final LinkError error;
  const LinkParseError(this.error);
}

abstract final class MeshLinks {
  static const int maxLinkLength = 2048;
  static const int maxNameBytes = 31; // firmware names are 32 bytes including the terminator
  static const int minAdvertBytes = 98;
  static const int maxAdvertBytes = 171;

  static bool _validName(String s) {
    if (s.isEmpty || s.trim().isEmpty) return false;
    if (utf8.encode(s).length > maxNameBytes) return false;
    for (final r in s.runes) {
      if (r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0x2028 || r == 0x2029 || (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) || r == 0xfeff) return false;
    }
    return true;
  }

  static String encodeChannel({required String name, required List<int> secret, String? regionScope}) {
    if (secret.length != 16) throw ArgumentError('channel secret must be 16 bytes');
    if (!_validName(name)) throw ArgumentError('bad channel name');
    final b = StringBuffer('meshcore://channel/add?name=${Uri.encodeQueryComponent(name)}&secret=${toHex(secret)}');
    if (regionScope != null && regionScope.isNotEmpty) {
      if (!_validName(regionScope)) throw ArgumentError('bad region scope');
      b.write('&region_scope=${Uri.encodeQueryComponent(regionScope)}');
    }
    return b.toString();
  }

  static String encodeContact({required String name, required String publicKey, ContactType? type}) {
    if (!isHex(publicKey, 64)) throw ArgumentError('public key must be 64 hex characters');
    if (!_validName(name)) throw ArgumentError('bad contact name');
    final b = StringBuffer('meshcore://contact/add?name=${Uri.encodeQueryComponent(name)}&public_key=${publicKey.toLowerCase()}');
    if (type != null) b.write('&type=${type.code}');
    return b.toString();
  }

  static String encodeAdvert(List<int> packet) {
    if (packet.length < minAdvertBytes || packet.length > maxAdvertBytes) throw ArgumentError('advert packet size');
    return 'meshcore://${toHex(packet)}';
  }

  /// Never throws.
  static MeshLink parse(String? input) {
    try {
      return _parse(input);
    } catch (_) {
      return const LinkParseError(LinkError.notMeshcore);
    }
  }

  static MeshLink _parse(String? input) {
    final s = (input ?? '').trim();
    if (s.isEmpty) return const LinkParseError(LinkError.empty);
    if (s.length > maxLinkLength) return const LinkParseError(LinkError.tooLong);
    if (!s.toLowerCase().startsWith('meshcore://')) return const LinkParseError(LinkError.notMeshcore);
    final rest = s.substring('meshcore://'.length);
    final q = rest.indexOf('?');
    final path = (q < 0 ? rest : rest.substring(0, q)).replaceAll(RegExp(r'^/+|/+$'), '').toLowerCase();
    if (path == 'channel/add' || path == 'contact/add') {
      final Map<String, String> p;
      try {
        p = q < 0 ? const {} : Uri.splitQueryString(rest.substring(q + 1));
      } catch (_) {
        return const LinkParseError(LinkError.missingField);
      }
      return path == 'channel/add' ? _channel(p) : _contact(p);
    }
    if (isHex(path) && path.isNotEmpty && q < 0) {
      final bytes = fromHex(path);
      if (bytes.length < minAdvertBytes || bytes.length > maxAdvertBytes) return const LinkParseError(LinkError.badAdvert);
      return AdvertLink(bytes);
    }
    return const LinkParseError(LinkError.unknownKind);
  }

  static MeshLink _channel(Map<String, String> p) {
    final name = p['name']?.trim();
    final secret = p['secret']?.trim();
    if (name == null || secret == null) return const LinkParseError(LinkError.missingField);
    if (!_validName(name)) return const LinkParseError(LinkError.badName);
    if (!isHex(secret, 32)) return const LinkParseError(LinkError.badSecret);
    String? scope = p['region_scope']?.trim();
    if (scope != null && scope.isEmpty) scope = null;
    if (scope != null && !_validName(scope)) return const LinkParseError(LinkError.badScope);
    return ChannelLink(name: name, secret: fromHex(secret), regionScope: scope);
  }

  static MeshLink _contact(Map<String, String> p) {
    final key = p['public_key']?.trim();
    if (key == null) return const LinkParseError(LinkError.missingField);
    if (!isHex(key, 64)) return const LinkParseError(LinkError.badPublicKey);
    final name = (p['name'] ?? '').trim();
    if (name.isNotEmpty && !_validName(name)) return const LinkParseError(LinkError.badName);
    final t = p['type'];
    ContactType? type;
    if (t != null) {
      final n = int.tryParse(t.trim());
      type = ContactType.fromCode(n); // out of range tolerated as unknown, like MeshCore Open
    }
    return ContactLink(name: name, publicKey: key.toLowerCase(), type: type);
  }
}
