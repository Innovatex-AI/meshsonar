// Every MeshTrack sentence the screens show, as pure functions (meshtrack plan sections 5-8), so the copy is tested in one
// place. Plain words only: MeshTrack, group, share / sharing, position, last heard, meet-up point, Where are you?. Distances
// and speeds go through Units.
import '../../core/heard.dart' show compass;
import '../../core/meshtrack/meshtrack_service.dart';
import '../../core/meshtrack/mt_wire.dart';
import '../../core/meshtrack/smart_beacon.dart' show bearingDeg;
import '../../core/privacy_zones.dart' show distanceM;
import '../../core/units.dart';

/// A position on the phone (my own fix) or of a friend.
typedef MtLatLon = ({double lat, double lon});

/// Every MeshTrack control is at least this tall and wide (48 pt, the larger of the app's two target sizes).
const double kMtHit = 48;

const String mtFeatureName = 'MeshTrack';

/// The one-time disclosure the first time sharing is turned on (plan section 7, exact text).
const String mtIntroTitle = 'MeshTrack';
const String mtIntroBody = 'See your friends on the map while you drive. Your position goes over your group\'s private channel, '
    'encrypted with its key. Only people with the group link can read it, and MeshSonar\'s servers never get it. It is sent '
    'only while you share, for the time you choose, and never inside your privacy zones. Like any message you send, the mesh '
    'can tell roughly which repeaters carried it.';

/// Footer under a group's people list (U5).
const String mtRosterFooter =
    'Anyone with the group link can see positions shared here. To remove someone, start a new group and invite again.';

/// Under the groups list (5.5).
const String mtGroupsFooter = 'Anyone with the invite can see the group. To remove someone, start a fresh group.';

const String mtPeopleEmpty = 'No one has shared yet. Invite friends with the group link.';
const String mtNoGroupsTitle = 'No groups yet';
const String mtNoGroupsBody = 'A group is a private channel you share with friends. Make one and invite them, or join theirs.';
const String mtUpToThree = 'Up to 3 groups';
const String mtNotOnRadio = 'Not on this radio: it has no room for another channel';
const String mtMakeRoom = 'Make room';
const String mtRadioDisconnectedStop = 'Stopped sharing: radio disconnected';
const String mtShareAgain = 'Share again';
const String mtAirtimeSlower = 'Sharing slower: airtime limit';
const String mtAsked = 'Asked';
const String mtWhereAreYou = 'Where are you?';

/// "Joined Saturday crew. They show on your map when they share."
String mtJoinedBanner(String name) => 'Joined $name. They show on your map when they share.';

/// "Sam asked where you are".
String mtAskedToast(String name) => '$name asked where you are';

/// "Stopped sharing with Club".
String mtStoppedSharingWith(String name) => 'Stopped sharing with $name';

/// "Andy's crew" from my radio name, kept under the radio's 31-byte channel-name limit.
String mtDefaultGroupName(String? selfName) {
  final me = (selfName ?? '').trim();
  if (me.isEmpty) return 'My crew';
  const suffix = '\'s crew';
  var n = me;
  while (n.isNotEmpty && _bytes('$n$suffix') > 31) {
    n = n.substring(0, n.length - 1).trimRight();
  }
  return n.isEmpty ? 'My crew' : '$n$suffix';
}

int _bytes(String s) {
  var b = 0;
  for (final r in s.runes) {
    b += r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
  }
  return b;
}

// ------------------------------------------------------------------------------------------------ Drive chip

/// Names on the chip: all of them when they fit ("Family, Club"), else the first and a count ("Family +1").
String mtChipNames(List<String> names, {int maxChars = 16}) {
  if (names.isEmpty) return '';
  final all = names.join(', ');
  if (names.length == 1 || all.length <= maxChars) return all;
  return '${names.first} +${names.length - 1}';
}

enum MtChipTone { idle, sharing, paused }

/// What the Drive chip says and how it looks. Always visible while sharing so nobody shares by accident.
({String label, MtChipTone tone}) mtChip(MeshTrackState s) {
  if (!s.sharing) return (label: mtFeatureName, tone: MtChipTone.idle);
  final names = mtChipNames(s.sharingNames);
  return switch (s.reason) {
    MtShareReason.privacyZone => (label: 'Sharing paused: privacy zone', tone: MtChipTone.paused),
    MtShareReason.zonesNotLoaded => (label: 'Sharing paused: loading zones', tone: MtChipTone.paused),
    MtShareReason.waitingForGps => (label: 'Waiting for GPS', tone: MtChipTone.paused),
    MtShareReason.radioDisconnected => (label: 'Sharing paused: no radio', tone: MtChipTone.paused),
    MtShareReason.waitingForDrive => (label: 'Sharing starts with your drive', tone: MtChipTone.paused),
    MtShareReason.sharing || MtShareReason.airtimeLimit || MtShareReason.off => (label: 'Sharing: $names', tone: MtChipTone.sharing),
  };
}

/// Screen-reader label of the chip: what it says and what a tap does.
String mtChipSemantics(MeshTrackState s) {
  final c = mtChip(s);
  final names = s.sharingNames.join(', ');
  final what = c.tone == MtChipTone.idle ? mtFeatureName : '${c.label}${s.sharingNames.length > 1 ? '. Groups: $names' : ''}';
  return '$what. Opens your groups';
}

// ------------------------------------------------------------------------------------------------ Drive panel row

/// The Drive panel's MeshTrack row subtitle with no group yet.
const String mtPanelNoGroup = 'Share your position with friends';

/// The row subtitle without a radio (not sharing).
const String mtPanelNoRadio = 'Connect your radio to share';

/// The "New" tag on the row, shown once per install from the first drive until the row is opened.
const String mtPanelNewTag = 'New';

/// Friends heard in the last 30 min over all groups (a person in two groups counts in both).
int mtFriendsNearby(MeshTrackState s) => s.groups.fold(0, (n, g) => n + g.heardLast30Min);

/// What the Drive panel's MeshTrack row says under its title, and its tone (the dot). Sharing states are the chip's words
/// ("Sharing: Family, Club", "Sharing paused: privacy zone", "Waiting for GPS"); not sharing, it says what one tap gets.
({String text, MtChipTone tone}) mtPanelLine(MeshTrackState s) {
  if (s.sharing) {
    final c = mtChip(s);
    return (text: c.label, tone: c.tone);
  }
  if (!s.radioConnected) return (text: mtPanelNoRadio, tone: MtChipTone.idle);
  if (s.groups.isEmpty) return (text: mtPanelNoGroup, tone: MtChipTone.idle);
  final n = mtFriendsNearby(s);
  if (n > 0) return (text: '$n ${n == 1 ? 'friend' : 'friends'} nearby', tone: MtChipTone.idle);
  if (s.groups.length == 1) return (text: 'Not sharing with ${s.groups.first.name}', tone: MtChipTone.idle);
  return (text: '${s.groups.length} groups, not sharing', tone: MtChipTone.idle);
}

/// Screen-reader label of the panel row (and the Dock button): what it says and what a tap does.
String mtPanelSemantics(MeshTrackState s, {bool isNew = false}) {
  final line = mtPanelLine(s).text;
  final names = s.sharingNames.length > 1 ? '. Groups: ${s.sharingNames.join(', ')}' : '';
  return '$mtFeatureName${isNew ? ', new' : ''}. $line$names. Opens your groups';
}

/// The Share switch label on the row when there is exactly one group.
String mtPanelShareLabel(MtGroupView g) => 'Share my position with ${g.name}';

// ------------------------------------------------------------------------------------------------ Chats card

const String mtChatCardTitle = mtFeatureName;
const String mtChatCardBody = 'See friends on the map. Make a group or join one.';

/// The Chats card subtitle once there are groups ("Family, Club. Sharing with Family").
String mtChatCardLine(MeshTrackState s) {
  if (s.groups.isEmpty) return mtChatCardBody;
  final names = mtChipNames([for (final g in s.groups) g.name], maxChars: 28);
  if (!s.sharing) return '$names. See them on the Drive map.';
  return '$names. ${mtChip(s).label}.';
}

/// The New chat sheet entry.
const String mtNewGroupEntry = 'New MeshTrack group';
const String mtNewGroupEntryBody = 'A private channel for friends to see each other on the Drive map';

// ------------------------------------------------------------------------------------------------ sheet header

/// The status line at the top of the Group sheet; null when not sharing.
String? mtStatusLine(MeshTrackState s) {
  if (!s.sharing) return null;
  final n = s.sharingCount;
  final every = n * (s.rate == MtRate.lowTraffic ? 2 : 1);
  final updates = every == 1 ? 'updates about every minute at highway speed' : 'updates about every $every min at highway speed';
  return switch (s.reason) {
    MtShareReason.airtimeLimit => mtAirtimeSlower,
    MtShareReason.privacyZone => 'Sharing paused: you are in or near a privacy zone. Nothing is sent there.',
    MtShareReason.zonesNotLoaded => 'Sharing paused until your privacy zones are loaded.',
    MtShareReason.waitingForGps => 'Waiting for GPS. Your position goes out when the phone has a good fix.',
    MtShareReason.radioDisconnected => 'Radio not connected. Sharing stops if it is gone for 5 min.',
    MtShareReason.waitingForDrive => 'Sharing starts when you start a drive.',
    _ => n == 1 ? 'Sharing with ${s.sharingNames.first}: $updates.' : 'Sharing with $n groups: $updates.',
  };
}

String mtDurationLabel(MtShareDuration d) => switch (d) {
      MtShareDuration.thisDrive => 'This drive',
      MtShareDuration.oneHour => '1 hour',
      MtShareDuration.untilStopped => 'Until I stop',
    };

/// "3 heard in the last 30 min".
String mtHeardLine(MtGroupView g) {
  if (!g.config.see) return 'See is off';
  final n = g.heardLast30Min;
  return n == 0 ? 'No one heard in the last 30 min' : '$n heard in the last 30 min';
}

/// What a group's Share line says under its switches ("Until 3:40 PM", "This drive").
String mtShareDetail(MtGroupView g, DateTime now) {
  final c = g.config;
  if (!c.share) return c.shareEveryDrive ? 'Shares on every drive' : 'Not sharing';
  if (c.duration == MtShareDuration.oneHour && c.shareUntil != null) {
    final left = c.shareUntil!.difference(now);
    final m = left.inMinutes.clamp(0, 60);
    return 'Sharing for $m more min';
  }
  return c.duration == MtShareDuration.thisDrive ? 'Sharing this drive' : 'Sharing until you stop';
}

// ------------------------------------------------------------------------------------------------ people rows

/// "just now", "4 min ago", "2 h ago".
String mtAgo(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

/// "3.4 km NE" from me to them, or null when my position is unknown.
String? mtDistanceAndPoint(MtLatLon? me, double lat, double lon, Units units) {
  if (me == null) return null;
  final d = distanceM(me.lat, me.lon, lat, lon);
  if (d < 20) return 'here';
  final b = bearingDeg(me.lat, me.lon, lat, lon);
  return '${units.distance(d)} ${compass(b)}';
}

/// "direct · SNR 6.5 dB" / "via 2 repeaters · SNR -3.0 dB".
String? mtSignal(MtFriend f) {
  final route = switch (f.pathLen) {
    null => null,
    0 => 'direct',
    1 => 'via 1 repeater',
    final n => 'via $n repeaters',
  };
  final snr = f.snr == null ? null : 'SNR ${f.snr!.toStringAsFixed(1)} dB';
  final parts = [?route, ?snr];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Speed when moving (5 km/h or more), through Units.
String? mtSpeed(MtFriend f, Units units) {
  final v = f.speedKmh;
  if (v == null || v < 5 || f.parked || f.stopped) return null;
  return units.speed(v * 1000 / 3600);
}

/// What is special about this person right now ("Parked", "Stopped sharing", "Position jumped", "Typed position").
List<String> mtFriendNotes(MtFriend f) => [
      if (f.stopped) 'Stopped sharing',
      if (f.parked && !f.stopped) 'Parked',
      if (f.jumped) 'Position jumped',
      if (f.typed) 'Typed position',
      if (f.source == MtSource.team) 'From MeshCore-TEAM',
      if (!f.onMap) 'Not on the map',
    ];

/// A " · " list for display: each part keeps its words together (no break inside "0.7 mi W" or "25 mph"), lines
/// wrap only between parts.
String mtKeepTogether(String line) => line.split(' · ').map((p) => p.replaceAll(' ', '\u00A0')).join(' · ');

/// The two lines under a name, and the full screen-reader label.
({String line1, String? line2, String semantics}) mtFriendLines(MtFriend f, {required MtLatLon? me, required Units units, required DateTime now}) {
  final ago = mtAgo(f.lastHeard, now);
  final where = mtDistanceAndPoint(me, f.lat, f.lon, units);
  final line1 = [ago, ?where].join(' · ');
  final second = [?mtSignal(f), ?mtSpeed(f, units), ...mtFriendNotes(f)];
  final line2 = second.isEmpty ? null : second.join(' · ');
  final sem = StringBuffer('${f.name}, last heard $ago');
  if (where != null) sem.write(', ${where == 'here' ? 'right here' : where}');
  if (line2 != null) sem.write(', $line2');
  return (line1: line1, line2: line2, semantics: sem.toString());
}

// ------------------------------------------------------------------------------------------------ results

/// What a refused command says (Send my position, Where are you?, Meet here).
String? mtResultText(MtResult r) => switch (r) {
      MtResult.ok => null,
      MtResult.privacyZone => 'In a privacy zone: your position is not sent from there.',
      MtResult.zonesNotLoaded => 'Your privacy zones are still loading. Try again in a moment.',
      MtResult.waitingForGps => 'Waiting for GPS. Try again when the phone has a good fix.',
      MtResult.radioDisconnected => 'Connect your radio first.',
      MtResult.notOnRadio => 'This group is not on your radio right now.',
      MtResult.tooSoon => 'You asked less than a minute ago.',
      MtResult.tooManyGroups => 'You can share with up to 3 groups at once. Turn one off first.',
      MtResult.unknownGroup => 'That group is gone.',
    };

/// "Position friends see": Exact / Approximate with their sizes.
String mtPositionModeLabel(MtPositionMode m, Units units) => switch (m) {
      MtPositionMode.exact => 'Exact (about ${units.distance(3)})',
      MtPositionMode.approximate => 'Approximate (about ${units.distance(275, approx: true)})',
    };

String mtRateLabel(MtRate r) => switch (r) {
      MtRate.smart => 'Smart',
      MtRate.lowTraffic => 'Low traffic',
    };

// ------------------------------------------------------------------------------------------------ position messages

/// One line in plain words for a MeshTrack message in "Position messages" (channel detail): "Position, 50 km/h heading
/// E", "Parked", "Asked where everyone is", "Meet-up point: Big oak", "Stopped sharing".
String mtMessageSummary(MtLoggedMessage m, Units units) {
  final msg = m.message;
  return switch (msg) {
    MtPosition(parked: true) => 'Parked',
    MtPosition(:final speedKmh?, :final courseDeg?) when speedKmh >= 5 =>
      'Position, ${units.speed(speedKmh * 1000 / 3600)} heading ${compass(courseDeg.toDouble())}',
    MtPosition(:final speedKmh?) when speedKmh >= 5 => 'Position, ${units.speed(speedKmh * 1000 / 3600)}',
    MtPosition() => 'Position',
    MtRequest(name: null) => 'Asked where everyone is',
    MtRequest(:final name?) => 'Asked where $name is',
    MtMeet(label: final l?) when l.isNotEmpty => 'Meet-up point: $l',
    MtMeet() => 'Meet-up point',
    MtMeetClear() => 'Meet-up point cleared',
    MtStop() => 'Stopped sharing',
    null => 'Position (another app)',
  };
}

/// The note above the list: what this list is and is not.
const String mtPositionMessagesNote =
    'MeshTrack updates heard in this channel in the last 24 hours. They are shown here only: never saved in the chat, '
    'never notified, and not in backups, exports or search.';


// ------------------------------------------------------------------------------------------------ Ask for location (MT-13)

const String askLocationLabel = 'Ask for location';
const String askCancel = 'Cancel';
const String askTryAgain = 'Try again';
const String askOpenOnMap = 'Open on map';
const String askNotConnected = 'Connect your radio to ask.';
const String askBusy = 'Your radio is busy with another request. Try again in a moment.';
const String askFailed = 'Your radio could not send the request. Try again.';
const String askNoAnswerHint = 'They may be out of range, or their radio may not answer location requests.';

/// The "asked" mark on the Drive map pin and its legend.
const String askedPinMark = 'Asked';

String _first(String name) {
  final f = name.trim().split(RegExp(r'\s+')).first;
  return f.isEmpty ? name : f;
}

/// Under the Ask for location row before anything was asked.
String askFooter(String name) => "Asks ${_first(name)}'s radio where it is. It answers only if they allow it.";

/// While asking.
String askAsking(String name) => 'Asking $name…';

/// The answer had no position.
String askNoLocation(String name) =>
    "$name did not share a location. They can allow it in their MeshCore app's telemetry settings.";

/// Nothing came back in time.
String askNoAnswer(String name) => 'No answer from $name.';

/// The radio does not have the contact.
String askNotOnRadio(String name) => '$name is not on your radio yet. Put them on your radio, then ask.';

/// "Ask again in 25 s" while the once-per-30-s limit holds.
String askAgainIn(Duration left) => 'Ask again in ${(left.inMilliseconds / 1000).ceil()} s';

/// "Answered just now" / "Answered 3 min ago".
String askAnsweredAgo(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'Answered just now';
  if (d.inHours < 1) return 'Answered ${d.inMinutes} min ago';
  return 'Answered ${d.inHours} h ago';
}

/// The headline of an answered position: "2.4 km NE of you", or "Position received" when my own position is unknown.
String askWhere(MtLatLon? me, double lat, double lon, Units units) {
  final dp = mtDistanceAndPoint(me, lat, lon, units);
  if (dp == null) return 'Position received';
  if (dp == 'here') return 'Right where you are';
  return '$dp of you';
}

/// VoiceOver label of the asked pin on the map.
String askedPinSemantics(String name, String ago) => '$name, asked for location, ${ago.toLowerCase()}';
