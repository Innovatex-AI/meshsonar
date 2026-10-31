// Passenger lock: while a drive is running and the car is moving faster than walking pace, the chat composer is disabled
// (design doc 1.3, safety). "I'm a passenger" lifts it for the rest of THAT drive only. Pure Dart, no clock of its own.
//
// Rules (decisions recorded in HANDOFF):
//  * locks above 8 km/h, unlocks again below 6 km/h: GPS jitter around the threshold must not
//    make the composer flicker;
//  * a GPS fix older than [maxFixAge] says nothing about the speed now, so it is ignored (not locked): a stale fix must
//    not keep a parked person locked out, and a drive without any speed reading (some radios' simulated GPS) never locks;
//  * the passenger answer belongs to one drive session id: the next drive asks again.

class PassengerLock {
  /// 8 km/h and 6 km/h in metres per second (GPS speed is stored in m/s everywhere: no conversion needed at run time).
  static const double lockMps = 2.2222;
  static const double unlockMps = 1.6667;
  static const Duration maxFixAge = Duration(seconds: 30);

  String? _passengerOfSession;
  bool _locked = false;

  /// True while the composer must be off. Call [update] first.
  bool get locked => _locked;

  /// The person said they are a passenger in the drive [sessionId].
  bool isPassenger(String? sessionId) => sessionId != null && _passengerOfSession == sessionId;

  void setPassenger(String? sessionId, bool value) {
    if (sessionId == null) return;
    _passengerOfSession = value ? sessionId : (_passengerOfSession == sessionId ? null : _passengerOfSession);
  }

  /// Recomputes the lock from the latest facts. Returns true when [locked] changed.
  bool update({required bool driving, String? sessionId, double? speedMps, DateTime? fixAt, required DateTime now}) {
    final before = _locked;
    if (!driving) {
      _passengerOfSession = null;
      _locked = false;
      return before != _locked;
    }
    if (isPassenger(sessionId)) {
      _locked = false;
      return before != _locked;
    }
    final fresh = speedMps != null && fixAt != null && now.difference(fixAt) <= maxFixAge;
    if (!fresh) {
      _locked = false;
    } else {
      if (speedMps > lockMps) {
        _locked = true;
      } else if (speedMps < unlockMps) {
        _locked = false;
      } // between the two: keep what it was
    }
    return before != _locked;
  }
}
