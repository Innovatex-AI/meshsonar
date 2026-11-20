// What the Network screens read from the rest of the app (AZ-3.3 to AZ-3.5): the favourites and watch store (one file
// next to the UI preferences; memory only in tests that pump one screen) and "My nodes" (starred nodes plus claimed
// radios), each with a quiet fallback when there is no app above.
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../app/app_state.dart';
import '../../core/v1/favourites_store.dart';
import '../app.dart';

export '../../core/v1/favourites_store.dart';

final Expando<NetworkFavouritesStore> _stores = Expando('networkFavourites');
NetworkFavouritesStore _memoryStore = NetworkFavouritesStore();

/// Tests: start from an empty memory store.
void debugResetNetworkFavourites([NetworkFavouritesStore? s]) => _memoryStore = s ?? NetworkFavouritesStore();

/// The favourites and watches of this app. Starts loading on first use; listen to it for changes.
NetworkFavouritesStore networkFavourites(BuildContext context) {
  final AppState? app = AppScope.maybeOf(context);
  if (app == null) return _memoryStore..load();
  final dir = app.services.uiPrefsFile?.parent;
  final s = _stores[app] ??= NetworkFavouritesStore(file: dir == null ? null : File('${dir.path}${Platform.pathSeparator}network_favourites.json'));
  s.load();
  return s;
}

/// "My nodes": the starred nodes and observers plus the radios the person claimed.
MyNodes myNodesOf(BuildContext context) {
  final store = networkFavourites(context);
  final AppState? app = AppScope.maybeOf(context);
  final claimed = app == null ? const <String>{} : {for (final c in app.claims.active) c.pubkey.toLowerCase()};
  return MyNodes(keys: {...store.favouriteNodeKeys, ...claimed}, observerIds: store.favouriteObserverIds);
}

/// Rebuilds [builder] whenever the favourites or watches change.
class FavouritesListener extends StatefulWidget {
  final Widget Function(BuildContext context, NetworkFavouritesStore store) builder;
  const FavouritesListener({super.key, required this.builder});
  @override
  State<FavouritesListener> createState() => _FavouritesListenerState();
}

class _FavouritesListenerState extends State<FavouritesListener> {
  NetworkFavouritesStore? _s;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = networkFavourites(context);
    if (!identical(s, _s)) {
      _s?.removeListener(_changed);
      _s = s..addListener(_changed);
    }
  }

  @override
  void dispose() {
    _s?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _s!);
}
