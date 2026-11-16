// "Ask for location" on a person's contact screen (MeshTrack MT-13, meshtrack plan 5.9 row "Any MeshCore user, one
// person"). Asks their radio for its position with MeshCore's own telemetry request; the answer is one of:
//   * a position: "2.4 km NE of you · Answered just now", an "asked" pin on the Drive map (Friends layer) and Open on map;
//   * no position: "<name> did not share a location. They can allow it in their MeshCore app's telemetry settings.";
//   * nothing in time: "No answer from <name>." with Try again;
//   * no radio: the row is dimmed with the reason.
// While asking: a spinner and Cancel. The same person can be asked once per 30 s ("Ask again in 25 s").
// Only for people (companions): a repeater or room answers location only to a logged-in admin, and its position is in its
// announcement already (docs/protocol/telemetry-location-request.md).
//
// Privacy: the position stays in memory (the radio session's AskLocationHub and the map pin), is never uploaded, saved or
// logged with coordinates. Distances go through Units.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoButton;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../chat/models.dart';
import '../../core/units.dart';
import '../../radio/inbound.dart' show RadioContact;
import '../../radio/tools/ask_location.dart';
import '../app.dart';
import '../contacts/profile_widgets.dart' show ProfileGroup;
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import '../map/layers/registry.dart' show kFriendsLayerId, kPlanLayerId;
import '../map/main_map_focus.dart';
import '../nodes/node_actions.dart' show shellControllerFor;
import '../tools/tools_host.dart' show AppStateToolsHost;
import '../../core/meshtrack/meshtrack_service.dart' show MeshTrackService;
import 'meshtrack_copy.dart';

/// Opens the Drive map on an answered position. [friendsLayer]: the asked pin is on the Friends layer (MeshTrack on);
/// else the position is shown as a one-off target.
typedef OpenAskedOnMap = void Function(BuildContext context, MtAskedPosition p, {required bool friendsLayer});

/// What the card needs from the app. Tests put an [AskLocationScope] above the screen instead.
class AskLocationEnv {
  /// The connected radio's hub; null = no radio connected.
  final AskLocationHub? hub;
  final Units units;

  /// The phone's position (distance and direction to the answer); null = unknown.
  final MtLatLon? Function() here;

  /// MeshTrack (the Friends layer's asked pin); null when MeshTrack is off in this build.
  final MeshTrackService? meshTrack;
  final DateTime Function() now;
  final OpenAskedOnMap openOnMap;
  const AskLocationEnv({
    required this.hub,
    this.units = Units.metric,
    required this.here,
    this.meshTrack,
    this.now = DateTime.now,
    this.openOnMap = openAskedOnDriveMap,
  });

  /// The env for [context]: an [AskLocationScope] above it, else the app's. Null when neither exists.
  static AskLocationEnv? of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AskLocationScope>();
    if (scope != null) return scope.env;
    final s = AppScope.maybeOf(context);
    if (s == null) return null;
    final tools = AppStateToolsHost.of(s).tools;
    final hub = tools != null && tools.connected ? tools.askLocation : null;
    hub?.log ??= s.diagnostics.add; // lines carry no name and no coordinate
    return AskLocationEnv(
      hub: hub,
      units: s.units,
      here: () {
        final f = s.phoneFix?.fix;
        return f == null ? null : (lat: f.lat, lon: f.lon);
      },
      meshTrack: s.meshTrack,
    );
  }
}

class AskLocationScope extends InheritedWidget {
  final AskLocationEnv env;
  const AskLocationScope({super.key, required this.env, required super.child});
  @override
  bool updateShouldNotify(AskLocationScope old) => !identical(old.env, env);
}

/// Closes the screens over the tabs, switches to the Drive tab and centres its map on [p] (with the Friends layer on, or
/// with a one-off "Asked" target when MeshTrack is off).
void openAskedOnDriveMap(BuildContext context, MtAskedPosition p, {required bool friendsLayer}) {
  final shell = shellControllerFor(context);
  final local = Navigator.maybeOf(context);
  final root = Navigator.maybeOf(context, rootNavigator: true);
  root?.popUntil((r) => r.isFirst);
  if (local != null && local != root) local.popUntil((r) => r.isFirst);
  final at = LatLng(p.lat, p.lon);
  final id = p.keyHex.length >= 8 ? p.keyHex.substring(0, 8) : p.keyHex;
  MainMapFocus.request(at, 15,
      showLayers: {friendsLayer ? kFriendsLayerId : kPlanLayerId},
      targets: friendsLayer ? const [] : [MapFocusTarget(id: 'asked-$id', at: at, label: '$askedPinMark: ${p.name}')]);
  shell?.openDrive();
}

/// The Ask for location group of a person's contact screen. [env] overrides [AskLocationEnv.of] (tests).
class AskLocationCard extends StatefulWidget {
  final Contact contact;
  final AskLocationEnv? env;
  const AskLocationCard({super.key, required this.contact, this.env});

  @override
  State<AskLocationCard> createState() => _AskLocationCardState();
}

class _AskLocationCardState extends State<AskLocationCard> {
  StreamSubscription<void>? _sub;
  AskLocationHub? _hub;
  Timer? _tick;

  /// Re-draws when the shown answer expires ([kAskedOnMapFor]: its map pin is gone, so Open on map goes too).
  Timer? _expiry;

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    _expiry?.cancel();
    super.dispose();
  }

  void _listen(AskLocationHub? hub) {
    if (identical(hub, _hub)) return;
    _sub?.cancel();
    _hub = hub;
    _sub = hub?.changed.listen((_) {
      if (mounted) setState(() {});
    });
  }

  /// Re-draws every second while the 30 s limit counts down.
  void _armTick(bool counting) {
    if (counting && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        if (_hub == null || _hub!.retryIn(widget.contact.publicKey) == null) {
          _tick?.cancel();
          _tick = null;
        }
      });
    } else if (!counting && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  RadioContact get _radioContact => RadioContact(
        publicKeyHex: widget.contact.publicKey,
        type: widget.contact.type.code,
        outPath: Uint8List(0),
        name: widget.contact.displayName,
      );

  Future<void> _ask(AskLocationEnv env) async {
    final hub = env.hub;
    if (hub == null) return;
    final mt = env.meshTrack;
    await hub.ask(_radioContact, name: widget.contact.displayName, onLocated: mt?.putAsked);
  }

  @override
  Widget build(BuildContext context) {
    final env = widget.env ?? AskLocationEnv.of(context);
    if (env == null) return const SizedBox.shrink();
    final hub = env.hub;
    _listen(hub);
    final c = widget.contact;
    final name = c.displayName;
    final key = c.publicKey;
    final st = hub?.stateOf(key, name: name) ?? AskState(AskPhase.notConnected, key, name);
    final wait = hub?.retryIn(key);
    _armTick(wait != null && !st.asking);
    _expiry?.cancel();
    final left = st.answeredAt == null ? null : hub?.answerExpiresIn(key);
    _expiry = left == null
        ? null
        : Timer(left + const Duration(milliseconds: 50), () {
            if (mounted) setState(() {});
          });
    final now = env.now();
    final col = AppColors.of(context);

    final rows = <Widget>[];
    String? footer;
    String againLabel(String base) => wait == null ? base : askAgainIn(wait);

    if (hub == null) {
      rows.add(_ActionRow(key: const Key('ask-location'), label: askLocationLabel, symbol: AppSymbols.location, onTap: null));
      footer = askNotConnected;
    } else {
      switch (st.phase) {
        case AskPhase.idle:
          rows.add(_ActionRow(
              key: const Key('ask-location'),
              label: wait == null ? askLocationLabel : askAgainIn(wait),
              symbol: AppSymbols.location,
              onTap: wait == null ? () => _ask(env) : null));
          footer = askFooter(name);
        case AskPhase.asking:
          rows.add(_AskingRow(name: name, onCancel: () => hub.cancel(key)));
        case AskPhase.located:
          final p = st.position!;
          rows.add(_StatusRow(
            key: const Key('ask-location-answer'),
            symbol: AppSymbols.locationFill,
            tint: col.accent,
            title: askWhere(env.here(), p.lat, p.lon, env.units),
            detail: askAnsweredAgo(p.at, now),
          ));
          rows.add(_ActionRow(
              key: const Key('ask-location-open'),
              label: askOpenOnMap,
              symbol: AppSymbols.map,
              chevron: true,
              onTap: () => env.openOnMap(context, p, friendsLayer: env.meshTrack != null)));
          rows.add(_ActionRow(
              key: const Key('ask-location-again'),
              label: againLabel('Ask again'),
              symbol: AppSymbols.location,
              onTap: wait == null ? () => _ask(env) : null));
        case AskPhase.noLocation:
          rows.add(_StatusRow(
              key: const Key('ask-location-no-position'), symbol: AppSymbols.exclamationCircle, tint: col.textMuted, title: askNoLocation(name)));
          rows.add(_ActionRow(
              key: const Key('ask-location-again'), label: againLabel('Ask again'), symbol: AppSymbols.location, onTap: wait == null ? () => _ask(env) : null));
        case AskPhase.noAnswer:
          rows.add(_StatusRow(
              key: const Key('ask-location-no-answer'),
              symbol: AppSymbols.exclamationCircle,
              tint: col.textMuted,
              title: askNoAnswer(name),
              detail: askNoAnswerHint));
          rows.add(_ActionRow(
              key: const Key('ask-location-retry'), label: againLabel(askTryAgain), symbol: AppSymbols.location, onTap: wait == null ? () => _ask(env) : null));
        case AskPhase.notOnRadio || AskPhase.busy || AskPhase.failed || AskPhase.notConnected:
          final msg = switch (st.phase) {
            AskPhase.notOnRadio => askNotOnRadio(name),
            AskPhase.busy => askBusy,
            AskPhase.notConnected => askNotConnected,
            _ => askFailed,
          };
          rows.add(_StatusRow(key: const Key('ask-location-problem'), symbol: AppSymbols.exclamationCircle, tint: col.textMuted, title: msg));
          rows.add(_ActionRow(
              key: const Key('ask-location-retry'), label: againLabel(askTryAgain), symbol: AppSymbols.location, onTap: wait == null ? () => _ask(env) : null));
      }
    }

    return KeyedSubtree(key: const Key('ask-location-card'), child: ProfileGroup(rows: rows, footer: footer));
  }
}

/// A tappable row: symbol + label in the accent colour; dimmed and not tappable when [onTap] is null.
class _ActionRow extends StatelessWidget {
  final String label;
  final AppSymbol symbol;
  final VoidCallback? onTap;
  final bool chevron;
  const _ActionRow({super.key, required this.label, required this.symbol, required this.onTap, this.chevron = false});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final on = onTap != null;
    final tint = on ? c.accent : c.textMuted;
    return Semantics(
      button: true,
      enabled: on,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMtHit),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s + 2),
            child: Row(children: [
              AppSymbolIcon(symbol, size: 20, color: tint),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(label, style: AppType.body.copyWith(color: tint))),
              if (chevron) AppSymbolIcon(AppSymbols.chevronRight, size: 14, color: c.textMuted),
            ]),
          ),
        ),
      ),
    );
  }
}

/// What came back: a symbol, a sentence and an optional second line.
class _StatusRow extends StatelessWidget {
  final AppSymbol symbol;
  final Color tint;
  final String title;
  final String? detail;
  const _StatusRow({super.key, required this.symbol, required this.tint, required this.title, this.detail});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      liveRegion: true,
      label: detail == null ? title : '$title. $detail',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.m),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: AppSymbolIcon(symbol, size: 20, color: tint)),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppType.body.copyWith(color: c.textPrimary)),
              if (detail != null) ...[
                const SizedBox(height: 2),
                Text(detail!, style: AppType.footnote.copyWith(color: c.textMuted)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// "Asking Ann…" with a spinner and Cancel.
class _AskingRow extends StatelessWidget {
  final String name;
  final VoidCallback onCancel;
  const _AskingRow({required this.name, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ConstrainedBox(
      key: const Key('ask-location-asking'),
      constraints: const BoxConstraints(minHeight: kMtHit),
      child: Padding(
        padding: const EdgeInsets.only(left: Layout.screenMargin, right: Gap.xs),
        child: Row(children: [
          const SizedBox(width: 20, child: CupertinoActivityIndicator(radius: 9)),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(askAsking(name), style: AppType.body.copyWith(color: c.textPrimary)),
            ),
          ),
          Semantics(
            button: true,
            label: 'Cancel asking $name',
            excludeSemantics: true,
            child: CupertinoButton(
              key: const Key('ask-location-cancel'),
              minimumSize: const Size(kMtHit, kMtHit),
              padding: const EdgeInsets.symmetric(horizontal: Gap.m),
              onPressed: onCancel,
              child: Text(askCancel, style: AppType.body.copyWith(color: c.accent)),
            ),
          ),
        ]),
      ),
    );
  }
}
