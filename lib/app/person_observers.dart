// The person's observers (ID step 5, app half): fixed observers, phones and the owner offers. Used only while the server
// advertises `capabilities.radioProof`; without it nothing here is called. A fixed observer's name, position and release go
// through the existing claim calls (one copy of those). A ChangeNotifier like PersonDevicesController; AppState owns one
// (AppState.personObservers).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/person_observers.dart';

class PersonObserversController extends ChangeNotifier {
  final CmatClient Function() client;
  final String? Function() driverKey;
  final bool Function() enabled;

  /// Called after an offer was accepted or a fixed observer was changed or released: the claim list (My radios) is stale.
  final Future<void> Function()? onClaimsChanged;
  PersonObserversController({required this.client, required this.driverKey, required this.enabled, this.onClaimsChanged});

  PersonObservers _data = PersonObservers.empty;
  bool _loading = false, _loadedOnce = false, _notOffered = false;
  String? _error;
  List<PersonObserver> get observers => _data.observers;
  List<ObserverOffer> get offers => _data.offers;
  bool get loading => _loading;
  bool get loadedOnce => _loadedOnce;

  /// The server answered 404: its observer list is switched off.
  bool get notOffered => _notOffered;

  /// Why the list could not be loaded, in words; null when it did.
  String? get error => _error;

  /// Loads observers and offers. Never throws; the reason is in [error].
  Future<void> refresh() async {
    await Future<void>.value();
    final key = driverKey();
    if (!enabled() || key == null || key.isEmpty) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _data = await client().personObservers(key);
      _loadedOnce = true;
      _notOffered = false;
    } on CmatException catch (e) {
      if (e.status == 404) {
        _notOffered = true;
        _error = 'The server does not offer the observer list right now.';
      } else {
        _error = 'Could not load your observers (${e.message}).';
      }
    } catch (e) {
      _error = 'Could not load your observers ($e).';
    }
    _loading = false;
    notifyListeners();
  }

  String _key() {
    final k = driverKey();
    if (k == null || k.isEmpty) throw const CmatException('no driver key');
    return k;
  }

  /// Says yes or no to an offer. Throws [CmatException]: 409 `owned` (someone else holds it), 404 `not_found`.
  Future<OfferOutcome> answerOffer(String key, {required bool accept}) async {
    final r = await client().answerObserverOffer(_key(), key, accept: accept);
    if (accept) await _claimsChanged();
    await refresh();
    return r;
  }

  /// Shows or hides the name of the phone's radio in public. Optimistic; put back when the call fails. Throws [CmatException].
  Future<void> setShowRadioName(String key, bool show) async {
    final before = _data;
    _data = PersonObservers([
      for (final o in before.observers)
        if (o is PhoneObserver && o.key == key)
          PhoneObserver(
            key: o.key,
            name: o.name,
            lastHeardAt: o.lastHeardAt,
            blocked: o.blocked,
            deviceId: o.deviceId,
            deviceName: o.deviceName,
            installs: o.installs,
            mode: o.mode,
            radioKey: o.radioKey,
            radioName: o.radioName,
            feeds: o.feeds,
            showRadioName: show,
            countedOnce: o.countedOnce,
          )
        else
          o,
    ], before.offers);
    notifyListeners();
    try {
      await client().setShowRadioName(_key(), key, show);
    } catch (_) {
      _data = before;
      notifyListeners();
      rethrow;
    }
  }

  /// Name and position of a fixed observer: only the keys in [changes] (`displayName`, `positionPublic`) are sent, through the
  /// claim PATCH. Throws [CmatException].
  Future<void> updateFixed(String key, Map<String, Object?> changes) async {
    if (changes.isEmpty) return;
    await client().updateClaim(_key(), key, changes);
    await _claimsChanged();
    await refresh();
  }

  /// Gives a fixed observer up (claim DELETE): it keeps feeding data. Throws [CmatException].
  Future<void> release(String key) async {
    await client().releaseClaim(_key(), key);
    await _claimsChanged();
    await refresh();
  }

  Future<void> _claimsChanged() async {
    try {
      await onClaimsChanged?.call();
    } catch (_) {
      // the claim list refreshes on its own screen; a failure here must not hide that the change worked
    }
  }
}
