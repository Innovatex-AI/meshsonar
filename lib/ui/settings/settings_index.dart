// The searchable index of Settings: every section and every setting row, with the words a person might type to find
// it. Section widgets take their titles from here, so a result always names the row exactly as it is shown.
// Adding a row to Settings = add a [SettingsEntry] here and wrap the row in a SettingsAnchor with the same id
// (test/ui/settings_search_test.dart fails for an entry without a row). The Privacy and Observer sections keep their
// entries in their own files (privacySettingsEntries, observerSettingsEntries), spread in here in display order, so the
// work on those sections never edits this file.
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import 'battery_section.dart' show batterySettingsEntries;
import 'meshtrack_section.dart' show meshTrackAvailable, meshTrackSettingsEntries;
import 'observer_section.dart' show observerSettingsEntries;
import 'privacy_profile_rows.dart' show profileRowsAvailable;
import 'privacy_section.dart' show privacySettingsEntries;

class SettingsSectionInfo {
  final String id;
  final String title;
  final IconData icon;

  /// A section that only exists in some builds says so; null = always shown.
  final bool Function(AppState s)? available;
  const SettingsSectionInfo(this.id, this.title, this.icon, {this.available});

  bool isAvailable(AppState s) => available?.call(s) ?? true;
}

/// Display order, top to bottom (phone) / the left pane (wide screens). Build 76: eight sections, in the order a person
/// meets them (who am I, my radio, driving, how it looks, what leaves the phone, alerts, housekeeping, about). The ids
/// are the pre-76 ids of the sections that kept their place; the sections that were merged away are [settingsSectionAliases].
const List<SettingsSectionInfo> settingsSections = [
  SettingsSectionInfo('driver', 'Account', Icons.badge_outlined),
  SettingsSectionInfo('radio', 'Radio', Icons.settings_input_antenna),
  SettingsSectionInfo('wardriving', 'Driving', Icons.directions_car_outlined),
  SettingsSectionInfo('display', 'Map & display', Icons.map_outlined),
  SettingsSectionInfo('privacy', 'Sharing & privacy', Icons.privacy_tip_outlined),
  SettingsSectionInfo('notifications', 'Notifications', Icons.notifications_outlined),
  SettingsSectionInfo('storage', 'Storage & diagnostics', Icons.storage_outlined),
  SettingsSectionInfo('about-section', 'About', Icons.info_outline),
];

/// A page one level down from a section: the rare and expert rows of that section. Its row on the first level has the
/// anchor id `page-<id>`.
class SettingsPageInfo {
  final String id;
  final String section;
  final String title;
  final IconData icon;

  /// One short line under the title when the row has nothing live to say.
  final String summary;
  final bool Function(AppState s)? available;
  const SettingsPageInfo(this.id, this.section, this.title, this.icon, this.summary, {this.available});

  bool isAvailable(AppState s) => available?.call(s) ?? true;
}

const List<SettingsPageInfo> settingsPages = [
  SettingsPageInfo('profile', 'driver', 'How you appear', Icons.person_outline, 'Callsign, display name, anonymous, leaderboard.',
      available: profileRowsAvailable),
  SettingsPageInfo('claims', 'driver', 'Claimed radios', Icons.verified_user_outlined, 'The radios you manage, and claiming one.'),
  SettingsPageInfo('account-advanced', 'driver', 'Server (advanced)', Icons.dns_outlined, 'Server URL and what this server says about your region.'),
  SettingsPageInfo('uploads', 'wardriving', 'Uploads', Icons.cloud_upload_outlined, 'When drives go to the server.'),
  SettingsPageInfo('battery', 'wardriving', 'Battery details', Icons.tune, 'What is running now, and each power setting.'),
  SettingsPageInfo('driving-advanced', 'wardriving', 'Advanced', Icons.science_outlined, 'Listen window, what goes on the air, airtime, this drive.'),
  SettingsPageInfo('units', 'display', 'Units per quantity', Icons.straighten, 'A different unit for distance, speed, height, temperature or pressure.'),
  SettingsPageInfo('observer', 'privacy', 'Observer and MQTT feeds', Icons.sensors, 'Status, observer location, feeds to other sites.'),
  SettingsPageInfo('sharing', 'privacy', 'What is shared', Icons.fact_check_outlined, 'A switch for each kind of drive data, and the full list.'),
  SettingsPageInfo('meshtrack', 'privacy', 'MeshTrack', Icons.people_alt_outlined, 'Friends on the map: groups, position, rate.',
      available: meshTrackAvailable),
  SettingsPageInfo('storage-items', 'storage', 'Storage on this phone', Icons.storage_outlined, 'Drives, saved region data, repeater names.'),
  SettingsPageInfo('diagnostics-advanced', 'storage', 'Advanced', Icons.science_outlined, 'Bluetooth test, map health overlay, power counters.'),
];

SettingsPageInfo settingsPage(String id) => settingsPages.firstWhere((p) => p.id == id);

/// Sections that existed before build 76 and were merged into another one. A link that still names one (More > Observer,
/// More > Claimed radios, a test, an old deep link) lands where its rows went: the section, and the page when they are
/// one level down. (old id) -> (section, page, the old title for search).
const Map<String, (String, String?, String)> settingsSectionAliases = {
  'region': ('display', null, 'Region'),
  'maps': ('display', null, 'Map'),
  'my-radios-section': ('driver', 'claims', 'Claimed radios'),
  'meshtrack': ('privacy', 'meshtrack', 'MeshTrack'),
  'battery': ('wardriving', 'battery', 'Battery'),
  'drives': ('wardriving', 'uploads', 'Drives & uploads'),
  'observer': ('privacy', 'observer', 'Observer'),
  'diagnostics': ('storage', null, 'Diagnostics'),
};

/// Rows that were merged into another row keep their id as a second anchor on it.
const Map<String, String> settingsEntryAliases = {
  'observer-share': 'telemetry-toggle', // "Share with MeshSonar" was under Privacy and under Observer: one switch now
  'privacy-zones-website': 'privacy-zones', // the website link is on the Privacy zones page
};

/// Where a link into Settings lands.
class SettingsTarget {
  final String section;
  final String? page;

  /// The row to scroll to and tint; null for a whole section or page.
  final String? anchor;
  const SettingsTarget(this.section, {this.page, this.anchor});
}

/// Resolves a section id (current or pre-76), a page id or a row id; null when nothing has that id.
SettingsTarget? resolveSettingsTarget(String id) {
  if (settingsSections.any((s) => s.id == id)) return SettingsTarget(id);
  final old = settingsSectionAliases[id];
  if (old != null) return SettingsTarget(old.$1, page: old.$2);
  for (final p in settingsPages) {
    if (p.id == id) return SettingsTarget(p.section, page: p.id);
  }
  final rowId = settingsEntryAliases[id] ?? id;
  for (final e in settingsEntries) {
    if (e.id == rowId) return SettingsTarget(e.section, page: e.page, anchor: id);
  }
  return null;
}

/// The section with this id; a pre-76 id gives the section its rows moved to.
SettingsSectionInfo sectionInfo(String id) {
  final real = settingsSectionAliases[id]?.$1 ?? id;
  return settingsSections.firstWhere((s) => s.id == real);
}

/// The sections this build shows, in display order.
List<SettingsSectionInfo> visibleSettingsSections(AppState s) => [for (final x in settingsSections) if (x.isAvailable(s)) x];

class SettingsEntry {
  /// The anchor id; also the row's widget key where the row had one before (tests and deep links rely on those).
  final String id;
  final String section;

  /// The page of [section] the row is on (settingsPages); null = on the first level.
  final String? page;
  final String title;

  /// One line: what it does and what changing it means.
  final String summary;
  final List<String> keywords;

  /// The title of the section this row was in before build 76, so a search for the old name still finds it.
  final String? was;

  /// Rows that only exist in some states (a server answer, a key on the phone) say so, so search never offers a row
  /// that is not on screen.
  final bool Function(AppState s)? available;

  /// A row that only shows information (a status, a read-only comparison) and has nothing to tap by design. Every other
  /// row is actionable, or says why not and how to make it so (SettingsWhyNot).
  final bool info;
  const SettingsEntry(this.id, this.section, this.title, this.summary,
      {this.page, this.was, this.keywords = const [], this.available, this.info = false});

  bool isAvailable(AppState s) => (available?.call(s) ?? true) && (page == null || settingsPage(page!).isAvailable(s));

  /// "Driving > Battery details": where the row is, for a search result.
  String get where => page == null ? sectionInfo(section).title : '${sectionInfo(section).title} > ${settingsPage(page!).title}';
}

bool _isAndroid(AppState s) => defaultTargetPlatform == TargetPlatform.android;
bool _hasSiteConfig(AppState s) => s.siteConfig != null;
bool _hasDirectory(AppState s) => s.services.directory != null;
bool _hasSavedReport(AppState s) => s.savedReport != null;

const List<SettingsEntry> settingsEntries = [
  // Account & driver key
  SettingsEntry('driver-key', 'driver', 'Driver key',
      'Lets this phone upload drives to the coverage map. Without one, drives stay on this phone.',
      was: 'Account & driver key', keywords: ['key', 'account', 'create', 'paste', 'callsign', 'email', 'remove key', 'login', 'sign in']),
  SettingsEntry('server-url', 'driver', 'Server URL',
      'Where drives upload. Keys belong to the server that issued them, so moving to another server removes yours.',
      page: 'account-advanced', was: 'Account & driver key', keywords: ['server', 'url', 'address', 'host', 'website']),
  // Region
  SettingsEntry('region-pick', 'display', 'Region',
      'Which region the app shows. It follows your location unless you pick one. Never changes your radio.',
      was: 'Region', keywords: ['area', 'city', 'columbus', 'dayton', 'switch', 'location']),
  SettingsEntry('site-region', 'driver', 'Connected to', 'The region your server answers for.',
      page: 'account-advanced', was: 'Region', keywords: ['site', 'host', 'server region'], available: _hasSiteConfig, info: true),
  SettingsEntry('site-radio-preset', 'driver', 'Radio preset',
      'The region\'s suggested radio settings next to your radio\'s. Information only; nothing is written to the radio.',
      page: 'account-advanced', was: 'Region', keywords: ['frequency', 'bandwidth', 'spreading factor', 'sf', 'cr', 'mhz', 'preset', 'lora'],
      available: _hasSiteConfig,
      info: true),
  // Units & display
  SettingsEntry('units-tile', 'display', 'Units',
      'Distances, speeds, heights, temperature and pressure everywhere in the app. Stored data is unchanged.',
      was: 'Units & display', keywords: ['metric', 'imperial', 'miles', 'feet', 'kilometres', 'km', 'mph', 'auto', 'locale']),
  SettingsEntry('unit-distance', 'display', 'Distance',
      'Drive distance, GPS accuracy and minimum distance: km and m, or miles and feet.',
      page: 'units', was: 'Units & display', keywords: ['distance', 'miles', 'km', 'kilometres', 'feet', 'metres', 'mi', 'ft', 'units']),
  SettingsEntry('unit-speed', 'display', 'Speed', 'Driving speed in reports and ping details: km/h or mph.',
      page: 'units', was: 'Units & display', keywords: ['speed', 'mph', 'km/h', 'kph', 'units']),
  SettingsEntry('unit-height', 'display', 'Height and altitude', 'Antenna height and altitude: metres or feet.',
      page: 'units', was: 'Units & display', keywords: ['height', 'altitude', 'elevation', 'antenna', 'feet', 'metres', 'units']),
  SettingsEntry('unit-temperature', 'display', 'Temperature', 'Temperature readings: °C or °F.',
      page: 'units', was: 'Units & display', keywords: ['temperature', 'celsius', 'fahrenheit', 'c', 'f', 'degrees', 'units']),
  SettingsEntry('unit-pressure', 'display', 'Air pressure', 'Barometer readings: hPa, inHg or mmHg.',
      page: 'units', was: 'Units & display', keywords: ['pressure', 'barometer', 'hpa', 'inhg', 'mmhg', 'millibar', 'mbar', 'units']),
  SettingsEntry('colour-palette', 'display', 'Colour palette',
      'The colours for signal strength on every map and chart: Standard or Colour-blind safe.',
      was: 'Units & display', keywords: ['colour', 'color', 'colorblind', 'color blind', 'colour blind', 'deuteranopia', 'protanopia', 'tritanopia', 'contrast', 'accessibility', 'palette', 'theme', 'red green']),
  SettingsEntry('ui-haptics', 'display', 'Haptics',
      'Small taps when you toggle a switch, pick from a list, send a message or something succeeds or fails.',
      was: 'Units & display', keywords: ['haptic', 'haptics', 'vibration', 'vibrate', 'taps', 'feedback', 'buzz']),
  SettingsEntry('heard-hold', 'display', 'Heard list hold',
      'How long a repeater stays bright in the heard list after it was last heard.',
      was: 'Units & display', keywords: ['heard', 'repeaters', 'list', 'grey', 'stale', 'pings']),
  // Map
  SettingsEntry('map-follow-options', 'display', 'Follow and direction',
      'Heading-up or north-up map, re-centre by itself after you move the map, and zoom out a little at highway speed.',
      was: 'Map', keywords: ['follow', 'heading', 'north up', 'rotate', 'recenter', 're-center', 'zoom', 'speed', 'compass', 'direction']),
  // Privacy & data sharing: the entries live next to their rows (lib/ui/settings/privacy_section.dart).
  ...privacySettingsEntries,
  // Observer: the entries live next to their rows (lib/ui/settings/observer_section.dart).
  ...observerSettingsEntries,
  // Radio
  SettingsEntry('radio-tab', 'radio', 'Radio details',
      'What the connected radio reports, compared with the region\'s preset. Read-only.',
      was: 'Radio', keywords: ['radio', 'firmware', 'battery', 'companion', 'preset', 'connect']),
  SettingsEntry('auto-connect', 'radio', 'Auto-connect',
      'When MeshSonar connects to your auto-connect radio by itself: always, only at launch, or never.',
      was: 'Radio', keywords: ['auto connect', 'autoconnect', 'reconnect', 'automatic', 'launch', 'startup', 'bluetooth', 'connect', 'off']),
  SettingsEntry('saved-radios', 'radio', 'Saved radios',
      'Every radio you have connected to: tap to connect, give it a nickname, star the auto-connect radio, or forget it.',
      was: 'Radio', keywords: ['saved', 'radios', 'devices', 'nickname', 'forget', 'star', 'favourite', 'favorite', 'bluetooth', 'paired', 'remembered', 'connect']),
  // Wardriving
  SettingsEntry('channel', 'wardriving', 'Wardrive channel',
      'The channel pings are sent on (default #wardriving). The key comes from the name in lower case.',
      was: 'Wardriving', keywords: ['channel', 'wardriving', 'hashtag', '#', 'publish', 'message', 'ping channel']),
  SettingsEntry('send-pings', 'wardriving', 'Send pings to the mesh',
      'On: each ping is sent so repeaters and observers can hear it. Off: listen-only, nothing is transmitted.',
      was: 'Wardriving', keywords: ['listen', 'passive', 'silent', 'no transmit', 'receive only', 'discovery', 'publish', 'message', 'observer', 'transmit']),
  SettingsEntry('ping-message', 'wardriving', 'What goes on the air',
      'The ping text: MS: and ten random characters. No position, nothing about you.',
      page: 'driving-advanced', was: 'Wardriving', keywords: ['message', 'text', 'format', 'privacy', 'MS:', 'tag', 'scope', 'flood'], info: true),
  SettingsEntry('ping-airtime', 'wardriving', 'Airtime per ping',
      'How long one ping occupies the air at your radio\'s settings, and the share of time at your interval.',
      page: 'driving-advanced', was: 'Wardriving', keywords: ['airtime', 'duty cycle', 'time on air', 'budget', 'sf', 'bandwidth'], info: true),
  SettingsEntry('interval', 'wardriving', 'Auto-ping',
      'How often an automatic ping may go out while driving.',
      was: 'Wardriving', keywords: ['interval', 'seconds', 'cadence', 'frequency', 'how often', 'timer', 'ping interval', 'ping rate']),
  SettingsEntry('min-distance', 'wardriving', 'Minimum distance',
      'How far you must move before the next automatic ping.',
      was: 'Wardriving', keywords: ['distance', 'metres', 'feet', 'moved', 'stopped', 'lights', 'ping distance', 'min distance', 'how far apart']),
  SettingsEntry('listen-window', 'wardriving', 'Listen window',
      'How long each ping waits for repeaters to answer, and the shortest gap between pings.',
      page: 'driving-advanced', was: 'Wardriving', keywords: ['listen', 'window', 'echo', 'wait', 'seconds', 'timeout', 'hear', 'ping duration']),
  SettingsEntry('ping-feedback', 'wardriving', 'Ping feedback',
      'A haptic tap and an optional sound when a ping finishes: one way for heard, another for heard nothing. Sound is off by default.',
      was: 'Wardriving', keywords: ['sound', 'haptic', 'vibrate', 'vibration', 'beep', 'tone', 'audio', 'tap', 'heard', 'feedback', 'click']),
  SettingsEntry('wardrive-counters', 'wardriving', 'This drive',
      'Pings sent, repeaters that heard them and observers that confirmed them, for the drive in progress.',
      page: 'driving-advanced', was: 'Wardriving', keywords: ['counter', 'observer', 'confirmed', 'heard', 'repeaters', 'hop', 'intake', 'pings sent'], info: true),
  SettingsEntry('antenna', 'radio', 'Antenna',
      'Each radio\'s antenna setup, saved with every drive so coverage compares like with like.',
      was: 'Radio', keywords: ['antenna', 'gain', 'dbi', 'height', 'mount', 'mast', 'mag-mount']),
  // Claimed radios (server ownership claims; code ids keep the old "my-radios" name)
  SettingsEntry('my-radios', 'driver', 'Claimed radios',
      'The radios you manage: change a name, hide a position, give one up. Managing never changes whether a radio\'s data counts.',
      page: 'claims', was: 'Claimed radios', keywords: ['claim', 'own', 'owner', 'repeater', 'observer', 'manage', 'radios', 'release', 'position', 'hide']),
  SettingsEntry('claim-my-radio', 'driver', 'Claim my radio',
      'Prove the connected radio is yours: it signs a message from the server with its own key. No password, nothing over the air.',
      page: 'claims', was: 'Claimed radios', keywords: ['claim', 'own', 'verify', 'sign', 'companion', 'prove', 'key']),
  SettingsEntry('claim-repeater', 'driver', 'Claim a repeater',
      'Prove a repeater is yours with its admin password, through your radio. The password never leaves your phone.',
      page: 'claims', was: 'Claimed radios', keywords: ['claim', 'own', 'repeater', 'admin password', 'login', 'verify', 'observer', 'name', 'code']),
  // Drives & uploads
  SettingsEntry('auto-sync', 'wardriving', 'Upload at end of drive', 'Sends the drive when you press Stop.',
      page: 'uploads', was: 'Drives & uploads', keywords: ['upload', 'sync', 'automatic', 'auto sync', 'stop']),
  SettingsEntry('sync-during-drive', 'wardriving', 'Upload during the drive',
      'Sends new pings while you drive, so nothing waits for Stop.',
      page: 'uploads', was: 'Drives & uploads', keywords: ['upload', 'sync', 'live', 'during', 'while driving']),
  SettingsEntry('sync-every', 'wardriving', 'Upload interval', 'How often pings upload during a drive.',
      page: 'uploads', was: 'Drives & uploads', keywords: ['upload', 'period', 'minutes', 'every', 'sync']),
  SettingsEntry('last-upload', 'wardriving', 'Last upload', 'When the last upload happened, or why it failed.',
      page: 'uploads', was: 'Drives & uploads', keywords: ['upload', 'status', 'error', 'failed', 'sync'], info: true),
  // Data & storage
  SettingsEntry('storage-drives', 'storage', 'Drives on this phone',
      'Space drives use. Remove uploaded drives; drives not fully uploaded always stay.',
      page: 'storage-items', was: 'Data & storage', keywords: ['space', 'storage', 'delete', 'remove', 'free up', 'drives', 'disk']),
  SettingsEntry('storage-region', 'storage', 'Saved region data',
      'Coverage and region pages kept for use with no signal. Downloads again after clearing.',
      page: 'storage-items', was: 'Data & storage', keywords: ['cache', 'region', 'coverage', 'clear', 'space', 'offline']),
  SettingsEntry('refresh-repeaters', 'storage', 'Repeater names',
      'Names of repeaters kept for use with no signal. Refresh downloads them again.',
      page: 'storage-items', was: 'Data & storage', keywords: ['repeaters', 'names', 'refresh', 'update', 'cache', 'clear']),
  SettingsEntry('storage-node-map', 'storage', 'Public node map',
      'Repeater names and positions from map.meshcore.io near where you drive.',
      page: 'storage-items', was: 'Data & storage', keywords: ['meshcore map', 'directory', 'nodes', 'cache', 'clear', 'space'], available: _hasDirectory),
  SettingsEntry('storage-report-draft', 'storage', 'Unsent problem report',
      'A problem report that was not sent yet, kept so nothing you wrote is lost.',
      page: 'storage-items', was: 'Data & storage', keywords: ['report', 'draft', 'discard'], available: _hasSavedReport),
  // Notifications
  SettingsEntry('notif-enabled', 'notifications', 'Message alerts',
      'The master switch for notifications and in-app banners. Messages are still saved when it is off.',
      was: 'Notifications', keywords: ['notifications', 'alerts', 'push', 'badge', 'turn off']),
  SettingsEntry('notif-sound', 'notifications', 'Sound', 'Play the system sound with an alert.',
      was: 'Notifications', keywords: ['notification sound', 'silent', 'beep', 'ding']),
  SettingsEntry('notif-vibrate', 'notifications', 'Vibrate', 'Vibrate with an alert (Android).',
      was: 'Notifications', keywords: ['haptic', 'vibration', 'buzz'], available: _isAndroid),
  SettingsEntry('notif-previews', 'notifications', 'Show message text in alerts',
      'Off by default: alerts say "New message" so a locked screen does not show your chats.',
      was: 'Notifications', keywords: ['preview', 'lock screen', 'privacy', 'hide text', 'content']),
  SettingsEntry('notif-quiet', 'notifications', 'Quiet hours',
      'Between the hours you pick, alerts arrive without sound.',
      was: 'Notifications', keywords: ['night', 'sleep', 'do not disturb', 'dnd', 'silent', 'schedule', 'focus']),
  SettingsEntry('notif-conversations', 'notifications', 'Alerts per conversation',
      'Mute a conversation for a while or for good, or hear only when you are mentioned.',
      was: 'Notifications', keywords: ['mute', 'mentions', 'channel', 'contact', 'unmute']),
  SettingsEntry('notif-test', 'notifications', 'Send a test notification',
      'Shows one alert in 3 seconds so you can check sound and what the lock screen shows.',
      was: 'Notifications', keywords: ['test', 'try', 'check']),
  // MeshTrack: the entries live next to their rows (lib/ui/settings/meshtrack_section.dart).
  ...meshTrackSettingsEntries,
  // Battery: the entries live next to their rows (lib/ui/settings/battery_section.dart).
  ...batterySettingsEntries,
  // Diagnostics
  SettingsEntry('diagnostics-log', 'storage', 'Diagnostic log',
      'Recent app events to help explain a problem. Secrets hidden, positions rounded when copied.',
      was: 'Diagnostics', keywords: ['log', 'debug', 'copy', 'events', 'support', 'troubleshoot']),
  SettingsEntry('diagnostics-ble', 'storage', 'Background Bluetooth test',
      'A log of the radio link while the app is in the background, closed or restarted, for testing alerts.',
      page: 'diagnostics-advanced', was: 'Diagnostics', keywords: ['bluetooth', 'background', 'alerts', 'notifications', 'test', 'restore', 'suspend', 'log']),
  SettingsEntry('map-health-overlay', 'storage', 'Map and GPS health overlay',
      'Shows frame times, GPS update rate, camera mode and map source over the map. Samples are saved with each drive either way.',
      page: 'diagnostics-advanced', was: 'Diagnostics', keywords: ['map', 'gps', 'fps', 'frame', 'jank', 'smooth', 'performance', 'overlay', 'health', 'debug']),
  SettingsEntry('diagnostics-power-counters', 'storage', 'Power counters',
      'What used power since the app started: GPS, screen, compass and map minutes, radio commands and uploads per hour.',
      page: 'diagnostics-advanced', was: 'Diagnostics', keywords: ['battery', 'power', 'counters', 'energy', 'drain', 'gps', 'screen on', 'compass', 'ble', 'per hour'],
      info: true),
  SettingsEntry('report-problem', 'storage', 'Report a problem',
      'Send a report to your server\'s operators. You see exactly what is sent first.',
      was: 'Diagnostics', keywords: ['bug', 'feedback', 'support', 'issue', 'help', 'contact']),
  // About
  SettingsEntry('about', 'about-section', 'About MeshSonar', 'Version, licence and credits.',
      was: 'About', keywords: ['version', 'licence', 'license', 'mit', 'credits', 'open source', 'open-meteo', 'attribution']),
  SettingsEntry('map-legend', 'about-section', 'Map legend',
      'What every colour and symbol on the maps means, with real swatches in your colour palette.',
      was: 'About', keywords: ['legend', 'colours', 'colors', 'key', 'hexagon', 'snr', 'grey', 'no reply', 'link lines', 'help', 'info']),
  SettingsEntry('terms-of-service-link', 'about-section', 'Terms of service', 'Use of MeshSonar, photos and chat, reports. On the website.',
      was: 'Privacy & data sharing', keywords: ['terms', 'tos', 'legal', 'rules', 'conditions']),
  SettingsEntry('show-intro', 'about-section', 'Show the welcome tour', 'The four intro pages from first launch.',
      was: 'About', keywords: ['intro', 'onboarding', 'tour', 'welcome', 'help']),
];

SettingsEntry settingsEntry(String id) {
  final real = settingsEntryAliases[id] ?? id;
  return settingsEntries.firstWhere((e) => e.id == real);
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9#]+'), ' ').trim();

/// The rows matching [query] (every word must appear in the title, the explanation, the keywords, the section or page
/// name, or the name of the section the row was in before build 76), best first: title matches, then keyword matches,
/// then the rest, each in display order. Rows not on screen in [state] are left out. An empty query matches nothing.
List<SettingsEntry> searchSettings(String query, {AppState? state, List<SettingsEntry> entries = settingsEntries}) {
  final words = _norm(query).split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  final scored = <(int, int, SettingsEntry)>[];
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (state != null && !e.isAvailable(state)) continue;
    final title = _norm(e.title);
    final keys = _norm(e.keywords.join(' '));
    final hay = '$title ${_norm(e.summary)} $keys ${_norm(e.where)} ${_norm(e.was ?? '')}';
    if (!words.every(hay.contains)) continue;
    final rank = words.every(title.contains) ? 0 : (words.every(keys.contains) ? 1 : 2);
    scored.add((rank, i, e));
  }
  scored.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final s in scored) s.$3];
}
