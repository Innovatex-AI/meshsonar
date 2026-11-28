// MeshSonar Firmware detection from DEVICE_INFO (meshsonar-firmware docs/APP-INTEGRATION.md section 1). Nothing new on the
// Bluetooth wire: a MeshSonar radio is stock MeshCore companion firmware whose version string is
// `<MeshCore version>-ms<MeshSonar version>` (e.g. `v1.18.0-ms0.1.0`); the manufacturer string is MeshCore's board name
// (`Heltec V4 TFT`, `Heltec V4.3 TFT`, `Heltec V4 R8 TFT`). Everything MeshSonar-specific goes over the radio's Wi-Fi
// (lib/core/msradio/). Pure Dart.
import 'protocol.dart' show DeviceInfoFrame;

/// The contract's rule: group 4 is the MeshSonar version. Not anchored at the end, so a suffix such as the simulator's
/// `-sim` still matches.
final RegExp meshSonarFwPattern = RegExp(r'^v?(\d+)\.(\d+)(?:\.\d+)?-ms(\d+\.\d+\.\d+)');

/// What a MeshSonar radio says about itself over Bluetooth.
class MeshSonarFw {
  /// The MeshSonar Firmware version, e.g. `0.1.0`.
  final String msVersion;

  /// The MeshCore companion version the firmware is built on, as the radio wrote it (the text before `-ms`), e.g. `v1.18.0`.
  final String coreVersion;

  /// MeshCore's board name from DEVICE_INFO (`Heltec V4 TFT`); empty when the radio sent none.
  final String boardName;

  const MeshSonarFw({required this.msVersion, required this.coreVersion, this.boardName = ''});

  /// Null for stock MeshCore firmware (and for an empty or missing version string).
  static MeshSonarFw? tryParse(DeviceInfoFrame di) => tryParseStrings(di.firmwareVersion, di.manufacturer);

  /// [tryParse] on the two DEVICE_INFO strings.
  static MeshSonarFw? tryParseStrings(String? firmwareVersion, String? manufacturer) {
    final v = firmwareVersion?.trim();
    if (v == null || v.isEmpty) return null;
    final m = meshSonarFwPattern.firstMatch(v);
    if (m == null) return null;
    final dash = v.indexOf('-ms', m.start);
    return MeshSonarFw(msVersion: m.group(3)!, coreVersion: v.substring(0, dash), boardName: (manufacturer ?? '').trim());
  }

  /// (major, minor, patch) of [msVersion].
  (int, int, int) get msVersionParts {
    final p = msVersion.split('.').map(int.parse).toList();
    return (p[0], p[1], p[2]);
  }

  @override
  bool operator ==(Object other) =>
      other is MeshSonarFw && other.msVersion == msVersion && other.coreVersion == coreVersion && other.boardName == boardName;

  @override
  int get hashCode => Object.hash(msVersion, coreVersion, boardName);

  @override
  String toString() => 'MeshSonarFw($msVersion on $coreVersion, $boardName)';
}
