// The searchable index of Settings: every section and every setting row, with the words a person might type to find
// it. Section widgets take their titles from here, so a result always names the row exactly as it is shown.
// Adding a row to Settings = add a [SettingsEntry] here and wrap the row in a SettingsAnchor with the same id
// (test/ui/settings_search_test.dart fails for an entry without a row).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';

class SettingsSectionInfo {
  final String id;
  final String title;
  final IconData icon;
  const SettingsSectionInfo(this.id, this.title, this.icon);
}

/// Display order, top to bottom (phone) / the left pane (wide screens).
const List<SettingsSectionInfo> settingsSections = [
  SettingsSectionInfo('driver', 'Account & driver key', Icons.badge_outlined),
  SettingsSectionInfo('region', 'Region', Icons.public),
  SettingsSectionInfo('display', 'Units & display', Icons.straighten),
  SettingsSectionInfo('maps', 'Map & offline maps', Icons.map_outlined),
  SettingsSectionInfo('privacy', 'Privacy & data sharing', Icons.privacy_tip_outlined),
  SettingsSectionInfo('radio', 'Radio', Icons.settings_input_antenna),
  SettingsSectionInfo('drives', 'Drives & uploads', Icons.cloud_sync_outlined),
  SettingsSectionInfo('storage', 'Data & storage', Icons.storage_outlined),
  SettingsSectionInfo('diagnostics', 'Diagnostics', Icons.bug_report_outlined),
  SettingsSectionInfo('about-section', 'About', Icons.info_outline),
];

SettingsSectionInfo sectionInfo(String id) => settingsSections.firstWhere((s) => s.id == id);

class SettingsEntry {
  /// The anchor id; also the row's widget key where the row had one before (tests and deep links rely on those).
  final String id;
  final String section;
  final String title;

  /// One line: what it does and what changing it means.
  final String summary;
  final List<String> keywords;

  /// Rows that only exist in some states (a server answer, a key on the phone) say so, so search never offers a row
  /// that is not on screen.
  final bool Function(AppState s)? available;

  /// A row that only shows information (a status, a read-only comparison) and has nothing to tap by design. Every other
  /// row is actionable, or says why not and how to make it so (SettingsWhyNot).
  final bool info;
  const SettingsEntry(this.id, this.section, this.title, this.summary,
      {this.keywords = const [], this.available, this.info = false});

  bool isAvailable(AppState s) => available?.call(s) ?? true;
}

bool _hasSiteConfig(AppState s) => s.siteConfig != null;
bool _hasKey(AppState s) => s.hasKey;
bool _hasDirectory(AppState s) => s.services.directory != null;
bool _hasSavedReport(AppState s) => s.savedReport != null;

const List<SettingsEntry> settingsEntries = [
  // Account & driver key
  SettingsEntry('driver-key', 'driver', 'Driver key',
      'Lets this phone upload drives to the coverage map. Without one, drives stay on this phone.',
      keywords: ['key', 'account', 'request', 'approve', 'paste', 'callsign', 'email', 'remove key', 'login', 'sign in']),
  SettingsEntry('server-url', 'driver', 'Server URL',
      'Where drives upload. Keys belong to the server that issued them, so moving to another server removes yours.',
      keywords: ['server', 'url', 'address', 'host', 'website']),
  // Region
  SettingsEntry('region-pick', 'region', 'Region',
      'Which region the app shows. It follows your location unless you pick one. Never changes your radio.',
      keywords: ['area', 'city', 'columbus', 'dayton', 'switch', 'location']),
  SettingsEntry('site-region', 'region', 'Connected to', 'The region your server answers for.',
      keywords: ['site', 'host', 'server region'], available: _hasSiteConfig, info: true),
  SettingsEntry('site-radio-preset', 'region', 'Radio preset',
      'The region\'s suggested radio settings next to your radio\'s. Information only; nothing is written to the radio.',
      keywords: ['frequency', 'bandwidth', 'spreading factor', 'sf', 'cr', 'mhz', 'preset', 'lora'],
      available: _hasSiteConfig,
      info: true),
  // Units & display
  SettingsEntry('units-tile', 'display', 'Units',
      'Distances, speeds, heights, temperature and pressure everywhere in the app. Stored data is unchanged.',
      keywords: ['metric', 'imperial', 'miles', 'feet', 'kilometres', 'km', 'mph', 'auto', 'locale']),
  SettingsEntry('unit-distance', 'display', 'Distance',
      'Drive distance, GPS accuracy, range rings and minimum distance: km and m, or miles and feet.',
      keywords: ['distance', 'miles', 'km', 'kilometres', 'feet', 'metres', 'mi', 'ft', 'units']),
  SettingsEntry('unit-speed', 'display', 'Speed', 'Driving speed in reports and ping details: km/h or mph.',
      keywords: ['speed', 'mph', 'km/h', 'kph', 'units']),
  SettingsEntry('unit-height', 'display', 'Height and altitude', 'Antenna height and altitude: metres or feet.',
      keywords: ['height', 'altitude', 'elevation', 'antenna', 'feet', 'metres', 'units']),
  SettingsEntry('unit-temperature', 'display', 'Temperature', 'Temperature readings: °C or °F.',
      keywords: ['temperature', 'celsius', 'fahrenheit', 'c', 'f', 'degrees', 'units']),
  SettingsEntry('unit-pressure', 'display', 'Air pressure', 'Barometer readings: hPa, inHg or mmHg.',
      keywords: ['pressure', 'barometer', 'hpa', 'inhg', 'mmhg', 'millibar', 'mbar', 'units']),
  SettingsEntry('heard-hold', 'display', 'Heard list hold',
      'How long a repeater stays bright in the heard list after it was last heard.',
      keywords: ['heard', 'repeaters', 'list', 'grey', 'stale', 'pings']),
  // Map & offline maps
  SettingsEntry('offline-maps', 'maps', 'Offline maps',
      'Download a region\'s map so it works with no signal. Uses storage; delete a map any time.',
      keywords: ['offline', 'download', 'pmtiles', 'tiles', 'basemap', 'no signal', 'map pack']),
  // Privacy & data sharing
  SettingsEntry('telemetry-toggle', 'privacy', 'Share packet headers',
      'Sends the headers of packets your radio overhears to build the live feed. Never message text.',
      keywords: ['telemetry', 'sharing', 'data collection', 'opt out', 'live feed', 'packets', 'privacy']),
  // Drive-context categories (stream 7; titles = lib/core/data_categories.dart).
  SettingsEntry('collect-motion-toggle', 'privacy', 'Motion and altitude',
      'GPS height, direction of travel and accuracy, saved with your drive (uploaded with it when the server accepts it).',
      keywords: ['altitude', 'height', 'heading', 'course', 'gps accuracy', 'data collection', 'opt out']),
  SettingsEntry('collect-barometer-toggle', 'privacy', 'Air pressure',
      'Phone barometer during a drive, saved with your drive (uploaded with it when the server accepts it).',
      keywords: ['barometer', 'pressure', 'hpa', 'inhg', 'motion & fitness', 'sensor', 'data collection', 'opt out']),
  SettingsEntry('collect-phone_battery-toggle', 'privacy', 'Phone battery',
      'Battery level and charging during a drive, saved with your drive (uploaded with it when the server accepts it).',
      keywords: ['battery', 'charging', 'low power', 'data collection', 'opt out']),
  SettingsEntry('collect-device-toggle', 'privacy', 'Phone and app details',
      'System version, phone model code and app build, saved with your drive (uploaded with it when the server accepts it).',
      keywords: ['device', 'model', 'ios version', 'android version', 'build', 'data collection', 'opt out']),
  SettingsEntry('collect-radio_health-toggle', 'privacy', 'Radio health',
      'Radio battery, uptime, error flags, packet counters and airtime during a drive, saved with your drive (uploaded with it when the server accepts it).',
      keywords: ['radio battery', 'uptime', 'airtime', 'counters', 'stats', 'errors', 'data collection', 'opt out']),
  SettingsEntry('collect-radio_config-toggle', 'privacy', 'Radio settings',
      'Board, firmware and power limits of your radio, saved with your drive (uploaded with it when the server accepts it).',
      keywords: ['firmware', 'board', 'max power', 'radio settings', 'data collection', 'opt out']),
  SettingsEntry('collect-weather-toggle', 'privacy', 'Weather for my drives',
      'The server looks up weather near your uploaded drives, on a coarse grid, when it supports it. Data: Open-Meteo.com.',
      keywords: ['weather', 'temperature', 'open-meteo', 'data collection', 'opt out']),
  SettingsEntry('telemetry-erase-now', 'privacy', 'Erase shared packet headers',
      'Asks the server to delete every packet header this phone sent.',
      keywords: ['delete', 'erase', 'remove', 'telemetry', 'gdpr'], available: _hasKey),
  SettingsEntry('delete-my-data', 'privacy', 'Delete my collected data',
      'Deletes the drive context and packet headers the server holds for you, and, separately, the context saved on this phone. Your drives stay.',
      keywords: ['delete', 'erase', 'remove', 'gdpr', 'my data', 'privacy', 'forget', 'context', 'weather', 'sensors']),
  SettingsEntry('privacy-what-shared', 'privacy', 'What MeshSonar shares',
      'Everything that leaves this phone, where it goes, and what never does.',
      keywords: ['data', 'collected', 'disclosure', 'shared', 'privacy policy']),
  SettingsEntry('privacy-location', 'privacy', 'Location while driving',
      'Why the app asks for "Always" location and what it is never used for.',
      keywords: ['gps', 'always', 'background', 'location', 'permission', 'tracking']),
  SettingsEntry('privacy-zones-website', 'privacy', 'Manage privacy zones on the website',
      'Hide pings near places like home, on the website. Applies to drives on the server.',
      keywords: ['home', 'hide', 'zone', 'website']),
  // Radio
  SettingsEntry('radio-tab', 'radio', 'Radio details',
      'What the connected radio reports, compared with the region\'s preset. Read-only.',
      keywords: ['radio', 'firmware', 'battery', 'companion', 'preset', 'connect']),
  SettingsEntry('channel', 'radio', 'Channel', 'The channel pings are sent on.',
      keywords: ['channel', 'wardriving', 'hashtag', '#']),
  SettingsEntry('discovery-mode', 'radio', 'Discovery (listen-only)',
      'The next drive transmits nothing and only records what it overhears.',
      keywords: ['listen', 'passive', 'silent', 'no transmit', 'receive only']),
  SettingsEntry('interval', 'radio', 'Auto-ping',
      'How often an automatic ping may go out while driving.',
      keywords: ['interval', 'seconds', 'cadence', 'frequency', 'how often', 'timer']),
  SettingsEntry('min-distance', 'radio', 'Minimum distance',
      'How far you must move before the next automatic ping.',
      keywords: ['distance', 'metres', 'feet', 'moved', 'stopped', 'lights']),
  SettingsEntry('antenna', 'radio', 'Antenna',
      'Each radio\'s antenna setup, saved with every drive so coverage compares like with like.',
      keywords: ['antenna', 'gain', 'dbi', 'height', 'mount', 'mast', 'mag-mount']),
  // Drives & uploads
  SettingsEntry('auto-sync', 'drives', 'Upload at end of drive', 'Sends the drive when you press Stop.',
      keywords: ['upload', 'sync', 'automatic', 'auto sync', 'stop']),
  SettingsEntry('sync-during-drive', 'drives', 'Upload during the drive',
      'Sends new pings while you drive, so nothing waits for Stop.',
      keywords: ['upload', 'sync', 'live', 'during', 'while driving']),
  SettingsEntry('sync-every', 'drives', 'Upload interval', 'How often pings upload during a drive.',
      keywords: ['upload', 'period', 'minutes', 'every', 'sync']),
  SettingsEntry('last-upload', 'drives', 'Last upload', 'When the last upload happened, or why it failed.',
      keywords: ['upload', 'status', 'error', 'failed', 'sync'], info: true),
  // Data & storage
  SettingsEntry('storage-drives', 'storage', 'Drives on this phone',
      'Space drives use. Remove uploaded drives; drives not fully uploaded always stay.',
      keywords: ['space', 'storage', 'delete', 'remove', 'free up', 'drives', 'disk']),
  SettingsEntry('storage-region', 'storage', 'Saved region data',
      'Coverage and region pages kept for use with no signal. Downloads again after clearing.',
      keywords: ['cache', 'region', 'coverage', 'clear', 'space', 'offline']),
  SettingsEntry('refresh-repeaters', 'storage', 'Repeater names',
      'Names of repeaters kept for use with no signal. Refresh downloads them again.',
      keywords: ['repeaters', 'names', 'refresh', 'update', 'cache', 'clear']),
  SettingsEntry('storage-node-map', 'storage', 'Public node map',
      'Repeater names and positions from map.meshcore.io near where you drive.',
      keywords: ['meshcore map', 'directory', 'nodes', 'cache', 'clear', 'space'], available: _hasDirectory),
  SettingsEntry('storage-offline-maps', 'storage', 'Offline maps space',
      'Space used by downloaded map packs. Delete them on the Offline maps screen.',
      keywords: ['offline', 'maps', 'packs', 'space', 'delete']),
  SettingsEntry('storage-report-draft', 'storage', 'Unsent problem report',
      'A problem report that was not sent yet, kept so nothing you wrote is lost.',
      keywords: ['report', 'draft', 'discard'], available: _hasSavedReport),
  // Diagnostics
  SettingsEntry('diagnostics-log', 'diagnostics', 'Diagnostic log',
      'Recent app events to help explain a problem. Secrets hidden, positions rounded when copied.',
      keywords: ['log', 'debug', 'copy', 'events', 'support', 'troubleshoot']),
  SettingsEntry('report-problem', 'diagnostics', 'Report a problem',
      'Send a report to the server admin. You see exactly what is sent first.',
      keywords: ['bug', 'feedback', 'support', 'issue', 'help', 'contact']),
  // About
  SettingsEntry('about', 'about-section', 'About MeshSonar', 'Version, licence and third-party notices.',
      keywords: ['version', 'licence', 'license', 'mit', 'credits', 'open source', 'open-meteo', 'attribution']),
  SettingsEntry('show-intro', 'about-section', 'Show the welcome tour', 'The three intro pages from first launch.',
      keywords: ['intro', 'onboarding', 'tour', 'welcome', 'help']),
];

SettingsEntry settingsEntry(String id) => settingsEntries.firstWhere((e) => e.id == id);

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9#]+'), ' ').trim();

/// The rows matching [query] (every word must appear in the title, the explanation, the keywords or the section
/// name), best first: title matches, then keyword matches, then the rest, each in display order. Rows not on screen in
/// [state] are left out. An empty query matches nothing.
List<SettingsEntry> searchSettings(String query, {AppState? state, List<SettingsEntry> entries = settingsEntries}) {
  final words = _norm(query).split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  final scored = <(int, int, SettingsEntry)>[];
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (state != null && !e.isAvailable(state)) continue;
    final title = _norm(e.title);
    final keys = _norm(e.keywords.join(' '));
    final hay = '$title ${_norm(e.summary)} $keys ${_norm(sectionInfo(e.section).title)}';
    if (!words.every(hay.contains)) continue;
    final rank = words.every(title.contains) ? 0 : (words.every(keys.contains) ? 1 : 2);
    scored.add((rank, i, e));
  }
  scored.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final s in scored) s.$3];
}
