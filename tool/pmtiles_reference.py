#!/usr/bin/env python3
"""Independent reference values for test/core/pmtiles_real_pack_test.dart.

Uses the protomaps `pmtiles` Python package (not our Dart reader) to read a real region pack and print, as JSON:
header fields, directory statistics (root/leaf entries, run-length entries, addressed tiles) and, for a fixed list of
z/x/y tiles, the SHA-256 of the gunzipped tile bytes plus the MVT layer names (via `mapbox-vector-tile`).

Run (scratch venv, never in the repo):
  python3 -m venv /tmp/v && /tmp/v/bin/pip install pmtiles mapbox-vector-tile
  /tmp/v/bin/python -I tool/pmtiles_reference.py /path/to/CMH-v261024.pmtiles
"""
import gzip, hashlib, json, math, sys

from pmtiles.reader import MmapSource, Reader, all_tiles
from pmtiles.tile import deserialize_directory, deserialize_header
import mapbox_vector_tile


def tile_for(lat, lon, z):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    r = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(r)) / math.pi) / 2.0 * n)
    return z, x, y


def main(path):
    out = {}
    with open(path, 'rb') as f:
        src = MmapSource(f)
        rd = Reader(src)
        h = rd.header()
        out['header'] = {k: (v.value if hasattr(v, 'value') else v) for k, v in h.items()}
        # Directory statistics by walking root + every leaf.
        hb = deserialize_header(src(0, 127))
        root = deserialize_directory(src(hb['root_offset'], hb['root_length']))
        leaves = [e for e in root if e.run_length == 0]
        leaf_entries = []
        for e in leaves:
            leaf_entries += deserialize_directory(src(hb['leaf_directory_offset'] + e.offset, e.length))
        tile_entries = [e for e in root if e.run_length > 0] + [e for e in leaf_entries if e.run_length > 0]
        out['dirs'] = {
            'root_entries': len(root),
            'leaf_dirs': len(leaves),
            'leaf_entries': len(leaf_entries),
            'tile_entries': len(tile_entries),
            'run_entries': sum(1 for e in tile_entries if e.run_length > 1),
            'addressed_tiles': sum(e.run_length for e in tile_entries),
            'max_run': max(e.run_length for e in tile_entries),
        }
        # One concrete run-length entry (first with run > 1) so the Dart test can hit the middle of a run.
        run = next((e for e in sorted(tile_entries, key=lambda e: e.tile_id) if e.run_length > 1), None)
        out['first_run'] = None if run is None else {'tile_id': run.tile_id, 'run_length': run.run_length}
        # Entries sharing one data offset (planetiler dedupes identical tiles that way when they are not adjacent).
        offs = {}
        for e in tile_entries:
            offs[e.offset] = offs.get(e.offset, 0) + 1
        out['dirs']['shared_offset_entries'] = sum(c for c in offs.values() if c > 1)
        pts = {
            'z0': tile_for(39.96, -83.00, 0), 'z6': tile_for(39.96, -83.00, 6),
            'z10': tile_for(39.96, -83.00, 10), 'z14': tile_for(39.96, -83.00, 14),
            'z14_sw': tile_for(39.3613 + 1e-4, -83.6534 + 1e-4, 14),
            'z14_ne': tile_for(40.7127 - 1e-4, -82.0242 - 1e-4, 14),
        }
        z, x, y = pts['z14_sw']
        pts['z14_out_w'] = (14, x - 3, y)
        z, x, y = pts['z14_ne']
        pts['z14_out_n'] = (14, x, y - 3)
        tiles = {}
        for name, (z, x, y) in pts.items():
            raw = rd.get(z, x, y)
            if raw is None:
                tiles[name] = {'z': z, 'x': x, 'y': y, 'present': False}
                continue
            data = gzip.decompress(raw)
            mvt = mapbox_vector_tile.decode(data)
            tiles[name] = {
                'z': z, 'x': x, 'y': y, 'present': True, 'bytes': len(data),
                'sha256': hashlib.sha256(data).hexdigest(), 'layers': sorted(mvt.keys()),
            }
        out['tiles'] = tiles
        n = 0
        for _ in all_tiles(src):
            n += 1
        out['all_tiles_yielded'] = n
    print(json.dumps(out, indent=1, default=str))


if __name__ == '__main__':
    main(sys.argv[1])
