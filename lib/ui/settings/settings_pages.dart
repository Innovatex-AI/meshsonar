// How Settings is put together (build 76): which rows are on the first level of each of the eight sections, which sit
// one level down on a page (settings_index.dart `settingsPages`), the row that opens a page and the page itself.
// The first level holds what a person changes often; rare and expert rows are on a page behind a plainly named row.
// Every row keeps its anchor id, so search and deep links land on it wherever it lives now.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app.dart';
import 'about_section.dart';
import 'account_section.dart';
import 'battery_section.dart';
import 'diagnostics_section.dart';
import 'display_section.dart';
import 'drives_section.dart';
import 'maps_section.dart';
import 'meshtrack_section.dart';
import 'my_radios_section.dart';
import 'notifications_section.dart';
import 'observer_section.dart';
import 'privacy_profile_rows.dart';
import 'privacy_section.dart';
import 'radio_section.dart';
import 'region_section.dart';
import 'settings_index.dart';
import 'settings_kit.dart';
import 'storage_section.dart';
import 'wardriving_section.dart';

/// The first-level rows of section [id].
List<Widget> settingsSectionRows(BuildContext context, String id) {
  final s = AppScope.of(context);
  return switch (sectionInfo(id).id) {
    'driver' => [
        const SettingsAnchor(id: 'driver-key', child: DriverKeySection()),
        if (settingsPage('profile').isAvailable(s)) const SettingsPageRow('profile'),
        const SettingsPageRow('claims'),
        deleteMyDataRow(context),
        const SettingsPageRow('account-advanced'),
      ],
    'radio' => radioSectionRows(context),
    'wardriving' => [
        ...wardrivingSectionRows(context),
        const SettingsPageRow('uploads'),
        const SettingsAnchor(id: 'battery-mode', child: BatteryModePicker()),
        const SettingsPageRow('battery'),
        const SettingsPageRow('driving-advanced'),
      ],
    'display' => [
        const SettingsAnchor(id: 'region-pick', child: RegionPickTile()),
        ...mapsSectionRows(context),
        ...displaySectionRows(context),
      ],
    'privacy' => [
        // One switch: it has the anchor of the pre-76 Privacy switch and of the pre-76 Observer switch.
        const SettingsAnchor(id: 'observer-share', child: SettingsAnchor(id: 'telemetry-toggle', child: ObserverShareTile())),
        const SettingsPageRow('observer'),
        const SettingsPageRow('sharing'),
        privacyLocationRow(context),
        privacyZonesRow(context),
        if (settingsPage('meshtrack').isAvailable(s)) const SettingsPageRow('meshtrack'),
        privacyPolicyRow(context),
      ],
    'notifications' => notificationsSectionRows(context),
    'storage' => [
        const SettingsPageRow('storage-items'),
        ...diagnosticsSectionRows(context),
        const SettingsPageRow('diagnostics-advanced'),
      ],
    _ => aboutSectionRows(context),
  };
}

/// One short line under a section's title; null for a section that needs none.
String? settingsSectionHelp(String id) => switch (sectionInfo(id).id) {
      'driver' => driverHelp,
      'wardriving' => wardrivingHelp,
      'privacy' => privacyHelp,
      _ => null,
    };

/// The rows of page [id].
List<Widget> settingsPageRows(BuildContext context, String id) {
  final s = AppScope.of(context);
  return switch (id) {
    'profile' => const [PrivacyProfileRows()],
    'claims' => myRadiosSectionRows(context),
    'account-advanced' => [
        const SettingsAnchor(id: 'server-url', child: ServerUrlTile()),
        ...serverRegionRows(context),
      ],
    'uploads' => drivesSectionRows(context),
    'battery' => batterySectionRows(context),
    'driving-advanced' => drivingAdvancedRows(context),
    'units' => unitPageRows(context),
    'observer' => [...observerSectionRows(context), ...observerPrivacyRows(context)],
    'sharing' => sharingPageRows(context),
    'meshtrack' => meshTrackSectionRows(context),
    'storage-items' => storageSectionRows(context),
    'diagnostics-advanced' => diagnosticsAdvancedRows(context),
    _ => [ListTile(title: Text('Nothing here: ${s.settings.serverUrl}'))],
  };
}

/// One short line at the top of a page; null when the rows say it all.
String? settingsPageHelp(String id) => switch (id) {
      'claims' => myRadiosHelp,
      'uploads' => drivesHelp,
      'battery' => batteryHelp,
      'observer' => observerHelp,
      'sharing' => 'Each kind of drive data is saved with your drive. Off stops it at once.',
      'meshtrack' => meshTrackHelp,
      'storage-items' => storageHelp,
      'diagnostics-advanced' => diagnosticsHelp,
      'units' => 'Each follows Units unless you pick its own.',
      _ => null,
    };

/// What the row that opens page [id] says under its title: the live state where there is one, else the page's line.
String settingsPageCaption(BuildContext context, String id) {
  final s = AppScope.of(context);
  return switch (id) {
    'claims' => claimsCaption(context),
    'account-advanced' => Uri.tryParse(s.settings.serverUrl)?.host ?? s.settings.serverUrl,
    'uploads' => uploadsCaption(s),
    'observer' => observerStatusCaption(s),
    'sharing' => sharingItemsCaption(s),
    'profile' => s.driverSettings.callsign ?? settingsPage(id).summary,
    _ => settingsPage(id).summary,
  };
}

/// Opens page [id] over Settings; [highlight] is the row to scroll to and tint.
Future<void> openSettingsPage(BuildContext context, String id, {String? highlight}) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SettingsPageScreen(pageId: id, highlight: highlight)),
    );

/// The first-level row that opens a page. Anchor id and key: `page-<id>`.
class SettingsPageRow extends StatelessWidget {
  final String pageId;
  const SettingsPageRow(this.pageId, {super.key});

  @override
  Widget build(BuildContext context) {
    final p = settingsPage(pageId);
    return SettingsAnchor(
      id: 'page-$pageId',
      child: ListTile(
        key: Key('page-$pageId'),
        leading: Icon(p.icon),
        title: Text(p.title),
        subtitle: Text(settingsPageCaption(context, pageId), key: Key('page-$pageId-caption')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openSettingsPage(context, pageId),
      ),
    );
  }
}

/// A page one level down from a Settings section: the same card of rows, with its own anchors so a search result or a
/// link can land on one of them.
class SettingsPageScreen extends StatefulWidget {
  final String pageId;
  final String? highlight;
  const SettingsPageScreen({super.key, required this.pageId, this.highlight});

  @override
  State<SettingsPageScreen> createState() => _SettingsPageScreenState();
}

class _SettingsPageScreenState extends State<SettingsPageScreen> {
  final Map<String, GlobalKey> _anchors = {};

  @override
  void initState() {
    super.initState();
    final id = widget.highlight;
    if (id == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _anchors[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx, alignment: 0.05, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
      }
      final e = resolveSettingsTarget(id) == null ? null : settingsEntry(id);
      if (e != null) SemanticsService.sendAnnouncement(View.of(context), '${e.title}, in ${e.where}', Directionality.of(context));
    });
  }

  @override
  Widget build(BuildContext context) {
    AppScope.of(context); // rebuild with the app state
    return PowerProfileBuilder(builder: _page); // and with the battery profile (Uploads and Battery details show it)
  }

  Widget _page(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final p = settingsPage(widget.pageId);
    final help = settingsPageHelp(p.id);
    final rows = settingsPageRows(context, p.id);
    return Scaffold(
      appBar: AppBar(title: Text(p.title)),
      body: SafeArea(
        child: SettingsAnchors(
          keys: _anchors,
          highlighted: widget.highlight,
          child: SingleChildScrollView(
            // The same key as the Settings list: only the page in front is on stage, so "the settings list" is this one.
            key: const Key('settings-list'),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(key: Key('settings-page-${p.id}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (help != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                      child: Text(help, key: const Key('settings-page-help'), style: t.textTheme.bodySmall?.copyWith(color: c.onSurfaceVariant)),
                    ),
                  Card(
                    margin: EdgeInsets.zero,
                    clipBehavior: Clip.antiAlias,
                    child: Column(children: [
                      for (var i = 0; i < rows.length; i++) ...[
                        if (i > 0) Divider(height: 1, indent: 56, color: c.outlineVariant.withValues(alpha: 0.5)),
                        rows[i],
                      ],
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
