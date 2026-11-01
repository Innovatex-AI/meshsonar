// `plan-native?view=tracker`: the build tracker board, read-only. Where each site in the recommended build stands (proposed,
// contacting the host, host approved, hardware ready, installed, live on okimesh, dropped), who owns it, and the next action.
// Editing stays with the people installing, on the website. Pure Dart.
import '../region_dataset_fetch.dart' show jDbl, jInt, jMap, jMaps, jStr, jTime;

class TrackerSite {
  final String id, tag, name, phaseName, area, hostType, status, nextAction;
  final int phase;
  final int? order;
  final String? candId, mountHeight, owner, notes, publicKey, updatedBy;
  final double? lat, lon;
  final DateTime? updatedAt;
  const TrackerSite({
    required this.id,
    required this.tag,
    required this.name,
    required this.phase,
    required this.phaseName,
    required this.order,
    required this.area,
    required this.hostType,
    required this.candId,
    required this.lat,
    required this.lon,
    required this.status,
    required this.mountHeight,
    required this.owner,
    required this.notes,
    required this.publicKey,
    required this.updatedAt,
    required this.updatedBy,
    required this.nextAction,
  });
}

class TrackerEvent {
  final String siteId, by;
  final DateTime? at;
  final List<String> lines;
  const TrackerEvent(this.siteId, this.by, this.at, this.lines);
}

class PlanTracker {
  final bool available;
  final String? reason, asOf, editNote;
  final List<String> statuses;
  final Map<String, int> counts;
  final List<TrackerSite> sites;
  final List<TrackerEvent> history;
  const PlanTracker({required this.available, this.reason, this.asOf, this.editNote, this.statuses = const [], this.counts = const {}, this.sites = const [], this.history = const []});

  String siteName(String id) {
    for (final s in sites) {
      if (s.id == id) return s.name;
    }
    return id;
  }

  static PlanTracker parse(Map<String, dynamic> j) {
    if (j['available'] == false) return PlanTracker(available: false, reason: jStr(j['reason']));
    return PlanTracker(
      available: true,
      asOf: jStr(j['asOf']),
      editNote: jStr(j['editNote']),
      statuses: [if (j['statuses'] is List) for (final s in j['statuses'] as List) if (s is String) s],
      counts: {for (final e in jMap(j['counts']).entries) if (e.value is num) e.key: (e.value as num).toInt()},
      sites: [
        for (final s in jMaps(j['sites']))
          if (jStr(s['id']) != null)
            TrackerSite(
              id: jStr(s['id'])!,
              tag: jStr(s['tag']) ?? jStr(s['id'])!,
              name: jStr(s['name']) ?? jStr(s['id'])!,
              phase: jInt(s['phase']) ?? 4,
              phaseName: jStr(s['phaseName']) ?? '',
              order: jInt(s['order']),
              area: jStr(s['area']) ?? '',
              hostType: jStr(s['hostType']) ?? '',
              candId: jStr(s['candId']),
              lat: jDbl(s['lat']),
              lon: jDbl(s['lon']),
              status: jStr(s['status']) ?? 'Proposed',
              mountHeight: jStr(s['mountHeight']),
              owner: jStr(s['owner']),
              notes: jStr(s['notes']),
              publicKey: jStr(s['publicKey']),
              updatedAt: jTime(s['updatedAt']),
              updatedBy: jStr(s['updatedBy']),
              nextAction: jStr(s['nextAction']) ?? '',
            ),
      ],
      history: [
        for (final h in jMaps(j['history']))
          TrackerEvent(jStr(h['siteId']) ?? '', jStr(h['by']) ?? '', jTime(h['at']), [if (h['lines'] is List) for (final l in h['lines'] as List) if (l is String) l]),
      ],
    );
  }
}
