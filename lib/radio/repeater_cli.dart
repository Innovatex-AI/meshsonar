// The repeater CLI as the app sees it: which command strings may ever be sent, which words in a command or a reply are
// secret, and how replies are read. Everything here is about EXACT strings. The firmware matches commands by PREFIX
// (CommonCLI.cpp: `memcmp(command, "reboot", 6)`, so `rebootXYZ` reboots, `advertXYZ` floods an advert, `verXYZ` answers),
// so the app never builds a command by concatenating user text onto a name: every command is checked against this file
// first, and anything it does not recognise is not sent. Pure Dart.
//
// Sources: repeater-observer-live-research-2026-11-01.md sections A and 8; MeshCore main (Oct 2026) CommonCLI.cpp,
// CommonRadioPrefs.cpp, examples/simple_repeater/MyMesh.cpp.

/// What a command string is.
enum CliKind {
  /// Reads something, changes nothing.
  read,

  /// Does something with no stored change (advert, discover, clock sync, reboot).
  action,

  /// Changes a stored setting; goes through the typed settings API (confirm, read back, undo).
  write,

  /// Never sent from this app.
  blocked,

  /// Not recognised: not sent. A new firmware command is added here after it is checked, not guessed.
  unknown,
}

class CliVerdict {
  final CliKind kind;
  final String reason;

  /// For [CliKind.write]: the setting key (`name`, `radio`, ...), and the raw value text.
  final String? settingKey;
  final String? value;
  const CliVerdict(this.kind, this.reason, {this.settingKey, this.value});
  bool get sendable => kind == CliKind.read || kind == CliKind.action;
}

/// Longest command the companion passes through intact is 160 characters (165 was silently dropped, LIVE); the `NN|` tag
/// takes 3 of them.
const int maxCliCommandChars = 150;

/// `get` keys that are safe to read and show. `get guest.password` is NOT here: the repeater answers it in clear.
const Set<String> readableKeys = {
  'name', 'role', 'public.key', 'radio', 'tx', 'freq', 'af', 'dutycycle', 'txdelay', 'direct.txdelay', 'rxdelay', 'int.thresh',
  'cad', 'agc.reset.interval', 'multi.acks', 'flood.advert.interval', 'advert.interval', 'flood.max', 'flood.max.unscoped',
  'flood.max.advert', 'repeat', 'path.hash.mode', 'loop.detect', 'lat', 'lon', 'owner.info', 'allow.read.only', 'radio.rxgain',
  'radio.fem.rxgain', 'radio.fem.txgain', 'adc.multiplier', 'bootloader.ver', 'bridge.type', 'timezone',
};

final RegExp _observerKey = RegExp(
    r'^mqtt[1-6]?\.(status|stats|diag|preset|server|port|audience|filter|iata|origin|packets|raw|rx|tx|interval|neighbors|neighbors\.interval|ntp|ntp\.diag|config\.valid|presets|advert\.verify)$');

/// Keys whose reply is a secret (never shown, never logged).
bool isSecretKey(String key) =>
    key == 'guest.password' ||
    key == 'password' ||
    key == 'prv.key' ||
    key == 'bridge.secret' ||
    key == 'alert.psk' ||
    RegExp(r'^mqtt[1-6]?\.(password|token|username)$').hasMatch(key) ||
    RegExp(r'^wifi\.(pwd|ssid)$').hasMatch(key);

/// First words that are never sent, whatever follows (prefix variants included on purpose).
const List<String> _blockedPrefixes = [
  'reboot', 'poweroff', 'shutdown', 'clkreboot', 'erase', 'start', 'stop', 'ota', 'format', 'log', 'tempradio', 'time', 'password',
  'sensor', 'io', 'gps', 'powersaving', 'room.post', 'neighbor.remove', 'clear', 'setperm', 'bridge', 'eth',
];

/// Classifies [raw] (what the user typed, or what the app is about to send). Never sends anything.
CliVerdict classifyCommand(String raw) {
  final c = raw.trim();
  if (c.isEmpty) return const CliVerdict(CliKind.unknown, 'Nothing to send.');
  if (c.length > maxCliCommandChars) {
    return const CliVerdict(CliKind.blocked, 'Too long: the radio drops commands over $maxCliCommandChars characters without a word.');
  }
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(c)) return const CliVerdict(CliKind.blocked, 'Control characters are not allowed in a command.');
  if (c.length > 4 && c[2] == '|') {
    return const CliVerdict(CliKind.blocked, 'The two-character tag prefix is added by the app; leave it out.');
  }
  final parts = c.split(' ').where((p) => p.isNotEmpty).toList();
  final first = parts.first;
  // exact, single-spaced forms only
  final norm = parts.join(' ');
  if (norm != c) return const CliVerdict(CliKind.unknown, 'Use single spaces and no leading or trailing spaces.');

  // ---- reads
  if (first == 'get') {
    if (parts.length != 2) return const CliVerdict(CliKind.unknown, 'get needs exactly one name.');
    final key = parts[1];
    if (isSecretKey(key)) {
      return CliVerdict(CliKind.blocked, 'The repeater would print "$key" in clear text. MeshSonar never reads or shows passwords.');
    }
    if (readableKeys.contains(key) || _observerKey.hasMatch(key)) return const CliVerdict(CliKind.read, 'read');
    return CliVerdict(CliKind.unknown, 'MeshSonar does not know "get $key" yet, so it is not sent.');
  }
  if (c == 'ver' || c == 'board' || c == 'clock' || c == 'neighbors' || c == 'power' || c == 'memory' || c == 'powersaving' || c == 'gps') {
    return const CliVerdict(CliKind.read, 'read');
  }
  if (c == 'region' || c == 'region home' || c == 'region default' || c == 'region list allowed' || c == 'region list denied') {
    return const CliVerdict(CliKind.read, 'read');
  }
  if (parts.length == 3 && parts[0] == 'region' && parts[1] == 'get') return const CliVerdict(CliKind.read, 'read');
  if (c == 'ota branch') return const CliVerdict(CliKind.read, 'read');

  // ---- actions
  if (c == 'advert' || c == 'advert.zerohop' || c == 'discover.neighbors') return const CliVerdict(CliKind.action, 'action');
  if (c == 'clock sync') return const CliVerdict(CliKind.action, 'action');
  if (c == 'reboot') return const CliVerdict(CliKind.action, 'reboot');

  // ---- writes (typed API)
  if (first == 'set') {
    if (parts.length < 3) return const CliVerdict(CliKind.unknown, 'set needs a name and a value.');
    final key = parts[1];
    if (key == 'prv.key') {
      return const CliVerdict(CliKind.blocked, 'Changing the repeater identity key is never offered: it would make this a different node.');
    }
    if (key == 'freq') return const CliVerdict(CliKind.blocked, 'Not available over the air; use "set radio" through the Radio settings.');
    final value = c.substring('set '.length + key.length + 1);
    return CliVerdict(CliKind.write, 'write', settingKey: key, value: value);
  }

  // ---- blocked words (checked after the exact forms above so `ota branch` stays a read)
  for (final b in _blockedPrefixes) {
    if (first.startsWith(b)) {
      return CliVerdict(CliKind.blocked, _blockedReason(first));
    }
  }
  if (first == 'region') {
    if (parts.length >= 2 && parts[1] == 'load') {
      return const CliVerdict(CliKind.blocked,
          '"region load" makes the repeater swallow every following line as region text until a blank line. It is never sent.');
    }
    return const CliVerdict(CliKind.blocked, 'Region changes are made on the Regions screen, where they are read back and can be undone.');
  }
  return const CliVerdict(CliKind.unknown, 'Not a command MeshSonar knows, so it is not sent.');
}

String _blockedReason(String first) {
  if (first.startsWith('reboot') && first != 'reboot') {
    return 'The repeater matches commands by prefix, so "$first" would reboot it. Only the exact word "reboot" is ever sent, from the Advanced section.';
  }
  if (first.startsWith('password')) return 'Passwords are changed on the Access screen, which hides them and never logs them.';
  if (first.startsWith('setperm')) return 'Access changes are made on the Access screen, where they are checked and read back.';
  if (first.startsWith('poweroff') || first.startsWith('shutdown')) {
    return 'Powering a remote repeater off strands it until someone presses a button. MeshSonar does not offer it.';
  }
  if (first.startsWith('erase') || first.startsWith('format')) return 'Erasing is not available over the air and is never offered.';
  if (first.startsWith('start') || first.startsWith('stop') || first.startsWith('ota')) {
    return 'Firmware update and web-config modes take the repeater off the mesh. They are not offered.';
  }
  return 'MeshSonar does not send "$first" from here.';
}

// ------------------------------------------------------------------ redaction

/// The command with secret values replaced, for logs and the console history. `set guest.password hunter2` ->
/// `set guest.password ••••`. A command that is not recognised as holding a secret is returned as is.
String redactCommand(String command) {
  final c = command.trim();
  final parts = c.split(' ');
  if (parts.isNotEmpty && parts[0] == 'password') return 'password ••••';
  if (parts.length >= 3 && parts[0] == 'set' && isSecretKey(parts[1])) return 'set ${parts[1]} ••••';
  if (parts.length >= 2 && parts[0] == 'get' && isSecretKey(parts[1])) return c;
  return c;
}

/// The reply with secrets removed. The repeater echoes a new admin password (`password now: ...`) and prints
/// `get guest.password` in clear; neither may reach a screen or a log.
String redactReply(String command, String reply) {
  final parts = command.trim().split(' ');
  if (parts.isNotEmpty && parts[0] == 'password') return reply.startsWith('password now:') ? 'password now: ••••' : reply;
  if (parts.length >= 2 && parts[0] == 'get' && isSecretKey(parts[1])) return '••••';
  if (reply.startsWith('password now:')) return 'password now: ••••';
  return reply;
}

// ------------------------------------------------------------------ replies

/// How the repeater answered a command.
enum ReplyKind { ok, value, error, unsupported }

class CliReply {
  final ReplyKind kind;

  /// For [ReplyKind.value]: the text after the `> ` marker. For the others: the whole reply.
  final String text;
  const CliReply(this.kind, this.text);
  bool get isOk => kind == ReplyKind.ok;
  bool get isValue => kind == ReplyKind.value;
}

/// Reads a reply: `> value`, `OK...`, `Error...`/`ERR...`/`Err - ...`, `??: x`/`unsupported`/`Unknown command`.
CliReply parseReply(String reply) {
  final r = reply.trim();
  if (r.startsWith('> ')) return CliReply(ReplyKind.value, r.substring(2));
  if (r == '>') return const CliReply(ReplyKind.value, '');
  if (r.startsWith('??:') || r == 'Unknown command' || r.contains('unsupported') || r.contains('Unsupported') || r.startsWith('unknown config')) {
    return CliReply(ReplyKind.unsupported, r);
  }
  if (r.startsWith('OK') || r == 'ok' || r.startsWith('(OK')) return CliReply(ReplyKind.ok, r);
  if (r.startsWith('Error') || r.startsWith('ERR') || r.startsWith('Err') || r.startsWith('(ERR') || r.startsWith('ERROR')) {
    return CliReply(ReplyKind.error, r);
  }
  return CliReply(ReplyKind.value, r);
}

/// `21:23 - 31/10/2026 UTC` (the `clock` reply) -> epoch seconds; null when it does not parse.
int? parseClockReply(String reply) {
  final m = RegExp(r'(\d{1,2}):(\d{2}) - (\d{1,2})/(\d{1,2})/(\d{4})').firstMatch(reply);
  if (m == null) return null;
  final d = DateTime.utc(int.parse(m[5]!), int.parse(m[4]!), int.parse(m[3]!), int.parse(m[1]!), int.parse(m[2]!));
  return d.millisecondsSinceEpoch ~/ 1000;
}

/// Is [name] a name the firmware accepts? Rejects the characters `[ ] \ : , ? *` (it answers `Error, bad chars`) and
/// control characters; at most 31 bytes.
String? validateNodeName(String name) {
  if (name.trim().isEmpty) return 'A name cannot be empty.';
  if (name != name.trim()) return 'No spaces at the start or end.';
  if (RegExp(r'[\[\]\\:,?*]').hasMatch(name)) return 'These characters are not allowed in a name: [ ] \\ : , ? *';
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) return 'No control characters.';
  if (name.runes.length > 31 || _utf8Len(name) > 31) return 'At most 31 bytes.';
  return null;
}

int _utf8Len(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80 ? 1 : r < 0x800 ? 2 : r < 0x10000 ? 3 : 4;
  }
  return n;
}

int utf8Length(String s) => _utf8Len(s);
