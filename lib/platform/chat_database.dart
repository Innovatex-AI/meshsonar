// Opens the chat database file. Kept out of lib/chat so that layer stays free of path_provider and testable with an
// in-memory database.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../chat/secret_store.dart';
import '../chat/store.dart';

/// `<application support>/chat/chat.db`, WAL mode. Chat has its own export/import (lib/chat/backup.dart); secrets are not in this file.
Future<String> chatDatabasePath() async {
  final dir = await getApplicationSupportDirectory();
  final d = Directory(p.join(dir.path, 'chat'));
  await d.create(recursive: true);
  return p.join(d.path, 'chat.db');
}

Future<ChatStore> openChatStore(SecretStore secrets, {String? path}) async {
  final db = sqlite3.open(path ?? await chatDatabasePath());
  return ChatStore.open(db, secrets, wal: true);
}
