// Device settings: the writes of the Device settings screen (chat plan 4.14, WP12) that Radio setup does not do, and the
// guard rails for all of them.
//
//  * Every write is: validate on the phone -> send -> READ BACK (fresh SELF_INFO or DEVICE_INFO, never a cached copy) ->
//    compare. "Saved" means the radio reports it. A write that reads back differently is reported, not hidden.
//  * The radio's answers map to ONE error vocabulary ([DeviceErrorKind]). ERR 1 (unsupported) and DISABLED (15) switch the
//    feature OFF for this radio ([unavailable]) and the screen hides the row and lists the reason.
//  * Destructive actions check their typed word HERE as well as in the UI (factory reset: RESET, identity import: REPLACE),
//    so a caller that skipped the UI cannot skip the confirmation.
//  * The identity key lives in memory for the length of one call, is zeroed after, and is never logged or put in a message.
//
// Commands (protocol.dart "device settings"): SET_OTHER_PARAMS 38, SET_PATH_HASH_MODE 61, SET_DEVICE_PIN 37, REBOOT 19,
// FACTORY_RESET 51, EXPORT/IMPORT_PRIVATE_KEY 23/24, RUN_CLI_COMMAND 66, GET_BATT_AND_STORAGE 20, GET/SET_AUTOADD_CONFIG 59/58.
// Layouts are from the firmware source, not from a radio. Pure Dart.
import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:typed_data';

import '../../chat/backup.dart';
import '../../chat/backup_crypto.dart';
import '../caps.dart';
import '../command_queue.dart';
import '../inbound.dart' show ContactPolicy, RadioChannel;
import '../protocol.dart';
import 'radio_setup.dart' show RadioConfig;
import 'tool_state.dart';
import 'tools_radio.dart';

/// Words a person types to confirm what cannot be undone.
abstract final class TypedConfirm {
  static const String factoryReset = 'RESET';
  static const String replaceIdentity = 'REPLACE';

  /// True only for exactly [word] (surrounding spaces ignored, case must match: the point is to slow the hand down).
  static bool matches(String typed, String word) => typed.trim() == word;
}

/// Why a device call did not work, in the radio's terms.
enum DeviceErrorKind {
  /// ERR 1: this firmware does not know the command.
  unsupported,

  /// DISABLED (15): the firmware knows it but was built without it (private key export/import).
  disabled,

  /// ERR 6: the radio refused the value.
  refused,

  /// ERR 5: the radio could not write its storage.
  storage,

  /// ERR 2 / 3 / 4.
  notFound,
  tableFull,
  badState,

  /// No answer within the time limit.
  noAnswer,

  /// The Bluetooth link is down.
  disconnected,

  /// Anything else, including a reply that makes no sense for the command.
  unexpected,

  /// The phone refused before sending (bad value, wrong typed word, no permission).
  invalid,
}

/// Maps a reply frame to an error kind; null when [f] is an OK.
DeviceErrorKind? deviceErrorOf(Frame f) {
  if (f is OkFrame) return null;
  if (f is DisabledFrame) return DeviceErrorKind.disabled;
  if (f is ErrFrame) {
    return switch (f.code) {
      ErrCode.unsupportedCmd => DeviceErrorKind.unsupported,
      ErrCode.notFound => DeviceErrorKind.notFound,
      ErrCode.tableFull => DeviceErrorKind.tableFull,
      ErrCode.badState => DeviceErrorKind.badState,
      ErrCode.fileIoError => DeviceErrorKind.storage,
      ErrCode.illegalArg => DeviceErrorKind.refused,
      _ => DeviceErrorKind.unexpected,
    };
  }
  return DeviceErrorKind.unexpected;
}

/// Plain-language text for an error kind.
String deviceErrorText(DeviceErrorKind k, {String what = 'that'}) => switch (k) {
      DeviceErrorKind.unsupported => 'This radio\'s firmware does not support $what.',
      DeviceErrorKind.disabled => 'This radio\'s firmware was built without $what.',
      DeviceErrorKind.refused => 'The radio refused those values.',
      DeviceErrorKind.storage => 'The radio could not save that to its own storage.',
      DeviceErrorKind.notFound => 'The radio did not find what it was asked for.',
      DeviceErrorKind.tableFull => 'The radio\'s list is full.',
      DeviceErrorKind.badState => 'The radio is busy. Try again in a moment.',
      DeviceErrorKind.noAnswer => 'The radio did not answer. Check what it reports before trying again.',
      DeviceErrorKind.disconnected => 'The radio disconnected.',
      DeviceErrorKind.unexpected => 'The radio gave an unexpected answer.',
      DeviceErrorKind.invalid => 'That value cannot be used.',
    };

/// The features of the Device settings screen that depend on the radio's firmware.
enum DeviceFeature { battery, pathHashMode, console, identityKeyExport, identityKeyImport, autoAdd }

class DeviceResult {
  final bool ok;
  final String message;
  final DeviceErrorKind? error;

  /// The radio reported the new value when asked again.
  final bool verified;
  const DeviceResult.ok(this.message, {this.verified = true})
      : ok = true,
        error = null;
  const DeviceResult.fail(this.message, this.error)
      : ok = false,
        verified = false;
}

/// What the screen shows, as last read.
class DeviceSnapshot {
  final RadioConfig config;
  final DeviceInfoFrame? info;
  final BattAndStorageFrame? battery;
  final ContactPolicy? policy;
  const DeviceSnapshot({required this.config, this.info, this.battery, this.policy});

  TelemetryModes get telemetry => TelemetryModes.fromByte(config.telemetryModes);
  String? get firmwareVersion => info?.firmwareVersion;

  /// Hash size in bytes per hop now (1-3), or null when the radio does not report a mode.
  int? get pathHashBytes => info?.pathHashMode == null ? null : info!.pathHashMode! + 1;
}

/// Rough charge from a single-cell LiPo's resting voltage. An ESTIMATE (the curve differs per cell and under load), so the
/// screen always shows the voltage next to it and calls the percentage estimated.
int estimateBatteryPercent(int millivolts) {
  const curve = <(int, int)>[(3300, 0), (3500, 5), (3600, 15), (3700, 30), (3800, 50), (3900, 70), (4000, 82), (4100, 92), (4200, 100)];
  if (millivolts <= curve.first.$1) return 0;
  if (millivolts >= curve.last.$1) return 100;
  for (var i = 1; i < curve.length; i++) {
    final (v1, p1) = curve[i];
    if (millivolts <= v1) {
      final (v0, p0) = curve[i - 1];
      return (p0 + (p1 - p0) * (millivolts - v0) / (v1 - v0)).round();
    }
  }
  return 100;
}

/// PIN rules. The radio takes exactly 6 digits (or 0 for a random PIN at each boot, which this app does not offer: a PIN
/// nobody knows is a locked-out phone).
abstract final class PinCheck {
  /// A reason the PIN cannot be used, or null. [confirm] is the second typing.
  static String? problem(String pin, String confirm) {
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) return 'A PIN is exactly 6 digits.';
    if (pin.startsWith('0')) return 'The first digit cannot be 0 (the radio reads the PIN as a number).';
    if (pin != confirm) return 'The two PINs are different.';
    return null;
  }

  /// A gentle warning for a PIN everybody tries first; the PIN is still allowed.
  static String? weakness(String pin) {
    if (pin == '123456' || pin == '654321' || pin == '111111' || pin == '121212') return 'That is one of the first PINs anyone tries.';
    if (RegExp(r'^(\d)\1{5}$').hasMatch(pin)) return 'That is one digit repeated.';
    return null;
  }
}

/// Local-CLI lines this app will not send. They are the console's irreversible or secret-revealing commands: reboot and
/// factory reset have their own rows with a typed confirmation, the key never leaves except through the encrypted backup.
String? blockedCliReason(String line) {
  final t = line.trim().toLowerCase();
  if (t.isEmpty) return 'Type a command.';
  bool starts(String w) => t == w || t.startsWith('$w ');
  if (t.contains('prv.key')) return 'The identity key is never shown in the console. Use Export backup.';
  if (starts('reboot') || starts('clkreboot')) return 'Use Reboot radio, which asks first.';
  if (starts('erase') || starts('factory') || starts('format')) return 'Use Factory reset, which shows what is lost and asks you to type RESET.';
  if (starts('start') && t.contains('ota')) return 'Updating firmware happens at flasher.meshcore.io, not here.';
  if (starts('poweroff') || starts('shutdown')) return 'Powering the radio off from the app can strand it somewhere you cannot reach.';
  if (utf8.encode(t).length > maxCliCommandBytes) return 'That line is too long (limit $maxCliCommandBytes bytes).';
  return null;
}

/// What a backup restore did.
class RestoreReport {
  bool identityReplaced = false;
  int channels = 0;
  int contacts = 0;
  int contactsTableFull = 0;
  int failed = 0;
  bool get needsReboot => identityReplaced;
}

class DeviceSettingsTool with ToolChanges {
  final ToolsRadio radio;
  final int backupIterations;
  final bool backupUseIsolate;
  final DateTime Function() _clock;
  DeviceSnapshot? _snapshot;
  final Map<DeviceFeature, String> _unavailable = {};
  String? _undoLabel;
  Future<DeviceResult> Function()? _undo;
  bool _busy = false;

  DeviceSettingsTool(this.radio, {this.backupIterations = BackupCrypto.defaultIterations, this.backupUseIsolate = true, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  DeviceSnapshot? get snapshot => _snapshot;
  bool get busy => _busy;
  String? get undoLabel => _undoLabel;
  bool get canUndo => _undo != null;

  /// Features this radio cannot do and why, for the "Not available on this radio" list. Rows for these are hidden.
  Map<DeviceFeature, String> get unavailable => Map.unmodifiable(_unavailable);
  bool available(DeviceFeature f) => !_unavailable.containsKey(f);

  RadioCaps get caps {
    final di = _snapshot?.info;
    return di == null ? RadioCaps.baseline : RadioCaps.fromDeviceInfo(di);
  }

  void _markUnavailable(DeviceFeature f, String reason) {
    _unavailable[f] = reason;
    notifyChanged();
  }

  // ------------------------------------------------------------ read

  /// Reads everything the screen shows. Null when the radio does not report its settings. Feature gates come from the
  /// firmware version first and from the radio's own refusal after.
  Future<DeviceSnapshot?> read() async {
    final si = await radio.readSelfInfo();
    if (si == null) return null;
    final info = await _readInfo();
    final battery = await _readBattery();
    final policy = await _readPolicy();
    _snapshot = DeviceSnapshot(config: RadioConfig.fromFrame(si), info: info, battery: battery, policy: policy);
    _applyFirmwareGates();
    notifyChanged();
    return _snapshot;
  }

  void _applyFirmwareGates() {
    final info = _snapshot?.info;
    final c = caps;
    if (info != null && !c.hasPathHashMode) {
      _unavailable[DeviceFeature.pathHashMode] = 'Needs firmware with path hash sizes (version code ${FwCode.pathHashMode} or newer). This radio reports code ${info.firmwareVerCode}.';
    } else if (info != null) {
      _unavailable.remove(DeviceFeature.pathHashMode);
    }
    if (info != null && !c.hasLocalCli) {
      final v = c.fwVersion;
      _unavailable[DeviceFeature.console] =
          'Needs firmware ${localCliMinVersion.$1}.${localCliMinVersion.$2} or newer. This radio runs ${v == null ? 'an unknown version' : '${v.$1}.${v.$2}'}.';
    } else if (info != null) {
      // stays available unless the radio itself refuses (ERR 1) on first use
      if (_unavailable[DeviceFeature.console]?.startsWith('Needs firmware') ?? false) _unavailable.remove(DeviceFeature.console);
    }
  }

  Future<DeviceInfoFrame?> _readInfo() async {
    try {
      final f = await radio.send(encodeDeviceQuery(), priority: CommandPriority.admin);
      return f is DeviceInfoFrame ? f : null;
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    }
  }

  Future<BattAndStorageFrame?> _readBattery() async {
    if (!available(DeviceFeature.battery)) return null;
    try {
      final f = await radio.send(encodeGetBattAndStorage(), priority: CommandPriority.admin);
      if (f is BattAndStorageFrame) return f;
      final k = deviceErrorOf(f);
      if (k == DeviceErrorKind.unsupported) _unavailable[DeviceFeature.battery] = 'This radio\'s firmware does not report battery and storage.';
      return null;
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    }
  }

  /// Battery and storage again (the screen refreshes it on a timer while open).
  Future<BattAndStorageFrame?> refreshBattery() async {
    final b = await _readBattery();
    final s = _snapshot;
    if (b != null && s != null) {
      _snapshot = DeviceSnapshot(config: s.config, info: s.info, battery: b, policy: s.policy);
      notifyChanged();
    }
    return b;
  }

  Future<ContactPolicy?> _readPolicy() async {
    if (!available(DeviceFeature.autoAdd)) return null;
    try {
      final si = await radio.readSelfInfo();
      if (si == null) return null;
      final f = await radio.send(encodeGetAutoAddConfig(), priority: CommandPriority.admin);
      if (f is AutoAddConfigFrame) return _policyOf(si.manualAdd != 0, f.config, f.maxHops, true);
      if (deviceErrorOf(f) == DeviceErrorKind.unsupported) {
        _unavailable[DeviceFeature.autoAdd] = 'This radio\'s firmware cannot choose which node types it adds by itself.';
        return ContactPolicy(askBeforeAdding: si.manualAdd & 1 != 0, autoAddSupported: false);
      }
      return null;
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    }
  }

  static ContactPolicy _policyOf(bool ask, int cfg, int hops, bool supported) => ContactPolicy(
        askBeforeAdding: ask,
        autoAddSupported: supported,
        autoAddChat: cfg & AutoAddFlags.chat != 0,
        autoAddRepeaters: cfg & AutoAddFlags.repeater != 0,
        autoAddRooms: cfg & AutoAddFlags.room != 0,
        autoAddSensors: cfg & AutoAddFlags.sensor != 0,
        overwriteOldest: cfg & AutoAddFlags.overwriteOldest != 0,
        maxHops: hops,
      );

  /// How many contacts the radio holds. A full GET_CONTACTS, so the screen asks once, after the first paint.
  Future<int?> contactCount() async {
    try {
      return (await radio.contacts()).length;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ guarded send

  Future<({Frame? frame, DeviceResult? failure})> _send(Uint8List frame) async {
    if (!radio.isConnected) return (frame: null, failure: DeviceResult.fail(deviceErrorText(DeviceErrorKind.disconnected), DeviceErrorKind.disconnected));
    try {
      return (frame: await radio.send(frame, priority: CommandPriority.admin), failure: null);
    } on TimeoutException {
      return (frame: null, failure: DeviceResult.fail(deviceErrorText(DeviceErrorKind.noAnswer), DeviceErrorKind.noAnswer));
    } on StateError {
      return (frame: null, failure: DeviceResult.fail(deviceErrorText(DeviceErrorKind.disconnected), DeviceErrorKind.disconnected));
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() body) async {
    _busy = true;
    notifyChanged();
    try {
      return await body();
    } finally {
      _busy = false;
      notifyChanged();
    }
  }

  // ------------------------------------------------------------ SET_OTHER_PARAMS (flags, telemetry sharing)

  /// Writes the four SET_OTHER_PARAMS fields from a FRESH SELF_INFO with [change] applied, reads back, compares.
  Future<DeviceResult> _setOther({
    required String what,
    required ({int manual, int tel, int policy, int acks}) Function(SelfInfoFrame fresh) change,
    required bool Function(SelfInfoFrame after, ({int manual, int tel, int policy, int acks}) want) verify,
    bool allowUndo = true,
  }) =>
      _exclusive(() async {
        final fresh = await radio.readSelfInfo();
        if (fresh == null) return DeviceResult.fail('Could not read the radio first. Nothing was changed.', DeviceErrorKind.noAnswer);
        final want = change(fresh);
        final s = await _send(encodeSetOtherParams(manualAdd: want.manual, telemetryModes: want.tel, advertLocPolicy: want.policy, multiAcks: want.acks));
        if (s.failure != null) return s.failure!;
        final k = deviceErrorOf(s.frame!);
        if (k != null) return DeviceResult.fail(deviceErrorText(k, what: what), k);
        final after = await radio.readSelfInfo();
        if (after == null) return const DeviceResult.ok('The radio accepted the change but did not report back, so it could not be checked.', verified: false);
        _snapshot = _snapshot == null
            ? null
            : DeviceSnapshot(config: RadioConfig.fromFrame(after), info: _snapshot!.info, battery: _snapshot!.battery, policy: _snapshot!.policy);
        if (!verify(after, want)) {
          notifyChanged();
          return DeviceResult.fail('The radio accepted the change, but it reads back differently. Check $what before relying on it.', DeviceErrorKind.unexpected);
        }
        if (allowUndo) {
          final prev = (manual: fresh.manualAdd, tel: fresh.telemetryModes, policy: fresh.advertLocPolicy, acks: fresh.multiAcks);
          _undoLabel = what;
          _undo = () => _setOther(
                what: what,
                change: (_) => prev,
                verify: (a, w) => a.manualAdd == w.manual && a.telemetryModes == w.tel && a.advertLocPolicy == w.policy && a.multiAcks == w.acks,
                allowUndo: false,
              );
        }
        return DeviceResult.ok('Saved: the radio reports the new $what.');
      });

  Future<DeviceResult> setTelemetryModes(TelemetryModes m) {
    if (!m.valid) return Future.value(DeviceResult.fail('Unknown sharing choice.', DeviceErrorKind.invalid));
    return _setOther(
      what: 'telemetry sharing',
      change: (f) => (manual: f.manualAdd, tel: m.byte, policy: f.advertLocPolicy, acks: f.multiAcks),
      verify: (a, w) => a.telemetryModes == w.tel && a.manualAdd == w.manual && a.advertLocPolicy == w.policy && a.multiAcks == w.acks,
    );
  }

  /// "Always confirm sends" (multi-acks).
  Future<DeviceResult> setMultiAcks(bool on) => _setOther(
        what: 'extra acknowledgements',
        change: (f) => (manual: f.manualAdd, tel: f.telemetryModes, policy: f.advertLocPolicy, acks: on ? 1 : 0),
        verify: (a, w) => a.multiAcks == w.acks && a.telemetryModes == w.tel && a.manualAdd == w.manual && a.advertLocPolicy == w.policy,
      );

  /// "Add new contacts myself": manual_add bit 0 (the other bits are kept).
  Future<DeviceResult> setAskBeforeAdding(bool on) => _setOther(
        what: 'contact adding',
        change: (f) => (manual: on ? (f.manualAdd | 1) : (f.manualAdd & ~1), tel: f.telemetryModes, policy: f.advertLocPolicy, acks: f.multiAcks),
        verify: (a, w) => a.manualAdd == w.manual && a.telemetryModes == w.tel && a.advertLocPolicy == w.policy && a.multiAcks == w.acks,
      );

  /// "Share location in adverts": 0 = no, 1 = yes.
  Future<DeviceResult> setShareLocation(bool on) => _setOther(
        what: 'location sharing in adverts',
        change: (f) => (manual: f.manualAdd, tel: f.telemetryModes, policy: on ? 1 : 0, acks: f.multiAcks),
        verify: (a, w) => a.advertLocPolicy == w.policy && a.telemetryModes == w.tel && a.manualAdd == w.manual && a.multiAcks == w.acks,
      );

  // ------------------------------------------------------------ auto-add

  /// Writes the per-type auto-add switches, overwrite-oldest and max hops, then reads the config back.
  Future<DeviceResult> setAutoAdd(ContactPolicy p) {
    if (!available(DeviceFeature.autoAdd)) return Future.value(DeviceResult.fail(deviceErrorText(DeviceErrorKind.unsupported, what: 'choosing node types'), DeviceErrorKind.unsupported));
    if (p.maxHops < 0 || p.maxHops > 64) return Future.value(DeviceResult.fail('Max hops is 0 to 64.', DeviceErrorKind.invalid));
    return _exclusive(() async {
      final before = _snapshot?.policy;
      final cfg = (p.overwriteOldest ? AutoAddFlags.overwriteOldest : 0) |
          (p.autoAddChat ? AutoAddFlags.chat : 0) |
          (p.autoAddRepeaters ? AutoAddFlags.repeater : 0) |
          (p.autoAddRooms ? AutoAddFlags.room : 0) |
          (p.autoAddSensors ? AutoAddFlags.sensor : 0);
      final s = await _send(encodeSetAutoAddConfig(cfg, maxHops: p.maxHops));
      if (s.failure != null) return s.failure!;
      final k = deviceErrorOf(s.frame!);
      if (k != null) {
        if (k == DeviceErrorKind.unsupported) _markUnavailable(DeviceFeature.autoAdd, 'This radio\'s firmware cannot choose which node types it adds by itself.');
        return DeviceResult.fail(deviceErrorText(k, what: 'choosing node types'), k);
      }
      final g = await _send(encodeGetAutoAddConfig());
      final f = g.frame;
      if (f is! AutoAddConfigFrame) return const DeviceResult.ok('The radio accepted the change but did not report back, so it could not be checked.', verified: false);
      final ok = f.config == cfg && f.maxHops == p.maxHops;
      final s0 = _snapshot;
      if (s0 != null) {
        _snapshot = DeviceSnapshot(config: s0.config, info: s0.info, battery: s0.battery, policy: _policyOf(s0.config.manualAdd, f.config, f.maxHops, true));
      }
      if (!ok) return DeviceResult.fail('The radio accepted the change, but it reads back differently.', DeviceErrorKind.unexpected);
      if (before != null) {
        _undoLabel = 'node types';
        _undo = () => setAutoAdd(before.copyWith(askBeforeAdding: before.askBeforeAdding)).then((r) {
              _undo = null;
              _undoLabel = null;
              return r;
            });
      }
      return const DeviceResult.ok('Saved: the radio reports the new node-type settings.');
    });
  }

  // ------------------------------------------------------------ path hash size

  /// SET_PATH_HASH_MODE. [bytes] is the hash size per hop, 1 to 3. Read back from DEVICE_INFO.
  Future<DeviceResult> setPathHashSize(int bytes) {
    if (!available(DeviceFeature.pathHashMode)) {
      return Future.value(DeviceResult.fail(_unavailable[DeviceFeature.pathHashMode] ?? deviceErrorText(DeviceErrorKind.unsupported, what: 'path hash sizes'), DeviceErrorKind.unsupported));
    }
    if (bytes < 1 || bytes > 3) return Future.value(DeviceResult.fail('A path hash is 1, 2 or 3 bytes.', DeviceErrorKind.invalid));
    return _exclusive(() async {
      final before = _snapshot?.pathHashBytes;
      final s = await _send(encodeSetPathHashMode(bytes - 1));
      if (s.failure != null) return s.failure!;
      final k = deviceErrorOf(s.frame!);
      if (k != null) {
        if (k == DeviceErrorKind.unsupported) _markUnavailable(DeviceFeature.pathHashMode, 'This radio\'s firmware refused the path hash command.');
        return DeviceResult.fail(deviceErrorText(k, what: 'path hash sizes'), k);
      }
      final info = await _readInfo();
      if (info == null || info.pathHashMode == null) {
        return const DeviceResult.ok('The radio accepted the change but did not report back, so it could not be checked.', verified: false);
      }
      final s0 = _snapshot;
      if (s0 != null) _snapshot = DeviceSnapshot(config: s0.config, info: info, battery: s0.battery, policy: s0.policy);
      if (info.pathHashMode != bytes - 1) {
        notifyChanged();
        return DeviceResult.fail('The radio accepted the change, but it reads back as ${info.pathHashMode! + 1} bytes.', DeviceErrorKind.unexpected);
      }
      if (before != null && before != bytes) {
        _undoLabel = 'path hash size';
        _undo = () async {
          _undo = null;
          _undoLabel = null;
          return setPathHashSize(before);
        };
      }
      return DeviceResult.ok('Saved: the radio reports $bytes-byte path hashes.');
    });
  }

  // ------------------------------------------------------------ Bluetooth PIN

  /// SET_DEVICE_PIN, then DEVICE_INFO to see the radio holds it. The PIN is never put in a message.
  Future<DeviceResult> setPin(String pin, String confirm) {
    final problem = PinCheck.problem(pin, confirm);
    if (problem != null) return Future.value(DeviceResult.fail(problem, DeviceErrorKind.invalid));
    final value = int.parse(pin);
    return _exclusive(() async {
      final s = await _send(encodeSetDevicePin(value));
      if (s.failure != null) return s.failure!;
      final k = deviceErrorOf(s.frame!);
      if (k != null) return DeviceResult.fail(deviceErrorText(k, what: 'a Bluetooth PIN'), k);
      final info = await _readInfo();
      final bp = info?.blePin;
      if (bp == null) {
        return const DeviceResult.ok('The radio accepted the new PIN but did not report back, so it could not be checked. It applies the next time you pair.', verified: false);
      }
      if (bp != value) return DeviceResult.fail('The radio accepted the PIN, but it reads back differently. Try again.', DeviceErrorKind.unexpected);
      return const DeviceResult.ok('Saved: the radio holds the new PIN. It applies the next time you pair.');
    });
  }

  // ------------------------------------------------------------ reboot / factory reset

  /// REBOOT. The radio restarts without a reply, so a timeout or a dropped link IS the success.
  Future<DeviceResult> reboot() => _exclusive(() async {
        if (!radio.isConnected) return DeviceResult.fail(deviceErrorText(DeviceErrorKind.disconnected), DeviceErrorKind.disconnected);
        try {
          final f = await radio.send(encodeReboot(), priority: CommandPriority.admin);
          final k = deviceErrorOf(f);
          if (k != null && f is! OkFrame) return DeviceResult.fail(deviceErrorText(k, what: 'rebooting'), k);
        } on TimeoutException {
          // expected: no reply
        } on StateError {
          // expected: the link went down with the radio
        }
        return const DeviceResult.ok('The radio is restarting. MeshSonar reconnects when it is back.', verified: false);
      });

  /// FACTORY_RESET. Refuses unless [typed] is exactly RESET, whatever the caller's UI did.
  Future<DeviceResult> factoryReset(String typed) => _exclusive(() async {
        if (!TypedConfirm.matches(typed, TypedConfirm.factoryReset)) {
          return DeviceResult.fail('Type ${TypedConfirm.factoryReset} to confirm.', DeviceErrorKind.invalid);
        }
        if (!radio.isConnected) return DeviceResult.fail(deviceErrorText(DeviceErrorKind.disconnected), DeviceErrorKind.disconnected);
        try {
          final f = await radio.send(encodeFactoryReset(), priority: CommandPriority.admin);
          final k = deviceErrorOf(f);
          if (k != null) return DeviceResult.fail(deviceErrorText(k, what: 'a factory reset'), k);
        } on TimeoutException {
          // the radio formats and restarts; a missing reply is not a failure
        } on StateError {
          // link dropped with the restart
        }
        _snapshot = null;
        _undo = null;
        _undoLabel = null;
        return const DeviceResult.ok('The radio was reset and is restarting. It has a new identity now.', verified: false);
      });

  // ------------------------------------------------------------ backup / restore

  /// Reads the radio's contacts, channels and (when the firmware allows) identity key into an ENCRYPTED backup file.
  /// Returns the file bytes. The key never leaves this method in clear. A radio that refuses the key export still gets a
  /// contacts-and-channels backup, and [identityIncluded] says so.
  Future<({Uint8List? file, bool identityIncluded, DeviceResult result})> exportBackup(String passphrase) async {
    final problem = RadioBackup.passphraseProblem(passphrase);
    if (problem != null) return (file: null, identityIncluded: false, result: DeviceResult.fail(problem, DeviceErrorKind.invalid));
    return _exclusive(() async {
      final cfg = _snapshot?.config;
      final si = cfg == null ? await radio.readSelfInfo() : null;
      final config = cfg ?? (si == null ? null : RadioConfig.fromFrame(si));
      if (config == null) {
        return (file: null, identityIncluded: false, result: DeviceResult.fail('Could not read the radio first. Nothing was backed up.', DeviceErrorKind.noAnswer));
      }
      Uint8List? key;
      final s = await _send(encodeExportPrivateKey());
      if (s.failure != null) return (file: null, identityIncluded: false, result: s.failure!);
      final f = s.frame;
      if (f is PrivateKeyFrame) {
        key = Uint8List.fromList(f.key);
        f.key.fillRange(0, f.key.length, 0);
      } else {
        final k = deviceErrorOf(f!);
        if (k == DeviceErrorKind.disabled || k == DeviceErrorKind.unsupported) {
          _unavailable[DeviceFeature.identityKeyExport] = 'This radio\'s firmware does not allow exporting its identity key. Backups hold contacts and channels only.';
        } else {
          return (file: null, identityIncluded: false, result: DeviceResult.fail(deviceErrorText(k ?? DeviceErrorKind.unexpected, what: 'exporting the key'), k ?? DeviceErrorKind.unexpected));
        }
      }
      final data = RadioBackupData(
        radioName: config.name,
        publicKeyHex: config.publicKeyHex,
        createdMs: _clock().millisecondsSinceEpoch,
        identityKey: key,
      );
      try {
        List<RadioChannel> channels;
        try {
          channels = await radio.channels();
        } catch (_) {
          channels = const [];
        }
        final contacts = await radio.contacts();
        final full = RadioBackupData(
          radioName: data.radioName,
          publicKeyHex: data.publicKeyHex,
          createdMs: data.createdMs,
          identityKey: key,
          contacts: contacts,
          channels: channels,
        );
        final bytes = await RadioBackup.seal(full, passphrase, iterations: backupIterations, useIsolate: backupUseIsolate);
        final withKey = key != null;
        return (
          file: bytes,
          identityIncluded: withKey,
          result: DeviceResult.ok(withKey
              ? 'Backup ready: identity key, ${contacts.length} contacts and ${channels.where((c) => !c.isEmpty).length} channels, encrypted with your passphrase.'
              : 'Backup ready: ${contacts.length} contacts and ${channels.where((c) => !c.isEmpty).length} channels, encrypted. This radio does not allow exporting its identity key, so that is not in it.')
        );
      } catch (e) {
        return (file: null, identityIncluded: false, result: DeviceResult.fail('The backup could not be made. Check the radio is connected and try again.', DeviceErrorKind.unexpected));
      } finally {
        data.wipe();
        key?.fillRange(0, key.length, 0);
      }
    });
  }

  /// Opens a backup file with [passphrase] (wrong passphrase throws [BackupWrongPassphrase]). Nothing is sent to the radio.
  Future<RadioBackupData> openBackup(Uint8List file, String passphrase) => RadioBackup.open(file, passphrase, useIsolate: backupUseIsolate);

  /// Writes [data] to the radio: channels, contacts and, only when [replaceIdentity] and [typed] is exactly REPLACE, the
  /// identity key. A radio without key import reports it and the rest still restores.
  Future<({DeviceResult result, RestoreReport report})> restoreBackup(RadioBackupData data, {bool replaceIdentity = false, String typed = ''}) async {
    final report = RestoreReport();
    if (replaceIdentity) {
      if (!TypedConfirm.matches(typed, TypedConfirm.replaceIdentity)) {
        return (result: DeviceResult.fail('Type ${TypedConfirm.replaceIdentity} to confirm replacing this radio\'s identity.', DeviceErrorKind.invalid), report: report);
      }
      if (!data.hasIdentity) {
        return (result: DeviceResult.fail('This backup has no identity key to restore.', DeviceErrorKind.invalid), report: report);
      }
    }
    return _exclusive(() async {
      String? note;
      if (replaceIdentity) {
        final s = await _send(encodeImportPrivateKey(data.identityKey!));
        if (s.failure != null) return (result: s.failure!, report: report);
        final k = deviceErrorOf(s.frame!);
        if (k == null) {
          report.identityReplaced = true;
        } else if (k == DeviceErrorKind.disabled || k == DeviceErrorKind.unsupported) {
          _unavailable[DeviceFeature.identityKeyImport] = 'This radio\'s firmware does not allow importing an identity key.';
          note = 'This radio\'s firmware does not allow importing an identity key, so its identity was not changed.';
        } else {
          return (result: DeviceResult.fail(deviceErrorText(k, what: 'importing the key'), k), report: report);
        }
      }
      for (final ch in data.channels) {
        if (ch.isEmpty) continue;
        final s = await _send(encodeSetChannel(ch.index, ch.name, ch.secret));
        if (s.failure != null) {
          report.failed++;
          continue;
        }
        if (deviceErrorOf(s.frame!) == null) {
          report.channels++;
        } else {
          report.failed++;
        }
      }
      for (final c in data.contacts) {
        try {
          await radio.addContact(c);
          report.contacts++;
        } catch (e) {
          if (e.toString().contains('full')) {
            report.contactsTableFull++;
          } else {
            report.failed++;
          }
        }
      }
      final parts = <String>[
        if (report.identityReplaced) 'identity replaced',
        '${report.channels} channels',
        '${report.contacts} contacts',
        if (report.contactsTableFull > 0) '${report.contactsTableFull} contacts did not fit',
        if (report.failed > 0) '${report.failed} could not be written',
      ];
      final tail = report.needsReboot ? ' Reboot the radio now so it uses the restored identity.' : '';
      return (
        result: DeviceResult.ok('Restored: ${parts.join(', ')}.${note == null ? '' : ' $note'}$tail', verified: false),
        report: report,
      );
    });
  }

  // ------------------------------------------------------------ console

  /// Runs one line on the radio's own command line and returns its reply. The blocked lines never reach the radio.
  Future<({String? reply, DeviceResult? failure})> runCli(String line) async {
    if (!available(DeviceFeature.console)) {
      return (reply: null, failure: DeviceResult.fail(_unavailable[DeviceFeature.console] ?? deviceErrorText(DeviceErrorKind.unsupported, what: 'the console'), DeviceErrorKind.unsupported));
    }
    final blocked = blockedCliReason(line);
    if (blocked != null) return (reply: null, failure: DeviceResult.fail(blocked, DeviceErrorKind.invalid));
    final Uint8List frame;
    try {
      frame = encodeRunCliCommand(line.trim());
    } on ArgumentError {
      return (reply: null, failure: DeviceResult.fail('That line is too long (limit $maxCliCommandBytes bytes).', DeviceErrorKind.invalid));
    }
    final s = await _send(frame);
    if (s.failure != null) return (reply: null, failure: s.failure);
    final f = s.frame!;
    if (f is CliReplyFrame) return (reply: f.text, failure: null);
    if (f is OkFrame) return (reply: '', failure: null);
    final k = deviceErrorOf(f) ?? DeviceErrorKind.unexpected;
    if (k == DeviceErrorKind.unsupported) {
      _markUnavailable(DeviceFeature.console, 'This radio\'s firmware does not have the console command (ERR 1).');
    }
    return (reply: null, failure: DeviceResult.fail(deviceErrorText(k, what: 'the console'), k));
  }

  // ------------------------------------------------------------ undo

  Future<DeviceResult> undo() async {
    final u = _undo;
    if (u == null) return DeviceResult.fail('Nothing to undo.', DeviceErrorKind.invalid);
    final label = _undoLabel;
    _undo = null;
    _undoLabel = null;
    final r = await u();
    notifyChanged();
    return r.ok ? DeviceResult.ok('Put back: $label.') : r;
  }

  void dispose() => disposeChanges();
}
