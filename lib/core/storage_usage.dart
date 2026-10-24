// Space accounting for Settings > Data & storage: how many bytes something uses on disk, and which drives can leave the
// phone without losing anything the server does not already have. Pure Dart: no Flutter imports.
import 'dart:io';

import 'api.dart';

/// Something stored on disk that can say how much space it uses (the drive store, the region cache).
abstract class StorageSized {
  /// Bytes on disk now. Never throws; 0 when nothing is stored.
  Future<int> bytesUsed();
}

/// Bytes in [entity]: a file's length, or the total of every file under a directory (only paths [where] accepts, when
/// given). 0 when it is missing or cannot be read. Never throws.
Future<int> bytesOnDisk(FileSystemEntity entity, {bool Function(String path)? where}) async {
  try {
    if (entity is File) {
      if (!await entity.exists()) return 0;
      return (where == null || where(entity.path)) ? await entity.length() : 0;
    }
    if (entity is Directory) {
      if (!await entity.exists()) return 0;
      var n = 0;
      await for (final e in entity.list(recursive: true, followLinks: false)) {
        if (e is! File || (where != null && !where(e.path))) continue;
        try {
          n += await e.length();
        } catch (_) {
          // a file removed while counting costs nothing
        }
      }
      return n;
    }
  } catch (_) {}
  return 0;
}

/// True when removing this drive from the phone loses nothing: it has ended, is not being recorded, and the server has
/// confirmed every ping (none waiting, none rejected, no rename waiting to be sent). An empty ended drive is also safe.
bool driveSafeToRemove(SessionSummary s, {String? recordingId}) =>
    s.session.id != recordingId &&
    s.session.endedAt != null &&
    !s.sessionResendPending &&
    s.rejectedCount == 0 &&
    s.unsyncedCount == 0 &&
    s.syncedCount >= s.pingCount;

/// The drives on the phone split into those that may be removed ([removable], ids) and those that must stay ([kept]):
/// still recording, waiting to upload, or holding pings the server rejected (which exist only on this phone).
class DriveStorageSplit {
  final List<String> removable;
  final int kept;

  /// Pings in the kept drives that the server does not have yet.
  final int keptUnsentPings;
  const DriveStorageSplit({required this.removable, required this.kept, required this.keptUnsentPings});

  int get total => removable.length + kept;
}

DriveStorageSplit splitDrives(List<SessionSummary> sessions, {String? recordingId}) {
  final removable = <String>[];
  var kept = 0, unsent = 0;
  for (final s in sessions) {
    if (driveSafeToRemove(s, recordingId: recordingId)) {
      removable.add(s.session.id);
    } else {
      kept++;
      unsent += s.unsyncedCount + s.rejectedCount;
    }
  }
  return DriveStorageSplit(removable: removable, kept: kept, keptUnsentPings: unsent);
}

/// "820 KB", "3.4 MB", "1.25 GB" (binary units, like the offline maps screen).
String formatStorageBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(b < 100 * 1024 * 1024 ? 1 : 0)} MB';
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
