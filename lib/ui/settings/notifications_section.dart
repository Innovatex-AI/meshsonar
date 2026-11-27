// Settings > Messages, the alert rows (the section was "Notifications" until build 77; its first rows, delivery and the chat
// rows, are messages_section.dart). Honest about what is and is not possible:
//  * Alerts are LOCAL: the app builds them from messages its radio handed over. No server, no remote push.
//  * They only come while the radio is connected and the phone lets MeshSonar run. iOS may pause the app in the
//    background; whether the link survives that is still being measured (docs/BACKGROUND_BLE_SPIKE.md), so the words
//    here promise nothing beyond "open the app to catch up".
//  * Previews: message text is hidden on the lock screen by default (a lock screen is public). The setting turns it on.
//  * Build 77 (round 5): on iPhone there are no Sound or Quiet hours rows, the phone has them (per-app Sounds, Focus);
//    until notifications are allowed the switches that only shape an alert are greyed with "Allow notifications first".
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../../alerts/alert_prefs.dart';
import '../../alerts/alerts_runtime.dart';
import '../../chat/models.dart';
import '../../core/time_format.dart' as tf;
import '../../platform/local_notifications.dart';
import '../alerts/permission_prompt.dart';
import '../app.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import 'app_time_pick.dart';
import 'messages_section.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String notificationsHelp = 'Alerts for new messages, made on this phone. Nothing goes through a server.';

/// Under a switch that only shapes an alert, while the phone does not allow alerts yet.
const String allowNotificationsFirst = 'Allow notifications first.';

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
  final where = ios ? 'iOS Settings' : 'Android settings';
  if (!enabled) {
    return const AlertsStatus('Alerts are off', 'New messages are still saved and counted in the app, but no alert is shown.',
        Icons.notifications_off_outlined, AlertsStatusAction.none);
  }
  switch (permission) {
    case NotificationPermission.denied:
      return AlertsStatus('Notifications are blocked in $where',
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

/// Wording for the conversation's current notify mode. The end of a mute is said in the app's own time: "Muted until
/// 6:14 PM" today, "tomorrow 6:14 PM" the next day, the date after that (build 76 compared the day of the month only, so
/// a mute ending on the same date of another month read as today).
String notifyModeLabel(ConversationSummary c, DateTime now) {
  if (c.isMutedAt(now.millisecondsSinceEpoch)) {
    final until = c.mutedUntilMs;
    if (until == null) return 'Muted until you turn it back on';
    final end = DateTime.fromMillisecondsSinceEpoch(until);
    final clock = tf.timeOfDay(end);
    if (tf.sameDay(end, now)) return 'Muted until $clock';
    if (tf.sameDay(end, now.add(const Duration(days: 1)))) return 'Muted until tomorrow $clock';
    return 'Muted until ${tf.dateOnly(end, year: false)}, $clock';
  }
  return switch (c.notifyMode) {
    NotifyMode.all => 'All messages',
    NotifyMode.mentionsOnly => 'Only when you are mentioned',
    NotifyMode.muted => 'All messages', // a mute that has run out
  };
}

/// Quiet hours are a wall-clock window ("from 10:00 PM"), in the phone's own time whatever the Time zone setting.
String _hm(TimeOfDay t) {
  if (tf.use24HourClock) return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
}

/// The rows of Settings > Messages: delivery and the chat rows first, then the alerts.
List<Widget> notificationsSectionRows(BuildContext context) {
  return [
    ...messagesChatRows(context),
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
        // Sound, vibration, text and quiet hours only shape an alert the phone shows: live once it allows them.
        final allowed = c.permission == NotificationPermission.granted;
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
                secondary: const Icon(Icons.notifications_active_outlined),
                title: Text(settingsEntry('notif-enabled').title),
                subtitle: const Text('Off stops every alert. Messages are still saved.'),
                value: prefs.enabled,
                onChanged: (v) async {
                  await prefs.setEnabled(v);
                  if (v && context.mounted) await askForNotifications(context);
                },
              ),
            ),
            if (!prefs.systemSoundAndQuiet)
              SettingsAnchor(
                id: 'notif-sound',
                child: SwitchListTile(
                  key: const Key('notif-sound'),
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: Text(settingsEntry('notif-sound').title),
                  subtitle: allowed ? const Text('The system sound with an alert.') : const SettingsWhyNot(allowNotificationsFirst),
                  value: prefs.sound,
                  onChanged: allowed ? prefs.setSound : null,
                ),
              ),
            if ((defaultTargetPlatform == TargetPlatform.android))
              SettingsAnchor(
                id: 'notif-vibrate',
                child: SwitchListTile(
                  key: const Key('notif-vibrate'),
                  secondary: const Icon(Icons.vibration),
                  title: Text(settingsEntry('notif-vibrate').title),
                  subtitle: allowed ? const Text('Vibrate with an alert. iPhone haptics follow the system.') : const SettingsWhyNot(allowNotificationsFirst),
                  value: prefs.vibrate,
                  onChanged: allowed ? prefs.setVibrate : null,
                ),
              ),
            SettingsAnchor(
              id: 'notif-previews',
              child: SwitchListTile(
                key: const Key('notif-previews'),
                secondary: const Icon(Icons.visibility_outlined),
                title: Text(settingsEntry('notif-previews').title),
                subtitle: !allowed
                    ? const SettingsWhyNot(allowNotificationsFirst)
                    : Text(prefs.showText
                        ? 'On: alerts show who wrote and what, also on a locked screen.'
                        : 'Off: alerts say "New message", so a locked screen shows no words.'),
                value: prefs.showText,
                onChanged: allowed ? prefs.setShowText : null,
              ),
            ),
            if (!prefs.systemSoundAndQuiet) SettingsAnchor(id: 'notif-quiet', child: _QuietHoursTile(prefs, allowed: allowed)),
            SettingsAnchor(
              id: 'notif-conversations',
              child: ListTile(
                key: const Key('notif-conversations'),
                leading: const Icon(Icons.tune),
                title: Text(settingsEntry('notif-conversations').title),
                subtitle: const Text('Mute one, or hear only mentions.'),
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
                subtitle: const Text('One alert in 3 seconds. Lock the phone to see how it looks.'),
                onTap: () async {
                  await Future<void>.delayed(const Duration(seconds: 3));
                  final why = await c.sendTest();
                  if (context.mounted) showAppToast(context, why ?? 'Test notification sent.');
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
  final bool allowed;
  const _QuietHoursTile(this.prefs, {required this.allowed});

  Future<void> _pick(BuildContext context, bool start) async {
    final q = prefs.quiet;
    final minute = start ? q.startMinute : q.endMinute;
    final t = await showAppTimePicker(context, TimeOfDay(hour: minute ~/ 60, minute: minute % 60));
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
          secondary: const Icon(Icons.bedtime_outlined),
          title: Text(settingsEntry('notif-quiet').title),
          subtitle: !allowed
              ? const SettingsWhyNot(allowNotificationsFirst)
              : Text(q.enabled
                  ? 'From ${fmt(q.startMinute)} to ${fmt(q.endMinute)} alerts arrive without sound.'
                  : 'Alerts arrive without sound between the hours you pick.'),
          value: q.enabled,
          onChanged: allowed ? (v) => prefs.setQuiet(q.copyWith(enabled: v)) : null,
        ),
        if (q.enabled && allowed)
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

  Future<void> _choose(ConversationSummary c) async {
    final v = await showAppActionSheet<_Choice>(
      context,
      title: 'Alerts for ${c.title}',
      actions: [
        const AppAction('All messages', _Choice.all),
        if (c.kind == ConvKind.channel) const AppAction('Only when mentioned', _Choice.mentions),
        const AppAction('Mute for 1 hour', _Choice.mute1h),
        const AppAction('Mute for 8 hours', _Choice.mute8h),
        const AppAction('Mute for 24 hours', _Choice.mute24h),
        const AppAction('Mute until I turn it back on', _Choice.muteForever),
      ],
    );
    if (v != null) _apply(c, v);
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.runtime.coordinator.chat;
    final list = chat == null ? <ConversationSummary>[] : chat.conversations(includeEmpty: true).where((c) => !c.isSystem).toList();
    final now = widget.clock();
    Widget empty(String text, Key key) => Center(
          child: Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.forum_outlined, size: 40),
              const SizedBox(height: Gap.m),
              Text(text, key: key, textAlign: TextAlign.center),
            ]),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts per conversation')),
      body: SafeArea(
        child: chat == null
            ? empty('Chat is not set up yet. Connect your radio, then come back.', const Key('notif-no-chat'))
            : list.isEmpty
                ? empty('No conversations yet. Join a channel or message a contact in Chat.', const Key('notif-no-conversations'))
                : ListView(
                    padding: const EdgeInsets.only(bottom: Gap.xl),
                    children: [
                      for (final c in list)
                        ListTile(
                          key: Key('notif-conv-${c.key}'),
                          minTileHeight: 56,
                          // The state reads from the icon too: muted, mentions only, or everything.
                          leading: Icon(c.isMutedAt(now.millisecondsSinceEpoch)
                              ? Icons.notifications_off_outlined
                              : (c.notifyMode == NotifyMode.mentionsOnly ? Icons.alternate_email : Icons.notifications_outlined)),
                          title: Text(c.title),
                          subtitle: Text(notifyModeLabel(c, now)),
                          // The whole row opens the choices, not only the small button.
                          onTap: () => _choose(c),
                          trailing: IconButton(
                            key: Key('notif-conv-menu-${c.key}'),
                            tooltip: 'Alerts for ${c.title}',
                            icon: const AppSymbolIcon(AppSymbols.ellipsis),
                            onPressed: () => _choose(c),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}
