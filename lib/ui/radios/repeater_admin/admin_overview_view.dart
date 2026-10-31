// Dashboard: who this is, how it is doing, whether its clock is right, a health check with plain-language findings, and the
// advert buttons. Reads only; the one write here is "Sync clock" (confirmed).
import 'package:flutter/material.dart';

import '../../../radio/repeater_admin.dart';
import '../../../radio/repeater_health.dart';
import '../../claims/claim_widgets.dart' show ClaimRepeaterAction;
import '../../theme.dart';
import 'admin_common.dart';
import 'admin_controller.dart';

class AdminOverviewView extends StatelessWidget {
  final RepeaterAdminController controller;
  final String keyHex;
  const AdminOverviewView({super.key, required this.controller, required this.keyHex});

  RepeaterAdminController get c => controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.snapshot;
        return RefreshIndicator(
          onRefresh: c.refreshOverview,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                key: const Key('admin-overview'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                children: [
                  if (c.notices['overview'] != null) NoticeBanner(c.notices['overview']!, bannerKey: const Key('overview-notice')),
                  if (!c.isAdmin) NoticeBanner(const AdminNotice('Logged in as a guest: you can read status, but settings, the access list and the console need the admin password.', error: false), bannerKey: const Key('guest-note')),
                  _identity(context, s),
                  if (c.loadingOverview && s == null) _loading(context) else ...[
                    _status(context, s),
                    _clock(context, s),
                  ],
                  _health(context),
                  if (c.isAdmin) _adverts(context),
                  ClaimRepeaterAction(keyHex: keyHex, name: s?.identity.name ?? c.title, isRoom: c.isRoom),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _loading(BuildContext context) => Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(children: [
          const CircularProgressIndicator(key: Key('overview-loading')),
          const SizedBox(height: Gap.m),
          Text('Reading ${c.overviewStep ?? 'the repeater'}', textAlign: TextAlign.center),
        ]),
      );

  Widget _identity(BuildContext context, RepeaterSnapshot? s) {
    final t = Theme.of(context);
    final id = s?.identity;
    final heard = c.lastAdvertEpoch;
    final nowSecs = c.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    return AdminCard(
      cardKey: const Key('card-identity'),
      title: id?.name ?? c.title,
      icon: c.isRoom ? Icons.forum_outlined : Icons.cell_tower,
      trailing: IconButton(
        key: const Key('overview-refresh'),
        tooltip: 'Refresh',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: c.loadingOverview ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
        onPressed: c.loadingOverview ? null : c.refreshOverview,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        KeyValueRow('Role', id?.role ?? (c.isRoom ? 'room' : 'repeater')),
        if (id?.firmware != null) KeyValueRow('Firmware', id!.firmware!, valueKey: const Key('v-firmware')),
        if (id?.board != null) KeyValueRow('Board', id!.board!),
        KeyValueRow('Key', '${keyHex.substring(0, 12)}...'),
        KeyValueRow('Last advert you heard', heard == null || heard == 0 ? 'not heard yet' : agoText(nowSecs - heard)),
        if (id?.isObserverBuild ?? false)
          Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text('Observer firmware: it also sends what it hears to the internet.', style: t.textTheme.bodySmall)),
      ]),
    );
  }

  Widget _status(BuildContext context, RepeaterSnapshot? s) {
    final st = s?.stats;
    if (st == null) {
      return AdminCard(title: 'Status', icon: Icons.monitor_heart_outlined, child: Text(c.loadingOverview ? 'Reading...' : 'No status yet. Pull down to read it.'));
    }
    final volts = s!.telemetry?.voltageV ?? st.batteryV;
    final airPct = st.upTimeSecs > 0 ? (st.airTimeSecs * 100 / st.upTimeSecs) : 0.0;
    return AdminCard(
      cardKey: const Key('card-status'),
      title: 'Status',
      icon: Icons.monitor_heart_outlined,
      child: Column(children: [
        KeyValueRow('Battery', '${volts.toStringAsFixed(2)} V', valueKey: const Key('v-battery')),
        if (s.telemetry?.temperatureC != null) KeyValueRow('Chip temperature', '${s.telemetry!.temperatureC!.toStringAsFixed(1)} °C'),
        KeyValueRow('Up for', uptimeText(st.upTimeSecs), valueKey: const Key('v-uptime')),
        KeyValueRow('Noise floor', '${st.noiseFloorDbm} dBm', valueKey: const Key('v-noise')),
        KeyValueRow('Time on air (sending)', '${secondsText(st.airTimeSecs)} (${airPct.toStringAsFixed(2)}% of its uptime)'),
        KeyValueRow('Time on air (listening)', secondsText(st.rxAirTimeSecs)),
        KeyValueRow('Packets', '${st.packetsRecv} received, ${st.packetsSent} sent'),
        KeyValueRow('Floods and direct', '${st.recvFlood} / ${st.recvDirect} received, ${st.sentFlood} / ${st.sentDirect} sent'),
        KeyValueRow('Errors', '${st.recvErrors} bad packets, ${st.errEvents} radio events'),
        KeyValueRow('Duplicates dropped', '${st.floodDups + st.directDups}'),
        KeyValueRow('Last packet it heard', '${st.lastSnrDb.toStringAsFixed(1)} dB SNR, ${st.lastRssiDbm} dBm'),
        KeyValueRow('Waiting to send', '${st.txQueueLen}'),
      ]),
    );
  }

  Widget _clock(BuildContext context, RepeaterSnapshot? s) {
    final ck = s?.clock;
    if (ck == null) return const SizedBox.shrink();
    final skew = ck.skewSecs;
    final off = skew.abs();
    final t = Theme.of(context);
    final bad = off > 60;
    return AdminCard(
      cardKey: const Key('card-clock'),
      title: 'Clock',
      icon: Icons.schedule,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        KeyValueRow('Compared with your phone', off <= 2 ? 'Right (within 2 s)' : '${off >= 120 ? uptimeText(off) : '${off}s'} ${skew > 0 ? 'ahead' : 'behind'}',
            valueKey: const Key('v-skew'), valueColor: bad ? t.colorScheme.error : null),
        if (bad && skew < 0)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const Key('sync-clock'),
              style: FilledButton.styleFrom(minimumSize: kTarget),
              icon: const Icon(Icons.sync),
              label: const Text('Sync clock'),
              onPressed: c.isAdmin ? () => _syncClock(context) : null,
            ),
          ),
        if (bad && skew > 0) Text('A repeater never sets its clock backwards, so it cannot be fixed from here.', style: t.textTheme.bodySmall),
        if (bad && skew < 0 && !c.isAdmin) Text('Syncing needs the admin password.', style: t.textTheme.bodySmall),
      ]),
    );
  }

  Future<void> _syncClock(BuildContext context) async {
    final ok = await confirmAction(context,
        title: 'Set the repeater\'s clock?',
        body: 'The repeater\'s clock is set to your radio\'s time (your phone sets your radio\'s clock when it connects). It only ever moves forward. The change is read back afterwards.',
        confirmLabel: 'Sync clock',
        confirmKey: const Key('sync-clock-confirm'));
    if (!ok || !context.mounted) return;
    try {
      final r = await c.syncClock();
      if (context.mounted) showSnack(context, r.ok ? 'Clock set.' : r.message);
    } on AdminException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }

  Widget _health(BuildContext context) {
    final t = Theme.of(context);
    final f = c.findings;
    final w = worst(f);
    final look = severityLook(context, w);
    return AdminCard(
      cardKey: const Key('card-health'),
      title: 'Health check',
      icon: Icons.health_and_safety_outlined,
      trailing: f.isEmpty ? null : Semantics(label: 'Overall: ${look.word}', excludeSemantics: true, child: Icon(look.icon, color: look.color)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          c.isAdmin
              ? 'Checks the clock, radio settings against this region, power, adverts, neighbours and (for observers) the uplink. It reads about 15 values and never changes anything.'
              : 'Checks what a guest can read: the clock, battery and noise. Log in as admin for the full check.',
          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: Gap.s),
        FilledButton.tonalIcon(
          key: const Key('run-health'),
          style: FilledButton.styleFrom(minimumSize: kTarget),
          onPressed: c.checkingHealth ? null : c.runHealthCheck,
          icon: c.checkingHealth ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
          label: Text(c.checkingHealth ? 'Checking ${c.healthStep ?? ''}...' : (f.isEmpty ? 'Run health check' : 'Check again')),
        ),
        if (f.isEmpty && !c.checkingHealth) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('Not run yet.', style: t.textTheme.bodySmall)),
        for (final x in f) _finding(context, x),
        if (f.isNotEmpty) Padding(padding: const EdgeInsets.only(top: Gap.s), child: Text('Suggestions are never applied for you.', style: t.textTheme.bodySmall)),
      ]),
    );
  }

  Widget _finding(BuildContext context, HealthFinding x) {
    final t = Theme.of(context);
    final look = severityLook(context, x.severity);
    return Semantics(
      container: true,
      label: '${look.word}: ${x.title}. ${x.detail}${x.fix == null ? '' : ' Suggestion: ${x.fix}'}',
      excludeSemantics: true,
      child: Padding(
        key: Key('finding-${x.id}'),
        padding: const EdgeInsets.only(top: Gap.m),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(look.icon, color: look.color, size: 22),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(x.title, style: t.textTheme.titleSmall),
              Text(x.detail, style: t.textTheme.bodyMedium?.copyWith(height: 1.3)),
              if (x.fix != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text('What to do: ${x.fix}', style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.3))),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _adverts(BuildContext context) {
    final t = Theme.of(context);
    return AdminCard(
      cardKey: const Key('card-adverts'),
      title: 'Adverts',
      icon: Icons.campaign_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('An advert tells other radios this repeater exists. A flood advert travels the whole mesh and uses airtime on every repeater that passes it on (about 0.35 s each). A local advert only reaches direct neighbours.',
            style: t.textTheme.bodyMedium?.copyWith(height: 1.3)),
        const SizedBox(height: Gap.s),
        Wrap(spacing: Gap.m, runSpacing: Gap.s, children: [
          FilledButton.tonalIcon(
            key: const Key('advert-flood'),
            style: FilledButton.styleFrom(minimumSize: kTarget),
            icon: const Icon(Icons.public),
            label: const Text('Send flood advert'),
            onPressed: () => _advert(context, flood: true),
          ),
          FilledButton.tonalIcon(
            key: const Key('advert-local'),
            style: FilledButton.styleFrom(minimumSize: kTarget),
            icon: const Icon(Icons.near_me_outlined),
            label: const Text('Send local advert'),
            onPressed: () => _advert(context, flood: false),
          ),
        ]),
      ]),
    );
  }

  Future<void> _advert(BuildContext context, {required bool flood}) async {
    final ok = await confirmAction(context,
        title: flood ? 'Send a flood advert?' : 'Send a local advert?',
        body: flood
            ? 'The whole mesh will hear it and every repeater that passes it on uses airtime (about 0.35 s each). You can send one every 30 seconds.'
            : 'Only radios that hear this repeater directly will get it. You can send one every 30 seconds.',
        confirmLabel: 'Send',
        confirmKey: const Key('advert-confirm'));
    if (!ok || !context.mounted) return;
    try {
      final r = await (flood ? c.sendAdvert(flood: true) : c.sendAdvert(flood: false));
      if (context.mounted) showSnack(context, r.ok ? 'Advert sent.' : r.message);
    } on AdminException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    }
  }
}
