// Settings > Privacy & data sharing: one switch per kind of data collection (from the registry in data_sharing.dart),
// the erase action for what the server holds, the full "What MeshSonar shares" page, the location explainer and the
// website's privacy zones. Turning sharing on asks first; turning it off stops it at once and offers the erase.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/context_upload_hook.dart' show serverCannotEraseText;
import '../../core/data_categories.dart' show CategoryId;
import '../../core/phone_sensors.dart' show phoneTemperatureNote;
import '../always_location_screen.dart';
import '../app.dart';
import 'data_sharing.dart';
import 'delete_my_data.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String privacyHelp = 'Everything that leaves this phone is listed here, with its own switch where you can turn '
    'it off. Turning one off stops it at once.';

List<Widget> privacySectionRows(BuildContext context) {
  final s = AppScope.of(context);
  return [
    for (final c in dataCategories) SettingsAnchor(id: c.toggleKey, child: DataCategoryTile(category: c)),
    if (s.hasKey)
      for (final c in dataCategories)
        if (c.eraseFromServer != null)
          SettingsAnchor(
            id: '${c.id}-erase-now',
            child: ListTile(
              key: Key('${c.id}-erase-now'),
              leading: const Icon(Icons.delete_sweep_outlined),
              title: Text('Erase shared ${c.erasedNoun}'),
              subtitle: Text(c.erasePending?.call(s) == true
                  ? 'An erase is waiting to reach the server; it is retried automatically.'
                  : 'Asks the server to delete every one this phone sent. Sharing stays as it is.'),
              onTap: () => eraseCategory(context, s, c),
            ),
          ),
    SettingsAnchor(
      id: 'delete-my-data',
      child: ListTile(
        key: const Key('delete-my-data'),
        leading: const Icon(Icons.delete_forever_outlined),
        title: Text(settingsEntry('delete-my-data').title),
        subtitle: Text(s.contextErasePending
            ? 'An erase is waiting to reach the server; it is retried automatically.'
            : settingsEntry('delete-my-data').summary),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DeleteMyDataScreen())),
      ),
    ),
    SettingsAnchor(
      id: 'privacy-what-shared',
      child: ListTile(
        key: const Key('privacy-what-shared'),
        leading: const Icon(Icons.fact_check_outlined),
        title: Text(settingsEntry('privacy-what-shared').title),
        subtitle: Text(settingsEntry('privacy-what-shared').summary),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WhatIsSharedScreen())),
      ),
    ),
    SettingsAnchor(
      id: 'privacy-location',
      child: ListTile(
        key: const Key('privacy-location'),
        leading: const Icon(Icons.location_on_outlined),
        title: Text(settingsEntry('privacy-location').title),
        subtitle: const Text(locationSummary),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const AlwaysLocationScreen(explainOnly: true))),
      ),
    ),
    SettingsAnchor(
      id: 'privacy-zones-website',
      child: ListTile(
        key: const Key('privacy-zones-website'),
        leading: const Icon(Icons.open_in_new),
        title: Text(settingsEntry('privacy-zones-website').title),
        subtitle: Text('Hide pings near places like home on ${s.webPage('/me/privacy')}. Applies to uploaded drives.'),
        onTap: () => s.openWebPage('/me/privacy'),
      ),
    ),
  ];
}

/// One collection switch: title, what it shares, and what is waiting on the phone.
class DataCategoryTile extends StatelessWidget {
  final DataCategory category;
  const DataCategoryTile({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = category;
    final on = c.isOn(s.settings);
    final status = !on ? 'Off: nothing is collected.' : c.onStatus?.call(s);
    return SwitchListTile(
      key: Key(c.toggleKey),
      secondary: Icon(categoryIcon(c.coreId)),
      title: Text(c.title),
      subtitle: Text(status == null ? c.summary : '${c.summary}\n$status'),
      value: on,
      onChanged: (v) => setDataCategory(context, s, c, v),
    );
  }
}

/// The icon of a category's switch.
IconData categoryIcon(String coreId) => switch (coreId) {
      CategoryId.motion => Icons.terrain_outlined,
      CategoryId.barometer => Icons.speed_outlined,
      CategoryId.phoneBattery => Icons.battery_std_outlined,
      CategoryId.device => Icons.smartphone_outlined,
      CategoryId.radioHealth => Icons.monitor_heart_outlined,
      CategoryId.radioConfig => Icons.settings_input_antenna,
      CategoryId.weather => Icons.cloud_outlined,
      _ => Icons.podcasts,
    };

/// Turning sharing on asks first (it states exactly what goes where). Turning it off takes effect at once (collection
/// stops, the unsent queue is deleted); with a driver key, so something may have been sent, the person is also asked
/// whether to erase what the server already holds.
Future<void> setDataCategory(BuildContext context, AppState s, DataCategory c, bool on) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (on) {
    final ok = await confirmSettingsChange(
      context,
      dialogKey: '${c.id}-on-dialog',
      title: 'Turn on: ${c.title}?',
      body: 'Shared: ${c.shared.join('; ')}.\n\nNever shared: ${c.neverShared.join('; ')}.\n\n${c.destinationNow(s)}',
      confirmLabel: c.keepLabel,
    );
    if (!ok) return;
    await s.updateSettings(c.set(s.settings, true));
    return;
  }
  await s.updateSettings(c.set(s.settings, false));
  if (c.isDriveContext) {
    if (context.mounted) await _offerContextOff(context, s, c, messenger);
    return;
  }
  if (c.eraseFromServer == null || !s.hasKey || !context.mounted) {
    messenger?.showSnackBar(SnackBar(content: Text('${c.title} is off. ${c.offEffectNow(s)}')));
    return;
  }
  final erase = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: Key('${c.id}-erase-dialog'),
      title: const Text('Erase what was already shared?'),
      content: Text('Sharing is off. ${c.offEffect} You can also delete the ${c.erasedNoun} this phone already sent to '
          'the server.'),
      actions: [
        TextButton(key: Key('${c.id}-erase-keep'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
        FilledButton(key: Key('${c.id}-erase-yes'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Erase')),
      ],
    ),
  );
  if (erase != true) return;
  final n = await c.eraseFromServer!(s);
  messenger?.showSnackBar(SnackBar(content: Text(_erasedText(c, n))));
}

/// Off for a drive-context category. Collection already stopped and the unsent part was stripped (AppState). If the
/// server may hold some of it (it accepts context, or some was uploaded earlier) the person is offered the server
/// erase, Erase highlighted (stream 7 D5); a server that cannot erase is said so plainly and nothing else is claimed.
/// Then the (default Keep) delete of what is saved on this phone.
Future<void> _offerContextOff(
    BuildContext context, AppState s, DataCategory c, ScaffoldMessengerState? messenger) async {
  final before = await s.contextEverUploaded();
  final held = s.hasKey && (s.serverAcceptsDriveContext || before);
  var note = '';
  if (held) {
    final caps = s.uploadSiteConfig;
    if (caps != null && !caps.driveContextErase) {
      note = '$serverCannotEraseText Nothing else is claimed about it.\n\n';
    } else if (context.mounted) {
      final erase = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: Key('${c.id}-erase-dialog'),
          title: const Text('Erase what the server already holds?'),
          content: Text('${c.title} is off. ${c.offEffectNow(s, uploadedBefore: before)}\n\nErase asks the server to '
              'delete the ${c.erasedNoun} it holds from your uploaded drives. Keep leaves it there. This cannot be '
              'undone.'),
          actions: [
            TextButton(key: Key('${c.id}-erase-keep'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
            FilledButton(key: Key('${c.id}-erase-yes'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Erase')),
          ],
        ),
      );
      if (erase == true) {
        final o = await s.eraseServerContext(c.coreId);
        messenger?.showSnackBar(SnackBar(content: Text(o.message)));
      }
    }
  }
  if (context.mounted) await _offerLocalDelete(context, s, c, messenger, lead: note, uploadedBefore: before);
}

/// Off for a drive-context category: offers to delete what is saved on this phone (default Keep: it is the driver's own
/// data and the drive reports use it).
Future<void> _offerLocalDelete(BuildContext context, AppState s, DataCategory c, ScaffoldMessengerState? messenger,
    {String lead = '', bool uploadedBefore = false}) async {
  final delete = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: Key('${c.id}-local-dialog'),
      title: Text('${c.title} is off'),
      content: Text('$lead${c.offEffectNow(s, uploadedBefore: uploadedBefore)}\n\nDelete removes the ${c.erasedNoun} '
          'from every drive on this phone. The drives themselves stay.'),
      actions: [
        TextButton(key: Key('${c.id}-local-keep'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
        FilledButton(
            key: Key('${c.id}-local-delete'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ),
  );
  if (delete != true) {
    messenger?.showSnackBar(SnackBar(content: Text('${c.title} is off. What is saved on this phone stays.')));
    return;
  }
  final n = await c.deleteLocal(s);
  messenger?.showSnackBar(SnackBar(
      content: Text(n == 0
          ? 'Nothing of it was saved on this phone.'
          : 'Deleted the ${c.erasedNoun} from $n drive${n == 1 ? '' : 's'} on this phone.')));
}

String _erasedText(DataCategory c, int? n) =>
    n == null ? 'Couldn\'t reach the server. The erase will be retried.' : 'Erased $n shared ${c.erasedNoun}.';

/// The standalone erase (sharing may stay on). Destructive, so it states the consequence and asks.
Future<void> eraseCategory(BuildContext context, AppState s, DataCategory c) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ok = await confirmSettingsChange(
    context,
    dialogKey: '${c.id}-erase-now-dialog',
    title: 'Erase the ${c.erasedNoun} on the server?',
    body: 'The server deletes every one this phone sent. This cannot be undone. '
        '${c.isOn(s.settings) ? 'Sharing stays on, so new ones are sent from now on; turn the switch off to stop that.' : 'Sharing is off, so nothing new is sent.'}',
    confirmLabel: 'Erase',
    destructive: true,
  );
  if (!ok) return;
  final n = await c.eraseFromServer!(s);
  messenger?.showSnackBar(SnackBar(content: Text(_erasedText(c, n))));
}

/// Everything that leaves the phone, in one place: the switchable categories (with their current state), the other
/// flows and where each is controlled, and the location explainer's points.
class WhatIsSharedScreen extends StatelessWidget {
  const WhatIsSharedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    Widget head(String text) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 6),
          child: Semantics(header: true, child: Text(text, style: t.textTheme.titleMedium)),
        );
    Widget line(IconData i, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 18, color: t.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: Text(settingsEntry('privacy-what-shared').title)),
      body: SafeArea(
        child: ListView(key: const Key('what-shared-screen'), padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
          for (final c in dataCategories) ...[
            head('${c.title}: ${c.isOn(s.settings) ? 'on' : 'off'}'),
            Text(c.disclosureLead),
            const SizedBox(height: 6),
            for (final x in c.shared) line(Icons.check, x),
            for (final x in c.neverShared) line(Icons.block, 'Never: $x'),
            const SizedBox(height: 6),
            Text(c.destinationNow(s)),
            Text(c.offEffectNow(s)),
          ],
          head('Not collected'),
          const Text(phoneTemperatureNote),
          for (final f in otherDataFlows) ...[head(f.title), Text(f.body)],
          head('Location'),
          for (final p in locationPoints) ...[
            Text(p.head, style: t.textTheme.titleSmall),
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(p.body)),
          ],
        ]),
      ),
    );
  }
}
