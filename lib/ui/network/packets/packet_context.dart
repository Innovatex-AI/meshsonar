// What the Packets screens read from the rest of the app (AZ-3.2), each with a quiet null when it is not there (a test
// that pumps one screen, no radio): the connected radio's Rx log, the hashtag channels the person joined (keys public
// by name, used for the phone's own decode), and the saved-filter store.
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../../app/app_state.dart';
import '../../../chat/channel_secret.dart' show hashtagSecret16;
import '../../../core/v1/local_decoder.dart';
import '../../../core/v1/saved_packet_filters.dart';
import '../../../radio/crypto.dart' show toHex;
import '../../../radio/tools/radio_tools.dart';
import '../../../radio/tools/rx_log.dart';
import '../../app.dart';
import '../../contacts/route_nodes.dart' show radioToolsOf;
import '../../tools/tools_host.dart';

/// The connected radio's Tools; null without a radio (or without an app above, in tests).
RadioTools? packetRadioTools(BuildContext context) {
  if (context.getInheritedWidgetOfExactType<ToolsHostScope>() == null && AppScope.maybeOf(context) == null) return null;
  return radioToolsOf(context);
}

/// The ToolsHost above, or null.
ToolsHost? _host(BuildContext context) {
  final s = context.getInheritedWidgetOfExactType<ToolsHostScope>();
  if (s != null) return s.host;
  final app = AppScope.maybeOf(context);
  return app == null ? null : AppStateToolsHost.of(app);
}

/// The joined hashtag channels whose key is the public one derived from the name (never a private key).
Future<List<LocalChannelKey>> packetHashtagKeys(BuildContext context) async {
  final host = _host(context);
  if (host == null) return const [];
  List<KnownChannel> known;
  try {
    known = await host.knownChannels();
  } catch (_) {
    return const [];
  }
  return [
    for (final k in known)
      if (k.name.trim().startsWith('#') && toHex(k.secret16) == toHex(hashtagSecret16(k.name))) LocalChannelKey.hashtag(k.name)
  ];
}

final Expando<SavedPacketFilterStore> _stores = Expando('savedPacketFilters');
final SavedPacketFilterStore _memoryStore = SavedPacketFilterStore();

/// The saved packet filters of this app (a file next to the UI preferences; memory only in tests).
SavedPacketFilterStore savedPacketFilterStore(BuildContext context) {
  final AppState? app = AppScope.maybeOf(context);
  if (app == null) return _memoryStore;
  final dir = app.services.uiPrefsFile?.parent;
  return _stores[app] ??= SavedPacketFilterStore(file: dir == null ? null : File('${dir.path}${Platform.pathSeparator}saved_packet_filters.json'));
}
