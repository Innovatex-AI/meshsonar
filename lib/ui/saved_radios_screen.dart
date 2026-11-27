// Saved radios (CR6): the Bluetooth radios this phone has connected to (lib/alerts/saved_radios_store.dart). The same list is
// shown on the connect screen above the scan results and on its own page from Settings > Radio > Saved radios.
//
//  * Tap a radio to connect to it (no scan needed; the phone remembers its Bluetooth id).
//  * Swipe left to Forget (asks first). Forgetting only removes it from this list: chat history, contacts and its antenna
//    setup stay, and it comes back the next time you connect to it.
//  * Long-press, or the info button, for Nickname, Use for auto-connect (the star) / Follow the most recent radio, Forget.
//  * The star marks the auto-connect radio. By default it follows the most recently connected radio; starring one yourself
//    keeps it there.
import 'dart:async';

import 'package:flutter/material.dart';

import '../alerts/alerts_runtime.dart';
import '../alerts/saved_radios_store.dart';
import '../app/app_state.dart' show RadioKind;
import 'app.dart';
import 'connect_screen.dart' show ConnectScreen;
import 'design/app_surfaces.dart';
import '../core/time_format.dart' as tf;
import 'design/app_symbols.dart';
import 'settings/settings_kit.dart' show editSettingText;
import 'widgets.dart';

/// "Last connected 5 min ago", "… 30 h ago", "… 12 d ago" (the app's one wording, lib/core/time_format.dart), "… on Mar 3,
/// 2026" after 60 days; "Last connection time unknown" when there is no time (only possible for a damaged or hand-edited
/// file: migrated radios take the old file's time).
String lastConnectedText(DateTime? at, DateTime now) {
  if (at == null) return 'Last connection time unknown';
  if (now.difference(at).inDays < 60) return 'Last connected ${tf.relativeTime(at, now: now)}';
  return 'Last connected on ${tf.dateOnly(at)}';
}

enum _RadioAction { nickname, star, followRecent, forget }

/// Forgets [r] (chat history, contacts and the antenna setup stay) and offers Undo. Returns true when it was forgotten.
Future<bool> forgetSavedRadio(BuildContext context, SavedRadiosStore store, SavedRadio r) async {
  final wasStarred = store.starredId == r.id;
  final wasPinned = wasStarred && store.starPinned;
  await store.forget(r.id);
  if (context.mounted) {
    showAppToast(context, '${r.displayName} forgotten.', actionLabel: 'Undo', onAction: () => unawaited(store.restore(r, starred: wasStarred, pinned: wasPinned)));
  }
  return true;
}

/// Nickname / star / forget for one saved radio (long-press or the info button).
Future<void> showSavedRadioActions(BuildContext context, SavedRadiosStore store, SavedRadio r) async {
  final starred = store.starredId == r.id;
  // Two short lines at most on a phone: what it is, then when it was last used. The key prefix (to tell two radios with
  // the same name apart) goes last.
  final details = [
    [if (r.nickname != null) r.name, ?r.model].join(' · '),
    lastConnectedText(r.lastConnected, DateTime.now()),
    if (starred) store.starPinned ? 'Connects automatically (your choice).' : 'Connects automatically (most recent radio).',
    if (r.publicKeyHex != null && r.publicKeyHex!.length >= 8) 'Radio ID ${r.publicKeyHex!.substring(0, 8)}',
  ].where((l) => l.isNotEmpty).join('\n');
  final a = await showAppActionSheet<_RadioAction>(
    context,
    title: r.displayName,
    message: details,
    sheetKey: const Key('saved-radio-actions'),
    actions: [
      AppAction(r.nickname == null ? 'Add a nickname' : 'Change nickname', _RadioAction.nickname,
          symbol: AppSymbols.squareAndPencil, key: const Key('saved-radio-nickname')),
      if (!starred || !store.starPinned)
        AppAction('Always auto-connect to this radio', _RadioAction.star, symbol: AppSymbols.star, key: const Key('saved-radio-star')),
      if (starred && store.starPinned)
        AppAction('Auto-connect to my most recent radio', _RadioAction.followRecent,
            symbol: AppSymbols.clock, key: const Key('saved-radio-follow-recent')),
      AppAction('Forget this radio', _RadioAction.forget, destructive: true, symbol: AppSymbols.trash, key: const Key('saved-radio-forget')),
    ],
  );
  if (!context.mounted || a == null) return;
  switch (a) {
    case _RadioAction.nickname:
      final n = await editSettingText(
        context,
        title: 'Nickname',
        initial: r.nickname ?? '',
        hint: r.name,
        help: 'Only shown in MeshSonar. Leave empty to use "${r.name}".',
        validate: (v) => v.trim().length > 40 ? 'Keep it to 40 characters' : null,
      );
      if (n != null) await store.setNickname(r.id, n);
    case _RadioAction.star:
      await store.pinStar(r.id);
    case _RadioAction.followRecent:
      await store.followMostRecent();
    case _RadioAction.forget:
      await forgetSavedRadio(context, store, r);
  }
}

/// The saved radios as cards. [onConnect] is called with a tapped radio; [connectingId] shows a spinner on that one.
class SavedRadiosList extends StatelessWidget {
  final SavedRadiosStore store;
  final void Function(SavedRadio radio) onConnect;
  final String? connectingId;
  final String? connectedId;
  final bool enabled;

  /// Bluetooth ids the current scan sees ("In range" on the card).
  final Set<String> inRange;
  final DateTime Function() now;
  const SavedRadiosList({
    super.key,
    required this.store,
    required this.onConnect,
    this.connectingId,
    this.connectedId,
    this.enabled = true,
    this.inRange = const {},
    this.now = DateTime.now,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Column(
        key: const Key('saved-radios-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final r in store.radios)
            _SavedRadioCard(
              key: ValueKey('saved-radio-${r.id}'),
              store: store,
              radio: r,
              starred: store.starredId == r.id,
              connecting: connectingId == r.id,
              connected: connectedId == r.id,
              inRange: inRange.contains(r.id),
              enabled: enabled,
              now: now(),
              onTap: () => onConnect(r),
            ),
        ],
      ),
    );
  }
}

class _SavedRadioCard extends StatelessWidget {
  final SavedRadiosStore store;
  final SavedRadio radio;
  final bool starred;
  final bool connecting;
  final bool connected;
  final bool inRange;
  final bool enabled;
  final DateTime now;
  final VoidCallback onTap;
  const _SavedRadioCard({
    super.key,
    required this.store,
    required this.radio,
    required this.starred,
    required this.connecting,
    required this.connected,
    this.inRange = false,
    required this.enabled,
    required this.now,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final r = radio;
    final lines = [
      if (connecting)
        'Connecting…'
      else if (connected)
        'Connected'
      else
        '${inRange ? 'In range · ' : ''}${lastConnectedText(r.lastConnected, now)}',
      [if (r.nickname != null) r.name, ?r.model, if (starred) 'Auto-connect'].join(' · '),
    ].where((l) => l.isNotEmpty).join('\n');
    final card = Card(
      child: ListTile(
        minTileHeight: 72,
        contentPadding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.xs, Gap.xs),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: c.primary.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(Corners.small)),
          child: Icon(Icons.bluetooth_rounded, color: c.primary, size: 26),
        ),
        title: Row(children: [
          Flexible(child: Text(r.displayName, overflow: TextOverflow.ellipsis)),
          if (starred) ...[
            const SizedBox(width: Gap.xs),
            AppSymbolIcon(AppSymbols.starFill,
                key: ValueKey('saved-radio-star-${r.id}'), size: 18, color: c.primary, semanticLabel: 'Auto-connect radio'),
          ],
        ]),
        subtitle: Text(lines),
        trailing: connecting
            ? const Padding(
                padding: EdgeInsets.all(Gap.m),
                child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
              )
            : IconButton(
                key: ValueKey('saved-radio-info-${r.id}'),
                tooltip: 'Nickname, auto-connect, forget',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: const AppSymbolIcon(AppSymbols.ellipsis),
                onPressed: () => showSavedRadioActions(context, store, r),
              ),
        enabled: enabled,
        // A tap on the connected radio used to do nothing at all; say why.
        onTap: connected ? () => showAppToast(context, 'Already connected to ${r.displayName}.') : onTap,
        onLongPress: () => showSavedRadioActions(context, store, r),
      ),
    );
    return Dismissible(
      key: ValueKey('saved-radio-dismiss-${r.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => forgetSavedRadio(context, store, r),
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.circular(Corners.card)),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('Forget', style: TextStyle(color: c.onErrorContainer, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          AppSymbolIcon(AppSymbols.trash, color: c.onErrorContainer),
        ]),
      ),
      child: card,
    );
  }
}

/// Settings > Radio > Saved radios: the list on its own page. Tapping a radio connects to it here.
class SavedRadiosScreen extends StatefulWidget {
  const SavedRadiosScreen({super.key});
  @override
  State<SavedRadiosScreen> createState() => _SavedRadiosScreenState();
}

class _SavedRadiosScreenState extends State<SavedRadiosScreen> {
  String? _connectingId;
  final ScrollController _list = ScrollController();

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }

  void _openConnect() => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen())));

  Future<void> _connect(SavedRadio r) async {
    final s = AppScope.read(context);
    if (s.driving) {
      showAppToast(context, 'Stop the drive to change radios.');
      return;
    }
    setState(() => _connectingId = r.id);
    final ok = await s.connect(r.device, RadioKind.bluetooth);
    if (!mounted) return;
    setState(() => _connectingId = null);
    if (ok) {
      showAppToast(context, 'Connected to ${r.displayName}', kind: AppToastKind.success);
    } else if (_list.hasClients) {
      // The reason is in the banner at the top of the list: bring it into view.
      unawaited(_list.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final store = AlertsHost.runtime.value?.savedRadios;
    return Scaffold(
      appBar: AppBar(title: const Text('Saved radios')),
      body: SafeArea(
        child: store == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(Gap.xl),
                  child: Text('Saved radios are not ready yet. Go back and open this page again.', key: Key('saved-radios-unavailable'), textAlign: TextAlign.center),
                ),
              )
            : ListenableBuilder(
                listenable: store,
                builder: (context, _) => ListView(
                  key: const Key('saved-radios-screen'),
                  controller: _list,
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                  children: [
                    if (s.connectError != null && _connectingId == null) ErrorBanner(s.connectError!),
                    if (store.isEmpty)
                      Padding(
                        key: const Key('saved-radios-empty'),
                        padding: const EdgeInsets.all(Gap.l),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Icon(Icons.bluetooth_rounded, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          const SizedBox(height: Gap.m),
                          Text('No saved radios yet', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: Gap.xs),
                          Text('A radio is saved here the first time you connect to it.',
                              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: Gap.l),
                          FilledButton.icon(
                            key: const Key('saved-radios-connect'),
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                            onPressed: _openConnect,
                            icon: const Icon(Icons.bluetooth_searching),
                            label: const Text('Connect a radio'),
                          ),
                        ]),
                      )
                    else ...[
                      SavedRadiosList(
                        store: store,
                        onConnect: _connect,
                        connectingId: _connectingId,
                        connectedId: s.connected ? s.device?.id : null,
                        enabled: _connectingId == null && !s.connecting,
                      ),
                      const SizedBox(height: Gap.m),
                      Text(
                        'Tap a radio to connect. The star is the one MeshSonar connects to by itself.',
                        key: const Key('saved-radios-footer'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: Gap.s),
                      // A radio that is not in the list yet: one tap to the scan, instead of back > back > Connect.
                      OutlinedButton.icon(
                        key: const Key('saved-radios-connect'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: _openConnect,
                        icon: const Icon(Icons.add),
                        label: const Text('Connect another radio'),
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

/// Unawaited helper for callers that do not need the result.
void openSavedRadios(BuildContext context) =>
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SavedRadiosScreen())));
