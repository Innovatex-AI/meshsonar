// The local notification for a drive that ended on its own (battery plan §3 "End a drive left open"): "Drive ended: parked 30 min"
// / "Drive ended: no radio for 15 min". Goes through the app's one notification seam (AlertsHost -> LocalNotifications); never asks
// for permission (with none granted it simply does not show; the in-app message still does).
import '../alerts/alerts_runtime.dart';
import '../platform/local_notifications.dart';
import 'drive_power_governor.dart';

Future<void> postDriveAutoEndNotice(DriveAutoEnd end) async {
  final rt = AlertsHost.runtime.value;
  if (rt == null) return;
  try {
    await rt.coordinator.notifications.show(AlertNotification(
      id: notificationIdFor('drive-auto-end'),
      threadId: 'drive',
      title: 'MeshSonar',
      body: '${end.message}. The drive is saved.',
      payload: '',
    ));
  } catch (_) {}
}
