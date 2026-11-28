// Build 78 (builder A): shared pieces of builder A's MeshSonar radio screens (the page, pairing, overview, sharing, log,
// paired apps). Builder B's screens do not use this file.
//
//   MsChip       the Wi-Fi state pill: Paired / Not paired / Not on Wi-Fi
//   MsBody       a scrolling page body, centred and width-capped on iPad, safe at large text sizes
//   MsNotReady   the "Not on Wi-Fi" / "Pair first" / wrong-radio state with Retry
//   MsLive       loads one endpoint, shows the radio's own error text, and polls it (never faster than every 2 s, only
//                while its screen is the top route and the app is in front: lib/core/app_foreground.dart)
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';

import '../../core/app_foreground.dart';
import '../../core/msradio/msradio.dart';
import '../design/app_surfaces.dart' show showAppToast, AppToastKind;
import '../design/tokens.dart';
import '../theme.dart' show MeshSonarColors;

/// The fastest any MeshSonar radio screen polls (the brief: at most every 2 s).
const Duration kMsMinPoll = Duration(seconds: 2);

// ------------------------------------------------------------------------------------------------ formatting
String msBytes(int? b) {
  if (b == null) return '—';
  if (b < 1000) return '$b bytes';
  if (b < 1000 * 1000) return '${(b / 1000).toStringAsFixed(b < 10000 ? 1 : 0)} KB';
  return '${(b / 1000000).toStringAsFixed(1)} MB';
}

String msDuration(int? s) {
  if (s == null || s < 0) return '—';
  if (s < 60) return '$s s';
  if (s < 3600) return '${s ~/ 60} min';
  if (s < 86400) return '${s ~/ 3600} h ${(s % 3600) ~/ 60} min';
  return '${s ~/ 86400} d ${(s % 86400) ~/ 3600} h';
}

String msCount(int? n) {
  if (n == null) return '—';
  final s = '$n';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0 && s[i - 1] != '-') b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// The first 8 hex of a key, upper-case, as the radio's own screens show it.
String msKeyPrefix(String? key) => key == null || key.length < 8 ? '—' : key.substring(0, 8).toUpperCase();

/// Shows the radio's own refusal text (or a plain default) as an error toast.
void msShowError(BuildContext context, Object e) {
  if (!context.mounted) return;
  showAppToast(context, msErrorText(e), kind: AppToastKind.error);
}

// ------------------------------------------------------------------------------------------------ chip
class MsChip extends StatelessWidget {
  final MsLinkState state;
  const MsChip(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final m = MeshSonarColors.of(context);
    final (bg, fg) = switch (state.step) {
      MsLinkStep.paired => (c.primaryContainer, c.onPrimaryContainer),
      MsLinkStep.notPaired || MsLinkStep.idle || MsLinkStep.finding => (c.surfaceContainerHighest, c.onSurfaceVariant),
      MsLinkStep.notOnWifi || MsLinkStep.wrongRadio => (m.warning, m.onWarning),
    };
    return Semantics(
      label: 'Wi-Fi: ${state.chip}',
      excludeSemantics: true,
      child: Container(
        key: const Key('ms-chip'),
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(state.chip, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg)),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ page body
/// A scrolling list body: [Layout.screenMargin] at the sides, at most 720 wide (iPad), bottom safe area.
class MsBody extends StatelessWidget {
  final List<Widget> children;
  final Key? listKey;
  const MsBody({super.key, required this.children, this.listKey});

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              key: listKey,
              padding: const EdgeInsets.fromLTRB(0, Gap.m, 0, Gap.xl),
              children: children,
            ),
          ),
        ),
      );
}

/// A short paragraph in the page margin.
class MsNote extends StatelessWidget {
  final String text;
  const MsNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin + Gap.xs, 0, Layout.screenMargin + Gap.xs, Gap.l),
      child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }
}

/// A full-width button in the page margin.
class MsButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool busy;
  final bool destructive;
  const MsButton(this.label, {super.key, this.icon, this.onPressed, this.primary = false, this.busy = false, this.destructive = false});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final lead = busy
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : (icon == null ? null : Icon(icon));
    final min = Size.fromHeight(Hit.of(context));
    final style = primary
        ? FilledButton.styleFrom(
            minimumSize: min, backgroundColor: destructive ? c.errorContainer : null, foregroundColor: destructive ? c.onErrorContainer : null)
        : OutlinedButton.styleFrom(minimumSize: min, foregroundColor: destructive ? c.error : null);
    final text = Text(label, textAlign: TextAlign.center);
    final onTap = busy ? null : onPressed;
    final b = primary
        ? (lead == null ? FilledButton(style: style, onPressed: onTap, child: text) : FilledButton.icon(style: style, onPressed: onTap, icon: lead, label: text))
        : (lead == null ? OutlinedButton(style: style, onPressed: onTap, child: text) : OutlinedButton.icon(style: style, onPressed: onTap, icon: lead, label: text));
    return Padding(padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.s), child: b);
  }
}

// ------------------------------------------------------------------------------------------------ not ready
/// What a MeshSonar radio screen shows when it cannot talk to the radio: looking, Not on Wi-Fi, wrong radio, Pair first.
class MsNotReady extends StatelessWidget {
  final MsRadioController c;

  /// Retry instead of [MsRadioController.connect] (a screen whose own call failed).
  final Future<void> Function()? onRetry;

  /// Shown instead of the state's own text (the radio's error).
  final String? text;

  /// The radio could not be reached by the screen's own call.
  final bool unreachable;
  const MsNotReady(this.c, {super.key, this.onRetry, this.text, this.unreachable = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final step = unreachable ? MsLinkStep.notOnWifi : c.state.step;
    if (step == MsLinkStep.idle || step == MsLinkStep.finding) {
      return const Padding(
        key: Key('ms-finding'),
        padding: EdgeInsets.all(Gap.xl),
        child: Column(children: [
          CupertinoActivityIndicator(),
          SizedBox(height: Gap.s),
          Text('Looking for the radio on Wi-Fi…', textAlign: TextAlign.center),
        ]),
      );
    }
    final (key, icon, title, body, retry) = switch (step) {
      MsLinkStep.notOnWifi => (
          'ms-not-on-wifi',
          Icons.wifi_off_rounded,
          'Not on Wi-Fi',
          text ??
              'This phone cannot reach the radio over Wi-Fi. Check that the radio is on Wi-Fi (its Wi-Fi screen shows the '
                  'address), that the phone is on the same network, and that the radio\'s web console is On. Bluetooth '
                  'is not affected.',
          true,
        ),
      MsLinkStep.wrongRadio => (
          'ms-wrong-radio',
          Icons.report_gmailerrorred_rounded,
          'This is not the radio you are connected to',
          text ?? 'The radio that answered on Wi-Fi has a different key from the one connected over Bluetooth. Nothing was sent to it.',
          true,
        ),
      _ => (
          'ms-pair-first',
          Icons.link_rounded,
          'Pair first',
          text ?? 'Pair this app with the radio on the Pairing page first.',
          false,
        ),
    };
    return Padding(
      key: Key(key),
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.l, Layout.screenMargin, Gap.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(icon, size: 36, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(height: Gap.s),
        Semantics(header: true, child: Text(title, textAlign: TextAlign.center, style: t.textTheme.titleMedium)),
        const SizedBox(height: Gap.xs),
        Text(body, textAlign: TextAlign.center, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        if (retry) ...[
          const SizedBox(height: Gap.m),
          Center(
            child: FilledButton.tonalIcon(
              key: const Key('ms-retry'),
              style: FilledButton.styleFrom(minimumSize: Size(120, Hit.of(context))),
              onPressed: () => onRetry != null ? onRetry!() : c.connect(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------ live data
class MsLiveData<T> {
  final T data;

  /// Loads again (quietly: the data stays on screen).
  final Future<void> Function() reload;

  /// Replaces the data (an action's reply).
  final void Function(T data) set;

  /// The last refresh failed with this text (the old data is still shown).
  final String? refreshError;
  const MsLiveData(this.data, this.reload, this.set, this.refreshError);
}

/// Loads [load] once the radio is paired and shows [builder]; polls every [every] (at least [kMsMinPoll]) while this route
/// is on top and the app is in front. Before pairing, or when the radio cannot be reached, shows [MsNotReady].
class MsLive<T> extends StatefulWidget {
  final MsRadioController c;
  final Future<T> Function(MsRadioApi api) load;
  final Duration? every;
  final Widget Function(BuildContext context, MsLiveData<T> live) builder;
  const MsLive({super.key, required this.c, required this.load, required this.builder, this.every});

  @override
  State<MsLive<T>> createState() => _MsLiveState<T>();
}

class _MsLiveState<T> extends State<MsLive<T>> {
  StreamSubscription<MsLinkState>? _sub;
  Timer? _timer;
  T? _data;
  bool _has = false;
  MsRadioError? _error;
  String? _refreshError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.c.states.listen((s) {
      if (!mounted) return;
      setState(() {});
      if (s.paired && !_has && !_busy) unawaited(_load());
    });
    if (widget.c.state.step == MsLinkStep.idle) unawaited(widget.c.connect());
    if (widget.c.state.paired) unawaited(_load());
    final every = widget.every;
    if (every != null) _timer = Timer.periodic(every < kMsMinPoll ? kMsMinPoll : every, (_) => _tick());
    AppForeground.addListener(_foreground);
  }

  void _foreground(bool fg) {
    if (fg) _tick();
  }

  void _tick() {
    if (!mounted || !AppForeground.inForeground || !widget.c.state.paired || _busy) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    unawaited(_load());
  }

  Future<void> _load() async {
    final api = widget.c.api;
    if (api == null || _busy) return;
    _busy = true;
    try {
      final d = await widget.load(api);
      if (!mounted) return;
      setState(() {
        _data = d;
        _has = true;
        _error = null;
        _refreshError = null;
      });
    } on MsRadioError catch (e) {
      if (!mounted) return;
      setState(() {
        if (_has) {
          _refreshError = e.message;
        } else {
          _error = e;
        }
      });
    } finally {
      _busy = false;
    }
  }

  Future<void> _retry() async {
    setState(() => _error = null);
    if (!widget.c.state.paired) {
      await widget.c.connect();
      return;
    }
    await _load();
  }

  @override
  void dispose() {
    AppForeground.removeListener(_foreground);
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    if (!c.state.paired) return MsBody(children: [MsNotReady(c)]);
    final e = _error;
    if (!_has) {
      if (e == null) return const Center(key: Key('ms-loading'), child: CupertinoActivityIndicator());
      return MsBody(children: [MsNotReady(c, unreachable: e.unreachable, text: e.unreachable ? null : e.message, onRetry: _retry)]);
    }
    return widget.builder(
      context,
      MsLiveData<T>(_data as T, _load, (d) => setState(() => _data = d), _refreshError),
    );
  }
}

/// A one-line notice above a screen's content (an older reading, a refresh that failed).
class MsBanner extends StatelessWidget {
  final String text;
  const MsBanner(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.m),
      child: Container(
        key: const Key('ms-banner'),
        padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
        decoration: BoxDecoration(color: m.warning, borderRadius: BorderRadius.circular(Corners.chip)),
        child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: m.onWarning)),
      ),
    );
  }
}
