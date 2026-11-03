// Stats from a user (chat plan 4.11, WP8): what a contact's radio shares about itself, asked with a telemetry request
// (CMD 39) through the shared remote-request queue. A companion answers only what the owner's telemetry permissions allow
// (battery always when permitted, location and sensors by their own bits), so the sheet shows exactly what came back and
// says in words what was withheld. Spike S11: a companion does not answer a status request (CMD 27), so Stats stay
// telemetry-only. Sensors get the same sheet with an auto-refresh switch (background priority, every 10 s) and a sparkline
// per numeric reading. Silence is its own card ("No reply"), never an endless spinner. Opens from the Stats / Telemetry tile.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoButton, CupertinoSwitch;
import 'package:flutter/material.dart';

import '../../chat/models.dart';
import '../../radio/inbound.dart' show RadioContact;
import '../../radio/tools/telemetry_tool.dart';
import '../app.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/tokens.dart';
import '../tools/tools_host.dart';
import 'profile_widgets.dart';

/// Opens the Stats sheet for [contact]. [telemetry] defaults to the connected radio's tool (null = no radio connected).
Future<void> showUserStatsSheet(
  BuildContext context, {
  required Contact contact,
  TelemetryTool? telemetry,
  double? myLat,
  double? myLon,
  DateTime Function()? clock,
  Duration autoEvery = const Duration(seconds: 10),
  int? lastHeardMs,
}) {
  TelemetryTool? tool = telemetry;
  if (tool == null) {
    final scope = context.getInheritedWidgetOfExactType<ToolsHostScope>();
    final app = AppScope.maybeOf(context);
    tool = scope?.host.tools?.telemetry ?? (app == null ? null : AppStateToolsHost.of(app).tools?.telemetry);
  }
  return showAppSheet<void>(
    context,
    detents: const [0.5, 0.92],
    builder: (ctx, controller) => UserStatsBody(
      controller: controller,
      contact: contact,
      telemetry: tool,
      myLat: myLat,
      myLon: myLon,
      clock: clock,
      autoEvery: autoEvery,
      lastHeardMs: lastHeardMs,
    ),
  );
}

class UserStatsBody extends StatefulWidget {
  final ScrollController controller;
  final Contact contact;
  final TelemetryTool? telemetry;
  final double? myLat, myLon;
  final DateTime Function()? clock;
  final Duration autoEvery;

  /// Milliseconds since an advert from this contact was heard (null = never).
  final int? lastHeardMs;
  const UserStatsBody({
    super.key,
    required this.controller,
    required this.contact,
    required this.telemetry,
    this.myLat,
    this.myLon,
    this.clock,
    this.autoEvery = const Duration(seconds: 10),
    this.lastHeardMs,
  });

  @override
  State<UserStatsBody> createState() => _UserStatsBodyState();
}

class _UserStatsBodyState extends State<UserStatsBody> {
  TelemetryResult? _res;
  bool _loading = false;
  bool _auto = false;
  Timer? _timer;
  bool _disposed = false;

  Contact get _c => widget.contact;
  bool get _person => _c.type == ContactType.companion;
  DateTime _now() => (widget.clock ?? DateTime.now)();

  RadioContact get _radioContact => RadioContact(
        publicKeyHex: _c.publicKey,
        type: _c.type.code,
        outPath: Uint8List(0),
        name: _c.displayName,
      );

  @override
  void initState() {
    super.initState();
    _res = widget.telemetry?.latest[_c.publicKey];
    if (widget.telemetry != null) unawaited(_refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool background = false}) async {
    final t = widget.telemetry;
    if (t == null || _loading) return;
    setState(() => _loading = true);
    final r = await t.requestContactQueued(_radioContact, background: background);
    if (_disposed) return;
    setState(() {
      _loading = false;
      // A dropped / too-soon background refresh keeps what is on screen.
      if (!(background && r.status == TelemetryStatus.tooSoon)) _res = r;
    });
  }

  void _setAuto(bool v) {
    setState(() => _auto = v);
    _timer?.cancel();
    if (v) _timer = Timer.periodic(widget.autoEvery, (_) => _refresh(background: true));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final name = _c.displayName;
    final t = widget.telemetry;
    final r = _res;
    final kids = <Widget>[];

    if (t == null) {
      kids.add(_Card(
        key: const Key('stats-disconnected'),
        symbol: AppSymbols.antenna,
        title: 'Radio not connected',
        message: 'Connect your radio to ask $name for stats.',
      ));
    } else if (r == null || (_loading && !(r.ok))) {
      kids.add(_Waiting(who: name));
    } else {
      kids.addAll(_resultWidgets(context, r, t));
    }

    kids.add(const SizedBox(height: Gap.m));
    return Column(
      key: const Key('user-stats-sheet'),
      children: [
        Expanded(
          child: AppSheetScaffold(
            controller: widget.controller,
            title: 'Stats · $name',
            padding: EdgeInsets.zero,
            primaryAction: t == null
                ? null
                : CupertinoButton(
                    key: const Key('stats-refresh'),
                    onPressed: _loading ? null : () => _refresh(),
                    child: Text(_loading ? 'Asking…' : 'Refresh', style: AppType.headline.copyWith(color: _loading ? c.textMuted : c.accent)),
                  ),
            children: kids,
          ),
        ),
      ],
    );
  }

  List<Widget> _resultWidgets(BuildContext context, TelemetryResult r, TelemetryTool t) {
    final c = AppColors.of(context);
    final name = _c.displayName;
    switch (r.status) {
      case TelemetryStatus.silent:
        return [
          _Card(
            key: const Key('stats-no-reply'),
            symbol: AppSymbols.clock,
            title: 'No reply',
            message: '$name did not answer. They may be out of range, asleep, or their radio may not share stats. Nothing is wrong with your radio.',
          ),
          ..._linkGroup(context),
        ];
      case TelemetryStatus.noContact:
        return [_Card(key: const Key('stats-no-contact'), symbol: AppSymbols.person, title: 'Not on your radio', message: r.detail ?? '')];
      case TelemetryStatus.notConnected:
        return [_Card(key: const Key('stats-disconnected'), symbol: AppSymbols.antenna, title: 'Radio not connected', message: r.detail ?? '')];
      case TelemetryStatus.tooSoon:
        return [_Card(key: const Key('stats-too-soon'), symbol: AppSymbols.clock, title: 'Hold on', message: r.detail ?? 'Try again in a moment.')];
      case TelemetryStatus.refused:
        return [_Card(key: const Key('stats-refused'), symbol: AppSymbols.exclamationCircle, title: 'Your radio refused', message: r.detail ?? '')];
      case TelemetryStatus.empty:
        return [
          _Card(
            key: const Key('stats-empty'),
            symbol: AppSymbols.lock,
            title: 'Nothing shared',
            message: _person ? "$name's radio answered but shares nothing right now." : '$name answered but reported no readings.',
          ),
          ..._linkGroup(context),
        ];
      case TelemetryStatus.ok:
        break;
    }
    final s = TelemetrySummary.of(r, person: _person);
    final rows = <Widget>[];
    if (s.battery != null) {
      rows.add(ProfileRow(label: 'Battery', value: s.battery!.text, key: const Key('stats-battery')));
    }
    final p = s.position;
    if (p != null) {
      final away = (widget.myLat != null && widget.myLon != null) ? distanceKm(widget.myLat!, widget.myLon!, p.lat!, p.lon!) : null;
      rows.add(ProfileRow(
        key: const Key('stats-position'),
        label: 'Position',
        valueWidget: Text(away == null ? p.text : '${p.text}\n${AppScope.unitsOf(context).distance(away * 1000)} away',
            textAlign: TextAlign.end, style: monoStyle.copyWith(color: c.textMuted)),
        semanticsLabel: 'Position, ${p.text}',
      ));
    }
    for (final e in [...s.environment, ...s.other]) {
      final series = seriesOf(t.historyFor(_c.publicKey), e.kind, channel: e.channel);
      rows.add(ProfileRow(
        key: Key('stats-reading-${e.kind.name}-${e.channel}'),
        label: e.label,
        valueWidget: Row(mainAxisSize: MainAxisSize.min, children: [
          if (series.length >= 2) ...[
            StatsSparkline(key: Key('stats-spark-${e.kind.name}-${e.channel}'), values: series, color: c.accent),
            const SizedBox(width: Gap.s),
          ],
          Flexible(child: Text(e.text, textAlign: TextAlign.end, style: AppType.body.copyWith(color: c.textMuted))),
        ]),
        semanticsLabel: '${e.label}, ${e.text}${series.length >= 2 ? ', history available' : ''}',
      ));
    }
    final out = <Widget>[];
    if (rows.isNotEmpty) out.add(_Header('SHARED'));
    if (rows.isNotEmpty) out.add(ProfileGroup(rows: rows));
    out.addAll(_linkGroup(context));
    if (s.withheld.isNotEmpty) {
      out.add(_Header('NOT SHARED'));
      out.add(Padding(
        key: const Key('stats-withheld'),
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final w in s.withheld) Padding(padding: const EdgeInsets.only(bottom: Gap.xs), child: Text(w, style: AppType.subhead.copyWith(color: c.textMuted))),
        ]),
      ));
    }
    if (!_person) {
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.l),
        child: _AutoRow(on: _auto, onChanged: _setAuto),
      ));
    }
    out.add(Padding(
      key: const Key('stats-updated'),
      padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
      child: Text(_updated(r), textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: c.textMuted)),
    ));
    return out;
  }

  String _updated(TelemetryResult r) {
    final s = _now().difference(r.at).inSeconds;
    if (s < 5) return 'Updated just now';
    if (s < 90) return 'Updated $s s ago';
    return 'Updated ${s ~/ 60} min ago';
  }

  /// Route and last-heard from what the app already knows; no extra airtime.
  List<Widget> _linkGroup(BuildContext context) {
    final hops = _c.outPathLen;
    final route = hops < 0 ? 'Not known yet' : (hops == 0 ? 'Direct' : '$hops ${hops == 1 ? 'repeater' : 'repeaters'}');
    final heard = widget.lastHeardMs;
    return [
      _Header('LINK'),
      ProfileGroup(rows: [
        ProfileRow(key: const Key('stats-route'), label: 'Route', value: route),
        if (heard != null) ProfileRow(key: const Key('stats-heard'), label: 'Heard', value: _ago(heard)),
      ]),
    ];
  }

  static String _ago(int ms) {
    if (ms < 90000) return 'just now';
    final m = ms ~/ 60000;
    if (m < 60) return '$m min ago';
    final h = ms ~/ 3600000;
    if (h < 24) return '$h h ago';
    final d = ms ~/ 86400000;
    return d == 1 ? 'yesterday' : '$d days ago';
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.l, Gap.s, Layout.screenMargin, Gap.xs),
        child: Semantics(header: true, child: Text(text, style: AppType.footnote.copyWith(color: AppColors.of(context).textMuted))),
      );
}

class _Waiting extends StatelessWidget {
  final String who;
  const _Waiting({required this.who});
  @override
  Widget build(BuildContext context) => Padding(
        key: const Key('stats-waiting'),
        padding: const EdgeInsets.symmetric(vertical: Gap.xl, horizontal: Layout.screenMargin),
        child: Column(children: [
          const CupertinoActivityIndicator(),
          const SizedBox(height: Gap.m),
          Text('Asking $who…', style: AppType.subhead.copyWith(color: AppColors.of(context).textMuted)),
        ]),
      );
}

class _Card extends StatelessWidget {
  final AppSymbol symbol;
  final String title, message;
  const _Card({super.key, required this.symbol, required this.title, required this.message});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.l, horizontal: Layout.screenMargin),
      child: Semantics(
        container: true,
        label: '$title. $message',
        child: ExcludeSemantics(
          child: Column(children: [
            AppSymbolIcon(symbol, size: 34, color: c.textMuted),
            const SizedBox(height: Gap.m),
            Text(title, style: AppType.headline.copyWith(color: c.textPrimary)),
            const SizedBox(height: Gap.s),
            Text(message, textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: c.textMuted)),
          ]),
        ),
      ),
    );
  }
}

class _AutoRow extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onChanged;
  const _AutoRow({required this.on, required this.onChanged});
  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Hit.minAndroid),
        child: Row(children: [
          Expanded(child: Text('Refresh every 10 s', style: AppType.body.copyWith(color: AppColors.of(context).textPrimary))),
          CupertinoSwitch(key: const Key('stats-auto'), value: on, onChanged: onChanged),
        ]),
      );
}

/// A tiny line chart of a reading's recent values. Flat series draw a centre line; fewer than two points draw nothing.
class StatsSparkline extends StatelessWidget {
  final List<double> values;
  final Color color;
  const StatsSparkline({super.key, required this.values, required this.color});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: SizedBox(width: 64, height: 24, child: CustomPaint(painter: SparklinePainter(values, color))),
      );
}

/// Points of the line in a [width] x [height] box (y grows down); empty for fewer than two values. Pure, tested.
List<Offset> sparklinePoints(List<double> values, double width, double height) {
  if (values.length < 2) return const [];
  var lo = values.first, hi = values.first;
  for (final v in values) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final span = hi - lo;
  return [
    for (var i = 0; i < values.length; i++)
      Offset(width * i / (values.length - 1), span == 0 ? height / 2 : height - (values[i] - lo) / span * height),
  ];
}

class SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  const SparklinePainter(this.values, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final pts = sparklinePoints(values, size.width, size.height - 2);
    if (pts.isEmpty) return;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy + 1);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy + 1);
    }
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(SparklinePainter old) => old.values != values || old.color != color;
}
