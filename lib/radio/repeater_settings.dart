// The typed settings of a repeater: for every command the app can WRITE there is one [SettingDef] with its type, range,
// unit, danger level, when it takes effect, how to read it back, and what to tell the person before it is sent.
// The session (repeater_admin.dart) refuses to write anything that is not described here. Pure Dart.
//
// Ranges are the ones the firmware checks (CommonCLI.cpp / CommonRadioPrefs.cpp, MeshCore main of Oct 2026) or, where the
// firmware checks nothing (`set tx`, `set lat`, `set lon`, `set int.thresh`, `set multi.acks`), the ones the app imposes.
// Research: meshsonar-infra/docs/planning/repeater-observer-live-research-2026-11-01.md section A3.
// ignore_for_file: prefer_initializing_formals
import 'repeater_cli.dart';

/// How much harm a setting can do. Decides what the confirm step asks for.
enum Danger {
  /// Nothing lasting; no setting uses this today (reads and actions do).
  safe,

  /// Changes a stored value that can be set back over the air whenever the repeater is reachable.
  reversible,

  /// Can cut the repeater off from the mesh or hurt the mesh; recoverable only while it is still reachable.
  disruptive,

  /// Can need a cable or a re-flash to recover. Always needs a typed confirmation.
  bricking,
}

enum TakesEffect {
  /// Applied as soon as it is saved.
  live,

  /// Saved now, used after the next reboot (`OK - reboot to apply`).
  afterReboot,
}

enum SettingGroup { identity, radio, routing, access, advanced }

enum SettingKind { text, integer, decimal, toggle, choice, radio, secret }

/// What the person did on the confirm step.
class Confirmation {
  /// They read the consequences and pressed the apply button.
  final bool acknowledged;

  /// What they typed, for settings that need a typed phrase.
  final String typed;
  const Confirmation({this.acknowledged = false, this.typed = ''});

  /// A plain "yes, apply" for a setting that needs no typed phrase.
  static const Confirmation yes = Confirmation(acknowledged: true);
}

/// Limits that depend on the board.
class BoardLimits {
  /// Highest TX power the app lets you set, dBm.
  final int maxTxDbm;
  const BoardLimits(this.maxTxDbm);

  /// The CLI doc says 1-22. Measured: a Heltec V4.3 reports `get tx` = 28 (its power amplifier adds gain). Unknown boards
  /// get the documented 22. Decision recorded in HANDOFF.
  static BoardLimits forBoard(String? board) {
    final b = (board ?? '').toLowerCase();
    if (b.contains('heltec') && b.contains('v4')) return const BoardLimits(28);
    return const BoardLimits(22);
  }
}

/// One writable setting.
class SettingDef {
  final String key;
  final String label;
  final SettingGroup group;
  final SettingKind kind;
  final Danger danger;
  final TakesEffect effect;
  final String? unit;
  final num? min;
  final num? max;
  final int? maxBytes;
  final List<String> choices;

  /// One plain sentence for the form.
  final String help;

  /// Hidden under "Advanced" in the form.
  final bool expert;

  /// The value is a secret: never shown, never logged, no undo.
  final bool secret;

  /// The read command (without a leading `get`): `get <readKey>`. Null for [secret] write-only settings without a read.
  final String? readKey;

  final String? Function(String raw, BoardLimits limits) _validate;
  final String Function(String raw) _normalize;
  final String Function(String normalized) _command;
  final bool Function(String read, String wanted) _same;
  final String? Function(String? current, String next) _typed;
  final String Function(String? current, String next) _consequence;
  final List<String> Function(String? current, String next, BoardLimits limits) _warnings;

  SettingDef._({
    required this.key,
    required this.label,
    required this.group,
    required this.kind,
    required this.danger,
    this.effect = TakesEffect.live,
    this.unit,
    this.min,
    this.max,
    this.maxBytes,
    this.choices = const [],
    required this.help,
    this.expert = false,
    this.secret = false,
    String? readKey,
    required String? Function(String raw, BoardLimits limits) validate,
    String Function(String raw)? normalize,
    required String Function(String normalized) command,
    bool Function(String read, String wanted)? same,
    String? Function(String? current, String next)? typed,
    required String Function(String? current, String next) consequence,
    List<String> Function(String? current, String next, BoardLimits limits)? warnings,
  })  : readKey = readKey ?? key,
        _validate = validate,
        _normalize = normalize ?? _trim,
        _command = command,
        _same = same ?? _eq,
        _typed = typed ?? _noPhrase,
        _consequence = consequence,
        _warnings = warnings ?? _noWarnings;

  /// Why [raw] is not acceptable, or null.
  String? validate(String raw, BoardLimits limits) => _validate(raw, limits);

  /// The canonical text of [raw] (call after [validate] passed).
  String normalize(String raw) => _normalize(raw);

  /// The exact command to send for the normalized value. Built here, never by the caller.
  String command(String normalized) => _command(normalized);

  /// The read command, e.g. `get name`.
  String? get getCommand => readKey == null ? null : 'get $readKey';

  /// Stand-ins for changes that are not `set` commands (regions, access list), so they can share [ChangePlan] and
  /// [AppliedChange]. They are not in [repeaterSettings] and cannot be written through the settings API.
  factory SettingDef.regionPlaceholder() => SettingDef._(
        key: 'region',
        label: 'Regions',
        group: SettingGroup.routing,
        kind: SettingKind.choice,
        danger: Danger.disruptive,
        help: 'Flood scopes.',
        validate: (r, l) => 'Use the Regions screen.',
        command: (n) => 'region',
        consequence: (c, n) => '',
      );

  factory SettingDef.accessPlaceholder() => SettingDef._(
        key: 'access',
        label: 'Access list',
        group: SettingGroup.access,
        kind: SettingKind.choice,
        danger: Danger.disruptive,
        help: 'Who may log in.',
        validate: (r, l) => 'Use the Access screen.',
        command: (n) => 'setperm',
        consequence: (c, n) => '',
      );

  /// Does the repeater's read-back [read] equal [wanted]?
  bool matches(String read, String wanted) => _same(read, wanted);

  /// The phrase to type for this change, or null when none is needed. A bricking setting always has one.
  String? typedPhrase(String? current, String next) => _typed(current, next);

  /// What happens, in plain words.
  String consequence(String? current, String next) => _consequence(current, next);

  List<String> warnings(String? current, String next, BoardLimits limits) => _warnings(current, next, limits);

  /// What to show for a stored value.
  String display(String? v) {
    if (secret) return '••••';
    if (v == null) return 'not read';
    if (kind == SettingKind.toggle) return v == 'on' ? 'On' : 'Off';
    if (v.isEmpty) return 'empty';
    return unit == null || kind == SettingKind.radio ? v : '$v $unit';
  }
}

String _trim(String s) => s.trim();
bool _eq(String a, String b) => a.trim() == b.trim();
String? _noPhrase(String? c, String n) => null;
List<String> _noWarnings(String? c, String n, BoardLimits l) => const [];

double? _num(String s) => double.tryParse(s.trim().replaceAll('%', ''));

bool _numEq(String a, String b, [double tol = 0.0005]) {
  final x = _num(a), y = _num(b);
  return x != null && y != null && (x - y).abs() <= tol;
}

String _fmt(num v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  var s = v.toStringAsFixed(6);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  return s;
}

SettingDef _intSetting(
  String key,
  String label,
  SettingGroup group,
  int min,
  int max, {
  String? unit,
  Danger danger = Danger.reversible,
  bool expert = false,
  required String help,
  int step = 1,
  String Function(String? c, String n)? consequence,
  String? Function(String? c, String n)? typed,
  List<String> Function(String? c, String n, BoardLimits l)? warnings,
  int Function(BoardLimits l)? maxFor,
  bool Function(int v)? valid,
  String? invalidMessage,
}) =>
    SettingDef._(
      key: key,
      label: label,
      group: group,
      kind: SettingKind.integer,
      danger: danger,
      unit: unit,
      min: min,
      max: max,
      help: help,
      expert: expert,
      validate: (raw, l) {
        final v = int.tryParse(raw.trim());
        final hi = maxFor?.call(l) ?? max;
        if (v == null) return 'Enter a whole number.';
        if (v < min || v > hi) return 'Between $min and $hi${unit == null ? '' : ' $unit'}.';
        if (step > 1 && v % step != 0) return 'A multiple of $step.';
        if (valid != null && !valid(v)) return invalidMessage ?? 'Not a value the repeater accepts.';
        return null;
      },
      normalize: (r) => int.parse(r.trim()).toString(),
      command: (n) => 'set $key $n',
      same: (read, want) => _numEq(read, want),
      typed: typed,
      consequence: consequence ?? (c, n) => 'Sets $label to $n${unit == null ? '' : ' $unit'}${c == null ? '' : ' (now $c)'}. Takes effect at once.',
      warnings: warnings,
    );

SettingDef _decimalSetting(String key, String label, SettingGroup group, double min, double max,
    {String? unit, bool expert = false, required String help, String? readKey}) {
  return SettingDef._(
    key: key,
    label: label,
    group: group,
    kind: SettingKind.decimal,
    danger: Danger.reversible,
    unit: unit,
    min: min,
    max: max,
    help: help,
    expert: expert,
    readKey: readKey,
    validate: (raw, _) {
      final v = _num(raw);
      if (v == null) return 'Enter a number.';
      if (v < min || v > max) return 'Between ${_fmt(min)} and ${_fmt(max)}.';
      return null;
    },
    normalize: (r) => _fmt(_num(r)!),
    command: (n) => 'set $key $n',
    same: (read, want) => _numEq(read, want),
    consequence: (c, n) => 'Sets $label to $n${unit == null ? '' : ' $unit'}${c == null ? '' : ' (now $c)'}. Takes effect at once.',
  );
}

SettingDef _toggleSetting(String key, String label, SettingGroup group,
    {bool expert = false,
    required String help,
    Danger danger = Danger.reversible,
    String? Function(String? c, String n)? typed,
    required String Function(String? c, String n) consequence}) {
  return SettingDef._(
    key: key,
    label: label,
    group: group,
    kind: SettingKind.toggle,
    danger: danger,
    help: help,
    expert: expert,
    choices: const ['on', 'off'],
    validate: (raw, _) => raw.trim() == 'on' || raw.trim() == 'off' ? null : 'On or off.',
    command: (n) => 'set $key $n', // exactly "on" or "off": the firmware reads anything but "off" as on
    typed: typed,
    consequence: consequence,
  );
}

SettingDef _choiceSetting(String key, String label, SettingGroup group, List<String> choices,
    {required String help, bool expert = false, required String Function(String? c, String n) consequence, List<String> Function(String? c, String n, BoardLimits l)? warnings}) {
  return SettingDef._(
    key: key,
    label: label,
    group: group,
    kind: SettingKind.choice,
    danger: Danger.reversible,
    help: help,
    expert: expert,
    choices: choices,
    validate: (raw, _) => choices.contains(raw.trim()) ? null : 'One of: ${choices.join(', ')}.',
    command: (n) => 'set $key $n',
    consequence: consequence,
    warnings: warnings,
  );
}

/// The registry. Order is the order of the form.
final List<SettingDef> repeaterSettings = List.unmodifiable([
  // ---------------------------------------------------------------- identity
  SettingDef._(
    key: 'name',
    label: 'Name',
    group: SettingGroup.identity,
    kind: SettingKind.text,
    danger: Danger.reversible,
    maxBytes: 31,
    help: 'Shown to everyone who hears this repeater. Others see a new name after its next advert. Only the first 23 bytes fit in an advert that carries a position.',
    validate: (raw, _) => validateNodeName(raw),
    command: (n) => 'set name $n',
    consequence: (c, n) => 'Renames the repeater${c == null ? '' : ' from "$c"'} to "$n". Maps and contact lists show the new name after its next advert. A claim on this repeater stays yours.',
    warnings: (c, n, l) => [if (utf8Length(n) > 23) 'Longer than 23 bytes: adverts that carry a position cut the name.'],
  ),
  SettingDef._(
    key: 'lat',
    label: 'Latitude',
    group: SettingGroup.identity,
    kind: SettingKind.decimal,
    danger: Danger.reversible,
    unit: 'degrees',
    min: -90,
    max: 90,
    help: 'Published in every advert, so anyone can see where this repeater is.',
    validate: (raw, _) {
      final v = _num(raw);
      if (v == null) return 'Enter a number such as 39.9612.';
      if (v < -90 || v > 90) return 'Between -90 and 90.';
      return null;
    },
    normalize: (r) => _num(r)!.toStringAsFixed(6),
    command: (n) => 'set lat $n',
    same: (read, want) => _numEq(read, want, 0.00005),
    consequence: (c, n) => 'Moves the repeater\'s published position${c == null ? '' : ' from $c'} to $n. Every advert shows it, on the public map too.',
  ),
  SettingDef._(
    key: 'lon',
    label: 'Longitude',
    group: SettingGroup.identity,
    kind: SettingKind.decimal,
    danger: Danger.reversible,
    unit: 'degrees',
    min: -180,
    max: 180,
    help: 'Published in every advert, so anyone can see where this repeater is.',
    validate: (raw, _) {
      final v = _num(raw);
      if (v == null) return 'Enter a number such as -82.9988.';
      if (v < -180 || v > 180) return 'Between -180 and 180.';
      return null;
    },
    normalize: (r) => _num(r)!.toStringAsFixed(6),
    command: (n) => 'set lon $n',
    same: (read, want) => _numEq(read, want, 0.00005),
    consequence: (c, n) => 'Moves the repeater\'s published position${c == null ? '' : ' from $c'} to $n. Every advert shows it, on the public map too.',
  ),
  SettingDef._(
    key: 'owner.info',
    label: 'Owner info',
    group: SettingGroup.identity,
    kind: SettingKind.text,
    danger: Danger.reversible,
    maxBytes: 120,
    help: 'A short note anyone can read from the repeater. Use | for a new line.',
    validate: (raw, _) {
      if (RegExp(r'[\x00-\x08\x0b-\x1f\x7f]').hasMatch(raw)) return 'No control characters.';
      if (utf8Length(raw.replaceAll('\n', '|')) > 120) return 'At most 120 bytes.';
      return null;
    },
    normalize: (r) => r.trim().replaceAll('\n', '|'),
    command: (n) => 'set owner.info $n',
    consequence: (c, n) => 'Replaces the owner note. It is public: anyone who asks the repeater can read it.',
  ),
  _intSetting('advert.interval', 'Local advert interval', SettingGroup.identity, 0, 240,
      unit: 'min',
      step: 2,
      valid: (v) => v == 0 || v >= 60,
      invalidMessage: '0 (off) or 60 to 240 minutes.',
      help: 'How often the repeater sends a zero-hop advert to its direct neighbours. 0 turns it off; otherwise 60 to 240, in even minutes.',
      consequence: (c, n) => 'Sets the zero-hop advert interval to ${n == '0' ? 'off' : '$n minutes'}${c == null ? '' : ' (now $c)'}.',
      warnings: (c, n, l) => [if (int.parse(n) != 0 && int.parse(n) < 60) 'Under 60 minutes: the repeater turns this off.']),
  _intSetting('flood.advert.interval', 'Flood advert interval', SettingGroup.identity, 0, 168,
      unit: 'h',
      valid: (v) => v == 0 || v >= 3,
      invalidMessage: '0 (off) or 3 to 168 hours.',
      help: 'How often the repeater tells the whole mesh it exists. 0 turns it off; otherwise 3 to 168 hours.',
      consequence: (c, n) => 'Sets the flood advert interval to ${n == '0' ? 'off' : '$n hours'}${c == null ? '' : ' (now $c)'}. Every flood advert uses airtime on every repeater that passes it on.',
      warnings: (c, n, l) => [if (int.parse(n) > 0 && int.parse(n) < 3) 'The repeater accepts 0 or 3 to 168 hours.']),

  // ---------------------------------------------------------------- radio
  SettingDef._(
    key: 'radio',
    label: 'Radio parameters',
    group: SettingGroup.radio,
    kind: SettingKind.radio,
    danger: Danger.disruptive,
    effect: TakesEffect.afterReboot,
    help: 'Frequency, bandwidth, spreading factor and coding rate. Every radio that talks to this repeater must use the same four values.',
    validate: (raw, _) {
      final p = parseRadioParams(raw);
      if (p == null) return 'Four numbers: frequency MHz, bandwidth kHz, spreading factor, coding rate.';
      if (p.freqMhz < 150 || p.freqMhz > 2500) return 'Frequency between 150 and 2500 MHz.';
      if (p.bwKhz < 7 || p.bwKhz > 500) return 'Bandwidth between 7 and 500 kHz.';
      if (p.sf < 5 || p.sf > 12) return 'Spreading factor 5 to 12.';
      if (p.cr < 5 || p.cr > 8) return 'Coding rate 5 to 8.';
      return null;
    },
    normalize: (r) => parseRadioParams(r)!.text,
    command: (n) => 'set radio $n',
    same: (read, want) {
      final a = parseRadioParams(read), b = parseRadioParams(want);
      return a != null && b != null && (a.freqMhz - b.freqMhz).abs() <= 0.0011 && (a.bwKhz - b.bwKhz).abs() <= 0.051 && a.sf == b.sf && a.cr == b.cr;
    },
    typed: (c, n) => 'RADIO',
    consequence: (c, n) =>
        'Saves new radio parameters${c == null ? '' : ' (now $c)'} -> $n. They apply after the repeater reboots. From then on this repeater only hears radios on $n; every radio that should still talk to it, including yours, must be changed to match. A wrong value takes the repeater off the air and it can only be fixed on site.',
  ),
  _intSetting('tx', 'TX power', SettingGroup.radio, 1, 30,
      unit: 'dBm',
      maxFor: (l) => l.maxTxDbm,
      help: 'Transmit power. Check your local rules: the legal limit is often lower than the radio can do.',
      consequence: (c, n) => 'Sets transmit power to $n dBm${c == null ? '' : ' (now $c)'}. Takes effect at once. You are responsible for staying inside the legal limit for your band.',
      warnings: (c, n, l) => [
            if (int.parse(n) > l.maxTxDbm) 'More than ${l.maxTxDbm} dBm is above what this board is documented to do.',
            if (int.parse(n) > 22) 'Above 22 dBm: check that your local rules and your antenna allow it.',
          ]),
  _decimalSetting('af', 'Airtime factor', SettingGroup.radio, 0, 9,
      expert: true, help: 'How long the repeater waits after sending, as a multiple of the packet\'s airtime. Higher means politer and slower.'),
  _intSetting('dutycycle', 'Duty cycle', SettingGroup.radio, 1, 100,
      unit: '%',
      expert: true,
      help: 'The share of time the repeater may transmit. Your local rules may cap this (for example 1% or 10%).',
      consequence: (c, n) => 'Allows the repeater to transmit up to $n% of the time${c == null ? '' : ' (now $c)'}. Check your local duty-cycle rule.',
      warnings: (c, n, l) => [if (int.parse(n) > 10) 'Above 10%: many regions limit repeaters to 10% or less.']),
  _decimalSetting('txdelay', 'Flood TX delay', SettingGroup.radio, 0, 2,
      expert: true, help: 'Random wait before repeating a flooded packet, so neighbours do not collide.'),
  _decimalSetting('direct.txdelay', 'Direct TX delay', SettingGroup.radio, 0, 2,
      expert: true, help: 'Random wait before repeating a direct packet.'),
  _decimalSetting('rxdelay', 'RX delay base', SettingGroup.radio, 0, 20,
      expert: true, help: 'Experimental: delays repeats of weak packets so stronger copies win.'),
  _intSetting('int.thresh', 'Interference threshold', SettingGroup.radio, 0, 200,
      expert: true, help: 'Noise level above which the repeater waits before sending. 0 is off.'),
  _toggleSetting('cad', 'Listen before talk', SettingGroup.radio,
      expert: true,
      help: 'Check the channel is quiet before sending.',
      consequence: (c, n) => 'Turns channel-activity detection ${n == 'on' ? 'on' : 'off'}.'),
  _intSetting('agc.reset.interval', 'AGC reset interval', SettingGroup.radio, 0, 1020,
      unit: 's', step: 4, expert: true, help: 'How often the receiver gain is reset. 0 is off; multiples of 4 seconds.'),

  // ---------------------------------------------------------------- routing
  _toggleSetting('repeat', 'Repeat packets', SettingGroup.routing,
      danger: Danger.disruptive,
      help: 'Turn off and this node stops forwarding other people\'s packets. It still answers you.',
      typed: (c, n) => n == 'off' ? 'REPEAT OFF' : null,
      consequence: (c, n) => n == 'off'
          ? 'This repeater will STOP repeating. Every radio that reaches the mesh through it loses that path. You can still reach it, and turn this back on, as long as your own radio hears it.'
          : 'This node will repeat other radios\' packets again.'),
  _intSetting('flood.max', 'Flood hop limit', SettingGroup.routing, 0, 64,
      unit: 'hops',
      help: 'The most hops a flooded packet may have travelled for this repeater to pass it on.',
      danger: Danger.disruptive,
      typed: (c, n) => int.parse(n) < 3 ? 'LOW LIMIT' : null,
      consequence: (c, n) => 'Flooded packets that already travelled more than $n hops are no longer passed on by this repeater${c == null ? '' : ' (now $c)'}.',
      warnings: (c, n, l) => [if (int.parse(n) < 3) 'Under 3 hops this repeater passes on almost nothing from farther away.']),
  _intSetting('flood.max.unscoped', 'Hop limit, unscoped floods', SettingGroup.routing, 0, 64,
      unit: 'hops', expert: true, help: 'Hop limit for floods that carry no region scope.'),
  _intSetting('flood.max.advert', 'Hop limit, adverts', SettingGroup.routing, 0, 64,
      unit: 'hops', expert: true, help: 'Hop limit for adverts.'),
  _intSetting('path.hash.mode', 'Path hash size', SettingGroup.routing, 0, 2,
      expert: true,
      help: '0 is 1 byte, 1 is 2 bytes, 2 is 3 bytes per hop in the repeater\'s own adverts.',
      consequence: (c, n) =>
          'Sets the hash size of this repeater\'s own flood adverts to ${int.parse(n) + 1} byte(s)${c == null ? '' : ' (now $c)'}. Repeaters running firmware older than 1.14 drop multi-byte-hash floods, so this can hide the repeater from them.',
      warnings: (c, n, l) => [if (int.parse(n) > 0) 'Old neighbours (firmware before 1.14) will not forward this repeater\'s adverts.']),
  _choiceSetting('loop.detect', 'Loop detection', SettingGroup.routing, const ['off', 'minimal', 'moderate', 'strict'],
      expert: true,
      help: 'How hard the repeater tries to drop packets that come back around.',
      consequence: (c, n) => 'Sets loop detection to $n${c == null ? '' : ' (now $c)'}.'),
  _intSetting('multi.acks', 'Extra ACK copies', SettingGroup.routing, 0, 1,
      expert: true, help: '1 sends each acknowledgement twice.'),

  // ---------------------------------------------------------------- access
  _toggleSetting('allow.read.only', 'Guests may read (room servers)', SettingGroup.access,
      expert: true,
      help: 'A room server lets anyone with no password read it when this is on.',
      consequence: (c, n) => n == 'on' ? 'Anyone can log in to this room without a password and read it.' : 'Only people with the room or admin password can log in.'),
  SettingDef._(
    key: 'guest.password',
    label: 'Guest password',
    group: SettingGroup.access,
    kind: SettingKind.secret,
    danger: Danger.reversible,
    secret: true,
    maxBytes: 15,
    help: 'Lets someone read this repeater (status, telemetry) without being an admin. Up to 15 characters. Never shown again after you set it.',
    validate: (raw, _) => validateSecretText(raw, 'guest password'),
    normalize: (r) => r,
    command: (n) => 'set guest.password $n',
    consequence: (c, n) => 'Sets a new guest password. Anyone who knows it can log in as a guest. The old guest password stops working. This cannot be undone from here because the old one is never shown.',
  ),
  SettingDef._(
    key: 'password',
    label: 'Admin password',
    group: SettingGroup.access,
    kind: SettingKind.secret,
    danger: Danger.bricking,
    secret: true,
    maxBytes: 15,
    readKey: null,
    help: 'The password that lets someone administer this repeater. Up to 15 characters (a radio cannot send more).',
    validate: (raw, _) => validateSecretText(raw, 'admin password'),
    normalize: (r) => r,
    command: (n) => 'password $n',
    typed: (c, n) => 'CHANGE PASSWORD',
    consequence: (c, n) =>
        'Changes the admin password. If you mistype it or forget it you cannot log in again, and the only way back is a cable at the repeater. Radios that are already admins stay admins: changing the password does not remove them (use the Access list for that).',
  ),
]);

/// A setting by key; null when the app does not describe it.
SettingDef? settingFor(String key) {
  for (final s in repeaterSettings) {
    if (s.key == key) return s;
  }
  return null;
}

/// Passwords from a radio: 1 to 15 printable characters, no control characters, no leading or trailing space. Longer ones
/// are cut by the companion radio, so a repeater given one could never be logged in to again.
String? validateSecretText(String raw, String what) {
  if (raw.isEmpty) return 'A $what cannot be empty.';
  if (utf8Length(raw) > 15) return 'At most 15 bytes: a radio cuts longer passwords when it logs in.';
  if (raw != raw.trim()) return 'No spaces at the start or end.';
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(raw)) return 'No control characters.';
  return null;
}

/// Four radio parameters.
class RadioParams {
  final double freqMhz;
  final double bwKhz;
  final int sf;
  final int cr;
  const RadioParams(this.freqMhz, this.bwKhz, this.sf, this.cr);

  String get text => '${_fmt(freqMhz)},${_fmt(bwKhz)},$sf,$cr';
  @override
  String toString() => '${_fmt(freqMhz)} MHz, ${_fmt(bwKhz)} kHz, SF$sf, CR$cr';
}

/// `910.525,62.5,7,5` (also with spaces) -> params; null if it is not four numbers.
RadioParams? parseRadioParams(String s) {
  final p = s.trim().split(RegExp(r'\s*,\s*|\s+'));
  if (p.length != 4) return null;
  final f = double.tryParse(p[0]), b = double.tryParse(p[1]);
  final sf = int.tryParse(p[2]), cr = int.tryParse(p[3]);
  if (f == null || b == null || sf == null || cr == null) return null;
  return RadioParams(f, b, sf, cr);
}
