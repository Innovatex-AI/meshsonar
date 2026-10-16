// Opens the platform share sheet for an exported drive file (share_plus).
import 'dart:io';

import 'package:share_plus/share_plus.dart';

Future<void> shareDriveFile(File file) async {
  await SharePlus.instance.share(ShareParams(
    files: [XFile(file.path, mimeType: 'application/json')],
    subject: 'MeshSonar drive',
    text: 'MeshSonar drive (Drive Format v1)',
  ));
}
