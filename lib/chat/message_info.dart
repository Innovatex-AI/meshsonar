// What a message can tell about how it travelled: the inline info strip under a tapped bubble, the message details sheet and
// the DM route subtitle (chat plan 4.2 / 4.4, vocabulary 2.1). Pure Dart.
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

  /// "SNR 6.5 dB · RSSI -92 dBm" (parts that are unknown are left out), or null when neither is known.
  final String? signalText;
  final String? signalWord;
  final int? signalBars;

  const MessageInfo({
    required this.kind,
    required this.routeWord,
    required this.chips,
    required this.hops,
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

/// Builds the strip for [m]. [repeaters] are the known repeater contacts (to name hop hashes); [peer] is the other side's
/// name; for your own message [contact] supplies the saved route.
MessageInfo messageInfo(ChatMessage m, {required Iterable<Contact> repeaters, String? peer, Contact? contact, String selfLabel = 'You'}) {
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

  if (m.isOutgoing) {
    if (m.convKind == ConvKind.channel) {
      return const MessageInfo(kind: TravelKind.searching, routeWord: 'Sent to everyone nearby', chips: [], hops: []);
    }
    if (m.route == Route.flood) return const MessageInfo(kind: TravelKind.searching, routeWord: 'Searching', chips: [], hops: []);
    if (contact == null || !contact.hasPath) {
      return MessageInfo(kind: TravelKind.unknown, routeWord: m.route == Route.direct ? 'Saved route' : 'Route unknown', chips: const [], hops: const []);
    }
    final ids = contact.routeIds;
    final names = [for (final h in ids) hopName(h, repeaters)];
    if (names.isEmpty) {
      return MessageInfo(kind: TravelKind.direct, routeWord: 'Direct', chips: [selfLabel, other], hops: const []);
    }
    return MessageInfo(
        kind: TravelKind.viaRepeaters,
        routeWord: 'Via ${names.length} ${names.length == 1 ? 'repeater' : 'repeaters'}',
        chips: _cap([selfLabel, ...names, other]),
        hops: names);
  }

  // Incoming. pathLen null = it arrived direct; otherwise hops = pathLen (already masked to the low 6 bits).
  final hops = m.pathLen;
  if (hops == null || hops == 0) {
    return MessageInfo(kind: TravelKind.direct, routeWord: 'Direct', chips: [other, selfLabel], hops: const [], signalText: signal, signalWord: word, signalBars: bars);
  }
  final hashes = m.hopHashes;
  final named = hashes.length == hops ? [for (final h in hashes) hopName(h, repeaters)] : <String>[];
  final word2 = 'Via $hops ${hops == 1 ? 'repeater' : 'repeaters'}';
  if (named.isEmpty) {
    // Hash unknown (the radio gave only the hop count): say how many, name none.
    return MessageInfo(kind: TravelKind.viaRepeaters, routeWord: word2, chips: [other, '$hops ${hops == 1 ? 'hop' : 'hops'}', selfLabel], hops: const [], signalText: signal, signalWord: word, signalBars: bars);
  }
  return MessageInfo(kind: TravelKind.viaRepeaters, routeWord: word2, chips: _cap([other, ...named, selfLabel]), hops: named, signalText: signal, signalWord: word, signalBars: bars);
}
