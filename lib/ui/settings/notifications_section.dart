// Settings > Notifications. Honest about what is and is not possible:
//  * Alerts are LOCAL: the app builds them from messages its radio handed over. No server, no remote push.
//  * They only come while the radio is connected and the phone lets MeshSonar run. iOS may pause the app in the
//    background; whether the link survives that is still being measured (docs/BACKGROUND_BLE_SPIKE.md), so the words
//    here promise nothing beyond "open the app to catch up".
//  * Previews: message text is hidden on the lock screen by default (a lock screen is public). The setting turns it on.
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../alerts/alert_prefs.dart';
import '../../alerts/alerts_runtime.dart';
import '../../chat/models.dart';
import '../../platform/local_notifications.dart';
import '../alerts/permission_prompt.dart';
import '../app.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String notificationsHelp = 'Alerts for new messages. They are built on this phone from messages your radio receives: '
    'nothing goes through a server.';

/// How the state is worded. Pure, so the copy is tested.
class AlertsStatus {
  final String headline;
  final String detail;
  final IconData icon;

  /// Which button belongs with it.
  final AlertsStatusAction action;
  const AlertsStatus(this.headline, this.detail, this.icon, this.action);
}

enum AlertsStatusAction { none, allow, openSystemSettings }

AlertsStatus describeAlertsStatus({
  required NotificationPermission permission,
  required bool enabled,
  required bool radioConnected,
  required bool ios,
}) {
  final system = ios ? 'iOS Settings' : 'Android settings';
  if (!enabled) {
    return const AlertsStatus('Alerts are off', 'New messages are still saved and counted in the app, but no alert is shown.',
        Icons.notifications_off_outlined, AlertsStatusAction.none);
  }
  switch (permission) {
    case NotificationPermission.denied:
      return AlertsStatus('Notifications are blocked in $system',
          'MeshSonar cannot show alerts until you allow them there. In the app you still see new messages and banners.',
          Icons.block, AlertsStatusAction.openSystemSettings);
    case NotificationPermission.restricted:
      return const AlertsStatus('Notifications are restricted on this device',
          'Screen Time or a device profile does not allow this app to show notifications. Only that setting can change it.',
          Icons.lock_outline, AlertsStatusAction.none);
    case NotificationPermission.notDetermined:
      return const AlertsStatus('Not allowed yet',
          'MeshSonar will ask the first time you send a message or join a channel, or you can allow it now.',
          Icons.notifications_none, AlertsStatusAction.allow);
    case NotificationPermission.granted:
      if (!radioConnected) {
        return const AlertsStatus('Allowed, but your radio is not connected',
            'You will not get messages while your radio is not connected. Your radio keeps about 16 waiting messages; '
                'MeshSonar collects them when it connects again.',
            Icons.bluetooth_disabled, AlertsStatusAction.none);
      }
      return const AlertsStatus('Allowed and your radio is connected',
          'iOS can pause MeshSonar when it is not in front, so alerts are not guaranteed. If one is missed, open the app: '
              'it collects what your radio kept.',
          Icons.notifications_active_outlined, AlertsStatusAction.none);
  }
}

/// Wording for the conversation's current notify mode.
String notifyModeLabel(ConversationSummary c, DateTime now) {
  if (c.isMutedAt(now.millisecondsSinceEpoch)) {
    final until = c.mutedUntilMs;
    if (until == null) return 'Muted until you turn it back on';
    final t = TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(until));
    final sameDay = DateTime.fromMillisecondsSinceEpoch(until).day == now.day;
    return 'Muted until ${sameDay ? '' : 'tomorrow '}${_hm(t)}';
  }
  return switch (c.notifyMode) {
    NotifyMode.all => 'All messages',
    NotifyMode.mentionsOnly => 'Only when you are mentioned',
    NotifyMode.muted => 'All messages', // a mute that has run out
  };
}

String _hm(TimeOfDay t) {
  final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
}

List<Widget> notificationsSectionRows(BuildContext context) {
  return [
    ValueListenableBuilder<AlertsRuntime?>(
      valueListenable: AlertsHost.runtime,
      builder: (context, rt, _) {
        if (rt == null) {
          return const ListTile(
            key: Key('notif-unavailable'),
            leading: Icon(Icons.notifications_off_outlined),
            title: Text('Alerts are not available in this build'),
          );
        }
        return _NotificationRows(rt);
      },
    ),
  ];
}

class _NotificationRows extends StatelessWidget {
  final AlertsRuntime rt;
  const _NotificationRows(this.rt);

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([rt.prefs, rt.coordinator, rt.queue, s]),
      builder: (context, _) {
        final prefs = rt.prefs;
        final c = rt.coordinator;
        final status = describeAlertsStatus(
          permission: c.permission,
          enabled: prefs.enabled,
          radioConnected: s.connected,
          ios: (defaultTargetPlatform == TargetPlatform.iOS),
        );
        return Column(
          children: [
            ListTile(
              key: const Key('notif-state'),
              leading: Icon(status.icon),
              title: Text(status.headline),
              subtitle: Text(status.detail),
              isThreeLine: true,
            ),
            if (status.action == AlertsStatusAction.allow)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: Gap.l, bottom: Gap.s),
                  child: FilledButton.tonal(
                    key: const Key('notif-allow'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => askForNotifications(context, force: true),
                    child: const Text('Allow notifications'),
                  ),
                ),
              ),
            if (status.action == AlertsStatusAction.openSystemSettings)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: Gap.l, bottom: Gap.s),
                  child: FilledButton.tonal(
                    key: const Key('notif-open-system'),
                    style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => c.notifications.openSystemSettings(),
                    child: Text((defaultTargetPlatform == TargetPlatform.iOS) ? 'Open iOS Settings' : 'Open settings'),
                  ),
                ),
              ),
            SettingsAnchor(
              id: 'notif-enabled',
              child: SwitchListTile(
                key: const Key('notif-enabled'),
                title: Text(settingsEntry('notif-enabled').title),
                subtitle: const Text('Turn off to stop every alert. Messages are still saved.'),
                value: prefs.enabled,
                onChanged: (v) async {
                  await prefs.setEnabled(v);
                  if (v && context.mounted) await askForNotifications(context);
                },
              ),
            ),
            SettingsAnchor(
              id: 'notif-sound',
              child: SwitchListTile(
                key: const Key('notif-sound'),
                title: Text(settingsEntry('notif-sound').title),
                subtitle: const Text('Play the system sound with an alert.'),
                value: prefs.sound,
                onChanged: prefs.setSound,
              ),
            ),
            if ((defaultTargetPlatform == TargetPlatform.android))
              SettingsAnchor(
                id: 'notif-vibrate',
                child: SwitchListTile(
                  key: const Key('notif-vibrate'),
                  title: Text(settingsEntry('notif-vibrate').title),
                  subtitle: const Text('Vibrate with an alert. iPhone haptics follow the system.'),
                  value: prefs.vibrate,
                  onChanged: prefs.setVibrate,
                ),
              ),
            SettingsAnchor(
              id: 'notif-previews',
              child: SwitchListTile(
                key: const Key('notif-previews'),
                title: Text(settingsEntry('notif-previews').title),
                subtitle: Text(prefs.showText
                    ? 'Alerts show who wrote and what they said, also on a locked screen.'
                    : 'Alerts show the conversation name and "New message". The words stay hidden on a locked screen. '
                        'Safer, because a lock screen can be read by anyone nearby.'),
                value: prefs.showText,
                onChanged: prefs.setShowText,
              ),
            ),
            SettingsAnchor(id: 'notif-quiet', child: _QuietHoursTile(prefs)),
            SettingsAnchor(
              id: 'notif-conversations',
              child: ListTile(
                key: const Key('notif-conversations'),
                leading: const Icon(Icons.tune),
                title: Text(settingsEntry('notif-conversations').title),
                subtitle: const Text('Mute a conversation, or hear only when you are mentioned. The wardrive channel never alerts.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ConversationAlertsScreen(rt))),
              ),
            ),
            SettingsAnchor(
              id: 'notif-test',
              child: ListTile(
                key: const Key('notif-test'),
                leading: const Icon(Icons.send_outlined),
                title: Text(settingsEntry('notif-test').title),
                subtitle: const Text('Shows one alert in 3 seconds. Lock the phone or leave the app to see how it looks.'),
                onTap: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  await Future<void>.delayed(const Duration(seconds: 3));
                  final why = await c.sendTest();
                  messenger?.showSnackBar(SnackBar(content: Text(why ?? 'Test notification sent.')));
                },
              ),
            ),
            if (rt.queue.message != null)
              ListTile(
                key: const Key('notif-queue'),
                leading: const Icon(Icons.warning_amber_rounded),
                title: const Text('Radio queue warning'),
                subtitle: Text(rt.queue.message!),
                trailing: TextButton(onPressed: rt.queue.dismiss, child: const Text('Dismiss')),
              ),
          ],
        );
      },
    );
  }
}

class _QuietHoursTile extends StatelessWidget {
  final AlertPrefs prefs;
  const _QuietHoursTile(this.prefs);

  Future<void> _pick(BuildContext context, bool start) async {
    final q = prefs.quiet;
    final minute = start ? q.startMinute : q.endMinute;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: minute ~/ 60, minute: minute % 60));
    if (t == null) return;
    final m = t.hour * 60 + t.minute;
    await prefs.setQuiet(start ? q.copyWith(startMinute: m) : q.copyWith(endMinute: m));
  }

  @override
  Widget build(BuildContext context) {
    final q = prefs.quiet;
    String fmt(int m) => _hm(TimeOfDay(hour: m ~/ 60, minute: m % 60));
    return Column(
      children: [
        SwitchListTile(
          key: const Key('notif-quiet'),
          title: Text(settingsEntry('notif-quiet').title),
          subtitle: Text(q.enabled
              ? 'From ${fmt(q.startMinute)} to ${fmt(q.endMinute)} alerts arrive without sound.'
              : 'Alerts still arrive, silently, between the hours you pick. Focus and Do Not Disturb always apply as well.'),
          value: q.enabled,
          onChanged: (v) => prefs.setQuiet(q.copyWith(enabled: v)),
        ),
        if (q.enabled)
          Padding(
            padding: const EdgeInsets.only(left: Gap.l, right: Gap.l, bottom: Gap.s),
            child: Wrap(
              spacing: Gap.m,
              runSpacing: Gap.s,
              children: [
                OutlinedButton(
                    key: const Key('notif-quiet-start'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => _pick(context, true),
                    child: Text('From ${fmt(q.startMinute)}')),
                OutlinedButton(
                    key: const Key('notif-quiet-end'),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => _pick(context, false),
                    child: Text('To ${fmt(q.endMinute)}')),
              ],
            ),
          ),
      ],
    );
  }
}

/// Per-conversation overrides: every conversation with its mode, changeable here.
class ConversationAlertsScreen extends StatefulWidget {
  final AlertsRuntime runtime;
  final DateTime Function() clock;
  const ConversationAlertsScreen(this.runtime, {super.key, this.clock = DateTime.now});
  @override
  State<ConversationAlertsScreen> createState() => _ConversationAlertsScreenState();
}

enum _Choice { all, mentions, mute1h, mute8h, mute24h, muteForever }

class _ConversationAlertsScreenState extends State<ConversationAlertsScreen> {
  void _apply(ConversationSummary c, _Choice v) {
    final chat = widget.runtime.coordinator.chat;
    if (chat == null) return;
    switch (v) {
      case _Choice.all:
        chat.setNotifyMode(c.radioId, c.key, NotifyMode.all);
      case _Choice.mentions:
        chat.setNotifyMode(c.radioId, c.key, NotifyMode.mentionsOnly);
      case _Choice.mute1h:
        chat.setNotifyMode(c.radioId, c.key, NotifyMode.muted, muteFor: const Duration(hours: 1));
      case _Choice.mute8h:
        chat.setNotifyMode(c.radioId, c.key, NotifyMode.muted, muteFor: const Duration(hours: 8));
      case _Choice.mute24h:
        chat.setNotifyMode(c.radioId, c.key, NotifyMode.muted, muteFor: const Duration(hours: 24));
      case _Choice.muteForever:
        chat.setNotifyMode(c.radioId, c.key, NotifyMode.muted);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.runtime.coordinator.chat;
    final list = chat == null ? <ConversationSummary>[] : chat.conversations(includeEmpty: true).where((c) => !c.isSystem).toList();
    final now = widget.clock();
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts per conversation')),
      body: chat == null
          ? const Center(child: Padding(padding: EdgeInsets.all(Gap.xl), child: Text('Chat is not set up yet.', key: Key('notif-no-chat'))))
          : list.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(Gap.xl), child: Text('No conversations yet.', key: Key('notif-no-conversations'))))
              : ListView(
                  children: [
                    for (final c in list)
                      ListTile(
                        key: Key('notif-conv-${c.key}'),
                        title: Text(c.title),
                        subtitle: Text(notifyModeLabel(c, now)),
                        trailing: PopupMenuButton<_Choice>(
                          key: Key('notif-conv-menu-${c.key}'),
                          tooltip: 'Alerts for ${c.title}',
                          onSelected: (v) => _apply(c, v),
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: _Choice.all, child: Text('All messages')),
                            if (c.kind == ConvKind.channel) const PopupMenuItem(value: _Choice.mentions, child: Text('Only when mentioned')),
                            const PopupMenuItem(value: _Choice.mute1h, child: Text('Mute for 1 hour')),
                            const PopupMenuItem(value: _Choice.mute8h, child: Text('Mute for 8 hours')),
                            const PopupMenuItem(value: _Choice.mute24h, child: Text('Mute for 24 hours')),
                            const PopupMenuItem(value: _Choice.muteForever, child: Text('Mute until I turn it back on')),
                          ],
                        ),
                      ),
                  ],
                ),
    );
  }
}
