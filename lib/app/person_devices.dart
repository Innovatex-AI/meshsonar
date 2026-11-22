// The person's devices, notices and "ask me first" (ID step 3, app half) and the email hand-off. Used only while the server
// advertises `capabilities.radioProof`; without it More > Devices keeps the old driver-key screen and none of these calls
// is made. A ChangeNotifier like ClaimController; AppState owns one (AppState.personDevices).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/person_identity.dart';

class PersonDevicesController extends ChangeNotifier {
  final CmatClient Function() client;
  final String? Function() driverKey;
  final bool Function() enabled;
  PersonDevicesController({required this.client, required this.driverKey, required this.enabled});

  List<PersonDevice> _devices = const [];
  List<PersonNotice> _notices = const [];
  bool _askFirst = false, _loading = false, _loadedOnce = false;
  String? _error;
  List<PersonDevice> get devices => _devices;
  List<PersonNotice> get notices => _notices;
  bool get askFirst => _askFirst;
  bool get loading => _loading;
  bool get loadedOnce => _loadedOnce;

  /// Why the lists could not be loaded, in words; null when they did.
  String? get error => _error;

  /// Notices that want a look (unread, or a join request nobody answered).
  int get attention => _notices.where((n) => !n.read || n.isOpenRequest).length;

  /// Loads devices and notices. Never throws; the reason is in [error].
  Future<void> refresh() async {
    await Future<void>.value();
    final key = driverKey();
    if (!enabled() || key == null || key.isEmpty) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final c = client();
      final results = await Future.wait<Object>([c.personDevices(key), c.personNotices(key)]);
      _devices = results[0] as List<PersonDevice>;
      final n = results[1] as PersonNotices;
      _notices = n.notices;
      _askFirst = n.askFirst;
      _loadedOnce = true;
    } on CmatException catch (e) {
      _error = e.status == 404 ? 'The server does not offer the device list right now.' : 'Could not load your devices (${e.message}).';
    } catch (e) {
      _error = 'Could not load your devices ($e).';
    }
    _loading = false;
    notifyListeners();
  }

  String _key() {
    final k = driverKey();
    if (k == null || k.isEmpty) throw const CmatException('no driver key');
    return k;
  }

  /// 1 to 40 characters; null or blank = the default name. Throws [CmatException].
  Future<void> rename(String id, String? name) async {
    final n = name?.trim();
    await client().renameDevice(_key(), id, n == null || n.isEmpty ? null : n);
    await refresh();
  }

  /// Revokes the device's key; its drives stay. Throws [CmatException].
  Future<void> remove(String id) async {
    await client().removeDevice(_key(), id);
    await refresh();
  }

  Future<void> noticeAct(String id, String action) async {
    await client().personNoticeAct(_key(), id, action);
    await refresh();
  }

  Future<void> setAskFirst(bool v) async {
    final was = _askFirst;
    _askFirst = v;
    notifyListeners();
    try {
      _askFirst = await client().setAskFirst(_key(), v);
    } catch (_) {
      _askFirst = was;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  /// A one-time link for adding this device to an account on the website. Throws [CmatException].
  Future<LinkStart> startLink() => client().linkStart(_key());
}
