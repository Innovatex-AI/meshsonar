// What a message can tell about how it travelled: the inline info strip under a tapped bubble, the message details sheet and
// the DM route subtitle (chat plan 4.2 / 4.4, vocabulary 2.1). Pure Dart.
import 'hop_resolver.dart';
import 'models.dart';

/// "Strong" / "Good" / "Fair" / "Weak" from SNR in dB (ramp from the theme: >= +5, 0..+5, -5..0, < -5).
String signalWord(double snr) => snr >= 5 ? 'Strong' : (snr >= 0 ? 'Good' : (snr >= -5 ? 'Fair' : 'Weak'));

/// Filled bars of the 3-bar signal glyph for [snr] (3 strong, 2 good, 1 fair, 0 weak).
int signalBars(double snr) => snr >= 5 ? 3 : (snr >= 0 ? 2 : (snr >= -5 ? 1 : 0));

/// "Direct" / "Via N repeaters" / "Searching" / "No route yet" for a direct-message contact (the conversation subtitle).
String dmRouteText(Contact? c) {
  if (c == null) return 'No route yet';
  if (c.forceFlood) return 'Searching';
  if (!c.hasPath) return 'No route yet';
  final n = c.pathHops ?? 0;
  if (n == 0) return 'Direct';
  return 'Via $n ${n == 1 ? 'repeater' : 'repeaters'}';
}

/// Subtitle of a channel: kind plus region ("Hashtag channel · Ohio"). Decision D4.
String channelSubtitle(Channel? ch) {
  if (ch == null) return 'Channel';
  final kind = switch (ch.kind) {
    ChannelKind.public => 'Public channel',
    ChannelKind.hashtag => 'Hashtag channel',
    ChannelKind.private => 'Private channel',
    ChannelKind.system => 'System channel',
  };
  final region = ch.regionScope;
  return region == null || region.isEmpty ? kind : '$kind · $region';
}

String roomSubtitle({required bool joined}) => joined ? 'Room · Joined' : 'Room · Not joined';

/// Names a hop hash: the repeater contact whose public key starts with [hashHex], or `?a1` when none or several match.
String hopName(String hashHex, Iterable<Contact> repeaters) {
  final h = hashHex.toLowerCase();
  final hits = [for (final r in repeaters) if (r.type == ContactType.repeater && r.publicKey.toLowerCase().startsWith(h)) r];
  if (hits.length == 1) return hits.first.displayName;
  return '?$h';
}

/// True when more than one known repeater shares [hashHex] (the radio cannot tell them apart).
bool hashCollides(String hashHex, Iterable<Contact> repeaters) =>
    repeaters.where((r) => r.type == ContactType.repeater && r.publicKey.toLowerCase().startsWith(hashHex.toLowerCase())).length > 1;

enum TravelKind { direct, viaRepeaters, searching, unknown }

class MessageInfo {
  final TravelKind kind;

  /// "Direct" / "Searching" / "Via 2 repeaters" / "Route unknown".
  final String routeWord;

  /// Chips of the route, first node first: ["You", "Ridge", "Maya"]. Capped at 3 with a trailing "+N" chip.
  final List<String> chips;

  /// Every hop named, uncapped (the details sheet and the VoiceOver value).
  final List<String> hops;

  /// The hops resolved (name, ambiguity, position), first hop first; empty when unknown or direct.
  final List<HopNode> nodes;

  /// For a sent DM: true when [nodes] is the route this message actually used (recorded at send), false when it is only the
  /// contact's saved route (messages sent before that was recorded).
  final bool routeIsActual;

  /// "SNR 6.5 dB · RSSI -92 dBm" (parts that are unknown are left out), or null when neither is known.
  final String? signalText;
  final String? signalWord;
  final int? signalBars;

  const MessageInfo({
    required this.kind,
    required this.routeWord,
    required this.chips,
    required this.hops,
    this.nodes = const [],
    this.routeIsActual = true,
    this.signalText,
    this.signalWord,
    this.signalBars,
  });

  /// One sentence for the strip and for VoiceOver.
  String get sentence {
    final parts = <String>[
      chips.isEmpty ? routeWord : '$routeWord, ${chips.join(' › ')}',
      if (signalText != null) signalText! + (signalWord == null ? '' : ' · $signalWord'),
    ];
    return parts.join('. ');
  }
}

List<String> _cap(List<String> nodes) {
  if (nodes.length <= 4) return nodes;
  // Both ends and the first repeater stay; the rest is "+N".
  return [nodes.first, nodes[1], '+${nodes.length - 3}', nodes.last];
}

/// Builds the strip for [m]. Hop names come from [resolver] when given, else from the radio's [repeaters]; [peer] is the other
/// side's name. For your own DM the route is the one recorded when it was sent ([ChatMessage.sentPath]); for a message sent
/// before that existed, [contact]'s saved route stands in (and [MessageInfo.routeIsActual] is false). For a channel
/// message [repeatsHeard] (sent) or the arrivals (received) are counted from [ChatMessage.repeatsHeard].
MessageInfo messageInfo(ChatMessage m,
    {Iterable<Contact> repeaters = const [], HopResolver? resolver, String? peer, Contact? contact, String selfLabel = 'You'}) {
  final res = resolver ?? HopResolver(contacts: repeaters);
  final other = peer ?? m.senderName ?? 'Them';
  String? signal;
  String? word;
  int? bars;
  if (!m.isOutgoing) {
    final snr = m.snr;
    final rssi = m.rssi;
    final bits = [if (snr != null) 'SNR ${snr.toStringAsFixed(1)} dB', if (rssi != null) 'RSSI $rssi dBm'];
    signal = bits.isEmpty ? null : bits.join(' · ');
    if (snr != null) {
      word = signalWord(snr);
      bars = signalBars(snr);
    }
  }

  String via(int n) => 'Via $n ${n == 1 ? 'repeater' : 'repeaters'}';

  if (m.isOutgoing) {
    if (m.convKind == ConvKind.channel) {
      final n = m.repeatsHeard;
      return MessageInfo(
          kind: TravelKind.searching,
          routeWord: n == 0 ? 'Sent to everyone nearby' : 'Heard by $n ${n == 1 ? 'repeater' : 'repeaters'}',
          chips: const [],
          hops: const []);
    }
    if (m.route == Route.flood) return const MessageInfo(kind: TravelKind.searching, routeWord: 'Searching', chips: [], hops: []);
    // The route this message used (v4), else the contact's saved route for older messages.
    final List<String> ids;
    final bool actual;
    if (m.sentPath != null) {
      ids = m.sentHops;
      actual = true;
    } else if (contact != null && contact.hasPath) {
      ids = contact.routeIds;
      actual = false;
    } else {
      return MessageInfo(kind: TravelKind.unknown, routeWord: m.route == Route.direct ? 'Saved route' : 'Route unknown', chips: const [], hops: const []);
    }
    final nodes = res.resolveAll(ids);
    if (nodes.isEmpty) {
      return MessageInfo(kind: TravelKind.direct, routeWord: 'Direct', chips: [selfLabel, other], hops: const [], routeIsActual: actual);
    }
    final names = [for (final n in nodes) n.label];
    return MessageInfo(
        kind: TravelKind.viaRepeaters,
        routeWord: via(nodes.length),
        chips: _cap([selfLabel, ...names, other]),
        hops: names,
        nodes: nodes,
        routeIsActual: actual);
  }

  // Incoming. pathLen null = it arrived direct; otherwise hops = pathLen (already masked to the low 6 bits).
  final hops = m.pathLen;
  if (hops == null || hops == 0) {
    return MessageInfo(kind: TravelKind.direct, routeWord: 'Direct', chips: [other, selfLabel], hops: const [], signalText: signal, signalWord: word, signalBars: bars);
  }
  final hashes = m.hopHashes;
  final nodes = hashes.length == hops ? res.resolveAll(hashes) : <HopNode>[];
  if (nodes.isEmpty) {
    // Hash unknown (the radio gave only the hop count): say how many, name none.
    return MessageInfo(
        kind: TravelKind.viaRepeaters,
        routeWord: via(hops),
        chips: [other, '$hops ${hops == 1 ? 'repeater' : 'repeaters'}', selfLabel],
        hops: const [],
        signalText: signal,
        signalWord: word,
        signalBars: bars);
  }
  final named = [for (final n in nodes) n.label];
  return MessageInfo(
      kind: TravelKind.viaRepeaters,
      routeWord: via(hops),
      chips: _cap([other, ...named, selfLabel]),
      hops: named,
      nodes: nodes,
      signalText: signal,
      signalWord: word,
      signalBars: bars);
}

/// One heard copy of a channel message, resolved for display (CR4). For a message you sent, [relayedBy] is the repeater
/// that heard you and passed it on; for one you received it is the first repeater after the sender.
class RepeatView {
  final MessageRepeat repeat;
  final List<HopNode> path;

  /// Milliseconds after the message was sent (sent) or first received (received); null when unknown.
  final int? afterMs;
  const RepeatView({required this.repeat, required this.path, this.afterMs});

  HopNode? get relayedBy => path.isEmpty ? null : path.first;
  HopNode? get heardFrom => path.isEmpty ? null : path.last;
  int get hops => repeat.hops;

  /// "SNR 6.5 · RSSI -92" (parts that are unknown are left out), or null.
  String? get signal {
    final bits = [if (repeat.snr != null) 'SNR ${repeat.snr!.toStringAsFixed(1)}', if (repeat.rssi != null) 'RSSI ${repeat.rssi}'];
    return bits.isEmpty ? null : bits.join(' · ');
  }
}

List<RepeatView> repeatViews(ChatMessage m, List<MessageRepeat> repeats, HopResolver resolver) => [
      for (final r in repeats)
        RepeatView(repeat: r, path: resolver.resolveAll(r.hopHashes), afterMs: r.heardMs >= m.tsLocalMs ? r.heardMs - m.tsLocalMs : null),
    ];

/// "Ridge, Hill +2": the repeaters that relayed a sent message, distinct, first heard first, at most [max] named.
String relayedBySummary(List<RepeatView> views, {int max = 2}) {
  final names = <String>[];
  for (final v in views) {
    final n = v.relayedBy?.label;
    if (n != null && !names.contains(n)) names.add(n);
  }
  if (names.length <= max) return names.join(', ');
  return '${names.take(max).join(', ')} +${names.length - max}';
}
