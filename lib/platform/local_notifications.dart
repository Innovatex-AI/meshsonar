// The seam for OS notifications. Everything above this file (lib/alerts, the Settings screen) talks to
// [LocalNotifications]; only local_notifications_plugin.dart knows flutter_local_notifications, so tests use a fake.
//
// Notifications here are LOCAL only: the app builds them itself from messages the radio handed over. There is no server,
// no push token and no remote push (design doc, product rule): chat never leaves the phone.

/// What iOS/Android let this app do right now.
enum NotificationPermission {
  /// Never asked (iOS) or not yet known. The app has not shown the system prompt.
  notDetermined,

  /// Allowed. Alerts can be shown.
  granted,

  /// The person said no (iOS) or turned the app's notifications off in system settings. Only the system settings can
  /// change this; the app cannot ask again.
  denied,

  /// The device or its owner forbids it (parental controls / managed device); not something the person can change here.
  restricted,
}

/// One notification, already decided: the policy (modes, previews, quiet hours) lives in AlertCoordinator, not here.
class AlertNotification {
  /// Stable per conversation, so a new message replaces the previous banner of that conversation instead of stacking.
  final int id;

  /// Groups notifications of one conversation (iOS threadIdentifier, Android group key). The conversation key.
  final String threadId;
  final String title;
  final String body;

  /// Handed back when the notification is tapped ([LocalNotifications.onTap]). The conversation key, nothing else:
  /// no message text ever goes into a payload.
  final String payload;

  /// No sound (quiet hours, or the person turned sound off).
  final bool silent;

  /// How many unread conversations the badge shows after this notification (iOS app icon badge).
  final int badge;

  /// Android only: also vibrate.
  final bool vibrate;
  const AlertNotification({
    required this.id,
    required this.threadId,
    required this.title,
    required this.body,
    required this.payload,
    this.silent = false,
    this.badge = 0,
    this.vibrate = false,
  });
}

abstract class LocalNotifications {
  /// Prepares the plugin. Must NOT trigger any permission prompt. [onTap] gets the payload of a tapped notification
  /// (the conversation key) while the app runs. Safe to call more than once.
  Future<void> init({required void Function(String payload) onTap});

  /// Payload of the notification that launched the app from killed, or null. Read once at start.
  Future<String?> launchPayload();

  /// Current state, without asking.
  Future<NotificationPermission> permission();

  /// Shows the system prompt (iOS), or the Android 13+ runtime permission. Returns the state afterwards. Call only from
  /// a moment the person chose (first send, first join, the Settings switch), after our own explanation.
  Future<NotificationPermission> requestPermission();

  Future<void> show(AlertNotification n);

  /// Removes the delivered notification(s) of one conversation (the person read it in the app).
  Future<void> cancelConversation(int id);
  Future<void> cancelAll();

  /// The app icon badge (iOS) / launcher count where supported.
  Future<void> setBadge(int count);

  /// Opens this app's page in the system Settings. False when the platform cannot.
  Future<bool> openSystemSettings();
}

/// A stable positive 31-bit id for a conversation key (FNV-1a), so the same conversation always maps to the same
/// notification slot. Never 0 (Android foreground services forbid 0) and never the reserved service id.
int notificationIdFor(String convKey) {
  var h = 0x811c9dc5;
  for (final u in convKey.codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0x7fffffff;
  }
  final id = h & 0x3fffffff;
  return id < 10 ? id + 10 : id;
}

/// Reserved ids (below 10): the Android foreground-service notification.
const int foregroundServiceNotificationId = 1;

/// Does nothing: the default where no real notifications exist (widget tests, platforms without a plugin). Permission
/// reads as never asked and the request is refused, so the Settings screen shows its honest "not allowed" states.
class UnavailableLocalNotifications implements LocalNotifications {
  const UnavailableLocalNotifications();
  @override
  Future<void> init({required void Function(String payload) onTap}) async {}
  @override
  Future<String?> launchPayload() async => null;
  @override
  Future<NotificationPermission> permission() async => NotificationPermission.notDetermined;
  @override
  Future<NotificationPermission> requestPermission() async => NotificationPermission.denied;
  @override
  Future<void> show(AlertNotification n) async {}
  @override
  Future<void> cancelConversation(int id) async {}
  @override
  Future<void> cancelAll() async {}
  @override
  Future<void> setBadge(int count) async {}
  @override
  Future<bool> openSystemSettings() async => false;
}
