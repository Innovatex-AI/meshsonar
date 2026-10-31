import 'package:meshsonar/platform/local_notifications.dart';

class FakeLocalNotifications implements LocalNotifications {
  NotificationPermission state;

  /// What the system prompt answers.
  NotificationPermission promptResult;
  final shown = <AlertNotification>[];
  final cancelled = <int>[];
  final badges = <int>[];
  int requests = 0;
  int initCalls = 0;
  bool settingsOpened = false;
  String? launch;
  void Function(String payload)? onTap;

  FakeLocalNotifications({this.state = NotificationPermission.notDetermined, this.promptResult = NotificationPermission.granted});

  @override
  Future<void> init({required void Function(String payload) onTap}) async {
    initCalls++;
    this.onTap = onTap;
  }

  @override
  Future<String?> launchPayload() async => launch;

  /// Like the real plugin on iOS: it reports granted or "not determined", never "denied".
  @override
  Future<NotificationPermission> permission() async => state == NotificationPermission.granted ? state : (state == NotificationPermission.restricted ? state : NotificationPermission.notDetermined);

  @override
  Future<NotificationPermission> requestPermission() async {
    requests++;
    state = promptResult;
    return promptResult;
  }

  @override
  Future<void> show(AlertNotification n) async => shown.add(n);

  @override
  Future<void> cancelConversation(int id) async => cancelled.add(id);

  @override
  Future<void> cancelAll() async => shown.clear();

  @override
  Future<void> setBadge(int count) async => badges.add(count);

  @override
  Future<bool> openSystemSettings() async => settingsOpened = true;
}
