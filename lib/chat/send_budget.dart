// The byte budget of the composer (chat plan 4.3). Pure Dart.
//
// A packet carries a fixed number of UTF-8 BYTES, not characters: an accent costs 2, an emoji 4. The ring around the send
// button fills with the bytes used; it appears at 60%, shows the number of bytes left at 20 or fewer, turns orange at 10 or
// fewer and red at 0.
import 'dart:convert';

enum BudgetLevel { quiet, ring, number, warning, full }

class ByteBudget {
  final int used;
  final int max;
  const ByteBudget(this.used, this.max);

  factory ByteBudget.of(String text, int max) => ByteBudget(utf8.encode(text.trim()).length, max);

  int get left => max - used;
  double get fraction => max <= 0 ? 1 : (used / max).clamp(0.0, 1.0);
  bool get over => used > max;
  bool get full => left <= 0;

  BudgetLevel get level {
    if (left <= 0) return BudgetLevel.full;
    if (left <= 10) return BudgetLevel.warning;
    if (left <= 20) return BudgetLevel.number;
    if (fraction >= 0.6) return BudgetLevel.ring;
    return BudgetLevel.quiet;
  }

  bool get showRing => level != BudgetLevel.quiet;
  bool get showNumber => left <= 20;

  /// What VoiceOver announces when the level crosses 20, 10 or 0 left; null for no announcement.
  String? announcementFor(BudgetLevel previous) {
    if (level == previous) return null;
    switch (level) {
      case BudgetLevel.number:
        return previous.index < BudgetLevel.number.index ? '$left bytes left' : null;
      case BudgetLevel.warning:
        return previous.index < BudgetLevel.warning.index ? '$left bytes left' : null;
      case BudgetLevel.full:
        return 'No bytes left';
      default:
        return null;
    }
  }
}

/// The longest prefix of [s] that fits in [maxBytes] UTF-8 bytes, cut on a character boundary (never inside an emoji's
/// surrogate pair, and a dangling joiner or variation selector is dropped with it).
String trimToBytes(String s, int maxBytes) {
  if (utf8.encode(s).length <= maxBytes) return s;
  final runes = s.runes.toList();
  var bytes = 0;
  var end = 0;
  for (var i = 0; i < runes.length; i++) {
    final n = utf8.encode(String.fromCharCode(runes[i])).length;
    if (bytes + n > maxBytes) break;
    bytes += n;
    end = i + 1;
  }
  // Do not leave a joiner or selector hanging at the cut.
  while (end > 0 && (runes[end - 1] == 0x200D || runes[end - 1] == 0xFE0F)) {
    end--;
  }
  return String.fromCharCodes(runes.sublist(0, end));
}
