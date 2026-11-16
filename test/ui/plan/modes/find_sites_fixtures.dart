// Fixtures for the Find sites tests: copies of the plan-suggest server fixtures in meshcore-insights
// (src/test/fixtures/plan/plan-suggest.response.json and plan-suggest.preparing.json, release/0.38), so the app tests
// parse exactly what the live endpoint returns. Re-copy them when the server contract changes.

const String kPlanSuggestResponseJson = r'''
{
  "pool": 83,
  "sites": [
    {
      "id": "t:882a956a89fffff",
      "lat": 39.98159,
      "lon": -82.98969,
      "groundM": 367.1,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 300.2,
        "newPeople": 1500,
        "newLinks": [
          {
            "key": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "name": "East",
            "km": 6.4,
            "odds": 0.226,
            "tier": "Likely",
            "marginDb": 36
          }
        ],
        "redundancy": "none",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 44
      },
      "score": 100,
      "reason": "+300 km² of new coverage, 1,500 people; reaches East; 44 m above its surroundings",
      "scores": {
        "coverage": 100,
        "links": 73,
        "redundancy": 0,
        "evidence": 0,
        "height": 81
      }
    },
    {
      "id": "t:882a956a87fffff",
      "lat": 39.97317,
      "lon": -83.01098,
      "groundM": 351.3,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 302.8,
        "newPeople": 1500,
        "newLinks": [
          {
            "key": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "name": "Downtown",
            "km": 2.7,
            "odds": 0.386,
            "tier": "Strong",
            "marginDb": 16
          }
        ],
        "redundancy": "none",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 48
      },
      "score": 97,
      "reason": "+303 km² of new coverage, 1,500 people; reaches Downtown; 48 m above its surroundings",
      "scores": {
        "coverage": 100,
        "links": 65,
        "redundancy": 0,
        "evidence": 0,
        "height": 84
      }
    },
    {
      "id": "t:882a956f51fffff",
      "lat": 39.93001,
      "lon": -82.94781,
      "groundM": 328.6,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 296.5,
        "newPeople": 0,
        "newLinks": [
          {
            "key": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "name": "East",
            "km": 4.1,
            "odds": 0.345,
            "tier": "Strong",
            "marginDb": 36
          },
          {
            "key": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "name": "Downtown",
            "km": 5,
            "odds": 0.187,
            "tier": "Likely",
            "marginDb": 26
          }
        ],
        "redundancy": "joins_components",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 55
      },
      "score": 88,
      "reason": "+297 km² of new coverage; reaches 2 existing repeaters; joins two separate parts of the mesh",
      "scores": {
        "coverage": 0,
        "links": 100,
        "redundancy": 100,
        "evidence": 0,
        "height": 90
      }
    },
    {
      "id": "t:882a956a27fffff",
      "lat": 40.01999,
      "lon": -83.05973,
      "groundM": 310,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 273.4,
        "newPeople": 1500,
        "newLinks": [],
        "redundancy": "none",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 47
      },
      "score": 71,
      "reason": "+273 km² of new coverage, 1,500 people; 47 m above its surroundings",
      "scores": {
        "coverage": 100,
        "links": 0,
        "redundancy": 0,
        "evidence": 0,
        "height": 83
      }
    },
    {
      "id": "t:882a956aebfffff",
      "lat": 39.98948,
      "lon": -83.01098,
      "groundM": 339.9,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 295.5,
        "newPeople": 1500,
        "newLinks": [],
        "redundancy": "none",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 41
      },
      "score": 70,
      "reason": "+296 km² of new coverage, 1,500 people; 41 m above its surroundings",
      "scores": {
        "coverage": 100,
        "links": 0,
        "redundancy": 0,
        "evidence": 0,
        "height": 77
      }
    },
    {
      "id": "t:882a956a61fffff",
      "lat": 40.04523,
      "lon": -83.05149,
      "groundM": 250.1,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 41.8,
        "newPeople": 1500,
        "newLinks": [],
        "redundancy": "none",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 0
      },
      "score": 58,
      "reason": "+42 km² of new coverage, 1,500 people",
      "scores": {
        "coverage": 100,
        "links": 0,
        "redundancy": 0,
        "evidence": 0,
        "height": 4
      }
    },
    {
      "id": "t:882a956159fffff",
      "lat": 40.0284,
      "lon": -82.91691,
      "groundM": 250,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 40.8,
        "newPeople": 1500,
        "newLinks": [],
        "redundancy": "none",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 0
      },
      "score": 57,
      "reason": "+41 km² of new coverage, 1,500 people",
      "scores": {
        "coverage": 100,
        "links": 0,
        "redundancy": 0,
        "evidence": 0,
        "height": 0
      }
    },
    {
      "id": "t:882a956335fffff",
      "lat": 40.04417,
      "lon": -82.92721,
      "groundM": 250,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 40.7,
        "newPeople": 1500,
        "newLinks": [],
        "redundancy": "none",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 0
      },
      "score": 57,
      "reason": "+41 km² of new coverage, 1,500 people",
      "scores": {
        "coverage": 100,
        "links": 0,
        "redundancy": 0,
        "evidence": 0,
        "height": 0
      }
    },
    {
      "id": "t:882a956339fffff",
      "lat": 40.04417,
      "lon": -82.90661,
      "groundM": 250,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 40,
        "newPeople": 1500,
        "newLinks": [],
        "redundancy": "none",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 0
      },
      "score": 57,
      "reason": "+40 km² of new coverage, 1,500 people",
      "scores": {
        "coverage": 100,
        "links": 0,
        "redundancy": 0,
        "evidence": 0,
        "height": 0
      }
    },
    {
      "id": "t:882a9568a5fffff",
      "lat": 39.9337,
      "lon": -83.09269,
      "groundM": 250,
      "heightAboveM": 6,
      "kind": "terrain",
      "mount": "ground",
      "osm": null,
      "gain": {
        "newAreaKm2": 42.2,
        "newPeople": 1500,
        "newLinks": [],
        "redundancy": "none",
        "spofName": null
      },
      "evidence": {
        "deadZoneDrives": 0,
        "heightAdvantageM": 0
      },
      "score": 57,
      "reason": "+42 km² of new coverage, 1,500 people",
      "scores": {
        "coverage": 100,
        "links": 0,
        "redundancy": 0,
        "evidence": 0,
        "height": 0
      }
    }
  ],
  "notes": [
    "Ranked from 83 candidate sites (terrain high points and OpenStreetMap structures); Verify runs the full model on a site.",
    "Scored at the pool's mount heights (pole 6 m, treetop 18 m, structure height) for a handheld at 1.5 m; your radio, power and gain shift every margin."
  ],
  "preparing": false,
  "goal": "overall",
  "radio": {
    "freqMHz": 910.525,
    "bwKHz": 62.5,
    "sf": 7,
    "cr": 5
  },
  "model": "profile+bullington+clutter v1 (E11 sparse grid)",
  "terrain": "AWS Terrain Tiles (Terrarium; USGS 3DEP / SRTM blend), bare earth",
  "asOf": "2026-11-15T12:00:00.000Z",
  "confidence": {
    "level": "calibrated",
    "note": "Calibrated on Columbus; 412 measured cells in this region"
  },
  "cached": false
}
''';

const String kPlanSuggestPreparingJson = r'''
{
  "pool": 0,
  "sites": [],
  "preparing": true,
  "cached": false,
  "goal": "overall",
  "radio": {
    "freqMHz": 910.525,
    "bwKHz": 62.5,
    "sf": 7,
    "cr": 5
  },
  "notes": [
    "Preparing this region: the candidate sites are being computed. Try again in a few minutes."
  ],
  "model": "profile+bullington+clutter v1 (E11 sparse grid)",
  "terrain": "AWS Terrain Tiles (Terrarium; USGS 3DEP / SRTM blend), bare earth",
  "asOf": null,
  "confidence": {
    "level": "estimate",
    "note": "no site table yet"
  }
}
''';
