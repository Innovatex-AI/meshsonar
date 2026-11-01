// Discover nearby: a zero-hop NODE_DISCOVER_REQ (CMD_SEND_CONTROL_DATA 55) that nearby repeaters, rooms and sensors answer
// with their own key and the SNR at which THEY heard the request. This radio measures the SNR of each answer, so every
// result has both directions.
//
// VERIFIED on hardware (research doc 2026-11-01, section B and live-run4): request [0x80|prefix_only][type filter bit n =
// node type n][tag u32][since u32]; answer = PUSH_CODE_CONTROL_DATA [snr x4][rssi][path_len][0x90|type][their snr x4]
// [tag u32][key 32, or 8 with prefix_only]; first answer after 1.5-2.4 s; 4 of 5 requests answered, one empty (silent loss
// is normal); repeaters limit themselves to 4 requests per 120 s, so this tool does too and shows the wait as a cooldown,
// never as an error.
// Pure Dart.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/heard.dart' show haversineM;
import '../command_queue.dart';
import '../crypto.dart';
import '../inbound.dart';
import '../protocol.dart';
import '../tx_arbiter.dart';
import 'tool_frames.dart';
import 'tool_state.dart';
import 'tools_radio.dart';

/// A sliding-window limiter: at most [max] uses in [window].
class RateWindow {
  final int max;
  final Duration window;
  final List<DateTime> _uses = [];
  RateWindow(this.max, this.window);

  void _prune(DateTime now) => _uses.removeWhere((t) => now.difference(t) >= window);

  /// How many uses are left right now.
  int remaining(DateTime now) {
    _prune(now);
    return max - _uses.length;
  }

  /// Time until the next use is allowed; null when one is allowed now.
  Duration? wait(DateTime now) {
    _prune(now);
    if (_uses.length < max) return null;
    return window - now.difference(_uses.first);
  }

  void use(DateTime now) {
    _prune(now);
    _uses.add(now);
  }
}

class DiscoveredNode {
  /// Full 64-hex key, or 16 hex (8 bytes) when only a prefix was returned.
  final String keyHex;
  final int nodeType;

  /// SNR at which this radio heard the answer (their signal to us), dB.
  final double snrHeardDb;

  /// SNR at which the node heard our request (our signal to them), dB.
  final double snrTheyHeardDb;
  final double rssiDbm;
  final DateTime at;

  /// Name when the radio already has this node as a contact.
  final String? knownName;
  final bool inContacts;
  final double? lat, lon;
  const DiscoveredNode({
    required this.keyHex,
    required this.nodeType,
    required this.snrHeardDb,
    required this.snrTheyHeardDb,
    required this.rssiDbm,
    required this.at,
    this.knownName,
    this.inContacts = false,
    this.lat,
    this.lon,
  });

  bool get hasFullKey => keyHex.length == 64;
  String get shortKey => keyHex.substring(0, 8);

  /// The weaker direction decides whether the link works.
  double get weakestSnrDb => math.min(snrHeardDb, snrTheyHeardDb);

  String get displayName => knownName ?? '${typeName(nodeType)} $shortKey';

  static String typeName(int t) => switch (t) { 1 => 'Chat', 2 => 'Repeater', 3 => 'Room', 4 => 'Sensor', _ => 'Node' };

  DiscoveredNode copyWith({bool? inContacts, String? knownName}) => DiscoveredNode(
      keyHex: keyHex,
      nodeType: nodeType,
      snrHeardDb: snrHeardDb,
      snrTheyHeardDb: snrTheyHeardDb,
      rssiDbm: rssiDbm,
      at: at,
      knownName: knownName ?? this.knownName,
      inContacts: inContacts ?? this.inContacts,
      lat: lat,
      lon: lon);
}

enum DiscoverStatus { idle, scanning, done, cooldown, notConnected, refused }

class DiscoverTool with ToolChanges {
  final ToolsRadio radio;
  final TxArbiter arbiter;
  final DateTime Function() _clock;
  final math.Random _rng;

  /// How long answers are collected. First answers took 1.5-2.4 s; the repeaters jitter their reply up to a few seconds.
  final Duration listenFor;
  final RateWindow limiter;

  List<DiscoveredNode> _results = const [];
  DiscoverStatus _status = DiscoverStatus.idle;
  String? _message;
  DateTime? _lastScanAt;
  List<RadioContact> _contacts = const [];

  DiscoverTool(this.radio, this.arbiter,
      {DateTime Function()? clock, math.Random? rng, this.listenFor = const Duration(seconds: 15), RateWindow? limiter})
      : _clock = clock ?? DateTime.now,
        _rng = rng ?? math.Random.secure(),
        limiter = limiter ?? RateWindow(4, const Duration(seconds: 120));

  DiscoverStatus get status => _status;
  String? get message => _message;
  DateTime? get lastScanAt => _lastScanAt;

  /// Sorted by the weaker direction, strongest first.
  List<DiscoveredNode> get results => _results;

  /// Requests left in the current window.
  int get requestsLeft => limiter.remaining(_clock());

  /// Wait until the next scan may go; null when it may go now.
  Duration? cooldown() => limiter.wait(_clock());

  /// Airtime of one request: a 20-byte zero-hop control packet.
  double estimateAirtimeMs() => arbiter.airParams?.call()?.airtimeMs(20) ?? 150;

  /// Gives the tool the radio's contacts (names, positions, "already added").
  void setContacts(List<RadioContact> contacts) {
    _contacts = contacts;
    _results = [for (final r in _results) _annotate(r)];
    notifyChanged();
  }

  DiscoveredNode _annotate(DiscoveredNode r) {
    final c = _contactFor(r.keyHex);
    if (c == null) return r;
    return DiscoveredNode(
        keyHex: r.keyHex,
        nodeType: r.nodeType,
        snrHeardDb: r.snrHeardDb,
        snrTheyHeardDb: r.snrTheyHeardDb,
        rssiDbm: r.rssiDbm,
        at: r.at,
        knownName: c.name.isEmpty ? null : c.name,
        inContacts: true,
        lat: c.lat,
        lon: c.lon);
  }

  RadioContact? _contactFor(String keyHex) {
    for (final c in _contacts) {
      if (c.publicKeyHex.startsWith(keyHex) || keyHex.startsWith(c.publicKeyHex)) return c;
    }
    return null;
  }

  /// Sends one discovery request and collects answers for [listenFor]. Returns the results of this scan. Never throws.
  Future<List<DiscoveredNode>> scan({Iterable<int> types = const [AdvType.repeater, AdvType.room, AdvType.sensor], bool fullKeys = true}) async {
    if (_status == DiscoverStatus.scanning) return _results;
    if (!radio.isConnected) {
      _status = DiscoverStatus.notConnected;
      _message = 'No radio is connected.';
      notifyChanged();
      return _results;
    }
    final now = _clock();
    final wait = limiter.wait(now);
    if (wait != null) {
      _status = DiscoverStatus.cooldown;
      _message = 'Nearby repeaters answer at most 4 scans every 2 minutes. Next scan in ${wait.inSeconds + 1} s.';
      notifyChanged();
      return _results;
    }
    final tag = _rng.nextInt(0xFFFFFFFF) + 1;
    final found = <String, DiscoveredNode>{};
    final sub = radio.controlPackets.listen((p) {
      final r = DiscoverResponse.tryParse(p.payload);
      if (r == null || r.tag != tag) return;
      final key = toHex(r.publicKey);
      final n = _annotate(DiscoveredNode(
          keyHex: key, nodeType: r.nodeType, snrHeardDb: p.snrDb, snrTheyHeardDb: r.remoteSnrDb, rssiDbm: p.rssiDbm.toDouble(), at: _clock()));
      final old = found[key];
      if (old == null || n.weakestSnrDb > old.weakestSnrDb) found[key] = n;
      _results = _sorted(found.values);
      notifyChanged();
    });
    _status = DiscoverStatus.scanning;
    _message = null;
    _results = const [];
    _lastScanAt = now;
    limiter.use(now);
    notifyChanged();
    try {
      final payload = encodeDiscoverRequestPayload(tag, typeFilter: discoverFilterFor(types), prefixOnly: !fullKeys);
      final Frame reply;
      try {
        reply = await radio.send(encodeSendControlData(payload), priority: CommandPriority.discovery);
      } on TimeoutException {
        _status = DiscoverStatus.refused;
        _message = 'The radio did not answer the scan command.';
        return _results;
      } on StateError {
        _status = DiscoverStatus.notConnected;
        _message = 'The radio disconnected.';
        return _results;
      }
      if (reply is! OkFrame) {
        _status = DiscoverStatus.refused;
        _message = reply is ErrFrame && reply.code == ErrCode.unsupportedCmd
            ? 'This radio’s firmware cannot scan for nearby nodes (it needs version 8 or newer).'
            : 'The radio refused the scan.';
        return _results;
      }
      arbiter.recordTx(TxPriority.discovery, estimateAirtimeMs());
      await Future<void>.delayed(listenFor);
      _results = _sorted(found.values);
      _status = DiscoverStatus.done;
      _message = _results.isEmpty
          ? 'Nothing answered. That is normal on a quiet mesh: replies are sometimes lost. Try again after the cooldown, or move to higher ground.'
          : null;
      return _results;
    } finally {
      await sub.cancel();
      notifyChanged();
    }
  }

  static List<DiscoveredNode> _sorted(Iterable<DiscoveredNode> v) =>
      v.toList()..sort((a, b) => b.weakestSnrDb.compareTo(a.weakestSnrDb));

  /// Adds a discovered node to the radio's contacts (ADD_UPDATE_CONTACT, path unknown so the first message floods). Needs the
  /// full key. Returns an error text, or null on success.
  Future<String?> addToContacts(DiscoveredNode n, {String? name}) async {
    if (!n.hasFullKey) return 'Only the start of this node’s key came back, so it cannot be added. Scan again.';
    if (!radio.isConnected) return 'No radio is connected.';
    try {
      await radio.addContact(RadioContact(
          publicKeyHex: n.keyHex,
          type: n.nodeType,
          outPath: Uint8List(0),
          name: (name ?? n.displayName).trim().isEmpty ? n.displayName : (name ?? n.displayName).trim(),
          lastAdvert: _clock().toUtc().millisecondsSinceEpoch ~/ 1000));
    } catch (e) {
      return 'The radio did not accept the contact (its contact list may be full).';
    }
    _results = [for (final r in _results) r.keyHex == n.keyHex ? r.copyWith(inContacts: true, knownName: name ?? n.displayName) : r];
    notifyChanged();
    return null;
  }

  /// Distance from [lat],[lon] to a result, km; null without a position.
  double? distanceKm(DiscoveredNode n, double lat, double lon) =>
      n.lat == null || n.lon == null ? null : haversineM(lat, lon, n.lat!, n.lon!) / 1000;

  void dispose() => disposeChanges();
}
