// Shared pieces of the Tools screens: the page that explains "no radio" in plain words, a button with a visible cooldown,
// the airtime note, notes with an icon AND words (colour never carries meaning alone), the small map, and formatters.
// Every Tools screen is built from these so the empty / disconnected / busy / error states read the same everywhere.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../radio/session.dart' show LinkState;
import '../../radio/tools/radio_tools.dart';
import '../map/coverage_map.dart' show CoverageMap;
import '../theme.dart';
import 'tools_host.dart';

/// Smallest tap target (logical px).
const double kToolTarget = 48;

// ---------------------------------------------------------------- page

/// A Tools screen: app bar, safe area, and the gate: with no usable radio the body is [ToolUnavailable], never an empty
/// or half-working screen.
class ToolPage extends StatelessWidget {
  /// Key prefix: the scaffold is `tool-<id>`.
  final String id;
  final String title;
  final Widget Function(BuildContext context, ToolsHost host, RadioTools tools) builder;
  final List<Widget> Function(BuildContext context, ToolsHost host, RadioTools tools)? actions;
  const ToolPage({super.key, required this.id, required this.title, required this.builder, this.actions});

  @override
  Widget build(BuildContext context) {
    final host = ToolsHostScope.of(context);
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final tools = host.tools;
        return Scaffold(
          key: Key('tool-$id'),
          appBar: AppBar(title: Text(title), actions: tools == null ? null : actions?.call(context, host, tools)),
          body: SafeArea(child: tools == null ? ToolUnavailable(host: host) : builder(context, host, tools)),
        );
      },
    );
  }
}

/// Why a tool cannot run right now, in plain language, with the one thing to do about it.
class ToolUnavailable extends StatelessWidget {
  final ToolsHost host;
  const ToolUnavailable({super.key, required this.host});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final state = host.linkState;
    final (IconData icon, String title, String body, bool canConnect) = switch (state) {
      LinkState.reconnecting => (
          Icons.bluetooth_searching,
          'Getting your radio back',
          'The Bluetooth link dropped and MeshSonar is reconnecting. This screen comes back by itself when the radio does.',
          false
        ),
      LinkState.connecting => (Icons.bluetooth_searching, 'Connecting', 'MeshSonar is connecting to your radio.', false),
      LinkState.handedOver => (
          Icons.swap_horiz,
          'Radio handed to another app',
          'You gave your radio to another app on purpose, so MeshSonar left it alone. Connect again to use these tools.',
          true
        ),
      LinkState.connected => (
          Icons.link_off,
          'This radio connection cannot run the tools',
          'The tools need a MeshCore companion radio. This connection does not offer them.',
          false
        ),
      LinkState.disconnected => (
          Icons.bluetooth_disabled,
          'No radio connected',
          'Connect a MeshCore radio and these tools work with it. Nothing is sent to the mesh until you ask.',
          true
        ),
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            key: const Key('tool-unavailable'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: t.colorScheme.onSurfaceVariant),
              const SizedBox(height: Gap.m),
              Text(title, style: t.textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: Gap.s),
              Text(body, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
              if (canConnect) ...[
                const SizedBox(height: Gap.l),
                FilledButton.icon(
                  key: const Key('tool-connect'),
                  style: FilledButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
                  onPressed: () => host.openConnect(context),
                  icon: const Icon(Icons.bluetooth),
                  label: const Text('Connect a radio'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- live updates

/// Rebuilds [builder] when any of [sources] fires (the tools' `changed` streams), at most [every] apart, so a burst of
/// packets is a few frames, not hundreds.
class ToolListener extends StatefulWidget {
  final List<Stream<void>> sources;
  final WidgetBuilder builder;
  final Duration every;
  const ToolListener({super.key, required this.sources, required this.builder, this.every = const Duration(milliseconds: 250)});
  @override
  State<ToolListener> createState() => _ToolListenerState();
}

class _ToolListenerState extends State<ToolListener> {
  final List<StreamSubscription<void>> _subs = [];
  Timer? _timer;
  bool _dirty = false;

  void _listen() {
    for (final s in widget.sources) {
      _subs.add(s.listen((_) => _poke()));
    }
  }

  void _poke() {
    if (!mounted) return;
    if (_timer != null) {
      _dirty = true;
      return;
    }
    setState(() {});
    _timer = Timer(widget.every, () {
      _timer = null;
      if (_dirty && mounted) {
        _dirty = false;
        setState(() {});
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(ToolListener old) {
    super.didUpdateWidget(old);
    final same = old.sources.length == widget.sources.length && [for (var i = 0; i < old.sources.length; i++) identical(old.sources[i], widget.sources[i])].every((x) => x);
    if (!same) {
      for (final s in _subs) {
        s.cancel();
      }
      _subs.clear();
      _listen();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

// ---------------------------------------------------------------- cooldown button

/// A button that counts its own cooldown down in words ("Send local advert" -> "Wait 23 s"), disabled meanwhile. A cooldown is
/// a normal state, never an error.
class CooldownButton extends StatefulWidget {
  final String label;
  final IconData icon;

  /// Time left, or null when the action may go now.
  final Duration? Function() cooldown;
  final VoidCallback? onPressed;
  final bool busy;
  final bool filled;
  const CooldownButton({
    super.key,
    required this.label,
    required this.icon,
    required this.cooldown,
    required this.onPressed,
    this.busy = false,
    this.filled = true,
  });
  @override
  State<CooldownButton> createState() => _CooldownButtonState();
}

class _CooldownButtonState extends State<CooldownButton> {
  Timer? _t;

  void _arm() {
    _t?.cancel();
    _t = null;
    if (widget.cooldown() != null) {
      _t = Timer(const Duration(seconds: 1), () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  static String waitText(Duration d) {
    final s = (d.inMilliseconds / 1000).ceil();
    return s >= 90 ? '${(s / 60).ceil()} min' : '$s s';
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.cooldown();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _arm();
    });
    final waiting = left != null;
    final enabled = !waiting && !widget.busy && widget.onPressed != null;
    final label = waiting ? 'Wait ${waitText(left)}' : (widget.busy ? 'Working' : widget.label);
    final icon = widget.busy
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(waiting ? Icons.hourglass_bottom : widget.icon);
    final style = ButtonStyle(minimumSize: WidgetStateProperty.all(const Size(kToolTarget, kToolTarget)));
    final button = widget.filled
        ? FilledButton.icon(style: style, onPressed: enabled ? widget.onPressed : null, icon: icon, label: Text(label))
        : OutlinedButton.icon(style: style, onPressed: enabled ? widget.onPressed : null, icon: icon, label: Text(label));
    return Semantics(
      container: true,
      label: waiting ? '${widget.label}. Available again in ${waitText(left)}.' : widget.label,
      excludeSemantics: true,
      button: true,
      enabled: enabled,
      child: button,
    );
  }
}

// ---------------------------------------------------------------- notes

enum NoteKind { info, caution, problem, good }

/// A short note with an icon and words. [kind] changes the icon and tint; the words always say what it means.
class NoteCard extends StatelessWidget {
  final NoteKind kind;
  final String text;
  final String? title;
  final Widget? trailing;
  const NoteCard(this.text, {super.key, this.kind = NoteKind.info, this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final (IconData icon, Color bg, Color fg, String word) = switch (kind) {
      NoteKind.info => (Icons.info_outline, c.surfaceContainerHigh, c.onSurface, 'Note'),
      NoteKind.good => (Icons.check_circle_outline, c.primaryContainer, c.onPrimaryContainer, 'OK'),
      NoteKind.caution => (Icons.warning_amber_rounded, c.tertiaryContainer, c.onTertiaryContainer, 'Careful'),
      NoteKind.problem => (Icons.error_outline, c.errorContainer, c.onErrorContainer, 'Problem'),
    };
    return Semantics(
      container: true,
      label: '$word. ${title == null ? '' : '$title. '}$text',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Corners.small)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: fg, size: 22),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (title != null) Text(title!, style: t.textTheme.titleSmall?.copyWith(color: fg)),
              Text(text, style: t.textTheme.bodyMedium?.copyWith(color: fg)),
            ]),
          ),
          ?trailing,
        ]),
      ),
    );
  }
}

/// "About 0.4 s on air. MeshSonar has sent 2.1 s in the last hour; its allowance is 36 s."
class AirtimeNote extends StatelessWidget {
  final RadioTools tools;

  /// Estimated airtime of the action about to be taken, ms.
  final double? ms;
  final String? action;
  const AirtimeNote({super.key, required this.tools, this.ms, this.action});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final own = tools.noise.ownAirtime;
    final text = '${ms == null ? '' : '${action ?? 'This'} uses about ${fmtAir(ms!)} of airtime. '}'
        'MeshSonar has transmitted ${fmtAir(own.lastHourMs)} in the last hour; its limit is ${fmtAir(own.capMs)}.';
    return Semantics(
      container: true,
      label: 'Airtime. $text',
      excludeSemantics: true,
      child: Row(key: const Key('airtime-note'), crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.graphic_eq, size: 18, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
      ]),
    );
  }
}

/// A section heading (announced as a heading to a screen reader).
class ToolHeading extends StatelessWidget {
  final String text;
  const ToolHeading(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.s),
        child: Semantics(container: true, header: true, child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
      );
}

// ---------------------------------------------------------------- signal words

/// The words for a link's SNR, from the website's coverage levels (strong from +5 dB, good from 0, fair from -5).
String snrWord(double? snr) {
  if (snr == null) return 'Unknown';
  if (snr >= 5) return 'Strong';
  if (snr >= 0) return 'Good';
  if (snr >= -5) return 'Fair';
  return 'Weak';
}

/// "+3.2 dB" / "-4.0 dB" / "unknown".
String fmtDb(double? v, {int digits = 1}) => v == null ? 'unknown' : '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(digits)} dB';

/// SNR text with its word: "+3.2 dB, good".
String fmtSnr(double? v) => v == null ? 'unknown' : '${fmtDb(v)}, ${snrWord(v).toLowerCase()}';

/// Airtime: "0.4 s", "36 s", "2.1 min".
String fmtAir(double ms) {
  if (ms < 1000) return '${(ms / 1000).toStringAsFixed(1)} s';
  if (ms < 100000) return '${(ms / 1000).toStringAsFixed(ms < 10000 ? 1 : 0)} s';
  return '${(ms / 60000).toStringAsFixed(1)} min';
}

/// "just now", "12 s ago", "4 min ago", "2 h ago".
String fmtAgo(Duration d) {
  final s = d.inSeconds;
  if (s < 5) return 'just now';
  if (s < 90) return '$s s ago';
  if (s < 5400) return '${(s / 60).round()} min ago';
  return '${(s / 3600).round()} h ago';
}

/// Local clock time, "14:05:09".
String fmtClock(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

// ---------------------------------------------------------------- map

class MapPin {
  final LatLng point;

  /// Spoken label for the pin.
  final String label;
  final IconData icon;
  final Color? color;

  /// Replaces the icon (a numbered circle for a trace).
  final Widget? child;
  const MapPin({required this.point, required this.label, this.icon = Icons.cell_tower, this.color, this.child});
}

class MapLine {
  final List<LatLng> points;
  final Color color;
  final double width;
  const MapLine(this.points, this.color, {this.width = 4});
}

/// A small non-interactive map that fits [pins] and [lines]. Tiles are the same OSM raster the other small maps use; with no
/// network the canvas colour and the lines still draw. The map itself is hidden from screen readers; [semanticLabel] says
/// what it shows and the screen lists the same facts as text.
class ToolMap extends StatelessWidget {
  /// Widget tests turn tiles off (no network).
  static bool tilesEnabled = true;

  final List<MapPin> pins;
  final List<MapLine> lines;
  final double height;
  final String semanticLabel;
  const ToolMap({super.key, required this.pins, this.lines = const [], this.height = 220, required this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    final pts = <LatLng>[for (final p in pins) p.point, for (final l in lines) ...l.points];
    if (pts.isEmpty) {
      return Container(
        key: const Key('tool-map-empty'),
        height: height * 0.5,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(Gap.l),
        decoration: BoxDecoration(color: m.mapBackground, borderRadius: BorderRadius.circular(Corners.small)),
        child: Text(semanticLabel, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    final fit = pts.length == 1
        ? null
        : CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(36), maxZoom: 15);
    return Semantics(
      container: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: ClipRRect(
        key: const Key('tool-map'),
        borderRadius: BorderRadius.circular(Corners.small),
        child: SizedBox(
          height: height,
          child: FlutterMap(
            options: MapOptions(
              initialCenter: pts.first,
              initialZoom: 13,
              initialCameraFit: fit,
              backgroundColor: m.mapBackground,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag),
            ),
            children: [
              if (tilesEnabled)
                TileLayer(
                  urlTemplate: CoverageMap.tileUrl,
                  userAgentPackageName: CoverageMap.userAgentPackageName,
                  maxNativeZoom: 19,
                  tileBuilder: (context, tile, _) => ColorFiltered(colorFilter: ColorFilter.matrix(m.tileMatrix), child: tile),
                ),
              if (lines.isNotEmpty)
                PolylineLayer(polylines: [
                  for (final l in lines)
                    Polyline(points: l.points, strokeWidth: l.width, color: l.color, borderStrokeWidth: 1.5, borderColor: m.linkLineCasing),
                ]),
              MarkerLayer(markers: [
                for (final p in pins)
                  Marker(
                    point: p.point,
                    width: 32,
                    height: 32,
                    child: p.child ?? Icon(p.icon, color: p.color ?? m.beacon, size: 28),
                  ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// A numbered dot for a pin on a path ("1", "2", ...).
class NumberDot extends StatelessWidget {
  final int n;
  final Color color;
  const NumberDot(this.n, {super.key, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
        child: Text('$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
      );
}
