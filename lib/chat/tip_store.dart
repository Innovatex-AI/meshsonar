// Remembers which one-time tips (TipCard) were dismissed, in the chat `settings` table (key `tip.<id>`), so a tip is shown once
// per install and survives restarts.
import '../ui/design/app_widgets.dart' show TipStore;
import 'store.dart';

class ChatDbTipStore implements TipStore {
  final ChatStore store;
  ChatDbTipStore(this.store);

  static String keyFor(String id) => 'tip.$id';

  @override
  bool seen(String id) {
    try {
      return store.db.setting(keyFor(id)) == '1';
    } catch (_) {
      return false;
    }
  }

  @override
  void markSeen(String id) {
    try {
      store.db.putSetting(keyFor(id), '1');
    } catch (_) {}
  }
}
