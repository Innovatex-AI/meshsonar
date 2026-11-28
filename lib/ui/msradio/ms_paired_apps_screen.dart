// Build 78 (builder A), brief C.11: Apps paired with this radio (GET /tokens): each app, how it paired, when, when the radio
// last saw it; remove one, or all. Removing this app's own pairing means pairing again.
import 'package:flutter/material.dart';

import '../../core/msradio/msradio.dart';
import '../../core/time_format.dart' as tf;
import '../design/app_surfaces.dart' show showAppAlert, showAppToast;
import '../design/tokens.dart';
import 'ms_common.dart';

class MsPairedAppsScreen extends StatelessWidget {
  final MsRadioController c;
  const MsPairedAppsScreen(this.c, {super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        key: const Key('ms-paired-apps-screen'),
        appBar: AppBar(title: const Text('Apps paired with this radio')),
        body: MsLive<MsTokens>(
          c: c,
          load: (api) => api.tokens(),
          builder: (context, live) => _AppsBody(c: c, live: live),
        ),
      );
}

String _via(String? via) => switch (via) {
      'sign' => 'Paired over Wi-Fi with Bluetooth',
      'approve' => 'Allowed on the radio',
      null => 'Paired',
      _ => 'Paired ($via)',
    };

class _AppsBody extends StatefulWidget {
  final MsRadioController c;
  final MsLiveData<MsTokens> live;
  const _AppsBody({required this.c, required this.live});

  @override
  State<_AppsBody> createState() => _AppsBodyState();
}

class _AppsBodyState extends State<_AppsBody> {
  bool _busy = false;

  Future<void> _revoke(MsTokenEntry? e) async {
    final api = widget.c.api;
    if (api == null) return;
    final ok = await showAppAlert(
      context,
      title: e == null ? 'Remove every paired app?' : 'Remove ${e.app}?',
      message: e == null || e.me
          ? 'This app is removed too: pair again to use the radio\'s Wi-Fi features.'
          : 'That app can no longer control the radio over Wi-Fi until it pairs again.',
      confirmLabel: 'Remove',
      destructive: true,
      confirmKey: const Key('ms-revoke-confirm'),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      if (e == null) {
        await api.revokeAllTokens();
      } else {
        await api.revokeToken(e.i);
      }
      if (!mounted) return;
      showAppToast(context, e == null ? 'Every app was removed.' : '${e.app} was removed.');
      // this app's own token is gone: the controller moves to Not paired on the next call (401)
      await widget.live.reload();
    } on MsRadioError catch (err) {
      if (mounted) msShowError(context, err);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final list = widget.live.data.tokens;
    return MsBody(listKey: const Key('ms-paired-apps-list'), children: [
      if (widget.live.refreshError != null) MsBanner('Not updated: ${widget.live.refreshError}'),
      const MsNote('Up to four apps can be paired with this radio. Pairing a fifth removes the oldest.'),
      if (list.isEmpty) const MsNote('No apps are paired.'),
      for (final e in list)
        Padding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, Gap.s),
          child: Material(
            color: t.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Corners.chip),
            // Text first, full width; Remove under it (a trailing button squeezed the name into a narrow column).
            child: Padding(
              key: Key('ms-token-${e.i}'),
              padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s + 2, Layout.screenMargin, Gap.xs),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: Gap.s, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(e.app, key: Key('ms-token-name-${e.i}'), style: t.textTheme.bodyLarge),
                  if (e.me)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 2),
                      decoration: BoxDecoration(color: t.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(999)),
                      child: Text('This app', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onPrimaryContainer)),
                    ),
                ]),
                const SizedBox(height: 2),
                Text(
                  [
                    _via(e.via),
                    if (e.created != null) 'Since ${tf.dateOnly(e.created)}',
                    if (e.seenS != null) 'Last seen ${msDuration(e.seenS)} ago',
                  ].join('\n'),
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
                TextButton.icon(
                  key: Key('ms-revoke-${e.i}'),
                  style: TextButton.styleFrom(
                      foregroundColor: t.colorScheme.error, minimumSize: Size(Hit.of(context), Hit.of(context)), padding: const EdgeInsets.symmetric(horizontal: 0)),
                  onPressed: _busy ? null : () => _revoke(e),
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  label: Text('Remove', semanticsLabel: 'Remove ${e.app}'),
                ),
              ]),
            ),
          ),
        ),
      const SizedBox(height: Gap.m),
      if (list.isNotEmpty)
        MsButton('Remove all', key: const Key('ms-revoke-all'), icon: Icons.delete_sweep_outlined, destructive: true, busy: _busy, onPressed: () => _revoke(null)),
    ]);
  }
}
