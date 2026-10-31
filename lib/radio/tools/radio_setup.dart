// Radio setup with guard rails. Writes this radio's name, advert position, TX power, behaviour flags and LoRa parameters,
// and after EVERY write reads the radio's settings back (APP_START -> SELF_INFO) and compares, so "saved" means "the radio
// reports it". The last change can be undone while the app runs.
//
// Commands (FW, MyMesh.cpp 1259-1282, 1424-1503; never run on hardware by the research; the read-back path, APP_START ->
// SELF_INFO, is VERIFIED): SET_ADVERT_NAME 8, SET_ADVERT_LATLON 14, SET_RADIO_TX_POWER 12, SET_RADIO_PARAMS 11 (retunes at
// once, no reboot), SET_OTHER_PARAMS 38 (writes all four flags, so the others are sent as read). Nothing here is applied
// without a person's explicit confirm: the UI owns the confirm; this class owns the limits and the read-back.
// Pure Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../command_queue.dart';
import '../protocol.dart';
import 'tool_frames.dart';
import 'tool_state.dart';
import 'tools_radio.dart';

/// LoRa parameters in the units SELF_INFO and SET_RADIO_PARAMS use.
class RadioParams {
  final int freqKhz;
  final int bwHz;
  final int sf;
  final int cr;
  const RadioParams(this.freqKhz, this.bwHz, this.sf, this.cr);

  factory RadioParams.fromMhz({required double freqMhz, required double bwKhz, required int sf, required int cr}) =>
      RadioParams((freqMhz * 1000).round(), (bwKhz * 1000).round(), sf, cr);

  double get freqMhz => freqKhz / 1000.0;
  double get bwKhz => bwHz / 1000.0;

  /// "910.525 MHz, 62.5 kHz, SF7, CR5".
  String get label => '${freqMhz.toStringAsFixed(3)} MHz, ${bwKhz.toStringAsFixed(bwKhz % 1 == 0 ? 0 : 1)} kHz, SF$sf, CR$cr';

  /// The radio stores float32 frequency and bandwidth and reports them back rounded, so compare to 1 kHz / 50 Hz.
  bool matches(RadioParams o) => (freqKhz - o.freqKhz).abs() <= 1 && (bwHz - o.bwHz).abs() <= 50 && sf == o.sf && cr == o.cr;

  /// Problems that make the radio refuse these values; empty when they are allowed.
  List<String> problems() => [
        if (freqKhz < RadioParamLimits.freqKhzMin || freqKhz > RadioParamLimits.freqKhzMax) 'Frequency must be between 150 and 2500 MHz.',
        if (bwHz < RadioParamLimits.bwHzMin || bwHz > RadioParamLimits.bwHzMax) 'Bandwidth must be between 7 and 500 kHz.',
        if (sf < RadioParamLimits.sfMin || sf > RadioParamLimits.sfMax) 'Spreading factor must be between 5 and 12.',
        if (cr < RadioParamLimits.crMin || cr > RadioParamLimits.crMax) 'Coding rate must be between 5 and 8.',
      ];
}

/// Everything SELF_INFO reports that Radio setup edits.
class RadioConfig {
  final String publicKeyHex;
  final String name;

  /// Null when the radio has no position stored (0, 0).
  final double? lat, lon;
  final int txDbm;
  final int maxTxDbm;
  final RadioParams params;
  final int multiAcks;

  /// 0 = adverts carry no position, 1 = they carry the stored position, 2 = prefs.
  final int advertLocPolicy;
  final int telemetryModes;
  final bool manualAdd;
  const RadioConfig({
    required this.publicKeyHex,
    required this.name,
    this.lat,
    this.lon,
    required this.txDbm,
    required this.maxTxDbm,
    required this.params,
    required this.multiAcks,
    required this.advertLocPolicy,
    required this.telemetryModes,
    required this.manualAdd,
  });

  bool get advertSharesPosition => advertLocPolicy != 0;

  static RadioConfig fromFrame(SelfInfoFrame f) => RadioConfig(
        publicKeyHex: f.publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        name: f.name,
        lat: f.advLat == 0 && f.advLon == 0 ? null : f.advLat,
        lon: f.advLat == 0 && f.advLon == 0 ? null : f.advLon,
        txDbm: f.txPowerDbm,
        maxTxDbm: f.maxTxPowerDbm,
        params: RadioParams(f.freqKhz, f.bwHz, f.sf, f.cr),
        multiAcks: f.multiAcks,
        advertLocPolicy: f.advertLocPolicy,
        telemetryModes: f.telemetryModes,
        manualAdd: f.manualAdd != 0,
      );
}

class SetupResult {
  final bool ok;

  /// Plain-language outcome.
  final String message;

  /// Fields that did not read back as written.
  final List<String> mismatches;
  final RadioConfig? after;
  const SetupResult(this.ok, this.message, {this.mismatches = const [], this.after});
}

class RadioSetupTool with ToolChanges {
  final ToolsRadio radio;
  RadioConfig? _config;
  _Undo? _undo;

  RadioSetupTool(this.radio);

  /// The settings as last read; null before [read] or when the radio did not answer.
  RadioConfig? get config => _config;
  bool get canUndo => _undo != null;
  String? get undoLabel => _undo?.label;

  /// Reads the radio's current settings.
  Future<RadioConfig?> read() async {
    final f = await radio.readSelfInfo();
    if (f != null) _config = RadioConfig.fromFrame(f);
    notifyChanged();
    return _config;
  }

  // ------------------------------------------------------------ validation (pure)

  /// Why [name] cannot be used, or null. 1-31 bytes; no control characters; no colon (chat shows "name: text", so a colon
  /// in a name breaks who said what).
  static String? nameProblem(String name) {
    final t = name.trim();
    if (t.isEmpty) return 'Enter a name.';
    if (utf8.encode(t).length > maxNodeNameBytes) return 'A name can be at most $maxNodeNameBytes bytes (about $maxNodeNameBytes letters).';
    if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(t)) return 'A name cannot contain control characters.';
    if (t.contains(':')) return 'A name cannot contain a colon. Chat shows messages as "name: text".';
    return null;
  }

  /// A name longer than this is cut in adverts that carry a position.
  static bool nameCutInAdvert(String name) => utf8.encode(name.trim()).length > maxAdvertNameBytesWithPosition;

  static String? positionProblem(double? lat, double? lon) {
    if (lat == null || lon == null) return 'Enter a latitude and a longitude.';
    if (!lat.isFinite || !lon.isFinite) return 'Latitude and longitude must be numbers.';
    if (lat < -90 || lat > 90) return 'Latitude must be between -90 and 90.';
    if (lon < -180 || lon > 180) return 'Longitude must be between -180 and 180.';
    if (lat == 0 && lon == 0) return '0, 0 means "no position" to a radio. Enter a real position, or turn position sharing off.';
    return null;
  }

  String? txPowerProblem(int dbm) {
    final max = _config?.maxTxDbm;
    if (dbm < RadioParamLimits.txDbmMin) return 'TX power cannot go below ${RadioParamLimits.txDbmMin} dBm.';
    if (max != null && max > 0 && dbm > max) return 'This radio’s hardware limit is $max dBm.';
    return null;
  }

  // ------------------------------------------------------------ writes

  Future<SetupResult> setName(String name) async {
    final p = nameProblem(name);
    if (p != null) return SetupResult(false, p);
    final before = _config;
    final t = name.trim();
    return _write(
      what: 'name',
      frame: encodeSetAdvertName(utf8.encode(t)),
      verify: (c) => [if (c.name != t) 'name'],
      undo: before == null ? null : _Undo('name', () => setName(before.name)),
    );
  }

  Future<SetupResult> setPosition(double lat, double lon) async {
    final p = positionProblem(lat, lon);
    if (p != null) return SetupResult(false, p);
    final before = _config;
    return _write(
      what: 'position',
      frame: encodeSetAdvertLatLon(lat, lon),
      verify: (c) => [if (c.lat == null || (c.lat! - lat).abs() > 0.00002 || (c.lon! - lon).abs() > 0.00002) 'position'],
      undo: before == null
          ? null
          : _Undo('position', () => before.lat == null ? Future.value(const SetupResult(false, 'The radio had no position before, and a radio cannot clear one.')) : setPosition(before.lat!, before.lon!)),
    );
  }

  Future<SetupResult> setTxPower(int dbm) async {
    final p = txPowerProblem(dbm);
    if (p != null) return SetupResult(false, p);
    final before = _config;
    return _write(
      what: 'TX power',
      frame: encodeSetRadioTxPower(dbm),
      verify: (c) => [if (c.txDbm != dbm) 'TX power'],
      undo: before == null ? null : _Undo('TX power', () => setTxPower(before.txDbm)),
    );
  }

  /// Writes the three behaviour flags. The telemetry modes stay as the radio reported them.
  Future<SetupResult> setBehaviour({bool? manualAdd, int? multiAcks, int? advertLocPolicy}) async {
    final c = _config ?? await read();
    if (c == null) return const SetupResult(false, 'Could not read the radio first.');
    final newManual = manualAdd ?? c.manualAdd;
    final newAcks = multiAcks ?? c.multiAcks;
    final newPolicy = advertLocPolicy ?? c.advertLocPolicy;
    if (newAcks < 0 || newAcks > 1) return const SetupResult(false, 'Extra acknowledgements are on or off.');
    if (newPolicy < 0 || newPolicy > 2) return const SetupResult(false, 'Unknown advert position setting.');
    return _write(
      what: 'behaviour',
      frame: encodeSetOtherParams(manualAdd: newManual ? 1 : 0, telemetryModes: c.telemetryModes, advertLocPolicy: newPolicy, multiAcks: newAcks),
      verify: (r) => [
        if (r.manualAdd != newManual) 'manual add',
        if (r.multiAcks != newAcks) 'extra acknowledgements',
        if (r.advertLocPolicy != newPolicy) 'advert position',
        if (r.telemetryModes != c.telemetryModes) 'telemetry sharing',
      ],
      undo: _Undo('behaviour', () => setBehaviour(manualAdd: c.manualAdd, multiAcks: c.multiAcks, advertLocPolicy: c.advertLocPolicy)),
    );
  }

  /// SET_RADIO_PARAMS. The caller has already shown the loud confirm. Reads the radio back and compares; a mismatch is
  /// reported, never hidden.
  Future<SetupResult> applyRadioParams(RadioParams p) async {
    final problems = p.problems();
    if (problems.isNotEmpty) return SetupResult(false, problems.first);
    final before = _config ?? await read();
    return _write(
      what: 'radio parameters',
      frame: encodeSetRadioParams(freqKhz: p.freqKhz, bwHz: p.bwHz, sf: p.sf, cr: p.cr),
      verify: (c) => [if (!c.params.matches(p)) 'radio parameters'],
      undo: before == null ? null : _Undo('radio parameters (${before.params.label})', () => applyRadioParams(before.params)),
    );
  }

  /// Puts back what the last change replaced.
  Future<SetupResult> undo() async {
    final u = _undo;
    if (u == null) return const SetupResult(false, 'Nothing to undo.');
    _undo = null;
    final r = await u.run();
    if (r.ok) _undo = null; // an undo is not itself undoable
    notifyChanged();
    return SetupResult(r.ok, r.ok ? 'Put back: ${u.label}.' : r.message, mismatches: r.mismatches, after: r.after);
  }

  Future<SetupResult> _write({
    required String what,
    required Uint8List frame,
    required List<String> Function(RadioConfig) verify,
    _Undo? undo,
  }) async {
    if (!radio.isConnected) return const SetupResult(false, 'No radio is connected.');
    try {
      final f = await radio.send(frame, priority: CommandPriority.admin);
      if (f is ErrFrame) {
        return SetupResult(false, f.code == ErrCode.illegalArg ? 'The radio refused those values.' : 'The radio refused the change (error ${f.code}).');
      }
      if (f is! OkFrame) return const SetupResult(false, 'The radio gave an unexpected answer.');
    } on TimeoutException {
      return SetupResult(false, 'The radio did not answer. Check what it reports before trying again.');
    } on StateError {
      return const SetupResult(false, 'The radio disconnected.');
    }
    // Read it back: the radio's word, not ours.
    RadioConfig? after;
    final info = await radio.readSelfInfo();
    if (info != null) after = RadioConfig.fromFrame(info);
    if (after == null) {
      return SetupResult(false, 'The radio accepted the change but did not report its settings back, so it could not be checked.');
    }
    _config = after;
    final bad = verify(after);
    if (bad.isNotEmpty) {
      notifyChanged();
      return SetupResult(false, 'The radio accepted the change, but it reads back differently: ${bad.join(', ')}.', mismatches: bad, after: after);
    }
    _undo = undo;
    notifyChanged();
    return SetupResult(true, 'Saved: the radio reports the new $what.', after: after);
  }

  void dispose() => disposeChanges();
}

class _Undo {
  final String label;
  final Future<SetupResult> Function() run;
  _Undo(this.label, this.run);
}
