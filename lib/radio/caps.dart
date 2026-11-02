// Capabilities: what THIS radio's firmware can do (RadioCaps, computed once on connect from DEVICE_INFO) and what the
// remote node we are logged in to lets us do (RemoteCaps, from LOGIN_SUCCESS). Gates for the UI: a feature that the
// capabilities rule out is shown disabled with a reason (or hidden), never tried and failed.
// Plan: meshsonar-infra/docs/planning/chat-redesign-plan-2026-11-02.md section 5.3. Pure Dart.
import 'claim_radio.dart' show RemoteLogin;
import 'protocol.dart' show DeviceInfoFrame;

/// Firmware version code (DEVICE_INFO byte 1) from which a feature exists.
abstract final class FwCode {
  /// CLIENT_REPEAT (off-grid repeat mode).
  static const int clientRepeat = 9;

  /// Path hash mode (multi-byte path hashes; CMD 61).
  static const int pathHashMode = 10;
}

/// The first release (companion firmware text version) that has the local CLI (CMD 66).
const (int, int) localCliMinVersion = (1, 18);

/// Parses "v1.17.1", "1.18", "v1.18.0-observer-x" to (major, minor); null when it has no version.
(int, int)? parseFirmwareVersion(String? text) {
  if (text == null) return null;
  final m = RegExp(r'(\d+)\.(\d+)').firstMatch(text);
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!));
}

bool _atLeast((int, int) v, (int, int) min) => v.$1 > min.$1 || (v.$1 == min.$1 && v.$2 >= min.$2);

enum PathDiscoverySupport {
  /// Not asked yet: try it; an ERR 1 (UNSUPPORTED_CMD) turns this into [no].
  unknown,
  yes,
  no,
}

class RadioCaps {
  /// DEVICE_INFO firmware code, or null when the radio did not say.
  final int? fwCode;
  final (int, int)? fwVersion;
  final int? pathHashModeByte;
  final PathDiscoverySupport pathDiscovery;

  const RadioCaps({this.fwCode, this.fwVersion, this.pathHashModeByte, this.pathDiscovery = PathDiscoverySupport.unknown});

  /// Unknown radio: nothing newer than the baseline is assumed.
  static const RadioCaps baseline = RadioCaps();

  factory RadioCaps.fromDeviceInfo(DeviceInfoFrame di) =>
      RadioCaps(fwCode: di.firmwareVerCode, fwVersion: parseFirmwareVersion(di.firmwareVersion), pathHashModeByte: di.pathHashMode);

  RadioCaps copyWith({PathDiscoverySupport? pathDiscovery}) =>
      RadioCaps(fwCode: fwCode, fwVersion: fwVersion, pathHashModeByte: pathHashModeByte, pathDiscovery: pathDiscovery ?? this.pathDiscovery);

  bool get hasPathHashMode => (fwCode ?? 0) >= FwCode.pathHashMode;
  bool get hasClientRepeat => (fwCode ?? 0) >= FwCode.clientRepeat;
  bool get hasLocalCli => fwVersion != null && _atLeast(fwVersion!, localCliMinVersion);

  /// Path discovery (CMD 52) is offered unless the radio refused it once.
  bool get hasPathDiscovery => pathDiscovery != PathDiscoverySupport.no;

  /// Bytes per path hash the radio can be set to: 1 without path hash mode, else the mode the radio reported + 1 is the
  /// current size and 3 the most the protocol has.
  int get maxHashSize => hasPathHashMode ? 3 : 1;
}

/// The permission level a remote node gave us at login.
class RemoteCaps {
  final bool isAdmin;

  /// The stored permission byte (low two bits: 0 guest, 1 read only, 2 read and write, 3 admin); null on old firmware.
  final int? perms;

  /// The remote node's firmware level (LOGIN_SUCCESS byte 12); null before login or on old firmware.
  final int? fwLevel;

  const RemoteCaps({this.isAdmin = false, this.perms, this.fwLevel});

  static const RemoteCaps none = RemoteCaps();

  factory RemoteCaps.fromLogin(RemoteLogin l) => RemoteCaps(isAdmin: l.isAdmin, perms: l.aclPermissions, fwLevel: l.firmwareLevel);

  bool get canPostToRoom => isAdmin || ((perms ?? 0) & 3) >= 2;

  // Gates (a guest can read status; the CLI, ACL and every write need admin; owner info needs level >= 2).
  bool get canReadStatus => true;
  bool get canReadTelemetry => true;
  bool get canReadNeighbours => true;
  bool get canUseCli => isAdmin;
  bool get canReadAcl => isAdmin;
  bool get canWrite => isAdmin;
  bool get canReadOwnerInfo => (fwLevel ?? 0) >= 2;
}
