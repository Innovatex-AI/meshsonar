// Every drive stored on this phone with its pings, read from the drive store (the progress dashboard and the
// repeater "Your drives" sections both need all of them). Oldest first. Reads one drive at a time; a drive that
// cannot be read is skipped and counted, never fatal, so one damaged file does not hide the rest.
import '../../core/api.dart';
import '../../core/model.dart';

class LocalDrives {
  final List<(DriveSession, List<DrivePing>)> drives;

  /// Drives listed by the store whose pings could not be read.
  final int unreadable;
  const LocalDrives(this.drives, {this.unreadable = 0});
}

Future<LocalDrives> loadLocalDrives(DriveStore store) async {
  final out = <(DriveSession, List<DrivePing>)>[];
  var bad = 0;
  for (final x in await store.sessions()) {
    try {
      out.add((x.session, await store.pings(x.session.id)));
    } catch (_) {
      bad++;
    }
  }
  out.sort((a, b) => a.$1.startedAt.compareTo(b.$1.startedAt));
  return LocalDrives(out, unreadable: bad);
}
