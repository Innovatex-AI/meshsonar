// Opens the platform share sheet for an exported drive file (share_plus).
import 'dart:io';

import 'package:share_plus/share_plus.dart';

Future<void> shareDriveFile(File file) async {
  if (file.path.endsWith('.txt')) {
    // A drive report: share the text itself (messages, mail) with the file alongside.
    final text = await file.readAsString();
    await SharePlus.instance.share(ShareParams(
      text: text,
      subject: 'MeshSonar drive report',
      files: [XFile(file.path, mimeType: 'text/plain')],
    ));
    return;
  }
  await SharePlus.instance.share(ShareParams(
    files: [XFile(file.path, mimeType: 'application/json')],
    subject: 'MeshSonar drive',
    text: 'MeshSonar drive (Drive Format v1)',
  ));
}

/// A long drive exported in parts (the server takes at most 5,000 pings per upload): one share sheet, all parts.
Future<void> shareDriveFiles(List<File> files) async {
  if (files.length == 1) return shareDriveFile(files.single);
  await SharePlus.instance.share(ShareParams(
    files: [for (final f in files) XFile(f.path, mimeType: 'application/json')],
    subject: 'MeshSonar drive (${files.length} parts)',
    text: 'MeshSonar drive (Drive Format v1), ${files.length} files: each is a complete upload of up to 5,000 pings.',
  ));
}
