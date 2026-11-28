// Shared pieces of builder B's MeshSonar radio screens (map pack, firmware, Lua apps, radio screen and sounds, owner link,
// RF tools): the page frame with the Wi-Fi gate (Not on Wi-Fi / Pair again, with a retry), the 2 s foreground-only poller,
// the radio's error text, a confirm dialog and a few formatters. Plain English, the app's inset lists and notes.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_foreground.dart';
import '../../core/msradio/msradio.dart';
import '../../platform/file_pick.dart';
import '../design/app_surfaces.dart' show showAppAlert;
import '../design/tokens.dart';
import '../tools/tool_kit.dart' show NoteCard, NoteKind;

export '../radio/inset_list.dart' show InsetGroup, InsetRow;
export '../tools/tool_kit.dart' show NoteCard, NoteKind;

/// The fastest the screens ask the radio again (the brief: at most every 2 s).
const Duration kMsBPollEvery = Duration(seconds: 2);

/// A screen of the MeshSonar radio page: app bar, then [builder]'s rows in a scrolling list (Dynamic Type safe, centred
/// and width-limited on iPad), or a plain "Not on Wi-Fi" / "Pair again" state with a retry while the link is not paired.
class MsBPage extends StatelessWidget {
  final MsRadioController c;
  final String id;
  final String title;
  final List<Widget> Function(BuildContext context) builder;
  final Future<void> Function()? onRefresh;
  const MsBPage({super.key, required this.c, required this.id, required this.title, required this.builder, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: Key('msb-$id'),
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: StreamBuilder<MsLinkState>(
          stream: c.states,
          initialData: c.state,
          builder: (context, snap) {
            final st = snap.data ?? c.state;
            if (!st.paired || c.api == null) return MsBNotReady(c: c, state: st);
            final list = ListView(
              key: Key('msb-$id-list'),
              padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.xl),
              children: [
                for (final w in builder(context))
                  Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: w)),
              ],
            );
            return onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list);
          },
        ),
      ),
    );
  }
}

/// The link is not usable: why, in plain words, and what to do.
class MsBNotReady extends StatefulWidget {
  final MsRadioController c;
  final MsLinkState state;
  const MsBNotReady({super.key, required this.c, required this.state});
  @override
  State<MsBNotReady> createState() => _MsBNotReadyState();
}

class _MsBNotReadyState extends State<MsBNotReady> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await widget.c.connect();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final st = widget.state;
    final (IconData icon, String title, String body) = switch (st.step) {
      MsLinkStep.notPaired => (Icons.link_off, 'Pair again', 'The radio no longer knows this app. Pair it again from the MeshSonar radio page.'),
      MsLinkStep.wrongRadio => (Icons.report_outlined, 'Wrong radio', 'This is not the radio you are connected to.'),
      MsLinkStep.finding || MsLinkStep.idle || MsLinkStep.paired => (Icons.wifi_find, 'Looking for the radio', 'MeshSonar is looking for your radio on this Wi-Fi.'),
      MsLinkStep.notOnWifi => (
          Icons.wifi_off,
          'Not on Wi-Fi',
          'The radio cannot be reached from this phone. Put the phone on the same Wi-Fi as the radio. Bluetooth keeps working.'
        ),
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(key: const Key('msb-not-ready'), mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(height: Gap.m),
            Text(title, style: t.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: Gap.s),
            Text(body, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
            if (st.step != MsLinkStep.notPaired) ...[
              const SizedBox(height: Gap.l),
              FilledButton.icon(
                key: const Key('msb-retry'),
                style: FilledButton.styleFrom(minimumSize: Size.fromHeight(Hit.of(context))),
                onPressed: _busy ? null : _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Padding for a block (button row, note, chart) that sits between inset groups.
class MsBBlock extends StatelessWidget {
  final Widget child;
  const MsBBlock({super.key, required this.child});
  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.l), child: child);
}

/// Buttons that wrap onto more lines at large text sizes.
class MsBButtons extends StatelessWidget {
  final List<Widget> children;
  const MsBButtons(this.children, {super.key});
  @override
  Widget build(BuildContext context) => MsBBlock(child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: children));
}

/// The radio's refusal (or any error) as a problem note; nothing when [text] is null.
class MsBError extends StatelessWidget {
  final String? text;
  final Key? noteKey;
  const MsBError(this.text, {super.key, this.noteKey});
  @override
  Widget build(BuildContext context) {
    if (text == null) return const SizedBox.shrink();
    return MsBBlock(child: NoteCard(text!, key: noteKey ?? const Key('msb-error'), kind: NoteKind.problem));
  }
}

/// A progress bar with words ("Sending 1.2 MB of 3.9 MB", "Writing on the radio: 40%").
class MsBProgress extends StatelessWidget {
  final String text;

  /// 0..1, or null for an indeterminate bar.
  final double? value;
  const MsBProgress(this.text, {super.key, this.value});
  @override
  Widget build(BuildContext context) => MsBBlock(
        child: Semantics(
          container: true,
          label: text,
          excludeSemantics: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: Gap.xs),
            LinearProgressIndicator(value: value?.clamp(0.0, 1.0)),
          ]),
        ),
      );
}

/// A switch row in an inset group (the whole row toggles; at least 44 pt).
class MsBSwitchRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? switchKey;
  const MsBSwitchRow({super.key, required this.title, this.subtitle, required this.value, this.onChanged, this.switchKey});
  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
        key: switchKey,
        contentPadding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        value: value,
        onChanged: onChanged,
      );
}

/// Asks before an action that cannot be taken back (the app's alert: Cupertino on Apple platforms). True when confirmed.
Future<bool> msBConfirm(BuildContext context,
    {required String key, required String title, required String body, required String confirmLabel, bool destructive = false}) async {
  final ok = await showAppAlert(
    context,
    title: title,
    message: body,
    confirmLabel: confirmLabel,
    destructive: destructive,
    dialogKey: Key('msb-confirm-$key'),
    confirmKey: Key('msb-confirm-$key-ok'),
    cancelKey: Key('msb-confirm-$key-cancel'),
  );
  return ok == true;
}

/// Runs [job] (a radio call) and returns null, or the text to show when it failed: the radio's own words for a refusal.
Future<String?> msBTry(Future<void> Function() job) async {
  try {
    await job();
    return null;
  } on FilePickRefused catch (e) {
    return e.message;
  } catch (e) {
    return msErrorText(e);
  }
}

/// Polls [tick] every [every] (never faster than [kMsBPollEvery]) while [want] says so and the app is in front; stops on
/// [dispose]. Ticks never overlap.
class MsBPoller {
  final Future<void> Function() tick;
  final bool Function() want;
  final Duration every;
  Timer? _timer;
  bool _running = false, _disposed = false;

  MsBPoller({required this.tick, required this.want, Duration every = kMsBPollEvery})
      : every = every < kMsBPollEvery ? kMsBPollEvery : every {
    AppForeground.addListener(_onForeground);
  }

  bool get active => _timer != null;

  void _onForeground(bool fg) => fg ? kick() : _stop();

  /// Starts polling when it is wanted (call after anything that may make it wanted).
  void kick() {
    if (_disposed || _timer != null || !want() || !AppForeground.inForeground) return;
    _timer = Timer.periodic(every, (_) => _onTick());
  }

  Future<void> _onTick() async {
    if (_disposed) return;
    if (!want() || !AppForeground.inForeground) {
      _stop();
      return;
    }
    if (_running) return;
    _running = true;
    try {
      await tick();
    } catch (_) {
      // the screen shows its own error; the next tick tries again
    } finally {
      _running = false;
    }
    if (!want()) _stop();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    _stop();
    AppForeground.removeListener(_onForeground);
  }
}

/// "3.9 MB", "512 KB", "800 bytes".
String msBBytes(int? b) {
  if (b == null) return 'unknown';
  if (b >= 1000 * 1000) return '${(b / (1000 * 1000)).toStringAsFixed(1)} MB';
  if (b >= 1000) return '${(b / 1000).round()} KB';
  return '$b bytes';
}

/// The radio's progress (0-100) as 0..1.
double msBPct(int p) => (p.clamp(0, 100)) / 100.0;
