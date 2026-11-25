// Settings > Sharing & privacy: one switch per kind of data collection (from the registry in data_sharing.dart),
// the erase action for what the server holds, the full "What MeshSonar shares" page, the location explainer and the
// website's privacy zones. Turning sharing on asks first; turning it off stops it at once and offers the erase.
import 'package:flutter/material.dart';

import '../design/app_surfaces.dart';
import '../../app/app_state.dart';
import '../../app/context_upload_hook.dart' show serverCannotEraseText;
import '../../core/data_categories.dart' show CategoryId;
import '../../core/server_url.dart' show privacyPolicyUrl;
import '../../core/phone_sensors.dart' show phoneTemperatureNote;
import '../always_location_screen.dart';
import '../app.dart';
import 'data_sharing.dart';
import 'delete_my_data.dart';
import 'privacy_profile_rows.dart' show privacyProfileEntries;
import 'privacy_zones_screen.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

/// The searchable rows of this section (spread into settingsEntries by settings_index.dart, in this order). Each id is a
/// SettingsAnchor below.
const List<SettingsEntry> privacySettingsEntries = [
  ...privacyProfileEntries,
  SettingsEntry('telemetry-toggle', 'privacy', 'Share with MeshSonar',
      'Whenever your radio is connected and the app is open, your phone is an observer: public packets and signal strength your radio hears go to the live map. Never private messages or private channels.',
      was: 'Privacy & data sharing', keywords: ['telemetry', 'observer', 'master switch', 'turn off', 'share', 'share what my radio hears', 'sharing', 'data collection', 'opt out', 'live feed', 'packets', 'packet headers', 'privacy']),
  SettingsEntry('telemetry-location', 'privacy', 'Observer location',
      'Approximate (~5 km hexagon, the default) or Region only. Never your exact position.',
      page: 'observer', was: 'Privacy & data sharing', keywords: ['location', 'observer', 'approximate', 'region only', 'hexagon', '5 km', 'privacy', 'telemetry']),
  // Drive-context categories (stream 7; titles = lib/core/data_categories.dart).
  SettingsEntry('collect-motion-toggle', 'privacy', 'Motion and altitude',
      'GPS height, direction of travel and accuracy, saved with your drive (uploaded with it when the server accepts it).',
      page: 'sharing', was: 'Privacy & data sharing', keywords: ['altitude', 'height', 'heading', 'course', 'gps accuracy', 'data collection', 'opt out']),
  SettingsEntry('collect-barometer-toggle', 'privacy', 'Air pressure',
      'Phone barometer during a drive, saved with your drive (uploaded with it when the server accepts it).',
      page: 'sharing', was: 'Privacy & data sharing', keywords: ['barometer', 'pressure', 'hpa', 'inhg', 'motion & fitness', 'sensor', 'data collection', 'opt out']),
  SettingsEntry('collect-phone_battery-toggle', 'privacy', 'Phone battery',
      'Battery level and charging during a drive, saved with your drive (uploaded with it when the server accepts it).',
      page: 'sharing', was: 'Privacy & data sharing', keywords: ['battery', 'charging', 'low power', 'data collection', 'opt out']),
  SettingsEntry('collect-device-toggle', 'privacy', 'Phone and app details',
      'System version, phone model code and app build, saved with your drive (uploaded with it when the server accepts it).',
      page: 'sharing', was: 'Privacy & data sharing', keywords: ['device', 'model', 'ios version', 'android version', 'build', 'data collection', 'opt out']),
  SettingsEntry('collect-radio_health-toggle', 'privacy', 'Radio health',
      'Radio battery, uptime, error flags, packet counters and airtime during a drive, saved with your drive (uploaded with it when the server accepts it).',
      page: 'sharing', was: 'Privacy & data sharing', keywords: ['radio battery', 'uptime', 'airtime', 'counters', 'stats', 'errors', 'data collection', 'opt out']),
  SettingsEntry('collect-radio_config-toggle', 'privacy', 'Radio settings',
      'Board, firmware and power limits of your radio, saved with your drive (uploaded with it when the server accepts it).',
      page: 'sharing', was: 'Privacy & data sharing', keywords: ['firmware', 'board', 'max power', 'radio settings', 'data collection', 'opt out']),
  SettingsEntry('collect-weather-toggle', 'privacy', 'Weather for my drives',
      'The server looks up weather near your uploaded drives, on a coarse grid, when it supports it. Data: Open-Meteo.com.',
      page: 'sharing', was: 'Privacy & data sharing', keywords: ['weather', 'temperature', 'open-meteo', 'data collection', 'opt out']),
  SettingsEntry('telemetry-erase-now', 'privacy', 'Erase shared observer packets',
      'Asks the server to delete every packet this phone sent as an observer.',
      page: 'observer', was: 'Privacy & data sharing', keywords: ['delete', 'erase', 'remove', 'telemetry', 'gdpr'], available: _privacyHasKey),
  SettingsEntry('delete-my-data', 'driver', 'Delete my data and account',
      'Deletes the drive context and observer packets the server holds for you, the context and drives saved on this phone, and your account on the website.',
      was: 'Privacy & data sharing', keywords: ['delete', 'erase', 'remove', 'gdpr', 'my data', 'privacy', 'forget', 'context', 'weather', 'sensors', 'account', 'driver key', 'drives']),
  SettingsEntry('privacy-policy', 'privacy', 'Privacy policy',
      'What MeshSonar shows in public and what stays yours, on meshsonar.com.',
      was: 'Privacy & data sharing', keywords: ['privacy policy', 'policy', 'terms', 'legal']),
  SettingsEntry('privacy-what-shared', 'privacy', 'What MeshSonar shares',
      'Everything that leaves this phone, where it goes, and what never does.',
      page: 'sharing', was: 'Privacy & data sharing', keywords: ['data', 'collected', 'disclosure', 'shared', 'privacy policy']),
  SettingsEntry('privacy-location', 'privacy', 'Location while driving',
      'Why the app asks for "Always" location and what it is never used for.',
      was: 'Privacy & data sharing', keywords: ['gps', 'always', 'background', 'location', 'permission', 'tracking']),
  SettingsEntry('privacy-zones', 'privacy', 'Privacy zones',
      'Places where your pings are hidden from the public map, and how much of the start and end of each drive is trimmed.',
      was: 'Privacy & data sharing', keywords: ['privacy zone', 'zones', 'home', 'hide', 'website', 'trim', 'start and end', 'private', 'map', 'location']),
];

bool _privacyHasKey(AppState s) => s.hasKey;

const String privacyHelp = 'What leaves this phone, and the switch for each part.';

Widget _linkRow(BuildContext context, String id, IconData icon, {String? subtitle, Widget? trailing, required VoidCallback onTap}) =>
    ListTile(
      key: Key(id),
      leading: Icon(icon),
      title: Text(settingsEntry(id).title),
      subtitle: Text(subtitle ?? settingsEntry(id).summary),
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: onTap,
    );

/// Sharing & privacy, first level: "Location while driving".
Widget privacyLocationRow(BuildContext context) => SettingsAnchor(
      id: 'privacy-location',
      child: _linkRow(context, 'privacy-location', Icons.location_on_outlined,
          subtitle: 'Why the app asks for "Always", and what it is never used for.',
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AlwaysLocationScreen(explainOnly: true)))),
    );

/// Sharing & privacy, first level: "Privacy zones". The pre-76 row "Manage privacy zones on the website" is a link on
/// that page now; its id stays as a second anchor here so an old link or search still lands on this row.
Widget privacyZonesRow(BuildContext context) {
  final s = AppScope.of(context);
  return SettingsAnchor(
    id: 'privacy-zones-website',
    child: SettingsAnchor(
      id: 'privacy-zones',
      child: _linkRow(context, 'privacy-zones', Icons.shield_outlined,
          subtitle: privacyZonesSummary(s, AppScope.unitsOf(context)),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PrivacyZonesScreen()))),
    ),
  );
}

/// Sharing & privacy, first level: the privacy policy (opens the browser).
Widget privacyPolicyRow(BuildContext context) {
  final s = AppScope.of(context);
  return SettingsAnchor(
    id: 'privacy-policy',
    child: _linkRow(context, 'privacy-policy', Icons.policy_outlined,
        subtitle: 'Opens in your browser.',
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => s.services.openUrl(Uri.parse(privacyPolicyUrl))),
  );
}

/// About: the terms of service (V1-PLAN LAUNCH-1): one page on the hub host.
Widget termsOfServiceRow(BuildContext context) {
  final s = AppScope.of(context);
  return SettingsAnchor(
    id: 'terms-of-service-link',
    child: _linkRow(context, 'terms-of-service-link', Icons.gavel_outlined,
        subtitle: 'Opens in your browser.',
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => s.openWebPage('/terms')),
  );
}

/// Account, first level: "Delete my data and account".
Widget deleteMyDataRow(BuildContext context) {
  final s = AppScope.of(context);
  return SettingsAnchor(
    id: 'delete-my-data',
    child: _linkRow(context, 'delete-my-data', Icons.delete_forever_outlined,
        subtitle: s.contextErasePending
            ? 'An erase is waiting to reach the server; it is retried automatically.'
            : 'On the server, on this phone, or both. Download a copy first.',
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DeleteMyDataScreen()))),
  );
}

/// How many of the per-item switches are on ("5 of 7 on"), for the "What is shared" row.
String sharingItemsCaption(AppState s) {
  final items = [for (final c in dataCategories) if (!identical(c, telemetryCategory)) c];
  final on = items.where((c) => c.isOn(s.settings)).length;
  return '$on of ${items.length} kinds of drive data on.';
}

/// The "What is shared" page: one switch per kind of drive data, then the full list of everything that leaves the phone.
List<Widget> sharingPageRows(BuildContext context) => [
      for (final c in dataCategories)
        if (!identical(c, telemetryCategory)) SettingsAnchor(id: c.toggleKey, child: DataCategoryTile(category: c)),
      SettingsAnchor(
        id: 'privacy-what-shared',
        child: _linkRow(context, 'privacy-what-shared', Icons.fact_check_outlined,
            subtitle: 'The full list: everything that leaves this phone, and what never does.',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WhatIsSharedScreen()))),
      ),
    ];

/// The observer rows that belong to the privacy registry: where the observer says it is, and the erase of what it sent.
List<Widget> observerPrivacyRows(BuildContext context) {
  final s = AppScope.of(context);
  return [
    const SettingsAnchor(id: 'telemetry-location', child: TelemetryLocationTile()),
    if (s.hasKey)
      for (final c in dataCategories)
        if (c.eraseFromServer != null)
          SettingsAnchor(
            id: '${c.id}-erase-now',
            child: ListTile(
              key: Key('${c.id}-erase-now'),
              leading: const Icon(Icons.delete_sweep_outlined),
              title: Text('Erase shared ${c.erasedNoun}'),
              subtitle: Text(
                c.erasePending?.call(s) == true
                    ? 'An erase is waiting to reach the server; it is retried automatically.'
                    : 'Deletes every one this phone sent. Sharing stays as it is.',
              ),
              onTap: () => eraseCategory(context, s, c),
            ),
          ),
  ];
}

/// The observer's location choice (contract section 6): Approximate (~5 km, the default) or Region only.
class TelemetryLocationTile extends StatelessWidget {
  const TelemetryLocationTile({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final regionOnly = s.settings.telemetryRegionOnly;
    final enabled = s.settings.telemetryEnabled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(telemetryLocationTitle, style: t.textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          SegmentedButton<bool>(
            key: const Key('telemetry-location-selector'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: true, label: segmentLabel(telemetryLocationRegionLabel)),
              ButtonSegment(value: false, label: segmentLabel(telemetryLocationApproxLabel)),
            ],
            selected: {regionOnly},
            onSelectionChanged: enabled ? (v) => s.updateSettings(s.settings.copyWith(telemetryRegionOnly: v.first)) : null,
          ),
          const SizedBox(height: Gap.xs),
          Text(
            !enabled
                ? 'Sharing is off, so nothing is sent.'
                : (regionOnly ? telemetryLocationRegionHelp : telemetryLocationApproxHelp),
            key: const Key('telemetry-location-help'),
            style: t.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
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
      // What it is in one sentence (the full text is on "What MeshSonar shares"), then where it stands.
      subtitle: Text(status == null ? _firstSentence(c.summary) : '${_firstSentence(c.summary)}\n$status'),
      value: on,
      onChanged: (v) => setDataCategory(context, s, c, v),
    );
  }
}

String _firstSentence(String text) {
  final i = text.indexOf('. ');
  return i < 0 ? text : text.substring(0, i + 1);
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

/// Turning on "Share with MeshSonar" (the master switch) asks first: that sheet is the data-collection disclosure. Every
/// other category turns on at once and a toast says exactly what is shared, with Undo. Turning it off takes effect at once
/// (collection stops, the unsent queue is deleted); with a driver key, so something may have been sent, the person is also
/// asked whether to erase what the server already holds.
Future<void> setDataCategory(BuildContext context, AppState s, DataCategory c, bool on) async {
  if (on) {
    if (identical(c, telemetryCategory)) {
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
    await s.updateSettings(c.set(s.settings, true));
    if (!context.mounted) return;
    showAppToast(
      context,
      '${c.title} is on. ${c.destinationNow(s)} The full list is under What MeshSonar shares.',
      actionLabel: 'Undo',
      duration: const Duration(seconds: 8),
      onAction: () => s.updateSettings(c.set(s.settings, false)),
    );
    return;
  }
  await s.updateSettings(c.set(s.settings, false));
  if (c.isDriveContext) {
    if (context.mounted) await _offerContextOff(context, s, c);
    return;
  }
  if (c.eraseFromServer == null || !s.hasKey || !context.mounted) {
    if (context.mounted) showAppToast(context, '${c.title} is off. ${c.offEffectNow(s)}');
    return;
  }
  final erase = await showEraseChoice(
    context,
    id: c.id,
    title: 'Erase what was already shared?',
    body:
        'Sharing is off. ${c.offEffect} You can also delete the ${c.erasedNoun} this phone already sent to '
        'the server.',
  );
  if (erase != true) return;
  final n = await c.eraseFromServer!(s);
  if (context.mounted) showAppToast(context, _erasedText(c, n));
}

/// Off for a drive-context category. Collection already stopped and the unsent part was stripped (AppState). If the
/// server may hold some of it (it accepts context, or some was uploaded earlier) the person is offered the server
/// erase, Erase highlighted (stream 7 D5); a server that cannot erase is said so plainly and nothing else is claimed.
/// Then the (default Keep) delete of what is saved on this phone.
Future<void> _offerContextOff(BuildContext context, AppState s, DataCategory c) async {
  final before = await s.contextEverUploaded();
  final held = s.hasKey && (s.serverAcceptsDriveContext || before);
  var note = '';
  if (held) {
    final caps = s.uploadSiteConfig;
    if (caps != null && !caps.driveContextErase) {
      note = '$serverCannotEraseText Nothing else is claimed about it.\n\n';
    } else if (context.mounted) {
      final erase = await showEraseChoice(
        context,
        id: c.id,
        title: 'Erase what the server already holds?',
        body:
            '${c.title} is off. ${c.offEffectNow(s, uploadedBefore: before)}\n\nErase asks the server to '
            'delete the ${c.erasedNoun} it holds from your uploaded drives. Keep leaves it there. This cannot be '
            'undone.',
      );
      if (erase == true) {
        final o = await s.eraseServerContext(c.coreId);
        if (context.mounted) showAppToast(context, o.message);
      }
    }
  }
  if (context.mounted) await _offerLocalDelete(context, s, c, lead: note, uploadedBefore: before);
}

/// Off for a drive-context category: offers to delete what is saved on this phone (default Keep: it is the driver's own
/// data and the drive reports use it).
Future<void> _offerLocalDelete(BuildContext context, AppState s, DataCategory c, {String lead = '', bool uploadedBefore = false}) async {
  final delete = await showAppSheet<bool>(
    context,
    detents: const [0.55],
    builder: (ctx, controller) => AppSheetScaffold(
      key: Key('${c.id}-local-dialog'),
      controller: controller,
      title: '${c.title} is off',

      primaryAction: FilledButton(key: Key('${c.id}-local-delete'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      secondaryAction: TextButton(key: Key('${c.id}-local-keep'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
      children: [
        Text(
          '$lead${c.offEffectNow(s, uploadedBefore: uploadedBefore)}\n\nDelete removes the ${c.erasedNoun} '
          'from every drive on this phone. The drives themselves stay.',
        ),
      ],
    ),
  );
  if (delete != true) {
    if (context.mounted) showAppToast(context, '${c.title} is off. What is saved on this phone stays.');
    return;
  }
  final n = await c.deleteLocal(s);
  if (!context.mounted) return;
  showAppToast(
    context,
    n == 0 ? 'Nothing of it was saved on this phone.' : 'Deleted the ${c.erasedNoun} from $n drive${n == 1 ? '' : 's'} on this phone.',
  );
}

/// Keep / Erase choice for what the server holds. Erase is the highlighted default (stream 7 D5); Keep is the other button.
Future<bool?> showEraseChoice(BuildContext context, {required String id, required String title, required String body}) =>
    showAppSheet<bool>(
      context,
      detents: const [0.55],
      builder: (ctx, controller) => AppSheetScaffold(
        key: Key('$id-erase-dialog'),
        controller: controller,
        title: title,

        primaryAction: FilledButton(key: Key('$id-erase-yes'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Erase')),
        secondaryAction: TextButton(key: Key('$id-erase-keep'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
        children: [Text(body)],
      ),
    );

String _erasedText(DataCategory c, int? n) =>
    n == null ? 'Couldn\'t reach the server. The erase will be retried.' : 'Erased $n shared ${c.erasedNoun}.';

/// The standalone erase (sharing may stay on). Destructive, so it states the consequence and asks.
Future<void> eraseCategory(BuildContext context, AppState s, DataCategory c) async {
  final ok = await confirmSettingsChange(
    context,
    dialogKey: '${c.id}-erase-now-dialog',
    title: 'Erase the ${c.erasedNoun} on the server?',
    body:
        'The server deletes every one this phone sent. This cannot be undone. '
        '${c.isOn(s.settings) ? 'Sharing stays on, so new ones are sent from now on; turn the switch off to stop that.' : 'Sharing is off, so nothing new is sent.'}',
    confirmLabel: 'Erase',
    destructive: true,
  );
  if (!ok) return;
  final n = await c.eraseFromServer!(s);
  if (context.mounted) showAppToast(context, _erasedText(c, n));
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(i, size: 18, color: t.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(settingsEntry('privacy-what-shared').title)),
      body: SafeArea(
        child: ListView(
          key: const Key('what-shared-screen'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            // What is on right now, and the way to the switches, before the long read.
            Card(
              key: const Key('what-shared-summary'),
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.toggle_on_outlined),
                title: Text('${dataCategories.where((c) => c.isOn(s.settings)).length} of ${dataCategories.length} on'),
                subtitle: const Text('Change them in Settings > Sharing & privacy.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
            for (final c in dataCategories) ...[
              Padding(
                padding: const EdgeInsets.only(top: 20, bottom: 6),
                child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
                  Semantics(header: true, child: Text(c.title, style: t.textTheme.titleMedium)),
                  _OnOffPill(on: c.isOn(s.settings), id: c.id),
                ]),
              ),
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
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('what-shared-policy'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => s.services.openUrl(Uri.parse(privacyPolicyUrl)),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Privacy policy'),
            ),
          ],
        ),
      ),
    );
  }
}

/// "On" / "Off" next to a heading: a word and a colour, so the state reads at a glance and without colour.
class _OnOffPill extends StatelessWidget {
  final bool on;
  final String id;
  const _OnOffPill({required this.on, required this.id});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final colour = on ? c.primary : c.onSurfaceVariant;
    return Container(
      key: Key('what-shared-state-$id'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colour.withValues(alpha: 0.45)),
      ),
      child: Text(on ? 'On' : 'Off', style: TextStyle(color: colour, fontWeight: FontWeight.w700)),
    );
  }
}
