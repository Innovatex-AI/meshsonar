// The Packets list filters (AZ-3.2): every filter of `GET /v1/packets` (analyzer-api-contract.md 8.2) plus the
// sheet's hops and SNR ranges and the "ours / outside" source switch, which the contract expresses in the filter
// language (section 10). One immutable value that
//   - maps to the `/v1/packets` query ([toV1Query]),
//   - maps to today's `region-packets` query while `/v1` is not live, naming what that read cannot do ([toLegacy]),
//   - is carried in NetworkRequest, so a list state is a link (`/packets?type=ADVERT&filter=hops%20%3E%3D%203`) and
//     comes back from one ([fromQuery] lifts the sheet's own clauses back out of `filter`),
//   - is stored as a saved filter on the device ([toJson] / [fromJson]; contract 13.26).
// Pure Dart: no Flutter imports.
import 'dart:convert';

import 'filter_language.dart';
import 'packet_models.dart';

/// The source switch of the sheet: every source, our observers only (fixed and phones), or outside feeds only.
enum PacketSourceFilter { all, ours, outside }

/// Our own source ids (contract 1.3).
const List<String> firstPartySources = ['meshsonar', 'meshsonar-phone'];

final _hex = RegExp(r'^[0-9a-f]+$');

/// One active filter shown as a chip, removable by [id].
class PacketFilterChip {
  final String id, label;
  const PacketFilterChip(this.id, this.label);
}

/// What today's `region-packets` read can be asked ([query]), what the phone filters itself on each page
/// ([keep]), and the filters it cannot apply at all ([unapplied], plain words for the banner).
class LegacyPacketQuery {
  final Map<String, String> query;
  final bool Function(PacketListRow row) keep;
  final List<String> unapplied;
  const LegacyPacketQuery(this.query, this.keep, this.unapplied);
}

class PacketFilter {
  /// Type names (`ADVERT`, `GRP_TXT`); empty = every type.
  final Set<String> types;

  /// Route names (`FLOOD`); empty = every route.
  final Set<String> routes;

  /// Observer ids (at most 20).
  final List<String> observers;

  /// Node keys, 64 hex (at most 20): origin or a unique / likely hop.
  final List<String> nodes;

  /// Node or hop prefix (2 to 6 hex): matched with the filter language's `hop ~`.
  final String? prefix;

  /// A packet hash or a prefix of 8 to 16 hex.
  final String? hash;

  /// Channel ids (`public`, `tag:wardriving`, `enc:62`).
  final Set<String> channels;

  /// `#name`, `unscoped` or `unmatched`.
  final String? scope;
  final PacketSourceFilter source;
  final int? hopsMin, hopsMax;
  final double? snrMin, snrMax;

  /// The filter-language string typed by the person (without the clauses above).
  final String text;

  const PacketFilter({
    this.types = const {},
    this.routes = const {},
    this.observers = const [],
    this.nodes = const [],
    this.prefix,
    this.hash,
    this.channels = const {},
    this.scope,
    this.source = PacketSourceFilter.all,
    this.hopsMin,
    this.hopsMax,
    this.snrMin,
    this.snrMax,
    this.text = '',
  });

  static const PacketFilter none = PacketFilter();

  bool get isEmpty => toJson().isEmpty;

  /// True when a filter narrows the list enough for the long windows (contract 3.3: `hash`, `node`, `observer`,
  /// `channel` allow 90 days).
  bool get narrows => hash != null || nodes.isNotEmpty || observers.isNotEmpty || channels.isNotEmpty;

  PacketFilter copyWith({
    Set<String>? types,
    Set<String>? routes,
    List<String>? observers,
    List<String>? nodes,
    String? prefix,
    bool clearPrefix = false,
    String? hash,
    bool clearHash = false,
    Set<String>? channels,
    String? scope,
    bool clearScope = false,
    PacketSourceFilter? source,
    int? hopsMin,
    bool clearHopsMin = false,
    int? hopsMax,
    bool clearHopsMax = false,
    double? snrMin,
    bool clearSnrMin = false,
    double? snrMax,
    bool clearSnrMax = false,
    String? text,
  }) =>
      PacketFilter(
        types: types ?? this.types,
        routes: routes ?? this.routes,
        observers: observers ?? this.observers,
        nodes: nodes ?? this.nodes,
        prefix: clearPrefix ? null : (prefix ?? this.prefix),
        hash: clearHash ? null : (hash ?? this.hash),
        channels: channels ?? this.channels,
        scope: clearScope ? null : (scope ?? this.scope),
        source: source ?? this.source,
        hopsMin: clearHopsMin ? null : (hopsMin ?? this.hopsMin),
        hopsMax: clearHopsMax ? null : (hopsMax ?? this.hopsMax),
        snrMin: clearSnrMin ? null : (snrMin ?? this.snrMin),
        snrMax: clearSnrMax ? null : (snrMax ?? this.snrMax),
        text: text ?? this.text,
      );

  static String _num(double v) => v == v.truncateToDouble() ? v.toInt().toString() : v.toString();

  /// The clauses the sheet adds to the filter language: hops, SNR, node prefix, outside sources.
  List<String> get sheetClauses => [
        if (hopsMin != null && hopsMax != null) 'hops between $hopsMin and $hopsMax' else if (hopsMin != null) 'hops >= $hopsMin' else if (hopsMax != null) 'hops <= $hopsMax',
        if (snrMin != null && snrMax != null)
          'snr between ${_num(snrMin!)} and ${_num(snrMax!)}'
        else if (snrMin != null)
          'snr >= ${_num(snrMin!)}'
        else if (snrMax != null)
          'snr <= ${_num(snrMax!)}',
        if (prefix != null) 'hop ~ $prefix',
        if (source == PacketSourceFilter.outside) 'source not in (${firstPartySources.join(', ')})',
      ];

  /// The `filter` parameter: the person's text (canonical when it parses; wrapped when it has a top-level `or`) and
  /// the sheet's clauses, joined with `and`. Null when there is none.
  String? get expression {
    final parts = <String>[];
    final t = text.trim();
    if (t.isNotEmpty) {
      FilterNode? n;
      try {
        n = parseFilter(t);
      } on FilterError {
        n = null;
      }
      if (n == null) {
        parts.add('($t)');
      } else {
        parts.add(n is FilterOr ? '(${n.print()})' : n.print());
      }
    }
    parts.addAll(sheetClauses);
    return parts.isEmpty ? null : parts.join(' and ');
  }

  /// The `/v1/packets` query parameters (contract 8.2), without window, paging or `include`.
  Map<String, String> toV1Query() => {
        if (types.isNotEmpty) 'type': (types.toList()..sort()).join(','),
        if (routes.isNotEmpty) 'route': (routes.toList()..sort()).join(','),
        if (observers.isNotEmpty) 'observer': observers.take(20).join(','),
        if (nodes.isNotEmpty) 'node': nodes.take(20).join(','),
        'hash': ?hash,
        if (channels.isNotEmpty) 'channel': (channels.toList()..sort()).join(','),
        'scope': ?scope,
        if (source == PacketSourceFilter.ours) 'source': firstPartySources.join(','),
        'filter': ?expression,
      };

  /// The link form (same keys as [toV1Query]: the website reads the contract's own parameters).
  Map<String, String> toQuery() => toV1Query();

  /// Reads the link / query form back. A clause the sheet owns (hops, SNR, hop prefix, outside sources) at the top
  /// level of `filter` comes back into its control; the rest stays as text. Bad values are dropped.
  static PacketFilter fromQuery(Map<String, String> q) {
    List<String> csv(String k) => [for (final v in (q[k] ?? '').split(',')) if (v.trim().isNotEmpty) v.trim()];
    final types = {for (final t in csv('type')) ?(packetTypeNumber(t) == null ? null : packetTypeWireName(packetTypeNumber(t)!))}..remove('UNKNOWN');
    final routes = {for (final r in csv('route')) ?(packetRouteNumber(r) == null ? null : packetRouteWireName(packetRouteNumber(r)!))}..remove('UNKNOWN');
    final nodes = [for (final n in csv('node')) if (n.length == 64 && _hex.hasMatch(n.toLowerCase())) n.toLowerCase()];
    final observers = [for (final o in csv('observer')) if (RegExp(r'^[A-Za-z0-9_.:-]{1,160}$').hasMatch(o)) (o.length == 64 && _hex.hasMatch(o.toLowerCase()) ? o.toLowerCase() : o)];
    final h = q['hash']?.toLowerCase();
    final channels = {for (final c in csv('channel')) if (RegExp(r'^(public|tag:[^\s/,]{1,64}|enc:[0-9a-f]{2})$').hasMatch(c)) c};
    final scope = q['scope'];
    final src = csv('source');
    var f = PacketFilter(
      types: types,
      routes: routes,
      nodes: nodes,
      observers: observers,
      hash: h != null && h.length >= 8 && h.length <= 16 && _hex.hasMatch(h) ? h : null,
      channels: channels,
      scope: scope != null && RegExp(r'^(#[^\s,]{1,31}|unscoped|unmatched)$').hasMatch(scope) ? scope : null,
      source: src.isNotEmpty && src.every(firstPartySources.contains) ? PacketSourceFilter.ours : PacketSourceFilter.all,
    );
    final text = q['filter']?.trim() ?? '';
    if (text.isEmpty) return f;
    FilterNode? n;
    try {
      n = parseFilter(text);
    } on FilterError {
      return f.copyWith(text: text);
    }
    if (n == null) return f;
    final rest = <FilterNode>[];
    for (final c in n is FilterAnd ? n.children : [n]) {
      final lifted = c is FilterClause ? _lift(f, c) : null;
      if (lifted == null) {
        rest.add(c);
      } else {
        f = lifted;
      }
    }
    final restText = rest.isEmpty ? '' : (rest.length == 1 ? rest.single.print() : FilterAnd(rest).print());
    return f.copyWith(text: restText);
  }

  /// [f] with clause [c] taken into a sheet control, or null when the clause is not one of the sheet's (or the
  /// control is already set).
  static PacketFilter? _lift(PacketFilter f, FilterClause c) {
    final field = c.field.toLowerCase();
    final nums = [for (final v in c.values) v.number];
    if (nums.contains(null) && field != 'source' && field != 'hop') return null;
    switch (field) {
      case 'hops':
        if (f.hopsMin != null || f.hopsMax != null || nums.any((n) => n is! int)) return null;
        return switch (c.op) {
          'between' => f.copyWith(hopsMin: nums[0]!.toInt(), hopsMax: nums[1]!.toInt()),
          '>=' => f.copyWith(hopsMin: nums[0]!.toInt()),
          '<=' => f.copyWith(hopsMax: nums[0]!.toInt()),
          _ => null,
        };
      case 'snr':
        if (f.snrMin != null || f.snrMax != null) return null;
        return switch (c.op) {
          'between' => f.copyWith(snrMin: nums[0]!.toDouble(), snrMax: nums[1]!.toDouble()),
          '>=' => f.copyWith(snrMin: nums[0]!.toDouble()),
          '<=' => f.copyWith(snrMax: nums[0]!.toDouble()),
          _ => null,
        };
      case 'hop':
        final v = c.values.single.text.toLowerCase();
        if (f.prefix != null || c.op != '~' || !RegExp(r'^[0-9a-f]{2,6}$').hasMatch(v) || v.length.isOdd) return null;
        return f.copyWith(prefix: v);
      case 'source':
        final vs = {for (final v in c.values) v.text.toLowerCase()};
        if (f.source != PacketSourceFilter.all || c.op != 'not in' || vs.length != 2 || !vs.containsAll(firstPartySources)) return null;
        return f.copyWith(source: PacketSourceFilter.outside);
    }
    return null;
  }

  /// Today's `region-packets` read (one type, one route, one observer key, one node, a whole hash, since/until):
  /// what it can be asked, what the phone filters on each page, and what it cannot do.
  LegacyPacketQuery toLegacy() {
    final q = <String, String>{};
    final unapplied = <String>[];
    if (types.length == 1) q['type'] = '${packetTypeNumber(types.single)}';
    if (routes.length == 1) q['route'] = '${packetRouteNumber(routes.single)}';
    if (observers.length == 1 && RegExp(r'^[0-9a-f]{1,64}$').hasMatch(observers.single)) {
      q['observer'] = observers.single;
    } else if (observers.isNotEmpty) {
      unapplied.add('observer');
    }
    if (nodes.length == 1) {
      q['node'] = nodes.single;
    } else if (nodes.isNotEmpty) {
      unapplied.add('node');
    }
    if (hash != null && hash!.length == 16) q['hash'] = hash!;
    if (channels.isNotEmpty) unapplied.add('channel');
    if (scope != null) unapplied.add('scope');
    if (prefix != null) unapplied.add('node prefix');
    if (source != PacketSourceFilter.all) unapplied.add('source');
    if (text.trim().isNotEmpty) unapplied.add('filter text');
    final typeNums = {for (final t in types) packetTypeNumber(t)};
    final routeNames = routes;
    bool keep(PacketListRow r) {
      if (types.length > 1 && !typeNums.contains(r.type)) return false;
      if (routes.length > 1 && !routeNames.contains(r.route)) return false;
      if (hash != null && !r.hash.startsWith(hash!)) return false;
      if (hopsMin != null && r.hops < hopsMin!) return false;
      if (hopsMax != null && r.hops > hopsMax!) return false;
      if (snrMin != null && (r.bestSnr == null || r.bestSnr! < snrMin!)) return false;
      if (snrMax != null && (r.bestSnr == null || r.bestSnr! > snrMax!)) return false;
      return true;
    }

    return LegacyPacketQuery(q, keep, unapplied);
  }

  /// The active filters as chips, in a fixed order.
  List<PacketFilterChip> get chips {
    String short(String s) => s.length > 14 ? '${s.substring(0, 8)}…' : s;
    return [
      for (final t in types.toList()..sort()) PacketFilterChip('type:$t', packetTypeLabel(t)),
      for (final r in routes.toList()..sort()) PacketFilterChip('route:$r', packetRouteLabel(r)),
      for (final o in observers) PacketFilterChip('observer:$o', 'Observer ${short(o)}'),
      for (final n in nodes) PacketFilterChip('node:$n', 'Node ${short(n)}'),
      if (prefix != null) PacketFilterChip('prefix', 'Hop $prefix'),
      if (hash != null) PacketFilterChip('hash', 'Hash ${short(hash!)}'),
      for (final c in channels.toList()..sort()) PacketFilterChip('channel:$c', c == 'public' ? 'Public' : (c.startsWith('tag:') ? '#${c.substring(4)}' : 'Private channel ID ${c.substring(4)}')),
      if (scope != null) PacketFilterChip('scope', 'Scope $scope'),
      if (source != PacketSourceFilter.all) PacketFilterChip('source', source == PacketSourceFilter.ours ? 'Our observers' : 'Outside feeds'),
      if (hopsMin != null || hopsMax != null)
        PacketFilterChip('hops', hopsMin != null && hopsMax != null ? 'Hops $hopsMin-$hopsMax' : (hopsMin != null ? 'Hops $hopsMin+' : 'Hops up to $hopsMax')),
      if (snrMin != null || snrMax != null)
        PacketFilterChip('snr', snrMin != null && snrMax != null ? 'SNR ${_num(snrMin!)} to ${_num(snrMax!)} dB' : (snrMin != null ? 'SNR from ${_num(snrMin!)} dB' : 'SNR up to ${_num(snrMax!)} dB')),
      if (text.trim().isNotEmpty) PacketFilterChip('text', text.trim().length > 24 ? '${text.trim().substring(0, 22)}…' : text.trim()),
    ];
  }

  /// This filter without the chip [id].
  PacketFilter without(String id) {
    final colon = id.indexOf(':');
    final kind = colon < 0 ? id : id.substring(0, colon);
    final v = colon < 0 ? '' : id.substring(colon + 1);
    return switch (kind) {
      'type' => copyWith(types: {...types}..remove(v)),
      'route' => copyWith(routes: {...routes}..remove(v)),
      'observer' => copyWith(observers: [...observers]..remove(v)),
      'node' => copyWith(nodes: [...nodes]..remove(v)),
      'prefix' => copyWith(clearPrefix: true),
      'hash' => copyWith(clearHash: true),
      'channel' => copyWith(channels: {...channels}..remove(v)),
      'scope' => copyWith(clearScope: true),
      'source' => copyWith(source: PacketSourceFilter.all),
      'hops' => copyWith(clearHopsMin: true, clearHopsMax: true),
      'snr' => copyWith(clearSnrMin: true, clearSnrMax: true),
      'text' => copyWith(text: ''),
      _ => this,
    };
  }

  Map<String, Object?> toJson() => {
        if (types.isNotEmpty) 'types': types.toList()..sort(),
        if (routes.isNotEmpty) 'routes': routes.toList()..sort(),
        if (observers.isNotEmpty) 'observers': observers,
        if (nodes.isNotEmpty) 'nodes': nodes,
        'prefix': ?prefix,
        'hash': ?hash,
        if (channels.isNotEmpty) 'channels': channels.toList()..sort(),
        'scope': ?scope,
        if (source != PacketSourceFilter.all) 'source': source.name,
        'hopsMin': ?hopsMin,
        'hopsMax': ?hopsMax,
        'snrMin': ?snrMin,
        'snrMax': ?snrMax,
        if (text.trim().isNotEmpty) 'text': text.trim(),
      };

  static PacketFilter fromJson(Object? j) {
    if (j is! Map) return none;
    List<String> l(String k) => [if (j[k] is List) for (final v in j[k] as List) if (v is String) v];
    double? d(String k) => j[k] is num ? (j[k] as num).toDouble() : null;
    int? i(String k) => j[k] is num ? (j[k] as num).toInt() : null;
    String? s(String k) => j[k] is String && (j[k] as String).isNotEmpty ? j[k] as String : null;
    return PacketFilter(
      types: l('types').toSet(),
      routes: l('routes').toSet(),
      observers: l('observers'),
      nodes: l('nodes'),
      prefix: s('prefix'),
      hash: s('hash'),
      channels: l('channels').toSet(),
      scope: s('scope'),
      source: PacketSourceFilter.values.where((e) => e.name == j['source']).firstOrNull ?? PacketSourceFilter.all,
      hopsMin: i('hopsMin'),
      hopsMax: i('hopsMax'),
      snrMin: d('snrMin'),
      snrMax: d('snrMax'),
      text: s('text') ?? '',
    );
  }

  @override
  bool operator ==(Object other) => other is PacketFilter && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
  @override
  String toString() => 'PacketFilter(${jsonEncode(toJson())})';
}

/// A filter saved on the device under a name (contract 13.26: saved filters live on the device in v1).
class SavedPacketFilter {
  final String name;
  final PacketFilter filter;

  /// The window saved with it (`1h`, `24h`, ...), null = keep the current one.
  final String? window;
  const SavedPacketFilter(this.name, this.filter, {this.window});

  Map<String, Object?> toJson() => {'name': name, 'filter': filter.toJson(), 'window': ?window};
  static SavedPacketFilter? fromJson(Object? j) {
    if (j is! Map || j['name'] is! String || (j['name'] as String).trim().isEmpty) return null;
    return SavedPacketFilter(j['name'] as String, PacketFilter.fromJson(j['filter']), window: j['window'] is String ? j['window'] as String : null);
  }
}
