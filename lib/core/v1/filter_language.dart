// The packet filter language (analyzer-api-contract.md section 10) on the phone: parse, check against the field
// catalogue (`GET /v1/filters/fields`, with a built-in copy for when `/v1` is not live or the phone is offline), print
// back in one canonical form (so a saved or shared filter round-trips), and suggest the next word while typing.
// The server parses the same string again; this side exists so a mistake shows under the text field before a request,
// with the character position, and so the filter sheet can lift its own clauses (hops, SNR, outside sources) back out
// of a shared link.
//
//   expr    := term { ("and" | "or") term }        ; "and" binds tighter than "or"
//   term    := "not" term | "(" expr ")" | clause
//   clause  := field op value | field "in" "(" value {"," value} ")" | field "not in" "(" ... ")"
//            | field "between" value "and" value
//   op      := "=" | "!=" | ">" | ">=" | "<" | "<=" | "~"
//
// Pure Dart: no Flutter imports.

/// One field of the catalogue (`filters/fields` `data.fields[]`).
class FilterField {
  final String name, kind;
  final List<String> values;
  final Map<String, String> aliases;
  final String? unit, note;
  final num? min, max;
  final List<String> types;
  const FilterField({required this.name, required this.kind, this.values = const [], this.aliases = const {}, this.unit, this.note, this.min, this.max, this.types = const []});

  static FilterField? tryParse(Object? j) {
    if (j is! Map || j['name'] is! String) return null;
    return FilterField(
      name: j['name'] as String,
      kind: j['kind'] is String ? j['kind'] as String : 'string',
      values: [if (j['values'] is List) for (final v in j['values'] as List) if (v is String) v],
      aliases: {
        if (j['aliases'] is Map)
          for (final e in (j['aliases'] as Map).entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String
      },
      unit: j['unit'] is String ? j['unit'] as String : null,
      note: j['note'] is String ? j['note'] as String : null,
      min: j['min'] is num ? j['min'] as num : null,
      max: j['max'] is num ? j['max'] as num : null,
      types: [if (j['types'] is List) for (final v in j['types'] as List) if (v is String) v],
    );
  }

  bool get numeric => kind == 'int' || kind == 'number';
}

/// The field catalogue (`GET /v1/filters/fields` `data`).
class FilterCatalogue {
  final int maxLength, maxClauses;
  final List<FilterField> fields;
  final List<String> examples;

  /// True when this is the copy built into the app (the server's catalogue was not reachable).
  final bool builtIn;
  const FilterCatalogue({this.maxLength = 512, this.maxClauses = 16, required this.fields, this.examples = const [], this.builtIn = false});

  FilterField? field(String name) {
    final n = name.toLowerCase();
    for (final f in fields) {
      if (f.name.toLowerCase() == n) return f;
    }
    return null;
  }

  static FilterCatalogue fromJson(Object? data) {
    if (data is! Map || data['fields'] is! List) throw const FormatException('no fields');
    return FilterCatalogue(
      maxLength: data['maxLength'] is num ? (data['maxLength'] as num).toInt() : 512,
      maxClauses: data['maxClauses'] is num ? (data['maxClauses'] as num).toInt() : 16,
      fields: [for (final f in data['fields'] as List) ?FilterField.tryParse(f)],
      examples: [if (data['examples'] is List) for (final e in data['examples'] as List) if (e is String) e],
    );
  }

  /// The catalogue of grammar version 1 (contract fixture `filter-fields.json`), used until the server answers.
  static const FilterCatalogue builtin = FilterCatalogue(builtIn: true, fields: [
    FilterField(name: 'type', kind: 'enum', values: [
      'REQ', 'RESPONSE', 'TXT_MSG', 'ACK', 'ADVERT', 'GRP_TXT', 'GRP_DATA', 'ANON_REQ', 'PATH', 'TRACE', 'MULTIPART', 'CONTROL', 'RAW_CUSTOM' //
    ], aliases: {'msg': 'TXT_MSG', 'chan': 'GRP_TXT', 'advert': 'ADVERT'}),
    FilterField(name: 'route', kind: 'enum', values: ['TRANSPORT_FLOOD', 'FLOOD', 'DIRECT', 'TRANSPORT_DIRECT']),
    FilterField(name: 'hops', kind: 'int', min: 0, max: 64),
    FilterField(name: 'hashSize', kind: 'int', min: 1, max: 3),
    FilterField(name: 'size', kind: 'int', unit: 'bytes', min: 2, max: 255),
    FilterField(name: 'snr', kind: 'number', unit: 'dB'),
    FilterField(name: 'rssi', kind: 'number', unit: 'dBm'),
    FilterField(name: 'observer', kind: 'observerId'),
    FilterField(name: 'observers', kind: 'int', note: 'distinct observers that heard the packet'),
    FilterField(name: 'node', kind: 'nodeKey', note: 'origin, or a hop that resolves uniquely or likely to the node'),
    FilterField(name: 'hop', kind: 'hexPrefix', note: 'any hop prefix in any observed path, 2-6 hex'),
    FilterField(name: 'channel', kind: 'channelId'),
    FilterField(name: 'scope', kind: 'string', note: "#name, 'unscoped', or 'unmatched'"),
    FilterField(name: 'source', kind: 'sourceId'),
    FilterField(name: 'decode', kind: 'enum', values: ['plain', 'decrypted', 'no_key', 'encrypted', 'failed']),
    FilterField(name: 'age', kind: 'duration', note: 'e.g. age < 15m'),
    FilterField(name: 'payload.name', kind: 'string', types: ['ADVERT']),
    FilterField(name: 'payload.role', kind: 'enum', values: ['companion', 'repeater', 'room', 'sensor'], types: ['ADVERT']),
    FilterField(name: 'payload.sender', kind: 'string', types: ['GRP_TXT']),
    FilterField(name: 'payload.text', kind: 'string', types: ['GRP_TXT'], note: 'decoded public and hashtag text only'),
  ], examples: [
    'type = ADVERT and payload.role = repeater',
    'channel = public and age < 1h',
    'hop ~ a7 and hops >= 3',
    'type in (TXT_MSG, PATH) and route = DIRECT',
  ]);
}

/// A mistake in a filter string, at character [at].
class FilterError implements Exception {
  final String message;
  final int at;
  final String? suggestion;
  const FilterError(this.message, this.at, {this.suggestion});
  @override
  String toString() => suggestion == null ? message : '$message Did you mean "$suggestion"?';
}

enum FilterValueKind { number, duration, word, quoted }

class FilterValue {
  final String text;
  final FilterValueKind kind;
  const FilterValue(this.text, this.kind);

  num? get number => kind == FilterValueKind.number ? num.tryParse(text) : null;

  String print() => kind == FilterValueKind.quoted ? '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"' : text;

  @override
  bool operator ==(Object other) => other is FilterValue && other.text == text && other.kind == kind;
  @override
  int get hashCode => Object.hash(text, kind);
}

sealed class FilterNode {
  const FilterNode();
  String print();

  /// Number of clauses.
  int get clauses;
}

class FilterClause extends FilterNode {
  final String field;

  /// `=`, `!=`, `>`, `>=`, `<`, `<=`, `~`, `in`, `not in`, `between`.
  final String op;
  final List<FilterValue> values;

  /// Character position of the field in the source text (0 for built clauses).
  final int at;
  const FilterClause(this.field, this.op, this.values, {this.at = 0});

  @override
  int get clauses => 1;

  @override
  String print() => switch (op) {
        'in' || 'not in' => '$field $op (${values.map((v) => v.print()).join(', ')})',
        'between' => '$field between ${values[0].print()} and ${values[1].print()}',
        _ => '$field $op ${values.single.print()}',
      };

  @override
  bool operator ==(Object other) => other is FilterClause && other.field == field && other.op == op && _listEq(other.values, values);
  @override
  int get hashCode => Object.hash(field, op, Object.hashAll(values));
}

class FilterAnd extends FilterNode {
  final List<FilterNode> children;
  const FilterAnd(this.children);
  @override
  int get clauses => children.fold(0, (a, c) => a + c.clauses);
  @override
  String print() => children.map((c) => c is FilterOr ? '(${c.print()})' : c.print()).join(' and ');
  @override
  bool operator ==(Object other) => other is FilterAnd && _listEq(other.children, children);
  @override
  int get hashCode => Object.hashAll(children);
}

class FilterOr extends FilterNode {
  final List<FilterNode> children;
  const FilterOr(this.children);
  @override
  int get clauses => children.fold(0, (a, c) => a + c.clauses);
  @override
  String print() => children.map((c) => c.print()).join(' or ');
  @override
  bool operator ==(Object other) => other is FilterOr && _listEq(other.children, children);
  @override
  int get hashCode => Object.hashAll(children);
}

class FilterNot extends FilterNode {
  final FilterNode child;
  const FilterNot(this.child);
  @override
  int get clauses => child.clauses;
  @override
  String print() => child is FilterClause || child is FilterNot ? 'not ${child.print()}' : 'not (${child.print()})';
  @override
  bool operator ==(Object other) => other is FilterNot && other.child == child;
  @override
  int get hashCode => child.hashCode ^ 0x5bd1e995;
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

enum _T { word, number, duration, quoted, op, lparen, rparen, comma, end }

class _Tok {
  final _T t;
  final String text;
  final int at;
  const _Tok(this.t, this.text, this.at);
  String get lower => text.toLowerCase();
  bool isKw(String k) => t == _T.word && lower == k;
}

final _wordChar = RegExp(r'[A-Za-z0-9_.:#\-/+@]');
final _numRe = RegExp(r'^-?\d+(\.\d+)?$');
final _durRe = RegExp(r'^\d+(\.\d+)?[smhd]$');

List<_Tok> _lex(String s) {
  final out = <_Tok>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c.trim().isEmpty) {
      i++;
      continue;
    }
    if (c == '(') {
      out.add(_Tok(_T.lparen, c, i++));
    } else if (c == ')') {
      out.add(_Tok(_T.rparen, c, i++));
    } else if (c == ',') {
      out.add(_Tok(_T.comma, c, i++));
    } else if (c == '"' || c == "'") {
      final start = i++;
      final sb = StringBuffer();
      var closed = false;
      while (i < s.length) {
        final d = s[i];
        if (d == r'\' && i + 1 < s.length) {
          sb.write(s[i + 1]);
          i += 2;
          continue;
        }
        if (d == c) {
          closed = true;
          i++;
          break;
        }
        sb.write(d);
        i++;
      }
      if (!closed) throw FilterError('A quoted value is not closed.', start);
      out.add(_Tok(_T.quoted, sb.toString(), start));
    } else if ('=!<>~'.contains(c)) {
      final start = i;
      final two = i + 1 < s.length ? s.substring(i, i + 2) : '';
      if (two == '!=' || two == '>=' || two == '<=') {
        out.add(_Tok(_T.op, two, start));
        i += 2;
      } else if (c == '!') {
        throw FilterError('"!" must be followed by "=".', start);
      } else {
        out.add(_Tok(_T.op, c, start));
        i++;
      }
    } else if (_wordChar.hasMatch(c)) {
      final start = i;
      while (i < s.length && _wordChar.hasMatch(s[i])) {
        i++;
      }
      final w = s.substring(start, i);
      out.add(_Tok(_numRe.hasMatch(w) ? _T.number : (_durRe.hasMatch(w) ? _T.duration : _T.word), w, start));
    } else {
      throw FilterError('"$c" is not part of the filter language.', i);
    }
  }
  out.add(_Tok(_T.end, '', s.length));
  return out;
}

class _Parser {
  final List<_Tok> toks;
  int p = 0;
  _Parser(this.toks);
  _Tok get cur => toks[p];
  _Tok next() => toks[p++];

  FilterNode expr() {
    final ors = <FilterNode>[andExpr()];
    while (cur.isKw('or')) {
      next();
      ors.add(andExpr());
    }
    return ors.length == 1 ? ors.single : FilterOr(ors);
  }

  FilterNode andExpr() {
    final ands = <FilterNode>[term()];
    while (cur.isKw('and')) {
      next();
      ands.add(term());
    }
    if (ands.length == 1) return ands.single;
    // Flatten nested ands from parentheses: (a and b) and c == a and b and c.
    return FilterAnd([for (final a in ands) ...(a is FilterAnd ? a.children : [a])]);
  }

  FilterNode term() {
    if (cur.isKw('not')) {
      next();
      return FilterNot(term());
    }
    if (cur.t == _T.lparen) {
      next();
      final e = expr();
      if (cur.t != _T.rparen) throw FilterError('A ")" is missing.', cur.at);
      next();
      return e;
    }
    return clause();
  }

  FilterValue value() {
    final t = cur;
    switch (t.t) {
      case _T.number:
        next();
        return FilterValue(t.text, FilterValueKind.number);
      case _T.duration:
        next();
        return FilterValue(t.text, FilterValueKind.duration);
      case _T.quoted:
        next();
        return FilterValue(t.text, FilterValueKind.quoted);
      case _T.word:
        if (const {'and', 'or', 'not', 'in', 'between'}.contains(t.lower)) throw FilterError('A value is missing before "${t.text}".', t.at);
        next();
        return FilterValue(t.text, FilterValueKind.word);
      default:
        throw FilterError(t.t == _T.end ? 'A value is missing at the end.' : 'A value is missing.', t.at);
    }
  }

  List<FilterValue> list() {
    if (cur.t != _T.lparen) throw FilterError('A "(" with a list of values is needed here.', cur.at);
    next();
    final vs = <FilterValue>[value()];
    while (cur.t == _T.comma) {
      next();
      vs.add(value());
    }
    if (cur.t != _T.rparen) throw FilterError('A ")" is missing after the list.', cur.at);
    next();
    return vs;
  }

  FilterNode clause() {
    final f = cur;
    if (f.t != _T.word || const {'and', 'or', 'in', 'between'}.contains(f.lower)) {
      throw FilterError(f.t == _T.end ? 'A field name is missing at the end.' : 'A field name is expected here.', f.at);
    }
    next();
    final field = f.text;
    final o = cur;
    if (o.t == _T.op) {
      next();
      return FilterClause(field, o.text, [value()], at: f.at);
    }
    if (o.isKw('in')) {
      next();
      return FilterClause(field, 'in', list(), at: f.at);
    }
    if (o.isKw('not') && p + 1 < toks.length && toks[p + 1].isKw('in')) {
      next();
      next();
      return FilterClause(field, 'not in', list(), at: f.at);
    }
    if (o.isKw('between')) {
      next();
      final a = value();
      if (!cur.isKw('and')) throw FilterError('"between" needs "and" between the two values.', cur.at);
      next();
      final b = value();
      return FilterClause(field, 'between', [a, b], at: f.at);
    }
    throw FilterError(o.t == _T.end ? 'An operator is missing after "$field".' : 'An operator (=, !=, >, <, ~, in, between) is expected after "$field".', o.at);
  }
}

/// Parses [text]; throws [FilterError]. Empty text parses to null. Keywords are case-insensitive.
FilterNode? parseFilter(String text, {FilterCatalogue? catalogue}) {
  final cat = catalogue ?? FilterCatalogue.builtin;
  if (text.trim().isEmpty) return null;
  if (text.length > cat.maxLength) throw FilterError('A filter can be ${cat.maxLength} characters at most.', cat.maxLength);
  final ps = _Parser(_lex(text));
  final node = ps.expr();
  if (ps.cur.t != _T.end) throw FilterError('"${ps.cur.text}" is not expected here; join clauses with "and" or "or".', ps.cur.at);
  if (node.clauses > cat.maxClauses) throw FilterError('A filter can have ${cat.maxClauses} clauses at most.', 0);
  _check(node, cat);
  return node;
}

/// The canonical print of [text] (same meaning, one spelling); null for empty text. Throws [FilterError].
String? canonicalFilter(String text, {FilterCatalogue? catalogue}) => parseFilter(text, catalogue: catalogue)?.print();

/// The mistake in [text], or null when it parses.
FilterError? filterError(String text, {FilterCatalogue? catalogue}) {
  try {
    parseFilter(text, catalogue: catalogue);
    return null;
  } on FilterError catch (e) {
    return e;
  }
}

int _distance(String a, String b) {
  final d = List.generate(a.length + 1, (i) => List<int>.filled(b.length + 1, 0));
  for (var i = 0; i <= a.length; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final c = a[i - 1] == b[j - 1] ? 0 : 1;
      d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c].reduce((x, y) => x < y ? x : y);
    }
  }
  return d[a.length][b.length];
}

void _check(FilterNode n, FilterCatalogue cat) {
  switch (n) {
    case FilterAnd(:final children) || FilterOr(:final children):
      for (final c in children) {
        _check(c, cat);
      }
    case FilterNot(:final child):
      _check(child, cat);
    case FilterClause c:
      final f = cat.field(c.field);
      if (f == null) {
        String? best;
        var bd = 3;
        for (final x in cat.fields) {
          final d = _distance(x.name.toLowerCase(), c.field.toLowerCase());
          if (d < bd) {
            bd = d;
            best = x.name;
          }
        }
        throw FilterError('"${c.field}" is not a field.', c.at, suggestion: best);
      }
      if (c.op == '~' && (f.numeric || f.kind == 'enum' || f.kind == 'duration')) {
        throw FilterError('"~" (contains) works on text and hex fields, not on "${f.name}".', c.at);
      }
      for (final v in c.values) {
        if (f.numeric && v.number == null) throw FilterError('"${f.name}" needs a number, not "${v.text}".', c.at);
        if (f.kind == 'int' && v.number != null && v.number is! int) throw FilterError('"${f.name}" needs a whole number.', c.at);
        if (f.kind == 'duration' && v.kind != FilterValueKind.duration) throw FilterError('"${f.name}" needs a duration such as 15m, 1h or 7d.', c.at);
        if (f.kind == 'enum') {
          final t = v.text.toLowerCase();
          final ok = f.values.any((x) => x.toLowerCase() == t) || f.aliases.keys.any((x) => x.toLowerCase() == t);
          if (!ok) throw FilterError('"${v.text}" is not a value of "${f.name}" (${f.values.join(', ')}).', c.at);
        }
      }
  }
}

/// Words that could come next at [cursor] in [text]: field names after a joiner, operators after a field, the
/// field's values after an operator, joiners after a value. Filtered by the partial word under the cursor.
({String partial, List<String> words}) filterSuggestions(String text, int cursor, {FilterCatalogue? catalogue}) {
  final cat = catalogue ?? FilterCatalogue.builtin;
  final before = text.substring(0, cursor.clamp(0, text.length));
  final m = RegExp(r'[A-Za-z0-9_.:#\-]*$').firstMatch(before);
  final partial = m?.group(0) ?? '';
  final head = before.substring(0, before.length - partial.length);
  List<_Tok> toks;
  try {
    toks = _lex(head)..removeLast();
  } on FilterError {
    return (partial: partial, words: const []);
  }
  List<String> pick(Iterable<String> all) {
    final p = partial.toLowerCase();
    return [for (final w in all) if (w.toLowerCase().startsWith(p) && w.toLowerCase() != p) w];
  }

  final fieldNames = [for (final f in cat.fields) f.name];
  if (toks.isEmpty || toks.last.t == _T.lparen && (toks.length < 2 || toks[toks.length - 2].t != _T.word || toks[toks.length - 2].isKw('and') || toks[toks.length - 2].isKw('or') || toks[toks.length - 2].isKw('not'))) {
    return (partial: partial, words: pick([...fieldNames, 'not']));
  }
  final last = toks.last;
  if (last.isKw('and') || last.isKw('or') || last.isKw('not')) {
    // "between a and" expects a value; otherwise a field.
    final betweenAt = toks.lastIndexWhere((t) => t.isKw('between'));
    if (last.isKw('and') && betweenAt >= 0 && betweenAt == toks.length - 3) return (partial: partial, words: const []);
    return (partial: partial, words: pick([...fieldNames, if (!last.isKw('not')) 'not']));
  }
  // Find the field this value belongs to: the nearest word before an operator, "in" or "between".
  FilterField? fieldOf(int opIndex) => opIndex > 0 && toks[opIndex - 1].t == _T.word ? cat.field(toks[opIndex - 1].text) : null;
  if (last.t == _T.op || last.isKw('between') || last.t == _T.comma || last.t == _T.lparen) {
    var j = toks.length - 1;
    while (j > 0 && (toks[j].t == _T.comma || toks[j].t == _T.lparen || toks[j].t != _T.op && !toks[j].isKw('in') && !toks[j].isKw('between'))) {
      j--;
    }
    final f = fieldOf(j);
    if (f == null) return (partial: partial, words: const []);
    final vals = f.kind == 'enum'
        ? f.values
        : switch (f.kind) {
            'duration' => const ['15m', '1h', '6h', '24h', '7d'],
            'channelId' => const ['public', 'tag:', 'enc:'],
            'sourceId' => const ['meshsonar', 'meshsonar-phone'],
            _ => const <String>[],
          };
    return (partial: partial, words: pick(vals));
  }
  if (last.t == _T.word && cat.field(last.text) != null && (toks.length < 2 || toks[toks.length - 2].t != _T.op)) {
    final f = cat.field(last.text)!;
    final ops = f.numeric || f.kind == 'duration'
        ? const ['=', '!=', '>', '>=', '<', '<=', 'between', 'in']
        : (f.kind == 'enum' ? const ['=', '!=', 'in', 'not in'] : const ['=', '!=', '~', 'in', 'not in']);
    return (partial: partial, words: pick(ops));
  }
  return (partial: partial, words: pick(const ['and', 'or']));
}
