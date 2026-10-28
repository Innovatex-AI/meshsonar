# Regions at scale (559 and growing)

Written Oct 28 2026 (app 0.20.1+25) after the platform went from about 5 to **559 active regions**. What the app does with
the region list, what was measured, what it assumes of the server and what it asks the server for. Server rules:
`meshcore-insights/docs/REGION_BORDERS.md`. Code: `lib/core/region_*.dart`, `lib/ui/region/region_switcher.dart`,
`regions_screen.dart`, `preset_info.dart`; tests: `test/support/regions_559.dart` builds a stand-in index.

## The payload
`GET /api/cmh/regions-index`: 559 regions, **3.46 MB JSON / 1.13 MB gzip**, about 182,000 vertices (median 228 per outline,
largest 2,805), outlines thinned to about 300 m, `ETag` (weak) and `Cache-Control: public, max-age=300`. Every row has
`code, slug, name, url, bbox, boundary`. `?slug=a,b` answers just those regions at full detail (CMH 73 vertices against 52,
MOW 3,798 against 2,805; 0.9 KB for one region). It carries **no** radio preset, time zone, group or country.

| Step | What the app does |
|---|---|
| Fetch | `HttpCmatClient.regionsIndex()` reads the body as text, parses it on a background isolate (`Isolate.run`, result moved back without a copy) when it is over 256 KB, and works out its fingerprint there too. 429 keeps its `Retry-After` (`CmatException.retryAfterSec`). |
| ETag | The shared ETag client sends `If-None-Match`; a 304 serves the stored body. The 304 no longer rewrites the 3.4 MB file (`RegionCache.touch`: file time moves, "as of" kept in memory) and the index cache is only written when the fingerprint changed. |
| Cache | `regions_index.json` (the parsed entries, own shape). Loaded on the isolate at launch, so Drive and the Region tab know the region before any network answer. A damaged file is an empty cache. |
| Cadence | Launch and a server change always ask. Coming back to the app asks again only when the last answer is older than 6 h **and** no back-off is running (`RegionIndexService.due`). A 429 waits its `Retry-After` (60 s without one); other failures wait 30 s, 1 min, ... up to 10 min. The stored index stays in use throughout (`regionIndexStale` says so). |
| Same answer | An index with the same fingerprint keeps the same list object: nothing is rewritten, nothing keyed on the list (typed outlines, search index, switcher order) is rebuilt, the region is not re-evaluated. |
| Memory | The parsed maps stay (they are what the cache file and the tests use) and each outline that is ever tested gets one `Float64List` copy (`PreparedBoundary`, about 3 MB for all 559). |

## Which region the phone is in
`regionsContaining` (every region holding the fix, most specific first) is the primitive; `regionContaining` is the first of them.

* bbox test, then point-in-polygon with holes on typed arrays with a bounding box per ring (`region_geometry.dart`), so a ring
  that cannot hold the fix costs four compares. "Most specific" is the smallest **real area**, ties by code.
* **Shared borders and nested zones** (REGION_BORDERS N1): the server lists a positioned node in every covering region and gives a
  ping to exactly one (nearest observer's code, rule 4 of the Oct 21 doc). The phone cannot reproduce that (it has no observers), so it
  shows the most specific region as current and reports the others (`AppState.regionAlsoIn`, "you are also here (shared border)" in the
  picker, "also CODE" under Follow my location). The server decides what a ping is tagged with, never the phone.
* **Seams.** The 300 m thinning means two neighbours no longer share an exact edge: a fix on the seam can fall in neither outline.
  The tracker adds a seam rule (`RegionTracker.seamM`, 300 m): with no real hit, the region whose edge is nearest within 300 m counts.
  Beyond that it is outside coverage and the committed region is held for 60 s (`outsideGrace`) before it is dropped.
* **Exact outline near an edge.** Within 300 m of the current region's edge, or in an overlap, or in a gap, the app asks `regions-index?slug=`
  for the regions whose box is within about 2 km and swaps their full outlines in (memory only, once per region per index;
  `RegionIndexService.refine`). A failure or an empty answer leaves the thinned outline in use.
* **Crossing.** Unchanged and now tested on seams: a new region needs 3 consecutive fixes, a fix inside the committed region never
  switches, within 100 m of the committed edge the committed region is held, outside every region for 60 s drops it.
* **Outside every region**: the nearest region by true edge distance (boxes only pick candidates, so a fix inside the *box* of an L-shaped
  zone but outside its outline goes to the nearer edge). Remembered per fix.
* A machine-derived outline (62 of them; the server flags them, the index does not) is treated like any other: same rules, same seam
  tolerance. If one is wrong the server's `/admin/regions` review replaces it and the next index carries the new outline.

## Picking a region
* **Switcher sheet** (`RegionSwitcherSheet`): a lazily built list (the old one built 559 radio tiles at once). A search box when there are
  more than 8 regions: accent-insensitive ("dusseldorf" finds "Düsseldorf", "chisinau" finds "Chișinău", dashes are spaces), matches name,
  code, slug and country (name or code), every word must match, ranked (exact code, name prefix, word prefix, code prefix, substring,
  country). Without a query: All regions, Follow my location, "Near you" (six nearest, only with a fix), then every region under its country
  (the part of the name after the last comma; an unknown code is shown as the code, a name without one goes under "Other").
* **Nearest first** is by distance to the box, and among the regions whose box holds the fix by distance to their centre (one big box no
  longer lists its members alphabetically).
* **All regions screen**: the same grouping, hub groups first. It used to fire one `public-stats` read **per region** on open (559 requests at
  once, against a limit of 300/min/IP), and drew a 559-row comparison table. Now a row reads its figures only when it is on screen: three at a time,
  newest first, 450 ms between reads per lane, queued reads are dropped when a row scrolls away or the screen closes, a 429 pauses all reads for
  45 s and says so. The comparison table moved to the top as a collapsed "Compare regions" card, covers only the regions already read that have
  drives (at most 25) and says so ("Among the 12 of 559 regions read so far ...").

## Radio preset and time zone
The region **catalogue** (`/v1/regions`, 250 KB, ETag cached; already used for hub groups) carries each region's `default_preset` with `basis`
(`published` / `community-observed`), `source`, `note`. The app reads it (`AppState.regionCatalog`) and shows the provenance under the numbers.
* A region **with** a preset: numbers from site-config, provenance from the catalogue (only when the numbers agree).
* A region **without** one (UKK, CEB, JHB today): Settings > Region and the Radio tab say "<Region> has no radio preset on file", show the stored
  reason as written (and its evidence link) when the server sends one, otherwise "The server has not said why.", and "MeshSonar does not guess one
  and does not show another region's in its place". There is no fallback to the US preset anywhere in the app.
* After a region switch the previous region's site-config is never shown for the new one ("Loading this region's preset." until it answers).
* Entering a region with no preset on file during a drive says so in the notice; no preset dialog (nothing to compare), the radio is never touched.
* A group host (`swoh`) has no single preset (`radioPreset: null`); the same honest state.
* **Time zone**: shown on Settings > Region when the server sends `timezone`. Not used for any calculation yet (no zone database in the app).

## Asks for the server (not built; the app reads them as soon as they exist)
1. `GET /api/cmh/site-config` and `/v1/regions` rows: **`radioPresetNone: {reason, source}`** (site-config) and **`preset_none: {reason, source}`**
   (catalogue) from `regions.settings.radio_preset_none`. The three regions without a preset are shown as "the server has not said why" until then.
2. **`timezone`** (IANA name) in both.
3. `regions-index` rows: `country` (or ISO code) so the app need not parse names, and `machine_derived: true` for the 62 derived outlines (the app could
   say "approximate outline" near such a border).
4. A bulk figures read (one `GET` for the per-region `public-stats` of all regions, or `drives`/`km` in `/v1/regions`): the All regions screen reads each visible
   row on its own host.
5. `regions-index` could drop `asOf` from the ETag input (it is stable; the body changes only when a region does): already true today (ETag is stable, 304 works).

## Measured (Oct 28 2026, M-series Mac, the real payload; a phone is about 3-5x slower)
`tool/bench_regions.dart` and `tool/bench_regions_new.dart` (`dart compile exe`, AOT; steps in the file headers).

| | before (0.20.0) | after (0.20.1) |
|---|---|---|
| jsonDecode of the 3.46 MB body | 39.7 ms on the main isolate (every launch, 304 included) | parsed on a background isolate; main isolate free (wall 86 ms) |
| cache save after a refresh | 153 ms `jsonEncode` + 3.4 MB write, every launch | 0 (same fingerprint, fingerprint worked out on the isolate) |
| 304 on the ETag cache | rewrites the 3.4 MB body | touches the file time only |
| region lookup, one fix, warm | 10.0 us | 6.0 us (4.0 us for the tracker step, was 15.0) |
| first lookups (build typed outlines) | - | 19.8 ms for 1,000 fixes, once per outline |
| nearest region (outside every region) | 52 us, box only (wrong on L shapes) | 245 us, true edge distance, remembered per fix |
| switcher order (559 sort) | 1.64 ms, per widget build | 0.19 ms, remembered per fix |
| picker list | 559 radio tiles built at once | about a screenful (under 40 tiles) |
| All regions screen on open | 559 `public-stats` requests at once | up to 3 at a time, only rows on screen (under 40 on open) |
| search index / one query | - | 2.1 ms once / 30-140 us |
| `viewingRegion` | 559-region scan on every notification | remembered per index / fix |
