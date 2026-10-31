// Settings shell: a search field, then the sections (lib/ui/settings/*_section.dart, one file each) in the order of
// lib/ui/settings/settings_index.dart. Phone: one scrolling list of collapsible section cards, expanded by default; the
// app bar has Search (back to the field from anywhere in the list) and Sections (a sheet listing every section, which
// jumps to it). Design reasoning: _docs/stream-6-settings.md "Build status (Andy decisions)".
// Wide screens (>= 840 dp, e.g. iPad landscape): sections on the left, the chosen section on the right.
// Search matches titles, explanations and keywords and jumps to the row (opening its section, tinting the row).
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app.dart';
import 'settings/about_section.dart';
import 'settings/account_section.dart';
import 'settings/diagnostics_section.dart';
import 'settings/display_section.dart';
import 'settings/drives_section.dart';
import 'settings/maps_section.dart';
import 'settings/my_radios_section.dart';
import 'settings/privacy_section.dart';
import 'settings/radio_section.dart';
import 'settings/region_section.dart';
import 'settings/settings_index.dart';
import 'settings/settings_kit.dart';
import 'settings/storage_section.dart';

export 'settings/account_section.dart'
    show DriverKeyScreen, KeyStatusBadge, keyStatusLabel, keyStatusHelp, confirmServerChange;
export 'settings/settings_kit.dart'
    show SliderTile, intervalStops, distanceStops, holdStops, syncEveryStops, nearestStop;

/// Width from which Settings shows sections and content side by side (Material "expanded" window class; the app's
/// design plan uses the same 840 dp for iPad master-detail).
const double settingsTwoPaneWidth = 840;

List<Widget> settingsSectionRows(BuildContext context, String id) => switch (id) {
      'driver' => accountSectionRows(context),
      'region' => regionSectionRows(context),
      'display' => displaySectionRows(context),
      'maps' => mapsSectionRows(context),
      'privacy' => privacySectionRows(context),
      'radio' => radioSectionRows(context),
      'my-radios-section' => myRadiosSectionRows(context),
      'drives' => drivesSectionRows(context),
      'storage' => storageSectionRows(context),
      'diagnostics' => diagnosticsSectionRows(context),
      _ => aboutSectionRows(context),
    };

String? settingsSectionHelp(String id) => switch (id) {
      'driver' => driverHelp,
      'region' => regionHelp,
      'display' => displayHelp,
      'maps' => mapsHelp,
      'privacy' => privacyHelp,
      'radio' => radioHelp,
      'my-radios-section' => myRadiosHelp,
      'drives' => drivesHelp,
      'storage' => storageHelp,
      'diagnostics' => diagnosticsHelp,
      _ => null,
    };

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _phoneScroll = ScrollController();
  final Map<String, GlobalKey> _anchors = {};
  final Set<String> _collapsed = {};
  String _query = '';
  String _selected = settingsSections.first.id;
  String? _highlight;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _phoneScroll.dispose();
    super.dispose();
  }

  void _setQuery(String q) => setState(() => _query = q);

  /// Opens [section], scrolls [anchorId] into view and tints it (unless [tint] is false, for whole sections); screen
  /// readers hear where focus went.
  void _jumpTo(String anchorId, String section, String announcement, {bool tint = true}) {
    setState(() {
      _search.clear();
      _query = '';
      _collapsed.remove(section);
      _selected = section;
      _highlight = tint ? anchorId : null;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _anchors[anchorId]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx, alignment: 0.05, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
      }
      SemanticsService.sendAnnouncement(View.of(context), announcement, Directionality.of(context));
    });
  }

  void _openEntry(SettingsEntry e) =>
      _jumpTo(e.id, e.section, '${e.title}, in ${sectionInfo(e.section).title}');

  /// App bar Search: back to the top and into the field, from anywhere in the list.
  void _focusSearch() {
    if (_phoneScroll.hasClients) {
      _phoneScroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
    }
    _searchFocus.requestFocus();
  }

  /// App bar Sections: every section in one short list; tapping one opens it and scrolls to it.
  Future<void> _showSectionIndex(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
        child: ListView(key: const Key('settings-section-index'), shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Semantics(header: true, child: Text('Jump to a section', style: Theme.of(ctx).textTheme.titleMedium)),
          ),
          for (final info in settingsSections)
            ListTile(
              key: Key('jump-${info.id}'),
              leading: Icon(info.icon),
              title: Text(info.title),
              subtitle: _collapsed.contains(info.id) ? const Text('Folded; opens when you jump to it') : null,
              onTap: () => Navigator.pop(ctx, info.id),
            ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    _jumpTo('section-$picked', picked, '${sectionInfo(picked).title} section', tint: false);
  }

  void _toggle(String id) => setState(() => _collapsed.contains(id) ? _collapsed.remove(id) : _collapsed.add(id));

  Widget _section(BuildContext context, SettingsSectionInfo info, {required bool collapsible}) => SettingsSection(
        id: info.id,
        title: info.title,
        icon: info.icon,
        help: settingsSectionHelp(info.id),
        collapsed: collapsible && _collapsed.contains(info.id),
        onToggle: collapsible ? () => _toggle(info.id) : null,
        children: settingsSectionRows(context, info.id),
      );

  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: TextField(
          key: const Key('settings-search'),
          controller: _search,
          focusNode: _searchFocus,
          onChanged: _setQuery,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: 'Search settings',
            hintText: 'For example: upload, units, privacy',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    key: const Key('settings-search-clear'),
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _search.clear();
                      _setQuery('');
                    },
                  ),
          ),
        ),
      );

  Widget _results(BuildContext context) {
    final t = Theme.of(context);
    final hits = searchSettings(_query, state: AppScope.of(context));
    return Column(key: const Key('settings-search-results'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        child: Semantics(
          liveRegion: true,
          child: Text(
            hits.isEmpty
                ? 'No setting matches "${_query.trim()}". Try another word, such as upload, units or privacy.'
                : '${hits.length} setting${hits.length == 1 ? '' : 's'} match.',
            key: const Key('settings-search-count'),
            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
      for (final e in hits)
        ListTile(
          key: Key('search-result-${e.id}'),
          leading: Icon(sectionInfo(e.section).icon),
          title: Text(e.title),
          subtitle: Text('${e.summary}\n${sectionInfo(e.section).title}'),
          isThreeLine: true,
          onTap: () => _openEntry(e),
        ),
    ]);
  }

  Widget _footer(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Text('Settings are saved on this phone as you change them.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }

  Widget _phone(BuildContext context) => SingleChildScrollView(
        key: const Key('settings-list'),
        controller: _phoneScroll,
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _searchField(),
              if (_query.trim().isNotEmpty)
                _results(context)
              else ...[
                for (final info in settingsSections) _section(context, info, collapsible: true),
                _footer(context),
              ],
            ]),
          ),
        ),
      );

  Widget _wide(BuildContext context) {
    final t = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        width: 320,
        child: ListView(key: const Key('settings-section-pane'), padding: const EdgeInsets.only(bottom: 24), children: [
          _searchField(),
          if (_query.trim().isNotEmpty)
            _results(context)
          else
            for (final info in settingsSections)
              ListTile(
                key: Key('section-nav-${info.id}'),
                leading: Icon(info.icon),
                title: Text(info.title),
                selected: info.id == _selected,
                selectedTileColor: t.colorScheme.primary.withValues(alpha: 0.10),
                onTap: () => setState(() {
                  _selected = info.id;
                  _highlight = null;
                }),
              ),
        ]),
      ),
      const VerticalDivider(width: 1),
      Expanded(
        child: SingleChildScrollView(
          key: const Key('settings-list'),
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _section(context, sectionInfo(_selected), collapsible: false),
                _footer(context),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    AppScope.of(context); // rebuild with the app state
    final wide = MediaQuery.sizeOf(context).width >= settingsTwoPaneWidth;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), actions: [
        IconButton(
          key: const Key('settings-search-action'),
          tooltip: 'Search settings',
          icon: const Icon(Icons.search),
          onPressed: _focusSearch,
        ),
        // Wide screens already list the sections on the left.
        if (!wide)
          IconButton(
            key: const Key('settings-sections-action'),
            tooltip: 'Jump to a section',
            icon: const Icon(Icons.toc),
            onPressed: () => _showSectionIndex(context),
          ),
      ]),
      body: SafeArea(
        child: SettingsAnchors(
          keys: _anchors,
          highlighted: _highlight,
          child: LayoutBuilder(
            builder: (context, box) => box.maxWidth >= settingsTwoPaneWidth ? _wide(context) : _phone(context),
          ),
        ),
      ),
    );
  }
}
