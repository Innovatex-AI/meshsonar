// ScopeGuard: the flood scope (region) is global radio state in the firmware: SET_FLOOD_SCOPE_KEY's override applies to
// every later flood, chat and ping alike, until changed (MyMesh.cpp 491-525 sendFloodScoped, 1978-1992). So before every
// flood send the session puts the scope that send wants on the radio, in the same command-queue slot as the send.
// A scoped chat channel and an unscoped ping channel therefore never leak into each other.
//
//   [0x36][0][key x16]  per-connection override = this region        (firmware v8+)
//   [0x36][0]           clear the override: the radio's default scope applies
//   [0x36][1]           send unscoped even if a default scope is set  (ver 12+, comment at MyMesh.cpp:1984)
//
// Support is learned, not assumed: DEVICE_INFO's firmware code gates the key form (8) and the unscoped form (12); an ERR
// reply (unsupported) turns the guard off for the rest of the session.
import 'dart:typed_data';

import 'inbound.dart';
import 'protocol.dart' show Cmd;

/// Firmware ver codes (MyMesh.cpp comments on CMD_SET_FLOOD_SCOPE_KEY).
const int scopeKeyMinFirmware = 8;
const int scopeUnscopedMinFirmware = 12;

/// CMD_SET_FLOOD_SCOPE_KEY for [scope] (MyMesh.cpp 1978-1992).
Uint8List encodeSetFloodScope(FloodScope scope) => switch (scope) {
      KeyedFloodScope(:final key16) => Uint8List.fromList([Cmd.setFloodScopeKey, 0, ...key16]),
      _ when scope == FloodScope.unscoped => Uint8List.fromList([Cmd.setFloodScopeKey, 1]),
      _ => Uint8List.fromList([Cmd.setFloodScopeKey, 0]),
    };

class ScopeGuard {
  /// FIRMWARE_VER_CODE of the radio, null = unknown (treated as: try, learn from the answer).
  int? firmwareVerCode;

  bool _disabled = false;

  /// What the radio holds now, as far as this session knows. Null = never touched (the radio's own state).
  FloodScope? _applied;

  /// The session has set a non-default scope at some point: later sends must set theirs, even "radio default", or the
  /// override would leak.
  bool _dirty = false;

  ScopeGuard({this.firmwareVerCode});

  bool get supported => !_disabled && (firmwareVerCode == null || firmwareVerCode! >= scopeKeyMinFirmware);

  /// A new link: the radio may have been rebooted (the override is RAM only) or serve another app in between.
  void reset() {
    _applied = null;
    _dirty = false;
  }

  /// Marks the guard unusable (the radio answered ERR to the command).
  void disable() => _disabled = true;

  /// The command to send right before a flood that wants [wanted] and the scope it sets, or null when nothing has to be
  /// sent. [wanted] null = "don't care" (a ping): then only a leaked override of an earlier send is cleared. Report the
  /// outcome with [applied].
  ({Uint8List cmd, FloodScope target})? commandFor(FloodScope? wanted) {
    if (!supported) return null;
    FloodScope? target = wanted;
    if (target == null) {
      if (!_dirty) return null;
      target = FloodScope.radioDefault;
    }
    if (target == FloodScope.unscoped && firmwareVerCode != null && firmwareVerCode! < scopeUnscopedMinFirmware) {
      target = FloodScope.radioDefault; // the nearest thing the firmware can do
    }
    if (_applied == target || (_applied == null && target == FloodScope.radioDefault && !_dirty)) return null;
    return (cmd: encodeSetFloodScope(target), target: target);
  }

  /// The command from [commandFor] was accepted.
  void applied(FloodScope scope) {
    _applied = scope;
    _dirty = scope != FloodScope.radioDefault;
  }
}
