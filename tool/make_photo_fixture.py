#!/usr/bin/env python3
"""Builds test/fixtures/photos/gps_fixture.jpg: a small camera-like JPEG (640x480 gradient) carrying an EXIF block with
Make/Model, Orientation and a GPS IFD (39.7589 N, 84.1916 W), a COM comment and an XMP packet naming GPS. Used by the
EXIF-strip tests (test/core/jpeg_meta_test.dart) and the simulator self-check. Needs macOS `sips`."""
import os, struct, subprocess, sys, tempfile, zlib

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', 'test', 'fixtures', 'photos', 'gps_fixture.jpg')
W, H = 640, 480
raw = bytearray()
for y in range(H):
    raw.append(0)
    for x in range(W):
        raw += bytes((x * 255 // W, y * 255 // H, 128))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b'')
tmp = tempfile.mkdtemp()
p, j = os.path.join(tmp, 'a.png'), os.path.join(tmp, 'a.jpg')
open(p, 'wb').write(png)
subprocess.run(['sips', '-s', 'format', 'jpeg', p, '--out', j], check=True, capture_output=True)
jpg = open(j, 'rb').read()

# TIFF (big endian) with IFD0 {Make, Model, Orientation, GPS pointer} and a GPS IFD {LatRef, Lat, LonRef, Lon}.
def rat(n, d): return struct.pack('>II', n, d)
make, model = b'Apple\x00', b'iPhone 17 Pro\x00'
ifd0_n = 4
ifd0_off = 8
ifd0_size = 2 + ifd0_n * 12 + 4
data_off = ifd0_off + ifd0_size
make_off = data_off
model_off = make_off + len(make)
gps_off = model_off + len(model)
gps_n = 4
gps_size = 2 + gps_n * 12 + 4
lat_off = gps_off + gps_size
lon_off = lat_off + 24
t = b'MM\x00\x2a' + struct.pack('>I', ifd0_off)
t += struct.pack('>H', ifd0_n)
t += struct.pack('>HHII', 0x010F, 2, len(make), make_off)
t += struct.pack('>HHII', 0x0110, 2, len(model), model_off)
t += struct.pack('>HHIHH', 0x0112, 3, 1, 1, 0)
t += struct.pack('>HHII', 0x8825, 4, 1, gps_off)
t += struct.pack('>I', 0)
t += make + model
t += struct.pack('>H', gps_n)
t += struct.pack('>HHI', 0x0001, 2, 2) + b'N\x00\x00\x00'
t += struct.pack('>HHII', 0x0002, 5, 3, lat_off)
t += struct.pack('>HHI', 0x0003, 2, 2) + b'W\x00\x00\x00'
t += struct.pack('>HHII', 0x0004, 5, 3, lon_off)
t += struct.pack('>I', 0)
t += rat(39, 1) + rat(45, 1) + rat(3204, 100)
t += rat(84, 1) + rat(11, 1) + rat(2976, 100)
exif = b'Exif\x00\x00' + t
app1 = b'\xff\xe1' + struct.pack('>H', len(exif) + 2) + exif
xmp = b'http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta><exif:GPSLatitude>39,45.534N</exif:GPSLatitude></x:xmpmeta>'
app1x = b'\xff\xe1' + struct.pack('>H', len(xmp) + 2) + xmp
com = b'home: 123 Example St'
comseg = b'\xff\xfe' + struct.pack('>H', len(com) + 2) + com
# Insert right after SOI and any APP0.
i = 2
if jpg[2:4] == b'\xff\xe0':
    i = 4 + struct.unpack('>H', jpg[4:6])[0]
res = jpg[:i] + app1 + app1x + comseg + jpg[i:]
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
open(out, 'wb').write(res)
print(out, len(res))
