// One handle for the whole chat database: the repositories share a connection and a transaction scope.
import 'package:sqlite3/sqlite3.dart';

import 'db/channel_repository.dart';
import 'db/chat_database.dart';
import 'db/contact_repository.dart';
import 'db/message_repository.dart';
import 'db/migrations.dart';
import 'db/misc_repositories.dart';
import 'db/outbox_repository.dart';
import 'secret_store.dart';

class ChatStore {
  final ChatDatabase db;
  final SecretStore secrets;
  final ContactRepository contacts;
  final ChannelRepository channels;
  final MessageRepository messages;
  final OutboxRepository outbox;
  final DraftRepository drafts;
  final AdvertRepository adverts;
  final SystemStatsRepository systemStats;

  ChatStore._(this.db, this.secrets)
      : contacts = ContactRepository(db),
        channels = ChannelRepository(db, secrets),
        messages = MessageRepository(db),
        outbox = OutboxRepository(db),
        drafts = DraftRepository(db),
        adverts = AdvertRepository(db),
        systemStats = SystemStatsRepository(db);

  /// Opens (and migrates) [database]. Production passes a file database from lib/platform/chat_database.dart.
  factory ChatStore.open(Database database, SecretStore secrets, {List<Migration>? migrations, bool wal = false}) =>
      ChatStore._(ChatDatabase.open(database, migrations: migrations, wal: wal), secrets);

  factory ChatStore.inMemory({SecretStore? secrets, List<Migration>? migrations}) =>
      ChatStore._(ChatDatabase.inMemory(migrations: migrations), secrets ?? InMemorySecretStore());

  void close() => db.close();
}
