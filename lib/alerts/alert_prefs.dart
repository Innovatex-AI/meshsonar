// The person's notification choices, kept in one small JSON file (never in the chat database: a backup/restore of chat
// must not change how this phone alerts). Per-conversation modes live on the conversation (ChatService.setNotifyMode),
// not here.
//
// Defaults, with the reason:
//  * enabled = true: the intent. The OS permission is a separate thing and is only asked at a moment the person chooses.
//  * sound = true, vibrate = true (Android only; iOS haptics follow the system).
//  * showText = false: a lock screen is a public place. A notification then reads "Alex: New message" (who and where
//    help triage; the words stay private). Turn it on to see the text. We choose the safe side and say so in Settings.
//  * quiet hours off. When on, alerts still arrive and count, silently.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class QuietHours {
  final bool enabled;

  /// Minutes after local midnight. The window may cross midnight (22:00 to 07:00).
  final int startMinute;
  final int endMinute;
  const QuietHours({this.enabled = false, this.startMinute = 22 * 60, this.endMinute = 7 * 60});

  bool contains(DateTime t) {
    if (!enabled || startMinute == endMinute) return false;
    final m = t.hour * 60 + t.minute;
    return startMinute < endMinute ? (m >= startMinute && m < endMinute) : (m >= startMinute || m < endMinute);
  }

  QuietHours copyWith({bool? enabled, int? startMinute, int? endMinute}) =>
      QuietHours(enabled: enabled ?? this.enabled, startMinute: startMinute ?? this.startMinute, endMinute: endMinute ?? this.endMinute);

  Map<String, Object?> toJson() => {'enabled': enabled, 'start': startMinute, 'end': endMinute};
  static QuietHours fromJson(Object? j) {
    if (j is! Map) return const QuietHours();
    int clampMin(Object? v, int d) => v is int && v >= 0 && v < 1440 ? v : d;
    return QuietHours(enabled: j['enabled'] == true, startMinute: clampMin(j['start'], 22 * 60), endMinute: clampMin(j['end'], 7 * 60));
  }
}

class AlertPrefs extends ChangeNotifier {
  final File? _file;
  bool _enabled = true;
  bool _sound = true;
  bool _vibrate = true;
  bool _showText = false;
  bool _asked = false;
  bool _prePromptSeen = false;
  bool _keepAliveIos = false;
  QuietHours _quiet = const QuietHours();

  AlertPrefs([this._file]);

  /// Global switch. Off = nothing is shown, in the app or outside. Messages are still stored and counted.
  bool get enabled => _enabled;
  bool get sound => _sound;
  bool get vibrate => _vibrate;

  /// Message text in notifications. Default false (see the file header).
  bool get showText => _showText;
  QuietHours get quiet => _quiet;

  /// We showed the system prompt once. On iOS this is the only way to tell "denied" from "never asked".
  bool get asked => _asked;

  /// The person saw our explanation (pre-prompt) once and chose not now / later; do not nag on every send.
  bool get prePromptSeen => _prePromptSeen;

  /// EXPERIMENT (iOS, off by default): hold a second Bluetooth link so iOS can wake the app again after it closed it.
  /// Not proven to work; see docs/BACKGROUND_BLE_SPIKE.md. Surfaced only in Diagnostics.
  bool get iosWakeKeeper => _keepAliveIos;

  Future<void> load() async {
    final f = _file;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      _enabled = j['enabled'] != false;
      _sound = j['sound'] != false;
      _vibrate = j['vibrate'] != false;
      _showText = j['showText'] == true;
      _asked = j['asked'] == true;
      _prePromptSeen = j['prePromptSeen'] == true;
      _keepAliveIos = j['iosWakeKeeper'] == true;
      _quiet = QuietHours.fromJson(j['quiet']);
      notifyListeners();
    } catch (_) {
      // a damaged file costs the choices, never the app: defaults apply
    }
  }

  Future<void> _save() async {
    notifyListeners();
    final f = _file;
    if (f == null) return;
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
          jsonEncode({
            'enabled': _enabled,
            'sound': _sound,
            'vibrate': _vibrate,
            'showText': _showText,
            'asked': _asked,
            'prePromptSeen': _prePromptSeen,
            'iosWakeKeeper': _keepAliveIos,
            'quiet': _quiet.toJson(),
          }),
          flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    await _save();
  }

  Future<void> setSound(bool v) async {
    _sound = v;
    await _save();
  }

  Future<void> setVibrate(bool v) async {
    _vibrate = v;
    await _save();
  }

  Future<void> setShowText(bool v) async {
    _showText = v;
    await _save();
  }

  Future<void> setQuiet(QuietHours q) async {
    _quiet = q;
    await _save();
  }

  Future<void> markAsked() async {
    _asked = true;
    await _save();
  }

  Future<void> markPrePromptSeen() async {
    _prePromptSeen = true;
    await _save();
  }

  Future<void> setIosWakeKeeper(bool v) async {
    _keepAliveIos = v;
    await _save();
  }
}
