// Dead-area warning: how many of the latest tx pings in a row heard no repeater. Pure over the pings the engine already
// emitted (no radio traffic, no cadence change); the Drive tab shows a chip once the run reaches [deadAreaPings] and it
// clears by itself on the next ping that was heard.
import 'model.dart';

/// Consecutive silent tx pings before the Drive tab warns.
const int deadAreaPings = 5;

/// The run of silent tx pings at the end of [pings] (oldest first). Passive rx pings are ignored: they are not answers
/// to a ping and neither extend nor break the run.
int silentPingStreak(Iterable<DrivePing> pings) {
  var n = 0;
  for (final p in pings.toList().reversed) {
    if (p.kind != PingKind.tx) continue;
    if (!p.heardNothing) break;
    n++;
  }
  return n;
}
