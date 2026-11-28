// Build 77 (redesign round 3, "Removed" list and decision D3): route modes (Automatic / Keep this route / Always search),
// the pinned route with its radio write, and the "This route may be broken" logic are not in the official MeshCore flow
// and are gone (their code too, deleted by W2-D). This file replaces route_modes_test.dart: it pins that what build 76
// left in the database changes nothing, and keeps the coverage of what still exists (manual Reset route, ping and route
// history).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/migrations.dart';
import 'package:meshsonar/chat/db/misc_repositories.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/path_tools.dart';
import 'package:sqlite3/sqlite3.dart';

import 'contact_support.dart';
import 'support.dart';

void main() {
  late Harness h;
  late FakeRadioPort port;
  setUp(() {
    h = Harness();
    port = FakeRadioPort();
    h.service.contacts.attach(port);
  });

  Contact bobNow() => h.store.contacts.get(radioA, bobKey)!;

  test('a contact saved again writes no route mode: the legacy columns read none', () async {
    final bob = h.bob(path: true);
    port.radioAdd(bob);
    h.store.db.raw.execute("UPDATE contacts SET path_mode = 'fixed', force_flood = 1, pinned_path = 'a1,b2', pinned_hash_size = 1");
    h.store.contacts.upsert(bobNow());
    final r = h.store.db.raw.select('SELECT path_mode, force_flood, pinned_path, pinned_hash_size FROM contacts WHERE pubkey = ?', [bobKey]).first;
    expect([r['path_mode'], r['force_flood'], r['pinned_path'], r['pinned_hash_size']], ['auto', 0, null, null]);
    expect(port.uploads, isEmpty, reason: 'no route is ever written to the radio');
  });

  test('a contact stored with a mode by build 76 sends like any other: 4 direct, one reset, 4 flood', () async {
    h.bob(path: true);
    // What build 76 left in the database for "Always search" and "Keep this route".
    h.store.db.raw.execute("UPDATE contacts SET path_mode = 'flood', force_flood = 1, pinned_path = 'a1,b2', pinned_hash_size = 1");
    h.service.send(radioId: radioA, convKey: h.bobConv, text: 'hi');
    for (var i = 0; i < 24; i++) {
      await h.service.pump();
      h.clock.advance(6000);
    }
    expect(h.sink.log, ['send', 'send', 'send', 'send', 'reset', 'send', 'send', 'send', 'send']);
    expect(h.sink.directs.map((d) => d.flood), [false, false, false, false, true, true, true, true]);
  });

  test('migration v6 clears stored modes and pins and turns "Probably delivered" rows into Not delivered', () {
    final db = sqlite3.openInMemory();
    migrateDatabase(db, chatMigrations.sublist(0, 5));
    db.execute("INSERT INTO contacts(radio_id, pubkey, type, name, path_mode, force_flood, pinned_path, pinned_hash_size) VALUES (?,?,1,'Bob','fixed',0,'a1,b2',1)", [radioA, bobKey]);
    db.execute("INSERT INTO contacts(radio_id, pubkey, type, name, path_mode, force_flood) VALUES (?,?,1,'Carol','flood',1)", [radioA, carolKey]);
    final conv = ConvKey.dm(bobKey.substring(0, 12));
    for (final (id, state) in [('m1', 'likelyDelivered'), ('m2', 'acked')]) {
      db.execute(
          "INSERT INTO messages(id, radio_id, conv_kind, conv_key, direction, ts_sender, ts_local_ms, text, state, dedupe_key) VALUES (?,?,'dm',?,'out',1,?,'x',?,?)",
          [id, radioA, conv, id == 'm2' ? 5000 : 4000, state, id]);
    }
    final store = ChatStore.open(db, InMemorySecretStore());
    expect(store.db.schemaVersion, 6);
    final bob = store.contacts.get(radioA, bobKey)!;
    final cols = store.db.raw.select('SELECT path_mode, force_flood, pinned_path FROM contacts ORDER BY name').map((r) => [r['path_mode'], r['force_flood'], r['pinned_path']]).toList();
    expect(cols, [['auto', 0, null], ['auto', 0, null]]);
    expect(store.messages.get('m1')!.state, MessageState.failed);
    expect(store.messages.get('m1')!.failReason, FailReason.noAck);
    // Rule 16 is backfilled: Bob confirmed a message once, Carol never did.
    expect(bob.everConfirmed, isTrue);
    expect(bob.confirmedMs, 5000);
    expect(store.contacts.get(radioA, carolKey)!.everConfirmed, isFalse);
    // Running it again changes nothing (idempotent).
    store.db.raw.execute('PRAGMA user_version = 5');
    migrateDatabase(store.db.raw, chatMigrations);
    expect(store.contacts.get(radioA, bobKey)!.confirmedMs, 5000);
    store.close();
  });

  group('kept: manual Reset route, ping and route history', () {
    test('Reset route clears the route on the radio and the phone\'s mirror of it, and logs it', () async {
      final bob = h.bob(path: true);
      port.radioAdd(bob);
      await h.service.contacts.resetPath(bobKey);
      expect(port.resets, [bobKey]);
      expect(port.table[bobKey]!.hasPath, isFalse);
      expect(bobNow().hasPath, isFalse);
      expect(h.store.pathHistory.list(bobKey).first.kind, 'reset');
      expect(port.uploads, isEmpty, reason: 'RESET_PATH, not a rewrite of the contact');
    });

    test('after a reset the radio\'s copy is what the phone shows (no route is ever put back by the app)', () async {
      final bob = h.bob(path: true);
      port.radioAdd(bob);
      await h.service.contacts.resetPath(bobKey);
      await h.service.contacts.refreshOne(bobKey);
      expect(port.uploads, isEmpty);
      expect(bobNow().hasPath, isFalse, reason: 'the phone shows what the radio holds');
    });

    test('a ping is remembered on the contact and in ping_results (trimmed to 50)', () {
      h.bob();
      for (var i = 0; i < 60; i++) {
        h.clock.advance(1000);
        h.service.contacts.recordPing(bobKey, kind: 'ping', ok: i.isEven, rttMs: 100 + i);
      }
      expect(bobNow().lastPingRttMs, 159);
      expect(bobNow().lastPingOk, isFalse);
      expect(h.store.pingResults.list(bobKey, limit: 100).length, 50);
    });

    test('path_history keeps the last 20 per contact', () {
      h.bob();
      for (var i = 0; i < 30; i++) {
        h.store.pathHistory.add(PathHistoryEntry(contactKey: bobKey, tsMs: 1000 + i, kind: 'learned', hops: const ['a1'], hashSize: 1));
      }
      expect(h.store.pathHistory.list(bobKey).length, 20);
    });

    test('a discovered route is noted in the history; it cannot be kept by hand', () async {
      h.bob();
      final r = PathRoute.fromHex(const ['a1', 'b2']);
      expect(await h.service.contacts.useDiscoveredRoute(bobKey, r, keep: false), isNull);
      expect(h.store.pathHistory.list(bobKey).first.kind, 'discovered');
      expect(await h.service.contacts.useDiscoveredRoute(bobKey, r, keep: true), isNotNull);
      expect(port.uploads, isEmpty);
    });

    test('a fresh copy from the radio keeps what only the phone knows (last ping, when the route was learned)', () {
      h.bob(path: true);
      h.service.contacts.recordPing(bobKey, kind: 'ping', ok: true, rttMs: 321);
      h.store.contacts.setPathLearned(radioA, bobKey, 4242);
      h.service.applyRadioContacts(radioA, [Contact(radioId: radioA, publicKey: bobKey, type: ContactType.companion, name: 'Bob', outPath: Uint8List.fromList([9]), outPathLen: 1)]);
      expect(bobNow().lastPingRttMs, 321);
      expect(bobNow().pathLearnedMs, 4242);
      expect(bobNow().routeIds, ['09'], reason: 'the route itself is the radio\'s');
    });
  });
}
