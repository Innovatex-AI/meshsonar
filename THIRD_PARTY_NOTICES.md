# Third-party notices

MeshSonar is MIT-licensed. It contains code ported or adapted from the projects below, each under the MIT License.
The full MIT License text follows each copyright line.

## Radio (lib/radio/)

### MeshCore firmware
Copyright (c) 2025 Scott Powell / rippleradios.com — https://github.com/meshcore-dev/MeshCore

Companion-protocol command/response/push codes and byte layouts (examples/companion_radio/MyMesh.cpp), the
over-the-air packet format (src/Packet.h, src/Packet.cpp), path-append rule (src/Mesh.cpp), group-text encryption
(src/Utils.cpp, src/Mesh.cpp, src/helpers/BaseChatMesh.cpp) and the node-discovery control payloads
(examples/simple_repeater/MyMesh.cpp) were re-implemented in Dart from this source.
Used in: lib/radio/protocol.dart, lib/radio/packet.dart, lib/radio/crypto.dart, lib/radio/companion_link.dart,
lib/radio/simulator.dart.

### MeshMapper web client
Copyright (c) 2025 MrAlders0n — MeshMapper wardriving client (content/wardrive.js, content/mc/)

Wardriving behaviour adapted: #wardriving channel join/creation and key derivation, the "@[MapperBot] lat, lon [power]"
ping text, echo recognition (channel hash + decrypt + text match + first path hop, best SNR per repeater), listen
window, distance rule and noise-floor read via radio stats.
Used in: lib/radio/wardrive_engine.dart, lib/radio/packet.dart, lib/radio/companion_link.dart.

### MeshCore Open
Copyright (c) 2025 zjs81 — https://github.com/zjs81/meshcore-open

BLE service/characteristic UUIDs and connection sequence (scan filtered on service UUID, MTU 185 where supported,
notify on TX, write-without-response to RX), path_len hash-size decoding and frame-builder conventions.
Used in: lib/radio/ble_transport.dart, lib/radio/packet.dart, lib/radio/protocol.dart.

### Dependency licence note: flutter_blue_plus (not MIT)
lib/radio/ble_transport.dart depends on the `flutter_blue_plus` package (2.x), which is distributed under the
**FlutterBluePlus License v1.6**, Copyright (c) 2026 Chip Weinberger — not MIT/BSD. Free for personal users, registered
nonprofits and educational institutions; any use by or for a for-profit organisation (including development and
testing) requires a commercial licence; it prohibits relicensing and may send build-time licence telemetry. No
flutter_blue_plus code is copied into MeshSonar; it is a pub dependency. See its LICENSE in the pub cache.

### MIT License (applies to each of the above)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Map and fonts (lib/ui/)

### Barlow typeface
Copyright 2017 The Barlow Project Authors (https://github.com/jpt/barlow). Licensed under the SIL Open Font License 1.1;
the full licence is bundled at assets/fonts/Barlow-OFL.txt. Used as the app typeface (Barlow, Barlow Semi Condensed).

### OpenStreetMap map tiles
Map data © OpenStreetMap contributors, available under the Open Database License (https://www.openstreetmap.org/copyright).
Tiles are loaded from tile.openstreetmap.org under the OSM tile usage policy; the app shows the required attribution on
every map. Map rendering uses the flutter_map package (BSD-3-Clause).
