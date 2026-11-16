// Settings > Observer (release 0.38, observer-everywhere-mqtt-plan-2026-11-15.md section 3.3; build plan §4.5 items 3, 4
// and 6): the one place for this phone as an observer.
//   * Share with MeshSonar: the master switch (= Settings.telemetryEnabled, default ON; the same switch as in Privacy &
//     data sharing, with the same confirm / erase flow).
//   * Observer status: what the observer is doing now, and what the server last heard from it (`GET /observer/me`).
//   * MQTT feeds: up to 10 outside MeshCore sites this phone feeds directly (lib/core/mqtt/). Each is added from the preset
//     picker (search) or as a Custom feed, stays OFF until the person turns it on, and shows its live
//     status, packets sent in 24 h and last error. Passwords go to the Keychain under the slot's `secretRef`, never to
//     settings.json. Test connects once and publishes a status message only.
// Vocabulary (build plan §4.5 item 6, checked by test/ui/settings/observer_section_test.dart): Radio = the connected
// device, Observer = this phone sharing public packets, Share with MeshSonar = the master switch, MQTT feed = an outside
// site you feed.
// The section keeps its search entries here ([observerSettingsEntries], spread into settings_index.dart) next to the rows
// they point at. [observerStatusLine] is also the subtitle of More > Observer.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/app_state.dart';
import '../../core/api.dart';
import '../../core/mqtt_presets.dart';
import '../../core/observer_engine.dart';
import '../../core/observer_status.dart' show ObserverCallOutcome, observerCallText;
import '../app.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/state_views.dart';
import 'data_sharing.dart' show telemetryCategory;
import 'privacy_section.dart' show setDataCategory;
import 'settings_index.dart';
import 'settings_kit.dart';

/// The searchable rows of this section, in display order. Each id is a SettingsAnchor in [observerSectionRows].
const List<SettingsEntry> observerSettingsEntries = [
  SettingsEntry('observer-share', 'observer', 'Share with MeshSonar',
      'The master switch: while it is on and your radio is connected, this phone is an observer and shares the public packets its radio hears.',
      keywords: ['observer', 'share', 'sharing', 'master switch', 'opt out', 'turn off', 'telemetry', 'packets']),
  SettingsEntry('observer-status', 'observer', 'Observer status',
      'Whether this phone is sharing the public packets its radio hears right now, and what it is waiting for if not.',
      keywords: ['observer', 'status', 'sharing', 'listening', 'packets', 'radio connected', 'heartbeat'], info: true),
  SettingsEntry('observer-feeds', 'observer', 'MQTT feeds',
      'Feed up to 10 other MeshCore sites from this phone, from a preset list or your own broker. Each one stays off until you turn it on.',
      keywords: ['mqtt', 'feed', 'feeds', 'broker', 'preset', 'letsmesh', 'meshmapper', 'custom', 'other sites', 'observer', 'iata']),
];

const String observerHelp =
    'While your radio is connected and the app is open, this phone can act as an observer: it shares the public '
    'packets its radio hears (never private messages or private channels).';

/// What an MQTT feed gets, in plain words (shown above the feeds and on "What MeshSonar shares").
const String mqttFeedsHelp =
    'An MQTT feed sends the public packets your radio hears to another MeshCore site you choose: each packet, its '
    'signal strength and your radio\'s public key as the observer id. Never your position, your name, direct messages '
    'or private channels. Feeds run only while the app is running, your radio is connected and Share with MeshSonar is '
    'on. Each feed stays off until you turn it on.';

/// One line on what the observer is doing now, in plain words (More > Observer and the status row).
String observerStatusLine(AppState s) {
  if (!s.settings.telemetryEnabled) {
    return 'Off. Turn on "Share with MeshSonar" in Settings > Observer to share again.';
  }
  if (s.observerSharing) {
    return s.connected
        ? 'On: sharing the public packets your radio hears while the app is open.'
        : 'On: starts when your radio is connected.';
  }
  if (s.connected && s.radioKind == RadioKind.simulator) return 'The simulator is connected: nothing is shared from it.';
  if (!s.keyApproved) return 'On: starts once this phone\'s driver key is approved.';
  return 'On: starts after you have seen what MeshSonar shares (the sheet shown on first launch).';
}

IconData _icon(BuildContext context, AppSymbol sym) {
  final pf = Theme.of(context).platform;
  return pf == TargetPlatform.iOS || pf == TargetPlatform.macOS ? sym.apple : sym.material;
}

List<Widget> observerSectionRows(BuildContext context) => const [
      SettingsAnchor(id: 'observer-share', child: ObserverShareTile()),
      SettingsAnchor(id: 'observer-status', child: ObserverStatusTile()),
      SettingsAnchor(id: 'observer-feeds', child: MqttFeedsBlock()),
    ];

// ---------------------------------------------------------------------------------------------------- master switch

/// Share with MeshSonar, the master switch. Same setting and flow as the Privacy switch (setDataCategory).
class ObserverShareTile extends StatelessWidget {
  const ObserverShareTile({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final on = s.settings.telemetryEnabled;
    return SwitchListTile(
      key: const Key('observer-share-toggle'),
      secondary: Icon(_icon(context, AppSymbols.antenna)),
      title: Text(telemetryCategory.title),
      subtitle: Text(on
          ? 'On. Whenever your radio is connected and the app is open, this phone is an observer: public packets only.'
          : 'Off: this phone shares nothing, with MeshSonar or any MQTT feed.'),
      value: on,
      onChanged: (v) {
        AppHaptics.selection();
        setDataCategory(context, s, telemetryCategory, v);
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------------- status

/// What the observer does now and what the server last heard from it. Reads `GET /observer/me` once when shown (with an
/// approved key), and again on Refresh.
class ObserverStatusTile extends StatefulWidget {
  const ObserverStatusTile({super.key});
  @override
  State<ObserverStatusTile> createState() => _ObserverStatusTileState();
}

class _ObserverStatusTileState extends State<ObserverStatusTile> {
  bool _busy = false;
  ObserverCallOutcome? _outcome;
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    final s = AppScope.of(context);
    if (s.keyApproved && s.settings.telemetryEnabled) WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!mounted || _busy) return;
    final s = AppScope.of(context);
    setState(() => _busy = true);
    final o = await s.refreshObserverStatus();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = o;
    });
  }

  String _ago(Duration d) {
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 48) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final live = s.observerSharing && s.connected;
    final lines = <String>[observerStatusLine(s)];
    final st = s.observerStatusService.status;
    final now = s.services.clock().toUtc();
    // The icon says the state too (VoiceOver reads the words): live, checking, a problem (offline included), or idle.
    var sym = live ? AppSymbols.waveform : AppSymbols.antenna;
    if (_busy) {
      sym = AppSymbols.clock;
      lines.add('Checking with the server…');
    } else if (st != null) {
      final heard = st.packets24h;
      if (heard != null) lines.add('The server got $heard packet${heard == 1 ? '' : 's'} from this phone in the last 24 h.');
      final hb = st.lastHeartbeatAt;
      if (hb != null) lines.add('Last check-in: ${_ago(now.difference(hb.toUtc()))}.');
    } else if (_outcome != null && _outcome != ObserverCallOutcome.ok) {
      // With an approved key, "no key" can only mean this server's client cannot report observer status.
      final o = _outcome == ObserverCallOutcome.noKey && s.keyApproved ? ObserverCallOutcome.notOnServer : _outcome!;
      lines.add(observerCallText(o));
      if (o != ObserverCallOutcome.notOnServer) sym = o == ObserverCallOutcome.offline ? AppSymbols.wifi : AppSymbols.exclamationCircle;
    }
    final canAsk = s.keyApproved;
    // The Refresh button sits under the row, not beside it: at AX3 a trailing button would squeeze the text out.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InfoTile(
        key: const Key('observer-status'),
        icon: _icon(context, sym),
        title: settingsEntry('observer-status').title,
        subtitle: lines.join('\n'),
      ),
      if (canAsk)
        Padding(
          padding: const EdgeInsets.only(left: Gap.l + 40, bottom: Gap.xs),
          child: TextButton(
            key: const Key('observer-status-refresh'),
            onPressed: _busy ? null : _refresh,
            child: const Text('Refresh status'),
          ),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------------------------------- presets

/// The app's preset store (bundled asset + last good server copy in the app support folder), made on first use.
abstract final class ObserverPresets {
  /// Tests put their own store here.
  static MqttPresetStore? debugStore;
  static MqttPresetStore? _store;
  static AppState? _app;

  /// The bundled preset file (pubspec `assets/mqtt/`).
  static const String asset = 'assets/mqtt/mqtt-presets.json';

  static Future<MqttPresetStore> of(AppState s) async {
    _app = s; // the fetch follows the app's current client (server URL)
    final d = debugStore;
    if (d != null) return d;
    final have = _store;
    if (have != null) return have;
    File? file;
    try {
      Directory base;
      try {
        base = await getApplicationSupportDirectory();
      } catch (_) {
        base = await getApplicationDocumentsDirectory();
      }
      file = File(p.join(base.path, 'meshsonar', 'mqtt', 'mqtt-presets.json'));
    } catch (_) {
      file = null; // no app folder (tests, a broken install): the copy lives in memory only
    }
    return _store ??= MqttPresetStore(
      loadBundled: () => rootBundle.loadString(asset),
      cacheFile: file,
      fetcher: () => _app!.client.mqttPresets,
    );
  }
}

// ---------------------------------------------------------------------------------------------------- feeds

/// The status a slot shows when the engine has none for it (no engine in this build, or not started yet).
ObserverFeedStatus _fallbackStatus(AppState s, MqttSlotSettings slot) {
  if (mqttHostIsMeshSonar(slot.host)) {
    return ObserverFeedStatus(slotId: slot.id, state: ObserverFeedState.notAllowed, lastError: meshSonarBrokerRefusal);
  }
  if (!slot.enabled) return ObserverFeedStatus(slotId: slot.id, state: ObserverFeedState.off);
  if (!s.observerSharing) {
    return ObserverFeedStatus(
      slotId: slot.id,
      state: ObserverFeedState.off,
      lastError: s.settings.telemetryEnabled ? observerStatusLine(s) : 'Share with MeshSonar is off.',
    );
  }
  if (!s.connected) return ObserverFeedStatus(slotId: slot.id, state: ObserverFeedState.waitingForRadio);
  return ObserverFeedStatus(slotId: slot.id, state: ObserverFeedState.connecting);
}

AppSymbol feedStateSymbol(ObserverFeedState st) => switch (st) {
      ObserverFeedState.connected => AppSymbols.checkmarkCircleFill,
      ObserverFeedState.connecting => AppSymbols.clock,
      ObserverFeedState.waitingForRadio => AppSymbols.antenna,
      ObserverFeedState.pausedInBackground => AppSymbols.clock,
      ObserverFeedState.notAllowed => AppSymbols.xmarkCircleFill,
      ObserverFeedState.authFailed => AppSymbols.lock,
      ObserverFeedState.radioCantSign => AppSymbols.exclamationTriangle,
      ObserverFeedState.error => AppSymbols.exclamationCircle,
      ObserverFeedState.off => AppSymbols.minus,
    };

Color? _feedStateColor(BuildContext context, ObserverFeedState st) {
  final c = Theme.of(context).colorScheme;
  return switch (st) {
    ObserverFeedState.connected => c.primary,
    ObserverFeedState.authFailed ||
    ObserverFeedState.radioCantSign ||
    ObserverFeedState.notAllowed ||
    ObserverFeedState.error =>
      c.error,
    _ => c.onSurfaceVariant,
  };
}

/// The airport code a new feed's topic uses by default: the region the phone is in, else the one being viewed (only a
/// 3-letter code; `swoh` style regions have none).
String? defaultFeedIata(AppState s) {
  for (final code in [s.currentRegion?.code, s.viewingRegion?.code]) {
    final c = code?.trim().toUpperCase();
    if (c != null && RegExp(r'^[A-Z]{3}$').hasMatch(c)) return c;
  }
  return null;
}

/// The first free slot id (`slot-1` .. `slot-10`); null when all 10 are used.
String? nextSlotId(List<MqttSlotSettings> slots) {
  if (slots.length >= Settings.maxMqttSlots) return null;
  final used = {for (final x in slots) x.id};
  for (var i = 1; i <= Settings.maxMqttSlots; i++) {
    if (!used.contains('slot-$i')) return 'slot-$i';
  }
  return null;
}

Future<void> _saveSlots(AppState s, List<MqttSlotSettings> slots) => s.updateSettings(s.settings.copyWith(mqttSlots: slots));

Future<void> _replaceSlot(AppState s, MqttSlotSettings slot) {
  final list = [for (final x in s.settings.mqttSlots) x.id == slot.id ? slot : x];
  if (!list.any((x) => x.id == slot.id)) list.add(slot);
  return _saveSlots(s, list);
}

/// The MQTT feeds: the explanation, one row per slot (live status from the engine) and "Add a feed".
class MqttFeedsBlock extends StatefulWidget {
  const MqttFeedsBlock({super.key});
  @override
  State<MqttFeedsBlock> createState() => _MqttFeedsBlockState();
}

class _MqttFeedsBlockState extends State<MqttFeedsBlock> {
  StreamSubscription<List<ObserverFeedStatus>>? _sub;
  ObserverEngine? _engine;
  Map<String, ObserverFeedStatus> _statuses = const {};
  MqttPresetCatalog? _catalog;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = AppScope.of(context);
    if (!identical(_engine, s.observerEngine)) {
      _sub?.cancel();
      _engine = s.observerEngine;
      _take(_engine!.statuses);
      _sub = _engine!.statusChanges.listen((l) {
        if (mounted) setState(() => _take(l));
      });
    }
    if (_catalog == null && s.settings.mqttSlots.any((x) => x.presetId != null)) unawaited(_loadCatalog(s));
  }

  Future<void> _loadCatalog(AppState s) async {
    try {
      final c = await (await ObserverPresets.of(s)).current();
      if (mounted) setState(() => _catalog = c);
    } catch (_) {
      // The bundled list is broken (a build error a test catches): slots still work, the picker just stays empty.
    }
  }

  void _take(List<ObserverFeedStatus> l) => _statuses = {for (final x in l) x.slotId: x};

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _add() async {
    final s = AppScope.of(context);
    final id = nextSlotId(s.settings.mqttSlots);
    if (id == null) return;
    final picked = await showMqttPresetPicker(context);
    if (picked == null || !mounted) return;
    if (picked.custom) {
      await showMqttSlotSheet(context,
          slot: MqttSlotSettings(id: id, name: '', host: '', iata: null), isNew: true);
      return;
    }
    final preset = picked.preset!;
    if (mqttHostIsMeshSonar(preset.host)) {
      // The picker hides such a preset; a list that still carries one is refused here too.
      showAppToast(context, meshSonarBrokerRefusal, kind: AppToastKind.error);
      return;
    }
    final iata = defaultFeedIata(s);
    final follows = iata != null && iata == s.currentRegion?.code.toUpperCase();
    await _replaceSlot(s, preset.toSlot(id, iata: follows ? null : iata));
    if (!mounted) return;
    setState(() => _catalog = picked.catalog);
    AppHaptics.success();
    showAppToast(context, 'Added ${preset.name}. It stays off until you turn it on.', kind: AppToastKind.success);
  }

  Future<void> _toggle(MqttSlotSettings slot, bool on) async {
    final s = AppScope.of(context);
    AppHaptics.selection();
    await _replaceSlot(s, slot.copyWith(enabled: on));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final slots = s.settings.mqttSlots;
    final full = slots.length >= Settings.maxMqttSlots;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.xs),
          child: Semantics(
            header: true,
            child: Text('${settingsEntry('observer-feeds').title} (${slots.length} of ${Settings.maxMqttSlots})',
                key: const Key('mqtt-feeds-title'), style: t.textTheme.titleMedium),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
          child: Text(mqttFeedsHelp, key: const Key('mqtt-feeds-help'), style: t.textTheme.bodySmall),
        ),
        if (slots.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
            child: MergeSemantics(
              child: Row(key: const Key('mqtt-feeds-empty'), crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: AppSymbolIcon(AppSymbols.tray, size: 18, color: t.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Text('No MQTT feeds yet. MeshSonar\'s own feed is the switch above; MQTT feeds are for other sites.',
                      style: t.textTheme.bodyMedium),
                ),
              ]),
            ),
          ),
        for (final slot in slots)
          MqttSlotTile(
            key: Key('mqtt-slot-${slot.id}'),
            slot: slot,
            status: _statuses[slot.id] ?? _fallbackStatus(s, slot),
            fromEngine: _statuses.containsKey(slot.id),
            onToggle: (v) => _toggle(slot, v),
            onTap: () => showMqttSlotSheet(context, slot: slot, isNew: false, preset: _catalog?.byId(slot.presetId)),
          ),
        ListTile(
          key: const Key('mqtt-add-feed'),
          leading: Icon(_icon(context, AppSymbols.plus)),
          title: const Text('Add a feed'),
          subtitle: full
              ? const SettingsWhyNot('All 10 feeds are in use. Delete one to add another.')
              : const Text('Pick a site from the list, or add your own broker.'),
          enabled: !full,
          onTap: full ? null : _add,
        ),
      ],
    );
  }
}

/// One feed: status icon and words, packets sent in 24 h, the last error, and its on/off switch.
class MqttSlotTile extends StatelessWidget {
  final MqttSlotSettings slot;
  final ObserverFeedStatus status;

  /// [status] came from the engine (its text is a real last error) rather than from what the app knows (a reason).
  final bool fromEngine;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;
  const MqttSlotTile({
    super.key,
    required this.slot,
    required this.status,
    this.fromEngine = true,
    required this.onToggle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // A saved slot that points at MeshSonar's own server: never connected, and it says why in plain words.
    final status = mqttHostIsMeshSonar(slot.host)
        ? ObserverFeedStatus(slotId: slot.id, state: ObserverFeedState.notAllowed, lastError: meshSonarBrokerRefusal)
        : this.status;
    final fromEngine = this.fromEngine && status.state != ObserverFeedState.notAllowed;
    final lines = <String>[
      slot.enabled || status.state != ObserverFeedState.off ? status.state.label : 'Off',
      if (status.sent24h > 0 || status.state == ObserverFeedState.connected)
        '${status.sent24h} packet${status.sent24h == 1 ? '' : 's'} sent in 24 h',
      if (status.lastError != null && status.lastError!.isNotEmpty)
        fromEngine ? 'Last error: ${status.lastError}' : status.lastError!,
    ];
    return ListTile(
      leading: Icon(_icon(context, feedStateSymbol(status.state)), color: _feedStateColor(context, status.state)),
      title: Text(slot.name.isEmpty ? slot.host : slot.name),
      subtitle: Text(lines.join('\n'), key: Key('mqtt-slot-${slot.id}-status')),
      isThreeLine: lines.length > 1,
      onTap: onTap,
      trailing: Switch(
        key: Key('mqtt-slot-${slot.id}-switch'),
        value: slot.enabled,
        onChanged: onToggle,
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------- picker

/// What the picker returned: a preset (with the catalog it came from) or Custom.
class MqttPresetPick {
  final MqttPreset? preset;
  final MqttPresetCatalog? catalog;
  bool get custom => preset == null;
  const MqttPresetPick.preset(MqttPreset this.preset, MqttPresetCatalog this.catalog);
  const MqttPresetPick.custom()
      : preset = null,
        catalog = null;
}

Future<MqttPresetPick?> showMqttPresetPicker(BuildContext context) => showAppSheet<MqttPresetPick>(
      context,
      detents: const [0.92],
      builder: (ctx, controller) => _PresetPicker(controller: controller, app: AppScope.of(context)),
    );

class _PresetPicker extends StatefulWidget {
  final ScrollController controller;
  final AppState app;
  const _PresetPicker({required this.controller, required this.app});
  @override
  State<_PresetPicker> createState() => _PresetPickerState();
}

class _PresetPickerState extends State<_PresetPicker> {
  final _search = TextEditingController();
  MqttPresetCatalog? _catalog;
  Object? _error;
  MqttPresetRefresh? _refresh;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final store = await ObserverPresets.of(widget.app);
      final c = await store.current();
      if (!mounted) return;
      setState(() {
        _catalog = c;
        _refreshing = true;
      });
      final r = await store.refreshIfStale();
      final after = await store.current();
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _refresh = r ?? store.lastRefresh;
        _catalog = after;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  String? _sourceLine(MqttPresetCatalog c) {
    if (_refreshing) return 'Checking the server for a newer list…';
    final offline = _refresh == MqttPresetRefresh.offline;
    final failed = _refresh == MqttPresetRefresh.failed;
    final asOf = c.list.asOf;
    final date = asOf == null ? '' : ' (list of ${asOf.toIso8601String().substring(0, 10)})';
    return switch (c.origin) {
      MqttPresetOrigin.server => 'Up to date with the server$date.',
      MqttPresetOrigin.saved => offline
          ? 'Offline: showing the list last downloaded$date.'
          : 'Showing the list last downloaded$date.',
      MqttPresetOrigin.bundled => offline
          ? 'Offline: showing the list built into the app$date.'
          : (failed ? 'The server has no newer list: showing the one built into the app$date.' : 'Built into the app$date.'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = _catalog;
    final slots = widget.app.settings.mqttSlots;
    final added = {for (final x in slots) ?x.presetId};

    Widget body;
    if (_error != null) {
      body = AppErrorView(
        key: const Key('mqtt-presets-error'),
        title: 'Couldn\'t read the preset list',
        message: 'You can still add your own broker with Custom.',
        onRetry: _load,
      );
    } else if (c == null) {
      body = const AppLoadingView(key: Key('mqtt-presets-loading'), label: 'Loading the preset list');
    } else {
      final found = [for (final x in c.search(_search.text)) if (!mqttHostIsMeshSonar(x.host)) x];
      final rows = <Widget>[];
      for (final g in MqttPresetGroup.values) {
        final inGroup = [for (final x in found) if (c.groupOf(x) == g) x];
        if (inGroup.isEmpty) continue;
        rows.add(Padding(
          padding: const EdgeInsets.only(top: Gap.m, bottom: Gap.xs),
          child: Semantics(header: true, child: Text(g.label, style: t.textTheme.titleSmall)),
        ));
        for (final x in inGroup) {
          rows.add(_PresetRow(
            preset: x,
            added: added.contains(x.id),
            onTap: () => Navigator.of(context).pop(MqttPresetPick.preset(x, c)),
          ));
        }
      }
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_sourceLine(c) case final line?)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(line, key: const Key('mqtt-presets-source'), style: t.textTheme.bodySmall),
          ),
        if (found.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.l),
            child: AppEmptyView(
              key: const Key('mqtt-presets-empty'),
              symbol: AppSymbols.magnifyingglass,
              title: 'No site matches "${_search.text.trim()}"',
              message: 'Check the spelling, or add the broker yourself.',
              actionLabel: 'Add a custom feed',
              onAction: () => Navigator.of(context).pop(const MqttPresetPick.custom()),
            ),
          ),
        ...rows,
      ]);
    }

    return AppSheetScaffold(
      key: const Key('mqtt-preset-picker'),
      controller: widget.controller,
      title: 'Add an MQTT feed',
      secondaryAction: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      children: [
        Text(
          'A preset says the site exists, not that its operator wants phone observers. Every feed starts off.',
          style: t.textTheme.bodySmall,
        ),
        const SizedBox(height: Gap.s),
        TextField(
          key: const Key('mqtt-preset-search'),
          controller: _search,
          enabled: _error == null,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            prefixIcon: AppSymbolIcon(AppSymbols.magnifyingglass, size: 20),
            hintText: 'Search by name, host or region',
            border: const OutlineInputBorder(),
          ),
        ),
        ListTile(
          key: const Key('mqtt-preset-custom'),
          contentPadding: EdgeInsets.zero,
          leading: AppSymbolIcon(AppSymbols.gear),
          title: const Text('Custom feed'),
          subtitle: const Text('Your own broker: host, port, sign-in.'),
          onTap: () => Navigator.of(context).pop(const MqttPresetPick.custom()),
        ),
        body,
        const SizedBox(height: Gap.l),
      ],
    );
  }
}

class _PresetRow extends StatelessWidget {
  final MqttPreset preset;
  final bool added;
  final VoidCallback onTap;
  const _PresetRow({required this.preset, required this.added, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final where = [preset.host, ?preset.region].join(' · ');
    return MergeSemantics(
      child: ListTile(
        key: Key('mqtt-preset-${preset.id}'),
        contentPadding: EdgeInsets.zero,
        title: Text(preset.name),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(where),
          if (added) const Text('Already in your feeds'),
          if (preset.needsRealIata)
            Text('Needs a real 3-letter airport code.', style: t.textTheme.bodySmall),
        ]),
        trailing: added ? AppSymbolIcon(AppSymbols.checkmark, semanticLabel: 'Added') : null,
        enabled: !added,
        onTap: added ? null : onTap,
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------- slot sheet

/// Edits one feed (a new Custom feed when [isNew]): fields, Test, Save, Delete. Preset feeds keep the preset's host,
/// port and sign-in; their WebSocket path and airport code can be changed (the sources disagree on some paths).
Future<void> showMqttSlotSheet(BuildContext context,
        {required MqttSlotSettings slot, required bool isNew, MqttPreset? preset}) =>
    showAppSheet<void>(
      context,
      detents: const [0.92],
      builder: (ctx, controller) =>
          _SlotSheet(controller: controller, app: AppScope.of(context), slot: slot, isNew: isNew, preset: preset),
    );

class _SlotSheet extends StatefulWidget {
  final ScrollController controller;
  final AppState app;
  final MqttSlotSettings slot;
  final bool isNew;
  final MqttPreset? preset;
  const _SlotSheet({required this.controller, required this.app, required this.slot, required this.isNew, this.preset});
  @override
  State<_SlotSheet> createState() => _SlotSheetState();
}

class _SlotSheetState extends State<_SlotSheet> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _host, _port, _path, _iata, _aud, _user, _pass;
  late bool _tls;
  late MqttAuth _auth;
  late bool _enabled;
  bool _hasSavedPassword = false;
  bool _wrotePassword = false;
  bool _testing = false;
  ObserverFeedStatus? _test;

  MqttSlotSettings get _orig => widget.slot;
  bool get _isPreset => _orig.presetId != null;
  String? get _regionIata => widget.app.currentRegion?.code.trim().toUpperCase();

  @override
  void initState() {
    super.initState();
    final x = _orig;
    _name = TextEditingController(text: x.name);
    _host = TextEditingController(text: x.host);
    _port = TextEditingController(text: '${x.port}');
    _path = TextEditingController(text: x.wsPath);
    _iata = TextEditingController(text: x.iata ?? defaultFeedIata(widget.app) ?? '');
    _aud = TextEditingController(text: x.aud ?? '');
    _user = TextEditingController(text: x.username ?? '');
    _pass = TextEditingController();
    _tls = x.tls;
    _auth = widget.isNew ? MqttAuth.jwt : x.auth;
    _enabled = x.enabled;
    unawaited(_checkSavedPassword());
  }

  Future<void> _checkSavedPassword() async {
    final store = widget.app.services.secretStore;
    if (store == null || widget.isNew) return;
    final v = await store.read(_orig.secretRef);
    if (mounted) setState(() => _hasSavedPassword = v != null && v.isNotEmpty);
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _path, _iata, _aud, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The feed as the form says now.
  MqttSlotSettings _built() {
    final iata = _iata.text.trim().toUpperCase();
    final follows = iata.isEmpty || (_orig.iata == null && iata == _regionIata);
    final host = _host.text.trim();
    final name = _name.text.trim();
    return _orig.copyWith(
      name: name.isEmpty ? host : name,
      host: _isPreset ? _orig.host : host,
      port: _isPreset ? _orig.port : int.tryParse(_port.text.trim()) ?? 443,
      wsPath: _path.text.trim().isEmpty ? '/' : _path.text.trim(),
      tls: _isPreset ? _orig.tls : _tls,
      auth: _isPreset ? _orig.auth : _auth,
      iata: follows ? null : iata,
      clearIata: follows,
      aud: _aud.text.trim().isEmpty ? null : _aud.text.trim(),
      clearAud: _aud.text.trim().isEmpty,
      username: _auth == MqttAuth.password && !_isPreset ? _user.text.trim() : null,
      clearUsername: !(_auth == MqttAuth.password && !_isPreset),
      enabled: _enabled,
    );
  }

  /// Writes a typed password to the Keychain (the slot's own entry). False when this build cannot keep secrets.
  Future<bool> _storePassword(MqttSlotSettings slot) async {
    if (slot.auth != MqttAuth.password || _pass.text.isEmpty) return true;
    final store = widget.app.services.secretStore;
    if (store == null) return false;
    await store.write(slot.secretRef, Uint8List.fromList(utf8.encode(_pass.text)));
    _wrotePassword = true;
    return true;
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final s = widget.app;
    final slot = _built();
    if (mqttHostIsMeshSonar(slot.host)) {
      // A preset feed has no host field to show the error under: say it here, save nothing.
      setState(() => _test = ObserverFeedStatus(slotId: slot.id, state: ObserverFeedState.notAllowed, lastError: meshSonarBrokerRefusal));
      return;
    }
    final passwordChanged = slot.auth == MqttAuth.password && _pass.text.isNotEmpty;
    if (!await _storePassword(slot)) {
      if (mounted) showAppToast(context, 'This phone can\'t keep the password safely, so it was not saved.', kind: AppToastKind.error);
      return;
    }
    if (slot.auth != MqttAuth.password) await s.services.secretStore?.delete(slot.secretRef);
    if (passwordChanged && slot.enabled && _orig.enabled && slot == _orig) {
      // Only the password changed: restart the feed so it logs in with the new one now (the engine reads it per connect).
      await _replaceSlot(s, slot.copyWith(enabled: false));
    }
    await _replaceSlot(s, slot);
    if (!mounted) return;
    AppHaptics.success();
    Navigator.of(context).pop();
    showAppToast(context, widget.isNew ? 'Added ${slot.name}. It stays off until you turn it on.' : 'Saved ${slot.name}.',
        kind: AppToastKind.success);
  }

  Future<void> _cancel() async {
    // A new feed that was tested and then dropped leaves no password behind.
    if (widget.isNew && _wrotePassword) await widget.app.services.secretStore?.delete(_orig.secretRef);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _runTest() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final slot = _built();
    if (!await _storePassword(slot)) {
      setState(() => _test = ObserverFeedStatus(
          slotId: slot.id, state: ObserverFeedState.error, lastError: 'This phone can\'t keep the password safely.'));
      return;
    }
    setState(() {
      _testing = true;
      _test = null;
    });
    ObserverFeedStatus r;
    try {
      r = await widget.app.observerEngine.test(slot);
    } catch (e) {
      r = ObserverFeedStatus(slotId: slot.id, state: ObserverFeedState.error, lastError: '$e');
    }
    if (!mounted) return;
    r.state == ObserverFeedState.connected ? AppHaptics.success() : AppHaptics.error();
    setState(() {
      _testing = false;
      _test = r;
    });
  }

  Future<void> _delete() async {
    final s = widget.app;
    AppHaptics.warning();
    final orig = _orig;
    final before = s.settings.mqttSlots;
    final at = before.indexWhere((x) => x.id == orig.id);
    // The feed stops and disappears at once; its saved password stays in the Keychain until the Undo window ends.
    await _saveSlots(s, [for (final x in before) if (x.id != orig.id) x]);
    if (!mounted) return;
    runWithUndo(
      context,
      'Deleted ${orig.name}.',
      onUndo: () {
        final now = [...s.settings.mqttSlots];
        if (!now.any((x) => x.id == orig.id)) now.insert(at < 0 || at > now.length ? now.length : at, orig);
        unawaited(_saveSlots(s, now));
      },
      commit: () async {
        if (!s.settings.mqttSlots.any((x) => x.id == orig.id)) await s.services.secretStore?.delete(orig.secretRef);
      },
    );
    Navigator.of(context).pop();
  }

  String? _hostOk(String? v) {
    final h = (v ?? '').trim();
    if (h.isEmpty) return 'Enter the broker\'s host name';
    if (mqttHostIsMeshSonar(h)) return meshSonarBrokerRefusal;
    if (h.contains('://') || h.contains('/') || h.contains(' ')) return 'Only the host name, e.g. mqtt.example.org';
    return null;
  }

  String? _portOk(String? v) {
    final n = int.tryParse((v ?? '').trim());
    return n == null || n < 1 || n > 65535 ? 'A port from 1 to 65535' : null;
  }

  String? _pathOk(String? v) {
    final x = (v ?? '').trim();
    return x.isEmpty || x.startsWith('/') ? null : 'Starts with /, e.g. /mqtt';
  }

  String? _iataOk(String? v) {
    final x = (v ?? '').trim().toUpperCase();
    if (x.isEmpty) return null;
    return RegExp(r'^[A-Z0-9]{3}$').hasMatch(x) ? null : 'Three letters or digits, e.g. CMH';
  }

  String? _userOk(String? v) =>
      _auth == MqttAuth.password && !_isPreset && (v ?? '').trim().isEmpty ? 'Enter the username' : null;

  String? _passOk(String? v) => _auth == MqttAuth.password && !_isPreset && (v ?? '').isEmpty && !_hasSavedPassword
      ? 'Enter the password'
      : null;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = widget.app;
    final region = defaultFeedIata(s);
    final preset = widget.preset;
    Widget field(String key, TextEditingController c, String label,
            {String? help, String? hint, String? Function(String?)? validator, TextInputType? keyboard, bool obscure = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.s),
          child: TextFormField(
            key: Key(key),
            controller: c,
            validator: validator,
            keyboardType: keyboard,
            obscureText: obscure,
            autocorrect: false,
            enableSuggestions: !obscure,
            textCapitalization: key == 'mqtt-field-iata' ? TextCapitalization.characters : TextCapitalization.none,
            decoration: InputDecoration(labelText: label, helperText: help, helperMaxLines: 4, hintText: hint, border: const OutlineInputBorder()),
          ),
        );

    final test = _test;
    return Form(
      key: _form,
      child: AppSheetScaffold(
        key: const Key('mqtt-slot-sheet'),
        controller: widget.controller,
        title: widget.isNew ? 'Custom feed' : (_orig.name.isEmpty ? _orig.host : _orig.name),
        primaryAction: FilledButton(key: const Key('mqtt-slot-save'), onPressed: _save, child: Text(widget.isNew ? 'Add feed' : 'Save')),
        secondaryAction: TextButton(key: const Key('mqtt-slot-cancel'), onPressed: _cancel, child: const Text('Cancel')),
        children: [
          SwitchListTile(
            key: const Key('mqtt-field-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Feed on'),
            subtitle: const Text('Sends while the app is running, your radio is connected and Share with MeshSonar is on.'),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: Gap.s),
          field('mqtt-field-name', _name, 'Name', hint: 'Shown in this list'),
          if (_isPreset)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: Text('${_orig.host}:${_orig.port}, ${_orig.tls ? 'secure WebSocket (wss)' : 'WebSocket'}, '
                  '${_orig.auth == MqttAuth.jwt ? 'login signed by your radio' : _orig.auth == MqttAuth.password ? 'username and password' : 'no login'}.',
                  key: const Key('mqtt-slot-endpoint'), style: t.textTheme.bodyMedium),
            )
          else ...[
            field('mqtt-field-host', _host, 'Host', hint: 'mqtt.example.org', validator: _hostOk, keyboard: TextInputType.url),
            field('mqtt-field-port', _port, 'Port', validator: _portOk, keyboard: TextInputType.number),
          ],
          field('mqtt-field-path', _path, 'WebSocket path',
              help: 'Usually / or /mqtt. If Test cannot connect, try the other one.', validator: _pathOk, keyboard: TextInputType.url),
          if (!_isPreset)
            SwitchListTile(
              key: const Key('mqtt-field-tls'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Secure connection (TLS)'),
              subtitle: Text(_tls
                  ? 'wss: encrypted, the broker\'s certificate is checked.'
                  : 'Off sends everything unencrypted. Only for a broker on your own network.'),
              value: _tls,
              onChanged: (v) => setState(() => _tls = v),
            ),
          field('mqtt-field-iata', _iata, 'Airport code for the topic',
              help: [
                region == null
                    ? 'Your region has no 3-letter code: enter the nearest airport code (e.g. CMH).'
                    : 'Default: $region, your region\'s airport code. Leave it to follow your region.',
                if (preset?.needsRealIata ?? false) 'This site drops packets without a real airport code.',
              ].join(' '),
              validator: _iataOk),
          if (!_isPreset) ...[
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.xs),
              child: Semantics(header: true, child: Text('Sign-in', style: t.textTheme.titleSmall)),
            ),
            SegmentedButton<MqttAuth>(
              key: const Key('mqtt-field-auth'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: MqttAuth.jwt, label: Text('Radio-signed')),
                ButtonSegment(value: MqttAuth.password, label: Text('Password')),
                ButtonSegment(value: MqttAuth.none, label: Text('None')),
              ],
              selected: {_auth},
              onSelectionChanged: (v) => setState(() => _auth = v.first),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              switch (_auth) {
                MqttAuth.jwt => 'Your radio signs a login token with its own key. No password, nothing secret leaves the radio.',
                MqttAuth.password => 'The password is kept in the phone\'s Keychain, never in the app\'s settings file.',
                MqttAuth.none => 'No login: only for a broker that accepts anyone.',
              },
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: Gap.s),
            if (_auth == MqttAuth.jwt) field('mqtt-field-aud', _aud, 'Token audience (optional)', help: 'Leave empty to use the host.'),
            if (_auth == MqttAuth.password) ...[
              field('mqtt-field-user', _user, 'Username', validator: _userOk),
              field('mqtt-field-pass', _pass, 'Password',
                  obscure: true,
                  hint: _hasSavedPassword ? 'Saved in the Keychain: leave empty to keep it' : null,
                  validator: _passOk),
            ],
          ],
          const SizedBox(height: Gap.s),
          OutlinedButton.icon(
            key: const Key('mqtt-slot-test'),
            onPressed: _testing ? null : _runTest,
            icon: AppSymbolIcon(AppSymbols.paperplaneFill, size: 18),
            label: Text(_testing ? 'Testing…' : 'Test'),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text('Test connects once and sends only a status message, never a packet.', style: t.textTheme.bodySmall),
          ),
          if (test != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: Semantics(
                liveRegion: true,
                child: Row(key: const Key('mqtt-test-result'), crossAxisAlignment: CrossAxisAlignment.start, children: [
                  AppSymbolIcon(feedStateSymbol(test.state), color: _feedStateColor(context, test.state)),
                  const SizedBox(width: Gap.s),
                  Expanded(
                    child: Text(test.state == ObserverFeedState.connected
                        ? 'Connected: the site accepted the login and the status message.'
                        : '${test.state.label}${test.lastError == null ? '' : ': ${test.lastError}'}'),
                  ),
                ]),
              ),
            ),
          if (!widget.isNew) ...[
            const SizedBox(height: Gap.l),
            TextButton.icon(
              key: const Key('mqtt-slot-delete'),
              onPressed: _delete,
              style: TextButton.styleFrom(foregroundColor: t.colorScheme.error),
              icon: AppSymbolIcon(AppSymbols.trash, size: 18, color: t.colorScheme.error),
              label: const Text('Delete feed'),
            ),
          ],
          const SizedBox(height: Gap.l),
        ],
      ),
    );
  }
}
