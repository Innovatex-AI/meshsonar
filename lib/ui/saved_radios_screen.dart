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
import 'design/app_surfaces.dart';
import 'design/app_symbols.dart';
import 'settings/settings_kit.dart' show editSettingText;
import 'widgets.dart';

/// "Last connected 5 min ago", "… yesterday", "… 12 days ago", "… on 3 Mar 2026"; "Last connection time unknown" when there
/// is no time (only possible for a damaged or hand-edited file: migrated radios take the old file's time).
String lastConnectedText(DateTime? at, DateTime now) {
  if (at == null) return 'Last connection time unknown';
  final d = now.difference(at);
  if (d.inSeconds < 90) return 'Last connected just now';
  if (d.inMinutes < 60) return 'Last connected ${d.inMinutes} min ago';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final days = today.difference(day).inDays;
  if (days <= 0) return 'Last connected ${d.inHours} h ago';
  if (days == 1) return 'Last connected yesterday';
  if (days < 60) return 'Last connected $days days ago';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return 'Last connected on ${at.day} ${months[at.month - 1]} ${at.year}';
}

enum _RadioAction { nickname, star, followRecent, forget }

/// Asks, then forgets [r]. Returns true when it was forgotten.
Future<bool> confirmForgetSavedRadio(BuildContext context, SavedRadiosStore store, SavedRadio r) async {
  final ok = await showAppAlert(
    context,
    title: 'Forget ${r.displayName}?',
    message: 'It leaves your saved radios${store.starredId == r.id ? ' and auto-connect moves to your most recent radio' : ''}. '
        'Chat history, contacts and its antenna setup stay. It comes back the next time you connect to it.',
    confirmLabel: 'Forget',
    destructive: true,
    dialogKey: const Key('saved-radio-forget-dialog'),
    confirmKey: const Key('saved-radio-forget-confirm'),
    cancelKey: const Key('saved-radio-forget-cancel'),
  );
  if (ok != true) return false;
  await store.forget(r.id);
  return true;
}

/// Nickname / star / forget for one saved radio (long-press or the info button).
Future<void> showSavedRadioActions(BuildContext context, SavedRadiosStore store, SavedRadio r) async {
  final starred = store.starredId == r.id;
  final details = [
    if (r.nickname != null) 'Radio name: ${r.name}',
    if (r.model != null) r.model!,
    if (r.publicKeyHex != null && r.publicKeyHex!.length >= 8) 'Key ${r.publicKeyHex!.substring(0, 8)}…',
    lastConnectedText(r.lastConnected, DateTime.now()),
    if (starred) store.starPinned ? 'Auto-connect radio (your choice).' : 'Auto-connect radio (your most recent).',
  ].join('\n');
  final a = await showAppActionSheet<_RadioAction>(
    context,
    title: r.displayName,
    message: details,
    sheetKey: const Key('saved-radio-actions'),
    actions: [
      AppAction(r.nickname == null ? 'Add a nickname' : 'Change nickname', _RadioAction.nickname,
          symbol: AppSymbols.squareAndPencil, key: const Key('saved-radio-nickname')),
      if (!starred || !store.starPinned)
        AppAction('Use for auto-connect', _RadioAction.star, symbol: AppSymbols.star, key: const Key('saved-radio-star')),
      if (starred && store.starPinned)
        AppAction('Follow the most recent radio', _RadioAction.followRecent,
            symbol: AppSymbols.clock, key: const Key('saved-radio-follow-recent')),
      AppAction('Forget', _RadioAction.forget, destructive: true, symbol: AppSymbols.trash, key: const Key('saved-radio-forget')),
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
        help: 'Shown instead of "${r.name}" in MeshSonar. Leave empty to use the radio\'s own name. Nothing is written to the radio.',
        validate: (v) => v.trim().length > 40 ? 'Keep it to 40 characters' : null,
      );
      if (n != null) await store.setNickname(r.id, n);
    case _RadioAction.star:
      await store.pinStar(r.id);
    case _RadioAction.followRecent:
      await store.followMostRecent();
    case _RadioAction.forget:
      await confirmForgetSavedRadio(context, store, r);
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
      [if (r.nickname != null) r.name, ?r.model].join(' · '),
      if (starred) 'Auto-connect radio',
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
                icon: const AppSymbolIcon(AppSymbols.infoCircle),
                onPressed: () => showSavedRadioActions(context, store, r),
              ),
        enabled: enabled,
        onTap: connected ? null : onTap,
        onLongPress: () => showSavedRadioActions(context, store, r),
      ),
    );
    return Dismissible(
      key: ValueKey('saved-radio-dismiss-${r.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => confirmForgetSavedRadio(context, store, r),
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
    if (ok) showAppToast(context, 'Connected to ${r.displayName}');
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final store = AlertsHost.runtime.value?.savedRadios;
    return Scaffold(
      appBar: AppBar(title: const Text('Saved radios')),
      body: SafeArea(
        child: store == null
            ? const Center(child: Text('Saved radios are not available in this build.'))
            : ListenableBuilder(
                listenable: store,
                builder: (context, _) => ListView(
                  key: const Key('saved-radios-screen'),
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                  children: [
                    if (s.connectError != null && _connectingId == null) ErrorBanner(s.connectError!),
                    if (store.isEmpty)
                      Padding(
                        key: const Key('saved-radios-empty'),
                        padding: const EdgeInsets.all(Gap.l),
                        child: Text('No saved radios yet. Every radio you connect to over Bluetooth is saved here.',
                            style: Theme.of(context).textTheme.bodyLarge),
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
                        'Tap a radio to connect. Swipe left to forget it; hold or tap the info button for a nickname or to choose '
                        'the auto-connect radio (the star). The star follows your most recent radio unless you choose one.',
                        key: const Key('saved-radios-footer'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
