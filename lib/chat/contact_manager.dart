// ContactManager: the phone's contact book and its sync with the radio. Pure Dart, no Flutter.
//
// The rules (design doc "phone is master", HANDOFF 71/74; build 77 redesign round 3):
//  * ChatStore holds EVERY contact the user has. The radio's table (100 entries by default, DEVICE_INFO says) holds the
//    ones it can send to and receive from. Nothing is ever deleted from the phone because the radio ran out of room.
//  * The ROUTE to a contact belongs to the radio. The phone's copy is a mirror for display: it is read from the radio and
//    never written back. A contact is written to the radio ONLY when the person adds or edits one (add, favourite), and
//    then the radio's own copy is read first and its route, last-advert time and position go back unchanged; a contact the
//    radio does not have yet is written with route "unknown", never "direct" (round 3 rule 15; the official app had this
//    bug twice, fixed in its v1.11.0 and v1.51.1). Nothing is written back on connect any more (build 76 pushed favourite
//    flags and filled the radio's table with the phone's copies, routes included).
//  * When the radio's table is full the person is told so ([ContactSyncState.tableFull], "Your radio's contact list is
//    full"). No contact is taken off the radio to make room (decision D1).
//  * A node heard advertising is NEVER added to the radio silently by this app. With the radio's "ask before adding" on it
//    pushes NEW_ADVERT and the node waits in "New nodes nearby" until the user adds or ignores it.
//  * Downloads are incremental (GET_CONTACTS since the last END_OF_CONTACTS cursor) and idempotent: the same list twice, or
//    a list cut short by a dropped link, leaves the book correct; the cursor only moves when a list ends properly.
//  * Radio commands on the user's behalf (DM to a contact the radio dropped, add, remove) work without waiting for a sync.
import 'dart:async';
import 'dart:convert';
import '../radio/packet.dart' show decodeAdvertPacket;
import '../radio/path_tools.dart';
import 'contact_port.dart';
import 'db/misc_repositories.dart' show PathHistoryEntry, PingResultRow;
import 'mesh_links.dart';
import 'models.dart';
import 'store.dart';

enum SyncPhase {
  /// No radio linked now. The book is shown from the phone's copy.
  offline,

  /// Linked, nothing running.
  idle,

  /// A list is coming from the radio ([ContactSyncState.received] of [ContactSyncState.total]).
  syncing,

  /// The last attempt failed ([ContactSyncState.error] says why in plain words); retry with [ContactManager.syncNow].
  failed,
}

class ContactSyncState {
  final SyncPhase phase;
  final int received;
  final int total;
  final String? error;

  /// Local time of the last list that ended properly.
  final int? lastSyncMs;

  /// How many contacts the radio holds (as of the last list, adjusted by our own adds and removes) and how many fit.
  final int? radioCount;
  final int? capacity;

  /// The radio refused a contact because it is full, and nothing has freed a slot since.
  final bool tableFull;
  final ContactPolicy? policy;

  const ContactSyncState({
    this.phase = SyncPhase.offline,
    this.received = 0,
    this.total = 0,
    this.error,
    this.lastSyncMs,
    this.radioCount,
    this.capacity,
    this.tableFull = false,
    this.policy,
  });

  ContactSyncState copyWith({
    SyncPhase? phase,
    int? received,
    int? total,
    Object? error = _keep,
    Object? lastSyncMs = _keep,
    Object? radioCount = _keep,
    Object? capacity = _keep,
    bool? tableFull,
    Object? policy = _keep,
  }) =>
      ContactSyncState(
        phase: phase ?? this.phase,
        received: received ?? this.received,
        total: total ?? this.total,
        error: identical(error, _keep) ? this.error : error as String?,
        lastSyncMs: identical(lastSyncMs, _keep) ? this.lastSyncMs : lastSyncMs as int?,
        radioCount: identical(radioCount, _keep) ? this.radioCount : radioCount as int?,
        capacity: identical(capacity, _keep) ? this.capacity : capacity as int?,
        tableFull: tableFull ?? this.tableFull,
        policy: identical(policy, _keep) ? this.policy : policy as ContactPolicy?,
      );

  /// Free slots on the radio, when both numbers are known.
  int? get freeSlots => (capacity != null && radioCount != null) ? (capacity! - radioCount!).clamp(0, 1 << 20) : null;
}

const Object _keep = Object();

/// One-off things worth telling the user about (a snackbar, not a state).
class ContactNotice {
  final String message;
  const ContactNotice(this.message);
}

/// Result of adding a contact from a link, key or scan. Never an exception for user input.
class AddContactResult {
  final Contact? contact;
  final bool created;

  /// The contact is on the radio now (false: saved on the phone, goes to the radio when it connects or has room).
  final bool onRadio;

  /// Plain-language problem, or null.
  final String? error;

  /// The input was a channel link: the caller should hand it to Channels.
  final bool isChannelLink;

  /// A sentence for the user when the contact was saved but something is still pending.
  final String? note;
  const AddContactResult({this.contact, this.created = false, this.onRadio = false, this.error, this.isChannelLink = false, this.note});
  bool get ok => contact != null && error == null;
}

/// A contact on the radio that could make room, with the reason in words.
class CleanupCandidate {
  final Contact contact;
  final String reason;
  const CleanupCandidate(this.contact, this.reason);
}

class ContactManager {
  final ChatStore store;
  final int Function() nowMs;

  /// Fired after the book changed (ChatService turns it into a contactsChanged event).
  final void Function() onChanged;

  /// Return true to hold a download back (a drive is running: contact frames share the BLE link with pings). Checked before
  /// every automatic sync, never before one the user asked for.
  final bool Function()? shouldDefer;

  /// Unused since build 77 (the app no longer fills the radio's table on its own). Kept for callers that pass it.
  final int reserveSlots;

  ContactRadioPort? _port;
  String? _lastRadioId;
  ContactSyncState _state = const ContactSyncState();
  final _states = StreamController<ContactSyncState>.broadcast();
  final _notices = StreamController<ContactNotice>.broadcast();
  Future<void>? _running;
  final Map<String, int> _refreshedMs = {};
  bool _disposed = false;

  ContactManager({required this.store, int Function()? nowMs, void Function()? onChanged, this.shouldDefer, this.reserveSlots = 5})
      : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        onChanged = onChanged ?? (() {}) {
    _lastRadioId = store.db.setting(_kLastRadio);
  }

  static const _kLastRadio = 'contacts.radio';
  static String _kCursor(String r) => 'contacts.cursor:$r';
  static String _kRemoved(String r) => 'contacts.removed:$r';
  static String _kPrompt(String r) => 'contacts.askPrompt:$r';
  static String _kPendingAdds(String r) => 'contacts.pendingAdds:$r';
  static String _kPendingFlags(String r) => 'contacts.pendingFlags:$r';

  // ------------------------------------------------------------------ state

  ContactSyncState get state => _state;
  Stream<ContactSyncState> get states => _states.stream;

  /// Never emits since build 77: its one notice was "X was taken off the radio to make room", and that no longer happens
  /// (decision D1). Kept so the Contacts screen written against build 76 compiles; delete with its listener.
  Stream<ContactNotice> get notices => _notices.stream;

  /// The radio refused a contact because its list is full and nothing has made room since (decision D1). The words to
  /// show are [radioContactListFullText]; the place to send the person is the radio list (Contacts > Radio list).
  bool get radioListFull => _state.tableFull;

  /// The radio whose contacts are shown: the linked one, else the last one used, else the only one the book has.
  String? get radioId {
    final id = _port?.radioId ?? _lastRadioId;
    if (id != null) return id;
    final r = store.db.raw.select('SELECT DISTINCT radio_id FROM contacts LIMIT 2');
    return r.length == 1 ? r.first['radio_id'] as String : null;
  }

  bool get connected => (_port?.isConnected ?? false) && _port?.radioId != null;

  void _set(ContactSyncState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  void _changed() {
    if (!_disposed) onChanged();
  }

  void dispose() {
    _disposed = true;
    unawaited(_states.close());
    unawaited(_notices.close());
  }

  // ------------------------------------------------------------------ attach / detach (one per radio session)

  /// A radio session is up. Call [syncNow] next (the adapter does).
  void attach(ContactRadioPort port) {
    _port = port;
    final id = port.radioId;
    if (id != null) {
      _lastRadioId = id;
      store.db.putSetting(_kLastRadio, id);
    }
    _set(_state.copyWith(phase: SyncPhase.idle, capacity: port.capacity, error: null));
  }

  /// The session ended. The book stays; the state says offline.
  void detach() {
    _port = null;
    _running = null;
    _set(_state.copyWith(phase: SyncPhase.offline, received: 0, total: 0, error: null));
  }

  // ------------------------------------------------------------------ sync

  /// Reads what changed on the radio and puts the phone's wishes back. Safe to call as often as you like: a second call while
  /// one runs joins it. [auto] = from a connect or a push, not a button: may be held back by [shouldDefer].
  Future<void> syncNow({bool full = false, bool auto = false}) {
    final p = _port;
    if (p == null || !p.isConnected || p.radioId == null) {
      _set(_state.copyWith(phase: SyncPhase.offline));
      return Future.value();
    }
    if (auto && (shouldDefer?.call() ?? false)) return Future.value();
    return _running ??= _sync(p, full).whenComplete(() => _running = null);
  }

  Future<void> _sync(ContactRadioPort p, bool full) async {
    final id = p.radioId!;
    _set(_state.copyWith(phase: SyncPhase.syncing, received: 0, total: 0, error: null, capacity: p.capacity));
    try {
      await _flushRemovals(p, id);
      var since = full ? 0 : _cursor(id);
      var d = await _download(p, id, since);
      if (since != 0 && d.totalOnRadio != store.contacts.countOnRadio(id)) {
        // Our picture of the radio's table is off (it changed while we were away, or we missed a delete): read it all.
        _set(_state.copyWith(received: 0, total: 0));
        since = 0;
        d = await _download(p, id, 0);
      }
      _afterList(id, d);
      // What the person did while the radio was away (added a contact, changed a favourite) goes to the radio now, each as
      // an edit: the radio's copy is read first and its route is left alone. Nothing else is written on connect.
      await _flushPendingEdits(p, id);
      final policy = await _tryPolicy(p, fresh: false);
      _set(_state.copyWith(phase: SyncPhase.idle, lastSyncMs: nowMs(), error: null, policy: policy ?? _state.policy));
    } on RadioUnavailable catch (e) {
      _set(_state.copyWith(phase: SyncPhase.failed, error: _plainFailure(e.reason)));
    } on TimeoutException {
      _set(_state.copyWith(phase: SyncPhase.failed, error: _plainFailure('timeout')));
    } on StateError {
      _set(_state.copyWith(phase: SyncPhase.failed, error: _plainFailure('link')));
    } catch (e) {
      _set(_state.copyWith(phase: SyncPhase.failed, error: _plainFailure('$e')));
    }
    _changed();
  }

  static String _plainFailure(String why) {
    final w = why.toLowerCase();
    if (w.contains('timeout') || w.contains('stopped sending') || w.contains('did not answer')) {
      return 'The radio stopped answering while the contact list was coming. What arrived is saved. Check the radio is on and close by, then try again.';
    }
    if (w.contains('link') || w.contains('not connected') || w.contains('disconnect')) {
      return 'The radio disconnected while the contact list was coming. What arrived is saved; it carries on when the radio is back.';
    }
    return 'The contact list could not be read from the radio. What arrived is saved. Try again.';
  }

  int _cursor(String id) => int.tryParse(store.db.setting(_kCursor(id)) ?? '') ?? 0;

  Future<ContactDownload> _download(ContactRadioPort p, String id, int since) async {
    final seen = <String>{};
    final batch = <Contact>[];
    final removed = _removed(id);
    final stale = <String>[]; // on the radio but removed on the phone while the radio was away
    void flush() {
      if (batch.isEmpty) return;
      store.db.transaction(() {
        for (final c in batch) {
          _mergeFromRadio(id, c);
        }
      });
      batch.clear();
      _changed();
    }

    final ContactDownload d;
    try {
      d = await p.download(
          // a contact whose lastmod equals the cursor may have changed again in the same second: ask from one earlier
          since: since > 0 ? since - 1 : 0,
          onContact: (c, received, total) {
            if (!isHex(c.publicKey, 64)) return;
            final key = c.publicKey.toLowerCase();
            seen.add(key);
            if (removed.contains(key)) {
              stale.add(key);
            } else {
              batch.add(c.copyWith(onRadio: true));
            }
            if (batch.length >= 25) flush();
            if (received % 10 == 0 || received == total) _set(_state.copyWith(received: received, total: total));
          });
    } finally {
      flush(); // whatever arrived before a failure is kept: the next try starts from the same cursor and merges idempotently
    }
    // A full list is the whole truth about the radio's table.
    if (since == 0) store.contacts.clearOnRadioExcept(id, seen);
    for (final k in stale) {
      try {
        await p.remove(k);
      } catch (_) {}
    }
    _set(_state.copyWith(received: d.totalOnRadio, total: d.totalOnRadio));
    return d;
  }

  void _afterList(String id, ContactDownload d) {
    if (d.cursor > _cursor(id)) store.db.putSetting(_kCursor(id), '${d.cursor}');
    final cap = _port?.capacity;
    _set(_state.copyWith(radioCount: d.totalOnRadio, capacity: cap, tableFull: cap != null && d.totalOnRadio >= cap ? _state.tableFull : false));
  }

  /// Puts a radio-side copy into the book. Radio wins for what the radio knows (name, type, position, route, last advert);
  /// the phone keeps what only the phone knows (favourite, blocked, custom name, notes, how it was added, flood preference).
  void _mergeFromRadio(String id, Contact rc) {
    final key = rc.publicKey.toLowerCase();
    final ex = store.contacts.get(id, key);
    final heard = _plausibleMs(rc.lastMod);
    final name = _cleanName(rc.name, key);
    final merged = ex == null
        ? rc.copyWith(
            name: name,
            favourite: (rc.radioFlags & 1) != 0,
            source: ContactSource.radio,
            onRadio: true,
            lastHeardMs: heard)
        : rc.copyWith(
            name: name,
            favourite: ex.favourite,
            blocked: ex.blocked,
            customName: ex.customName,
            notes: ex.notes,
            source: ex.source,
            pathLearnedMs: ex.pathLearnedMs,
            lastPingMs: ex.lastPingMs,
            lastPingRttMs: ex.lastPingRttMs,
            lastPingOk: ex.lastPingOk,
            onRadio: true,
            lastHeardMs: (heard != null && (ex.lastHeardMs == null || heard > ex.lastHeardMs!)) ? heard : ex.lastHeardMs);
    store.contacts.upsert(merged);
    store.adverts.remove(id, key); // no longer "nearby": it is a contact
  }

  int? _plausibleMs(int? radioSecs) => (radioSecs == null || radioSecs < 1600000000) ? null : radioSecs * 1000;

  static String _cleanName(String raw, String key) {
    final n = raw.replaceAll(RegExp('[\\u0000-\\u001f\\u007f\\u202a-\\u202e\\u2066-\\u2069]'), '').trim();
    return n.isEmpty ? key.substring(0, 8) : n;
  }

  int _flagsFor(Contact c) => c.favourite ? (c.radioFlags | 1) : (c.radioFlags & ~1);
  Contact _forRadio(Contact c) => c.copyWith(radioFlags: _flagsFor(c));

  /// A contact for ADD_UPDATE_CONTACT when the radio does NOT have it yet: the phone's name, type and key, the favourite
  /// flag, and NO route. The phone's copy of a route is never written to the radio (rule 15): a new contact starts as
  /// "route unknown", so the first message floods and the radio learns the route itself.
  Contact _asNewOnRadio(Contact c) => _forRadio(c).copyWith(outPath: null, outPathLen: -1);

  /// The only way this app writes a contact that the radio already has: [radioCopy] is what GET_CONTACT_BY_KEY just
  /// returned, so its route, last-advert time and position go back exactly as the radio holds them; only the favourite
  /// flag (bit 0 of the flags byte) follows the phone.
  Contact _asEditOf(Contact radioCopy, Contact mine) =>
      radioCopy.copyWith(radioFlags: mine.favourite ? (radioCopy.radioFlags | 1) : (radioCopy.radioFlags & ~1));

  /// Writes the person's edit of [key] to the radio: read the radio's copy, change the flags, write it back. A contact the
  /// radio does not have is left alone (nothing to edit there).
  Future<void> _writeEdit(ContactRadioPort p, String id, String key) async {
    final mine = store.contacts.get(id, key);
    if (mine == null) return;
    final there = await p.fetch(key);
    if (there == null) {
      if (mine.onRadio) store.contacts.setOnRadio(id, key, false);
      return;
    }
    final edited = _asEditOf(there, mine);
    if (edited.radioFlags != there.radioFlags) await p.upload(edited);
    store.contacts.setOnRadio(id, key, true);
    store.contacts.setRadioFlags(id, key, edited.radioFlags);
  }

  Set<String> _pendingSet(String settingKey) {
    final raw = store.db.setting(settingKey);
    if (raw == null) return <String>{};
    try {
      return {for (final k in (jsonDecode(raw) as List)) k as String};
    } catch (_) {
      return <String>{};
    }
  }

  void _savePending(String settingKey, Set<String> s) => store.db.putSetting(settingKey, s.isEmpty ? null : jsonEncode(s.toList()..sort()));

  void _pendingAdd(String settingKey, String key) => _savePending(settingKey, _pendingSet(settingKey)..add(key));

  void _pendingDone(String settingKey, String key) {
    final s = _pendingSet(settingKey);
    if (s.remove(key)) _savePending(settingKey, s);
  }

  /// Contacts the person added, and favourites they changed, while the radio was away. Done on the next sync, one by one.
  Future<void> _flushPendingEdits(ContactRadioPort p, String id) async {
    for (final key in _pendingSet(_kPendingAdds(id)).toList()) {
      if (store.contacts.get(id, key) == null) {
        _pendingDone(_kPendingAdds(id), key);
        continue;
      }
      try {
        await ensureOnRadio(key, force: true);
        _pendingDone(_kPendingAdds(id), key);
      } on ContactTableFull {
        break; // the state says "full"; it stays pending until there is room
      } on RadioUnavailable {
        rethrow;
      } catch (_) {
        // stays pending for the next sync
      }
    }
    for (final key in _pendingSet(_kPendingFlags(id)).toList()) {
      try {
        await _writeEdit(p, id, key);
        _pendingDone(_kPendingFlags(id), key);
      } on ContactTableFull {
        _pendingDone(_kPendingFlags(id), key); // cannot happen for an update; never loop on it
      } on RadioUnavailable {
        rethrow;
      } catch (_) {
        // stays pending for the next sync
      }
    }
  }

  /// For tests: the keys whose add / favourite change waits for the radio.
  Set<String> get pendingAdds => radioId == null ? <String>{} : _pendingSet(_kPendingAdds(radioId!));
  Set<String> get pendingFlagEdits => radioId == null ? <String>{} : _pendingSet(_kPendingFlags(radioId!));

  Future<ContactPolicy?> _tryPolicy(ContactRadioPort p, {bool fresh = true}) async {
    try {
      return await p.getPolicy(fresh: fresh);
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ one contact on the radio

  /// Puts [publicKey] on the radio because the person asked for it (they added the contact, pressed "Add to radio", or sent
  /// a message the radio answered "not a contact" to). The radio's own copy is read first: when it has the contact, that
  /// copy is taken as it is (its route wins) and nothing is written; when it does not, the contact is written as NEW with
  /// route unknown. Throws [RadioUnavailable] when not linked and [ContactTableFull] when the radio's list is full: the
  /// state then says so ([ContactSyncState.tableFull]) and NOTHING is taken off the radio to make room (decision D1).
  /// [force] false returns at once when the phone already believes the contact is on the radio.
  Future<void> ensureOnRadio(String publicKey, {bool force = false}) async {
    final p = _port;
    final id = p?.radioId;
    if (p == null || id == null || !p.isConnected) throw const RadioUnavailable('the radio is not connected');
    final key = publicKey.toLowerCase();
    final c = store.contacts.get(id, key);
    if (c == null) throw ArgumentError('unknown contact');
    if (c.onRadio && !force) return;
    final there = await p.fetch(key);
    if (there != null) {
      store.contacts.setOnRadio(id, key, true);
      store.contacts.setPath(id, key, there.hasPath ? there.outPath : null, there.hasPath ? there.outPathLen : -1);
      // The radio had it already: only the favourite flag may need to follow the phone (an edit of the radio's own copy,
      // route untouched).
      final edited = _asEditOf(there, c);
      if (edited.radioFlags != there.radioFlags) await p.upload(edited);
      store.contacts.setRadioFlags(id, key, edited.radioFlags);
      _changed();
      return;
    }
    try {
      await p.upload(_asNewOnRadio(c));
    } on ContactTableFull {
      _set(_state.copyWith(tableFull: true, radioCount: _state.capacity ?? _state.radioCount));
      _changed();
      rethrow;
    }
    store.contacts.setOnRadio(id, key, true);
    store.contacts.setRadioFlags(id, key, _flagsFor(c));
    final n = _state.radioCount;
    _set(_state.copyWith(radioCount: n == null ? null : n + 1));
    _changed();
  }

  /// The radio's copy of one contact, merged in (a route was learned, an advert arrived). Quietly does nothing when the radio
  /// does not answer.
  Future<void> refreshOne(String publicKey) async {
    final p = _port;
    final id = p?.radioId;
    if (p == null || id == null || !p.isConnected) return;
    final key = publicKey.toLowerCase();
    if (_removed(id).contains(key)) return;
    try {
      final rc = await p.fetch(key);
      if (rc == null) {
        if (store.contacts.get(id, key)?.onRadio ?? false) {
          store.contacts.setOnRadio(id, key, false);
          _changed();
        }
        return;
      }
      final was = store.contacts.get(id, key)?.onRadio ?? false;
      _mergeFromRadio(id, rc.copyWith(onRadio: true));
      if (!was) {
        final n = _state.radioCount;
        if (n != null) _set(_state.copyWith(radioCount: n + 1));
      }
      _refreshedMs[key] = nowMs();
      _changed();
    } catch (_) {
      // best effort; the next sync catches up
    }
  }

  // ------------------------------------------------------------------ radio events

  /// PUSH_PATH_UPDATED: the radio learned a route. Read it so the next DM goes direct.
  Future<void> pathUpdated(String publicKey) async {
    await refreshOne(publicKey);
    final id = radioId;
    if (id == null) return;
    final c = store.contacts.get(id, publicKey);
    if (c == null || !c.hasPath) return;
    final now = nowMs();
    store.contacts.setPathLearned(id, c.publicKey, now);
    final r = decodePath(c.outPathLen, c.outPath ?? const []);
    store.pathHistory.add(PathHistoryEntry(contactKey: c.publicKey, tsMs: now, kind: 'learned', hops: r?.hexHops ?? const [], hashSize: r?.hashSize));
    _changed();
  }

  /// A known contact advertised (PUSH_ADVERT, key only). Refreshes position and last advert, at most every 10 minutes, and
  /// adds a contact the radio added by itself (auto-add mode).
  Future<void> advertHeard(String publicKey) async {
    final id = radioId;
    if (id == null) return;
    final key = publicKey.toLowerCase();
    store.contacts.touchHeard(id, key, nowMs());
    final known = store.contacts.get(id, key) != null;
    final last = _refreshedMs[key] ?? 0;
    // Not while a direct message waits for its confirmation: the read's reply would share the radio's 4-frame Bluetooth
    // queue with that push (defect M5). The next advert of a known contact refreshes it.
    final hold = known && (_port?.deliveryInFlight ?? false);
    if (!hold && (!known || nowMs() - last > 10 * 60 * 1000)) await refreshOne(key);
    _changed();
  }

  /// Heard from this contact just now (an ack, a message): feeds "last heard".
  void heardNow(String publicKey) {
    final id = radioId;
    if (id != null) store.contacts.touchHeard(id, publicKey, nowMs());
  }

  /// PUSH_CONTACT_DELETED: the radio replaced this contact to make room. The phone keeps it.
  void radioDropped(String publicKey) {
    final id = radioId;
    if (id == null) return;
    store.contacts.setOnRadio(id, publicKey, false);
    final n = _state.radioCount;
    _set(_state.copyWith(radioCount: n == null ? null : (n - 1).clamp(0, 1 << 20)));
    _changed();
  }

  /// PUSH_CONTACTS_FULL: a node was heard and there was no room.
  void radioFull() {
    _set(_state.copyWith(tableFull: true, radioCount: _state.capacity ?? _state.radioCount));
    _changed();
  }

  // ------------------------------------------------------------------ adding

  /// "New nodes nearby": heard, not added, not ignored.
  List<AdvertSeen> nearby() {
    final id = radioId;
    return id == null ? const [] : store.adverts.nearby(id);
  }

  List<AdvertSeen> ignored() {
    final id = radioId;
    return id == null ? const [] : store.adverts.ignoredList(id);
  }

  void ignoreNearby(String publicKey) {
    final id = radioId;
    if (id == null) return;
    store.adverts.setIgnored(id, publicKey, true);
    _changed();
  }

  void restoreIgnored(String publicKey) {
    final id = radioId;
    if (id == null) return;
    store.adverts.setIgnored(id, publicKey, false);
    _changed();
  }

  Future<AddContactResult> addNearby(AdvertSeen a) {
    return _add(
        publicKey: a.publicKey,
        name: a.name,
        type: a.type ?? ContactType.companion,
        lat: a.lat,
        lon: a.lon,
        advertTs: a.advertTs,
        source: ContactSource.discovered);
  }

  Future<AddContactResult> addByKey(String publicKey, {String? name, ContactType type = ContactType.companion}) {
    final k = publicKey.trim().replaceAll(RegExp(r'\s'), '').toLowerCase();
    if (!isHex(k, 64)) {
      return Future.value(const AddContactResult(error: 'A contact key is 64 characters, 0-9 and a-f. Check that you copied all of it.'));
    }
    return _add(publicKey: k, name: name ?? '', type: type, source: ContactSource.manual);
  }

  /// A pasted or scanned `meshcore://` link: a contact link, or an advert packet link (the radio checks its signature).
  Future<AddContactResult> addFromLink(String link) async {
    final p = MeshLinks.parse(link);
    switch (p) {
      case LinkParseError():
        return AddContactResult(error: _linkErrorText(p.error));
      case ChannelLink():
        return const AddContactResult(isChannelLink: true, error: 'That is a channel link, not a contact. Open Channels to join it.');
      case ContactLink():
        return _add(publicKey: p.publicKey, name: p.name, type: p.type ?? ContactType.companion, source: ContactSource.imported);
      case AdvertLink():
        final info = decodeAdvertPacket(p.packet);
        if (info == null || info.name.isEmpty) {
          return const AddContactResult(error: 'That link does not hold a valid MeshCore advert, so there is nobody to add.');
        }
        final r = await _add(
            publicKey: toHex(info.publicKey),
            name: info.name,
            type: ContactType.fromCode(info.type) ?? ContactType.companion,
            lat: info.lat,
            lon: info.lon,
            advertTs: info.timestamp,
            source: ContactSource.imported);
        // Let the radio see the advert itself (it checks the signature and keeps the packet, which "share" needs).
        final port = _port;
        if (r.ok && port != null && port.isConnected) {
          try {
            await port.importAdvert(p.packet);
          } catch (_) {}
        }
        return r;
    }
  }

  static String _linkErrorText(LinkError e) => switch (e) {
        LinkError.empty => 'Nothing to add: paste a meshcore:// link.',
        LinkError.tooLong => 'That text is too long to be a MeshCore link.',
        LinkError.notMeshcore => 'That is not a MeshCore link. It should start with meshcore://',
        LinkError.badPublicKey => 'The key in that link is not valid. A contact key is 64 characters, 0-9 and a-f.',
        LinkError.badName => 'The name in that link has characters we cannot use.',
        LinkError.badAdvert => 'That advert link is damaged or the wrong size.',
        _ => 'That link is not one we understand. Ask for a fresh contact link or QR code.',
      };

  Future<AddContactResult> _add({
    required String publicKey,
    required String name,
    required ContactType type,
    double? lat,
    double? lon,
    int? advertTs,
    required ContactSource source,
  }) async {
    final id = radioId;
    if (id == null) {
      return const AddContactResult(error: 'Connect your radio once first, so MeshSonar knows which radio these contacts belong to.');
    }
    final key = publicKey.toLowerCase();
    if (_port?.radioId == key) return const AddContactResult(error: 'That is your own radio.');
    final ex = store.contacts.get(id, key);
    final nm = _cleanName(name, key);
    final c = (ex ??
            Contact(radioId: id, publicKey: key, type: type, name: nm, lat: lat, lon: lon, lastAdvertTs: advertTs, source: source, lastHeardMs: nowMs()))
        .copyWith(
      type: ex == null ? null : (name.isEmpty ? null : type),
      name: ex != null && name.isEmpty ? null : nm,
    );
    _removeTombstone(id, key);
    store.contacts.upsert(c);
    store.adverts.remove(id, key);
    _changed();
    final p = _port;
    if (p == null || !p.isConnected) {
      _pendingAdd(_kPendingAdds(id), key);
      return AddContactResult(
          contact: c, created: ex == null, onRadio: false, note: 'Saved on this phone. It goes onto your radio the next time it connects.');
    }
    try {
      await ensureOnRadio(key, force: true);
      _pendingDone(_kPendingAdds(id), key);
      return AddContactResult(contact: store.contacts.get(id, key), created: ex == null, onRadio: true);
    } on ContactTableFull {
      _pendingAdd(_kPendingAdds(id), key);
      return AddContactResult(
          contact: c,
          created: ex == null,
          onRadio: false,
          note: 'Saved on this phone. $radioContactListFullText: remove a contact from the radio (Contacts > Radio list) and it will be added.');
    } on RadioUnavailable {
      _pendingAdd(_kPendingAdds(id), key);
      return AddContactResult(contact: c, created: ex == null, onRadio: false, note: 'Saved on this phone. It goes onto your radio when it is back.');
    } catch (_) {
      _pendingAdd(_kPendingAdds(id), key);
      return AddContactResult(contact: c, created: ex == null, onRadio: false, note: 'Saved on this phone. The radio did not take it yet; it will be tried again.');
    }
  }

  // ------------------------------------------------------------------ editing (phone-only fields)

  void setFavourite(String publicKey, bool v) {
    final id = radioId;
    if (id == null) return;
    store.contacts.setFavourite(id, publicKey, v);
    _changed();
    // The radio keeps favourites when it must replace a contact: tell it. This is an edit by the person, so the radio's
    // copy is read first and written back with only the flag changed (its route is not touched). With the radio away the
    // edit waits for the next sync.
    final key = publicKey.toLowerCase();
    final p = _port;
    if (p != null && p.isConnected) {
      unawaited(_writeEdit(p, id, key).then((_) => _pendingDone(_kPendingFlags(id), key)).catchError((Object _) {
        _pendingAdd(_kPendingFlags(id), key);
      }));
    } else {
      _pendingAdd(_kPendingFlags(id), key);
    }
  }

  void rename(String publicKey, String? customName) {
    final id = radioId;
    if (id == null) return;
    final n = customName?.trim();
    store.contacts.setCustomName(id, publicKey, (n == null || n.isEmpty) ? null : n);
    _changed();
  }

  void setNotes(String publicKey, String notes) {
    final id = radioId;
    if (id == null) return;
    store.contacts.setNotes(id, publicKey, notes);
    _changed();
  }

  void setBlocked(String publicKey, bool v) {
    final id = radioId;
    if (id == null) return;
    store.contacts.setBlocked(id, publicKey, v);
    _changed();
  }

  /// REMOVED in build 77 with the route modes ("Always search" is not in the official flow). Does nothing; kept so
  /// callers written against build 76 compile.
  void setForceFlood(String publicKey, bool v) {}

  // ------------------------------------------------------------------ route, share, remove

  /// Manual "Reset route" (kept: the official app has it): CMD_RESET_PATH, so the radio forgets its route, the next
  /// message floods and the radio learns a fresh one. The phone's mirror of the route is cleared with it.
  Future<void> resetPath(String publicKey) async {
    final id = radioId;
    if (id == null) return;
    store.contacts.setPath(id, publicKey, null, -1);
    store.contacts.setPathLearned(id, publicKey, null);
    store.pathHistory.add(PathHistoryEntry(contactKey: publicKey, tsMs: nowMs(), kind: 'reset'));
    _changed();
    final p = _port;
    if (p != null && p.isConnected) {
      try {
        await p.resetPath(publicKey);
      } catch (_) {}
    }
  }

  /// The radio answered OK to a RESET_PATH that message delivery sent (the one reset of a message): the phone's mirror of
  /// the route follows what the radio now holds (none).
  void noteRadioPathReset(String publicKey) {
    final id = radioId;
    if (id == null) return;
    final key = publicKey.toLowerCase();
    final c = store.contacts.get(id, key);
    if (c == null || !c.hasPath) return;
    store.contacts.setPath(id, key, null, -1);
    store.contacts.setPathLearned(id, key, null);
    store.pathHistory.add(PathHistoryEntry(contactKey: key, tsMs: nowMs(), kind: 'reset'));
    _changed();
  }

  // ------------------------------------------------------------------ build 76 route features, removed in build 77
  // Route modes (Automatic / Keep this route / Always search), the pinned route and the set-path radio write are not in
  // the official flow and are gone (round 3 "Removed"). These members stay ONLY so screens written against build 76
  // compile until they are edited; none of them changes anything or writes to the radio. Delete them with those screens.

  /// Undo of a route reset. Cannot be done any more: the app never writes a route to the radio, and the phone's copy is
  /// only a mirror. Reads the radio's copy again so the screen shows the truth. (Build 76 put the phone's copy back.)
  Future<void> restorePath(Contact before) => refreshOne(before.publicKey);

  /// Always false: the set-path radio write is removed.
  bool Function() routeWriteEnabled = () => false;

  /// Does nothing and returns false: there are no route modes.
  bool setRouteMode(String publicKey, PathMode mode) => false;

  /// Does nothing and returns false: no route can be pinned.
  bool keepCurrentRoute(String publicKey) => false;

  /// Writes nothing; returns the reason in plain words.
  Future<String?> setRoute(String publicKey, PathRoute route) async => 'Choosing repeaters yourself is not available. The radio learns the route.';

  /// Writes nothing and returns false.
  Future<bool> restorePinnedPath(Contact c) async => false;

  /// A finished ping or discovery: remembered on the contact and in the history list.
  void recordPing(String publicKey, {required String kind, required bool ok, int? rttMs, int? hops, List<double> snr = const [], String? out, String? back, String? failReason}) {
    final id = radioId;
    if (id == null) return;
    final now = nowMs();
    store.contacts.setLastPing(id, publicKey, tsMs: now, rttMs: rttMs, ok: ok);
    store.pingResults.add(PingResultRow(
        contactKey: publicKey, tsMs: now, kind: kind, ok: ok, rttMs: rttMs, hops: hops, snrJson: snr.isEmpty ? null : snr.join(','), pathOut: out, pathBack: back, failReason: failReason));
    _changed();
  }

  /// A route found by a discovery, noted in the contact's route history. The radio learns and keeps the route by itself;
  /// nothing is written to it and nothing is pinned ([keep] true returns why, in plain words).
  Future<String?> useDiscoveredRoute(String publicKey, PathRoute route, {required bool keep}) async {
    final id = radioId;
    if (id == null) return 'Connect your radio first.';
    if (keep) return 'A route cannot be kept by hand. The radio learns the route from the next message.';
    store.pathHistory.add(PathHistoryEntry(contactKey: publicKey, tsMs: nowMs(), kind: 'discovered', hops: route.hexHops, hashSize: route.hashSize));
    _changed();
    return null;
  }

  /// The link/QR text for a contact (works for any contact, on the radio or not).
  String linkFor(Contact c) => MeshLinks.encodeContact(name: c.displayName, publicKey: c.publicKey, type: c.type);

  /// Radio-to-radio hand over, zero hop: only radios in direct range hear it. False when the radio has no stored advert for the
  /// contact (it only keeps the ones it heard itself).
  Future<bool> shareToNearbyRadios(String publicKey) async {
    final p = _port;
    if (p == null || !p.isConnected) throw const RadioUnavailable('the radio is not connected');
    return p.shareZeroHop(publicKey);
  }

  /// Removes a contact from the phone's book and from the radio. If the radio is away the removal is remembered and done when
  /// it is back, so the contact does not reappear from the radio's list.
  Future<void> remove(String publicKey) async {
    final id = radioId;
    if (id == null) return;
    final key = publicKey.toLowerCase();
    store.contacts.delete(id, key);
    _pendingDone(_kPendingAdds(id), key);
    _pendingDone(_kPendingFlags(id), key);
    _changed();
    // Even a contact the phone believes is not on the radio may be (the radio can add nodes by itself): always ask the radio.
    final p = _port;
    if (p != null && p.isConnected) {
      try {
        final had = await p.remove(key);
        final n = _state.radioCount;
        if (had) _set(_state.copyWith(radioCount: n == null ? null : (n - 1).clamp(0, 1 << 20), tableFull: false));
        return;
      } catch (_) {}
    }
    _addTombstone(id, key);
  }

  /// Takes contacts off the RADIO only (they stay in the book). Returns how many the radio let go.
  Future<int> removeFromRadio(Iterable<String> publicKeys) async {
    final p = _port;
    final id = p?.radioId;
    if (p == null || id == null || !p.isConnected) throw const RadioUnavailable('the radio is not connected');
    var n = 0;
    for (final k in publicKeys) {
      try {
        await p.remove(k);
        store.contacts.setOnRadio(id, k, false);
        n++;
      } catch (_) {}
    }
    final c = _state.radioCount;
    _set(_state.copyWith(radioCount: c == null ? null : (c - n).clamp(0, 1 << 20), tableFull: false));
    _changed();
    return n;
  }

  // ------------------------------------------------------------------ cleanup suggestions

  Map<String, int> _conversationTimes(String id) {
    final out = <String, int>{};
    for (final s in store.messages.conversations(radioId: id, includeEmpty: false)) {
      final k = s.key;
      if (k.length > 2 && (k.startsWith('d:') || k.startsWith('r:'))) out[ConvKey.body(k)] = s.lastTsMs ?? 0;
    }
    return out;
  }

  Set<String> _pendingPrefixes(String id) {
    final out = <String>{};
    for (final m in store.messages.byState([MessageState.queued, MessageState.sending, MessageState.sent, MessageState.retrying])) {
      if (m.convKind != ConvKind.channel) out.add(ConvKey.body(m.convKey));
    }
    return out;
  }

  /// Contacts on the radio that cost a slot and are the least likely to be missed, oldest first, with the reason. Favourites,
  /// anyone with a conversation and anyone with a message in flight are never suggested.
  List<CleanupCandidate> cleanupSuggestions({int limit = 50}) {
    final id = radioId;
    if (id == null) return const [];
    final conv = _conversationTimes(id);
    final pending = _pendingPrefixes(id);
    final now = nowMs();
    final list = <(Contact, int)>[];
    for (final c in store.contacts.list(id)) {
      if (!c.onRadio || c.favourite || conv.containsKey(c.prefix) || pending.contains(c.prefix)) continue;
      list.add((c, c.lastHeardMs ?? (c.lastAdvertTs ?? 0) * 1000));
    }
    list.sort((a, b) {
      final ra = a.$1.source == ContactSource.radio ? 0 : 1;
      final rb = b.$1.source == ContactSource.radio ? 0 : 1;
      return ra != rb ? ra.compareTo(rb) : a.$2.compareTo(b.$2);
    });
    return [
      for (final e in list.take(limit))
        CleanupCandidate(
            e.$1,
            e.$2 <= 0
                ? 'Never heard on this phone'
                : 'Last heard ${_ago(now - e.$2)}${e.$1.type == ContactType.repeater ? ', a repeater' : ''}')
    ];
  }

  static String _ago(int ms) {
    final d = ms ~/ 86400000;
    if (d >= 1) return '$d day${d == 1 ? '' : 's'} ago';
    final h = ms ~/ 3600000;
    if (h >= 1) return '$h hour${h == 1 ? '' : 's'} ago';
    return 'minutes ago';
  }

  // ------------------------------------------------------------------ radio policy (auto-add)

  /// What the radio does with a node it hears; null while the radio is not linked or does not say.
  Future<ContactPolicy?> loadPolicy() async {
    final p = _port;
    if (p == null || !p.isConnected) return null;
    final pol = await _tryPolicy(p);
    if (pol != null) _set(_state.copyWith(policy: pol));
    return pol;
  }

  Future<void> setPolicy(ContactPolicy policy) async {
    final p = _port;
    if (p == null || !p.isConnected) throw const RadioUnavailable('the radio is not connected');
    await p.setPolicy(policy);
    _set(_state.copyWith(policy: policy));
    _changed();
  }

  /// Whether the one-time "ask before adding nodes?" offer was answered: null (not yet), 'ask' or 'keep'.
  String? get policyPromptAnswer {
    final id = radioId;
    return id == null ? null : store.db.setting(_kPrompt(id));
  }

  void answerPolicyPrompt(String answer) {
    final id = radioId;
    if (id != null) store.db.putSetting(_kPrompt(id), answer);
    _changed();
  }

  /// True when the offer should be shown: the radio adds every node it hears by itself, and the user has not answered.
  bool get shouldOfferAskFirst => connected && _state.policy != null && !_state.policy!.askBeforeAdding && policyPromptAnswer == null;

  // ------------------------------------------------------------------ removals pending for a radio that was away

  Set<String> _removed(String id) {
    final raw = store.db.setting(_kRemoved(id));
    if (raw == null) return <String>{};
    try {
      return {for (final k in (jsonDecode(raw) as List)) k as String};
    } catch (_) {
      return <String>{};
    }
  }

  void _saveRemoved(String id, Set<String> s) => store.db.putSetting(_kRemoved(id), s.isEmpty ? null : jsonEncode(s.toList()..sort()));
  void _addTombstone(String id, String key) => _saveRemoved(id, _removed(id)..add(key));
  void _removeTombstone(String id, String key) {
    final s = _removed(id);
    if (s.remove(key)) _saveRemoved(id, s);
  }

  Future<void> _flushRemovals(ContactRadioPort p, String id) async {
    final s = _removed(id);
    if (s.isEmpty) return;
    for (final k in s.toList()) {
      try {
        await p.remove(k);
        s.remove(k);
      } on RadioUnavailable {
        rethrow;
      } catch (_) {
        s.remove(k); // the radio says it is not there: done
      }
    }
    _saveRemoved(id, s);
  }

  /// For tests: the keys whose removal waits for the radio.
  Set<String> get pendingRemovals => radioId == null ? <String>{} : _removed(radioId!);
}
