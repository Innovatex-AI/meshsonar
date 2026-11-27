// The link's side of the message log (round 3, defect M12): one line per command the phone gives the radio and one per
// reply code, per timeout, per stray frame that was discarded and per delivery push. Pure Dart.
//
// What a line may hold: codes, lengths, the try number, the sender timestamp, the first 4 hex characters of a contact
// key, the confirmation code, the radio's flood flag and its estimated wait. What it never holds: message text, channel
// secrets, passwords, PINs, private keys, positions, names. The describe functions below are the only place a frame is
// turned into log text, so that rule is checked in one place (test/radio/link_log_test.dart).
import 'dart:typed_data';

import 'protocol.dart';

enum LinkLogKind {
  /// A command written to the radio.
  command,

  /// The reply that was matched to the command in flight.
  reply,

  /// No reply came within the timeout.
  timeout,

  /// A reply frame nobody was waiting for, or with a code the command in flight cannot be answered with: discarded.
  stray,

  /// A push that matters to delivery (SEND_CONFIRMED, PATH_UPDATED, MSG_WAITING, CONTACTS_FULL, CONTACT_DELETED).
  push,

  /// Something the link noticed (clock, link down).
  note,
}

class LinkLogEntry {
  final DateTime at;
  final LinkLogKind kind;

  /// The frame's first byte (command, reply or push code); null for a note.
  final int? code;

  /// One line, no secrets (see the top of this file).
  final String text;
  const LinkLogEntry(this.at, this.kind, this.text, {this.code});

  /// The marker a log line starts with: `>` to the radio, `<` from it, `!` a problem, `~` discarded, `*` push, `#` note.
  String get marker => switch (kind) {
        LinkLogKind.command => '>',
        LinkLogKind.reply => '<',
        LinkLogKind.timeout => '!',
        LinkLogKind.stray => '~',
        LinkLogKind.push => '*',
        LinkLogKind.note => '#',
      };

  @override
  String toString() => '$marker $text';
}

String _hex8(int v) => (v & 0xffffffff).toRadixString(16).padLeft(8, '0');

String _key4(Uint8List f, int at) {
  if (f.length < at + 2) return '?';
  return f.sublist(at, at + 2).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

int _u32At(Uint8List f, int at) => f.length < at + 4 ? 0 : ByteData.sublistView(f).getUint32(at, Endian.little);

/// One line for a command frame. Only fields that are safe to export (see the top of this file).
String describeCommandForLog(Uint8List f) {
  if (f.isEmpty) return 'empty command';
  final name = '${commandName(f[0])}(${f[0]}) len=${f.length}';
  switch (f[0]) {
    case Cmd.sendTxtMsg:
      if (f.length < 13) return name;
      return '$name type=${f[1]} try=${f[2]} ts=${_u32At(f, 3)} to=${_key4(f, 7)} text=${f.length - 13}b';
    case Cmd.sendChannelTxtMsg:
      // [3][txt_type][channel_idx][ts u32][text]
      return f.length < 7 ? name : '$name slot=${f[2]} ts=${_u32At(f, 3)} text=${f.length - 7}b';
    case Cmd.resetPath:
    case Cmd.getContactByKey:
    case Cmd.removeContact:
    case Cmd.shareContact:
      return '$name key=${_key4(f, 1)}';
    case Cmd.addUpdateContact:
      return f.length < 36 ? name : '$name key=${_key4(f, 1)} type=${f[33]} flags=${f[34]} path_len=${f[35] == 0xff ? 'unknown' : f[35] & 63}';
    case Cmd.getContacts:
      return f.length >= 5 ? '$name since=${_u32At(f, 1)}' : name;
    case Cmd.deviceQuery:
      return f.length >= 2 ? '$name ver=${f[1]}' : name;
    case Cmd.setDeviceTime:
      return '$name t=${_u32At(f, 1)}';
    case Cmd.getStats:
      return f.length >= 2 ? '$name sub=${f[1]}' : name;
    default:
      return name; // code and length only: never the payload
  }
}

/// One line for a reply or push frame. Only fields that are safe to export.
String describeReplyForLog(Uint8List f) {
  if (f.isEmpty) return 'empty frame';
  final name = '${replyName(f[0])}(${f[0] >= 0x80 ? '0x${f[0].toRadixString(16)}' : f[0]})';
  switch (f[0]) {
    case Resp.err:
      return '$name ${errName(f.length > 1 ? f[1] : null)}';
    case Resp.sent:
      if (f.length < 10) return name;
      return '$name ${f[1] != 0 ? 'flood' : 'direct'} ack=${_hex8(_u32At(f, 2))} est=${_u32At(f, 6)}ms';
    case Resp.contactsStart:
      return '$name count=${_u32At(f, 1)}';
    case Resp.contact:
      return f.length < 36 ? name : '$name key=${_key4(f, 1)} path_len=${f[35] == 0xff ? 'unknown' : f[35] & 63}';
    case Resp.currTime:
      return '$name t=${_u32At(f, 1)}';
    case Resp.contactMsgRecv:
    case Resp.contactMsgRecvV3:
      final at = f[0] == Resp.contactMsgRecvV3 ? 4 : 1;
      return '$name from=${_key4(f, at)} len=${f.length}';
    case Resp.channelMsgRecv:
    case Resp.channelMsgRecvV3:
    case Resp.channelDataRecv:
      return '$name len=${f.length}';
    case Push.sendConfirmed:
      return f.length < 9 ? name : '$name ack=${_hex8(_u32At(f, 1))} trip=${_u32At(f, 5)}ms';
    case Push.pathUpdated:
    case Push.contactDeleted:
      return '$name key=${_key4(f, 1)}';
    default:
      return f[0] >= 0x80 ? name : '$name len=${f.length}';
  }
}
