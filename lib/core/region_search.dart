// Searching and grouping the region list (559 regions and growing): accent-insensitive matching on the name, code,
// slug and country, ranked results, and the country each region belongs to (the part of its name after the last comma,
// "Aachen, DE" -> DE). Pure Dart: no Flutter imports.
import 'region_lookup.dart';

/// ISO 3166-1 alpha-2 codes that appear in region names, with their English names. A code that is not here is shown as
/// the code itself (never guessed).
const Map<String, String> countryNames = {
  'AE': 'United Arab Emirates',
  'AT': 'Austria',
  'AU': 'Australia',
  'BE': 'Belgium',
  'BG': 'Bulgaria',
  'BR': 'Brazil',
  'BY': 'Belarus',
  'CA': 'Canada',
  'CH': 'Switzerland',
  'CL': 'Chile',
  'CR': 'Costa Rica',
  'CZ': 'Czechia',
  'DE': 'Germany',
  'DK': 'Denmark',
  'DO': 'Dominican Republic',
  'EC': 'Ecuador',
  'EE': 'Estonia',
  'ES': 'Spain',
  'FI': 'Finland',
  'FR': 'France',
  'GB': 'United Kingdom',
  'GG': 'Guernsey',
  'GR': 'Greece',
  'HR': 'Croatia',
  'HU': 'Hungary',
  'IE': 'Ireland',
  'IS': 'Iceland',
  'IT': 'Italy',
  'KZ': 'Kazakhstan',
  'LI': 'Liechtenstein',
  'LT': 'Lithuania',
  'LU': 'Luxembourg',
  'LV': 'Latvia',
  'MD': 'Moldova',
  'ME': 'Montenegro',
  'MX': 'Mexico',
  'MY': 'Malaysia',
  'NL': 'Netherlands',
  'NO': 'Norway',
  'NZ': 'New Zealand',
  'PH': 'Philippines',
  'PL': 'Poland',
  'PR': 'Puerto Rico',
  'PT': 'Portugal',
  'RO': 'Romania',
  'RS': 'Serbia',
  'RU': 'Russia',
  'SE': 'Sweden',
  'SI': 'Slovenia',
  'SK': 'Slovakia',
  'US': 'United States',
  'ZA': 'South Africa',
};

/// Latin letters with marks (Latin-1 Supplement, Latin Extended-A, the Romanian comma-below letters) -> their plain form.
const Map<String, String> _foldTable = {
  'À': 'A',
  'Á': 'A',
  'Â': 'A',
  'Ã': 'A',
  'Ä': 'A',
  'Å': 'A',
  'Æ': 'AE',
  'Ç': 'C',
  'È': 'E',
  'É': 'E',
  'Ê': 'E',
  'Ë': 'E',
  'Ì': 'I',
  'Í': 'I',
  'Î': 'I',
  'Ï': 'I',
  'Ñ': 'N',
  'Ò': 'O',
  'Ó': 'O',
  'Ô': 'O',
  'Õ': 'O',
  'Ö': 'O',
  'Ø': 'O',
  'Ù': 'U',
  'Ú': 'U',
  'Û': 'U',
  'Ü': 'U',
  'Ý': 'Y',
  'ß': 'ss',
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'æ': 'ae',
  'ç': 'c',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ñ': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'Ā': 'A',
  'ā': 'a',
  'Ă': 'A',
  'ă': 'a',
  'Ą': 'A',
  'ą': 'a',
  'Ć': 'C',
  'ć': 'c',
  'Ĉ': 'C',
  'ĉ': 'c',
  'Ċ': 'C',
  'ċ': 'c',
  'Č': 'C',
  'č': 'c',
  'Ď': 'D',
  'ď': 'd',
  'Đ': 'D',
  'đ': 'd',
  'Ē': 'E',
  'ē': 'e',
  'Ĕ': 'E',
  'ĕ': 'e',
  'Ė': 'E',
  'ė': 'e',
  'Ę': 'E',
  'ę': 'e',
  'Ě': 'E',
  'ě': 'e',
  'Ĝ': 'G',
  'ĝ': 'g',
  'Ğ': 'G',
  'ğ': 'g',
  'Ġ': 'G',
  'ġ': 'g',
  'Ģ': 'G',
  'ģ': 'g',
  'Ĥ': 'H',
  'ĥ': 'h',
  'Ĩ': 'I',
  'ĩ': 'i',
  'Ī': 'I',
  'ī': 'i',
  'Ĭ': 'I',
  'ĭ': 'i',
  'Į': 'I',
  'į': 'i',
  'İ': 'I',
  'ı': 'i',
  'Ĵ': 'J',
  'ĵ': 'j',
  'Ķ': 'K',
  'ķ': 'k',
  'Ĺ': 'L',
  'ĺ': 'l',
  'Ļ': 'L',
  'ļ': 'l',
  'Ľ': 'L',
  'ľ': 'l',
  'Ł': 'L',
  'ł': 'l',
  'Ń': 'N',
  'ń': 'n',
  'Ņ': 'N',
  'ņ': 'n',
  'Ň': 'N',
  'ň': 'n',
  'Ō': 'O',
  'ō': 'o',
  'Ŏ': 'O',
  'ŏ': 'o',
  'Ő': 'O',
  'ő': 'o',
  'Œ': 'OE',
  'œ': 'oe',
  'Ŕ': 'R',
  'ŕ': 'r',
  'Ŗ': 'R',
  'ŗ': 'r',
  'Ř': 'R',
  'ř': 'r',
  'Ś': 'S',
  'ś': 's',
  'Ŝ': 'S',
  'ŝ': 's',
  'Ş': 'S',
  'ş': 's',
  'Š': 'S',
  'š': 's',
  'Ţ': 'T',
  'ţ': 't',
  'Ť': 'T',
  'ť': 't',
  'Ũ': 'U',
  'ũ': 'u',
  'Ū': 'U',
  'ū': 'u',
  'Ŭ': 'U',
  'ŭ': 'u',
  'Ů': 'U',
  'ů': 'u',
  'Ű': 'U',
  'ű': 'u',
  'Ų': 'U',
  'ų': 'u',
  'Ŵ': 'W',
  'ŵ': 'w',
  'Ŷ': 'Y',
  'ŷ': 'y',
  'Ÿ': 'Y',
  'Ź': 'Z',
  'ź': 'z',
  'Ż': 'Z',
  'ż': 'z',
  'Ž': 'Z',
  'ž': 'z',
  'Ș': 'S',
  'ș': 's',
  'Ț': 'T',
  'ț': 't',
};

final Map<int, String> _fold = {
  for (final e in _foldTable.entries) e.key.runes.first: e.value,
};

/// Lower-case, accent-free form used for matching ("Chișinău" and "chisinau" meet; "Düsseldorf" and "dusseldorf" too).
String foldForSearch(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final f = _fold[r];
    b.write(f ?? String.fromCharCode(r));
  }
  return b
      .toString()
      .toLowerCase()
      .replaceAll(RegExp(r'[–—‐-]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// The country code at the end of a region name ("Aachen, DE" -> "DE"), or null when the name has no comma suffix of
/// two letters.
String? countryCodeOf(RegionIndexEntry r) {
  final i = r.name.lastIndexOf(',');
  if (i < 0) return null;
  final tail = r.name.substring(i + 1).trim();
  return RegExp(r'^[A-Za-z]{2}$').hasMatch(tail) ? tail.toUpperCase() : null;
}

/// Heading for a country group: the English name, the bare code when it is not in [countryNames], and "Other" for none.
String countryLabel(String? code) =>
    code == null ? 'Other' : (countryNames[code] ?? code);

/// The name without its country suffix ("Aachen, DE" -> "Aachen").
String shortNameOf(RegionIndexEntry r) {
  final c = countryCodeOf(r);
  return c == null
      ? r.name
      : r.name.substring(0, r.name.lastIndexOf(',')).trim();
}

class _Row {
  final RegionIndexEntry region;
  final String name; // folded short name
  final List<String> words;
  final String code; // folded
  final String slug;
  final String country; // folded country name
  final String countryCode; // folded country code
  _Row(
    this.region,
    this.name,
    this.words,
    this.code,
    this.slug,
    this.country,
    this.countryCode,
  );
}

/// A searchable view of one region list. Build once per list ([RegionSearchIndex.of] remembers it by list identity),
/// then [search] is a pass over the rows with no allocation per region beyond the result.
class RegionSearchIndex {
  final List<_Row> _rows;
  RegionSearchIndex._(this._rows);

  static final Expando<RegionSearchIndex> _cache = Expando('RegionSearchIndex');

  static RegionSearchIndex of(List<RegionIndexEntry> index) =>
      _cache[index] ??= RegionSearchIndex._([
        for (final r in index)
          () {
            final cc = countryCodeOf(r);
            final short = foldForSearch(shortNameOf(r));
            return _Row(
              r,
              short,
              short.split(' '),
              foldForSearch(r.code),
              foldForSearch(r.slug),
              foldForSearch(countryLabel(cc)),
              foldForSearch(cc ?? ''),
            );
          }(),
      ]);

  /// Regions matching [query], best first. Every word of the query must match something (name word prefix or
  /// substring, code, slug or country); an empty query returns the whole list in its original order. Ranking: exact
  /// code, name starts with the query, a name word starts with it, code starts with it, name contains it, country.
  List<RegionIndexEntry> search(String query) {
    final q = foldForSearch(query);
    if (q.isEmpty) return [for (final r in _rows) r.region];
    final terms = q.split(' ');
    final scored = <(int, String, RegionIndexEntry)>[];
    for (final row in _rows) {
      var total = 0;
      var ok = true;
      for (final t in terms) {
        final s = _score(row, t);
        if (s < 0) {
          ok = false;
          break;
        }
        total += s;
      }
      if (ok) scored.add((total, row.name, row.region));
    }
    scored.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    return [for (final s in scored) s.$3];
  }

  static int _score(_Row r, String t) {
    if (r.code == t) return 0;
    if (r.name.startsWith(t)) return 1;
    for (final w in r.words) {
      if (w.startsWith(t)) return 2;
    }
    if (r.code.startsWith(t) || r.slug.startsWith(t)) return 3;
    if (r.name.contains(t)) return 4;
    if (r.countryCode == t || r.country.startsWith(t)) return 5;
    if (r.country.contains(t)) return 6;
    return -1;
  }
}

/// A country with its regions, for the grouped list.
class CountryGroup {
  final String? code;
  final String label;
  final List<RegionIndexEntry> regions;
  const CountryGroup(this.code, this.label, this.regions);
}

/// Groups [regions] by country, countries by name, regions inside a country in the order given ([regions] is
/// already sorted by the caller, e.g. by name). Regions with no country suffix go last under "Other".
List<CountryGroup> groupByCountry(List<RegionIndexEntry> regions) {
  final by = <String?, List<RegionIndexEntry>>{};
  for (final r in regions) {
    (by[countryCodeOf(r)] ??= []).add(r);
  }
  final out = [
    for (final e in by.entries)
      CountryGroup(e.key, countryLabel(e.key), e.value),
  ];
  out.sort((a, b) {
    if (a.code == null) return 1;
    if (b.code == null) return -1;
    return foldForSearch(a.label).compareTo(foldForSearch(b.label));
  });
  return out;
}
