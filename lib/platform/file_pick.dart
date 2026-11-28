// Picking a file from Files / the document picker for the MeshSonar radio uploads: a map pack (`.msmp`), a firmware file
// (`.bin`) or a Lua app (`main.lua`). package:file_picker (MIT). The bytes are streamed, never read whole into memory, so a
// 4 MB pack or firmware file is fine. Tests and the screenshot build use a fake [FilePick].
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart' as fp;

import '../core/msradio/ms_api.dart' show MsUploadSource;

/// A picked file.
class PickedFile {
  /// Local path when the platform gives one (null for some providers).
  final String? path;
  final String name;
  final int size;

  /// Opens the file's bytes; can be called again (a retried upload opens it again).
  final Stream<List<int>> Function() openRead;
  const PickedFile({this.path, required this.name, required this.size, required this.openRead});

  /// The file as an upload for MsRadioApi.
  MsUploadSource get upload => MsUploadSource(name: name, size: size, open: openRead);

  /// The extension, lower-case without the dot; '' when none.
  String get extension {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }
}

/// The seam the screens use.
abstract interface class FilePick {
  /// Lets the person pick one file. [extensions] (without dots, e.g. `['msmp']`) limit what can be picked where the
  /// platform allows it, and a file with another extension is refused here too (iOS cannot filter unknown extensions in
  /// every provider). Null when the person backed out.
  Future<PickedFile?> pickFile({List<String> extensions = const []});
}

class DeviceFilePick implements FilePick {
  const DeviceFilePick();

  @override
  Future<PickedFile?> pickFile({List<String> extensions = const []}) async {
    final exts = [for (final e in extensions) e.toLowerCase().replaceFirst('.', '')];
    // iOS's document picker only filters by UTType; a custom extension such as .msmp has none, so pick any and check.
    final f = await fp.FilePicker.pickFile(type: fp.FileType.any);
    if (f == null) return null;
    final picked = PickedFile(
      path: f.path,
      name: f.name,
      size: f.lengthSync() ?? await f.length() ?? 0,
      openRead: () => f.readAsByteStream().map<List<int>>((Uint8List b) => b),
    );
    if (exts.isNotEmpty && !exts.contains(picked.extension)) {
      throw FilePickRefused('Pick a ${exts.map((e) => '.$e').join(' or ')} file.');
    }
    return picked;
  }
}

/// The picked file has the wrong extension.
class FilePickRefused implements Exception {
  final String message;
  const FilePickRefused(this.message);
  @override
  String toString() => message;
}
