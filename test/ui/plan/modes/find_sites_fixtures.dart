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

/// A copy of test/fixtures/plan_server/plan-verify.site.response.json (the simulator tour cannot read files from the
/// test folder; find_sites_test.dart checks the copy still equals the file).
const String kPlanVerifySiteJson = r'''
{
  "mode": "coverage",
  "params": {
    "mode": "coverage",
    "lat": 37.27,
    "lon": -79.94,
    "antennaFt": 33,
    "antennaM": 10,
    "txDbm": 22,
    "gainDbi": 3,
    "receiver": "handheld",
    "receiverM": 1.5,
    "radio": {
      "freqMHz": 910.525,
      "bwKHz": 62.5,
      "sf": 7,
      "cr": 5
    },
    "direction": "both",
    "radiusKm": 5,
    "searchKm": 1.5,
    "clutter": {
      "dbPerKm": 13.3,
      "endpointDb": 0,
      "canopyM": 15
    }
  },
  "model": {
    "name": "profile+bullington+clutter v1",
    "direction": "both",
    "freqMHz": 910.525,
    "kFactor": 1.3333333333333333,
    "bwKHz": 62.5,
    "sf": 7,
    "cr": 5,
    "noiseFigureDb": 6,
    "snrFloorDb": -7.5,
    "noiseFloorDbm": -120.04,
    "sensitivityDbm": -127.54,
    "clutter": {
      "dbPerKm": 13.3,
      "endpointDb": 0,
      "canopyM": 15
    },
    "receiver": {
      "kind": "handheld",
      "heightM": 1.5,
      "gainDbi": 0,
      "txDbm": 22
    },
    "existing": {
      "heightM": 8,
      "gainDbi": 3,
      "txDbm": 22
    },
    "calibration": {
      "baseline": "2026-10-14",
      "liveRepeaters": 65,
      "observedLinks": 145,
      "pairs": 1046,
      "maxKm": 20,
      "medianResidualDb": 0.31,
      "medianAbsResidualDb": 16.7,
      "atZero": {
        "predicted": 297,
        "tp": 105,
        "precision": 0.354,
        "recall": 0.724,
        "f1": 0.475
      },
      "atTen": {
        "predicted": 226,
        "tp": 84,
        "precision": 0.372,
        "recall": 0.579,
        "f1": 0.453
      },
      "distanceOnly": {
        "precision": 0.31,
        "recall": 0.634,
        "f1": 0.416
      },
      "auc": 0.818,
      "aucDistanceOnly": 0.787
    },
    "note": "Estimate — terrain + diffraction + clutter; lidar canopy not included. Bare-earth DEM; trees and buildings enter only through the calibrated clutter term."
  },
  "terrain": {
    "source": "AWS Terrain Tiles (Terrarium; USGS 3DEP / SRTM blend), bare earth",
    "zoom": 13,
    "pixelM": 15,
    "tiles": 16,
    "fetched": 1
  },
  "sweep": {
    "radials": 360,
    "stepM": 60,
    "samples": 83,
    "groundM": 300.7
  },
  "bands": [
    {
      "id": "below",
      "label": "Below 0 dB",
      "areaKm2": 38.85
    },
    {
      "id": "fringe",
      "label": "0–6 dB",
      "areaKm2": 6.54
    },
    {
      "id": "usable",
      "label": "6–12 dB",
      "areaKm2": 8.72
    },
    {
      "id": "solid",
      "label": "Over 12 dB",
      "areaKm2": 23.81
    }
  ],
  "coveredKm2": 39.07,
  "population": {
    "inRadius": 0,
    "covered": 0,
    "newlyCovered": 0,
    "reachKm": 3,
    "groupsCovered": 0,
    "liveRepeaters": 2
  },
  "links": [
    {
      "publicKey": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "keyShort": "aaaaaaaa",
      "name": "Mill Mountain",
      "piece": "Piece 1",
      "km": 2.394,
      "marginDb": 18.4,
      "downDb": 18.4,
      "upDb": 18.4,
      "diffractionDb": 21,
      "clutterDb": 16.9,
      "fsplDb": 99.2
    }
  ],
  "footprint": {
    "type": "FeatureCollection",
    "features": [
      {
        "type": "Feature",
        "properties": {
          "band": "below",
          "label": "Below 0 dB",
          "minDb": null,
          "maxDb": 0,
          "areaKm2": 38.85
        },
        "geometry": {
          "type": "MultiPolygon",
          "coordinates": [
            [
              [
                [
                  -79.94033,
                  37.30049
                ],
                [
                  -79.94049,
                  37.31478
                ],
                [
                  -79.93951,
                  37.31478
                ],
                [
                  -79.93967,
                  37.30049
                ],
                [
                  -79.94033,
                  37.30049
                ]
              ]
            ],
            [
              [
                [
                  -79.93967,
                  37.29995
                ],
                [
                  -79.93952,
                  37.31398
                ],
                [
                  -79.93855,
                  37.31396
                ],
                [
                  -79.93901,
                  37.29994
                ],
                [
                  -79.93967,
                  37.29995
                ]
              ]
            ]
          ]
        }
      },
      {
        "type": "Feature",
        "properties": {
          "band": "fringe",
          "label": "0–6 dB",
          "minDb": 0,
          "maxDb": 6,
          "areaKm2": 6.54
        },
        "geometry": {
          "type": "MultiPolygon",
          "coordinates": [
            [
              [
                [
                  -79.94032,
                  37.29941
                ],
                [
                  -79.94033,
                  37.30049
                ],
                [
                  -79.93967,
                  37.30049
                ],
                [
                  -79.93968,
                  37.29941
                ],
                [
                  -79.94032,
                  37.29941
                ]
              ]
            ],
            [
              [
                [
                  -79.93968,
                  37.29941
                ],
                [
                  -79.93967,
                  37.29995
                ],
                [
                  -79.93901,
                  37.29994
                ],
                [
                  -79.93903,
                  37.2994
                ],
                [
                  -79.93968,
                  37.29941
                ]
              ]
            ]
          ]
        }
      },
      {
        "type": "Feature",
        "properties": {
          "band": "usable",
          "label": "6–12 dB",
          "minDb": 6,
          "maxDb": 12,
          "areaKm2": 8.72
        },
        "geometry": {
          "type": "MultiPolygon",
          "coordinates": [
            [
              [
                [
                  -79.94031,
                  37.29833
                ],
                [
                  -79.94032,
                  37.29941
                ],
                [
                  -79.93968,
                  37.29941
                ],
                [
                  -79.93969,
                  37.29833
                ],
                [
                  -79.94031,
                  37.29833
                ]
              ]
            ],
            [
              [
                [
                  -79.93969,
                  37.29833
                ],
                [
                  -79.93968,
                  37.29941
                ],
                [
                  -79.93903,
                  37.2994
                ],
                [
                  -79.93907,
                  37.29832
                ],
                [
                  -79.93969,
                  37.29833
                ]
              ]
            ]
          ]
        }
      },
      {
        "type": "Feature",
        "properties": {
          "band": "solid",
          "label": "Over 12 dB",
          "minDb": 12,
          "maxDb": null,
          "areaKm2": 23.81
        },
        "geometry": {
          "type": "MultiPolygon",
          "coordinates": [
            [
              [
                [
                  -79.94,
                  37.27
                ],
                [
                  -79.94031,
                  37.29833
                ],
                [
                  -79.93969,
                  37.29833
                ],
                [
                  -79.94,
                  37.27
                ]
              ]
            ],
            [
              [
                [
                  -79.94,
                  37.27
                ],
                [
                  -79.93969,
                  37.29833
                ],
                [
                  -79.93907,
                  37.29832
                ],
                [
                  -79.94,
                  37.27
                ]
              ]
            ]
          ]
        }
      }
    ]
  },
  "grid": {
    "radials": 360,
    "n": 83,
    "stepM": 60,
    "margin": "f39/f39/fXhzbWhjXllUT0tGQj87ODUzMS8tKyooJyYlJCMiISAfIicpKSspKykn",
    "diffraction": "AAAAAAAAAAIEBgcJCw4QEhQWFxgZGhoaGhoaGRgYFxYVExIREA8ODQwMCwsKCgoK",
    "scale": 0.5
  },
  "computeMs": 30,
  "newAreaKm2": 39.05,
  "alreadyCoveredKm2": 0.02,
  "newPeople": null,
  "mount": "building",
  "asOf": "2026-11-15T10:00:00Z",
  "confidence": {
    "level": "estimate",
    "note": "terrain model only here; calibrated on Columbus links (Oct 14 2026); 1 covered map cells within 2 km to compare"
  },
  "cached": false,
  "totalMs": 34
}
''';
