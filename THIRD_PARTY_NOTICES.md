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

### Dependency note: flutter_reactive_ble (BSD-3-Clause)
lib/radio/ble_transport.dart uses the `flutter_reactive_ble` package (5.4.x, © Philips Hue / Signify, BSD-3-Clause,
free for commercial use). It replaced `flutter_blue_plus` (FlutterBluePlus License, paid for for-profit use) in
0.21.0. No flutter_reactive_ble code is copied into MeshSonar; it is a pub dependency.

## Chat (lib/chat/)

Link and QR formats (`meshcore://channel/add`, `meshcore://contact/add`, legacy advert hex) follow MeshCore `docs/qr_codes.md` and
MeshCore Open `lib/utils/contact_qr.dart` (both MIT, see above); re-implemented, no code copied. Used in: lib/chat/mesh_links.dart.

### Dependency note: chat packages
`sqlite3` (MIT, Simon Binder; bundles SQLite, public domain), `flutter_secure_storage` (BSD-3-Clause, Julian Steenbakker),
`archive` (MIT), `cryptography` (Apache-2.0, Gohilla; pure Dart AES-GCM and PBKDF2). All are pub dependencies; no code is copied.

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

## Data (shown in the drive report)

### Open-Meteo
Weather data by Open-Meteo.com (CC BY 4.0) — https://open-meteo.com

The weather block of the drive report shows hourly weather (temperature, humidity, dew point, wind, precipitation, cloud
cover, station pressure) that the MeshSonar server looked up from Open-Meteo for a cell of about 5 km around a drive. The
phone never contacts Open-Meteo and sends no position to it. The data is licensed under Creative Commons Attribution 4.0
(https://creativecommons.org/licenses/by/4.0/); the credit line above is shown directly under any weather values. Open-Meteo's
free API is for non-commercial use only: check its terms (or use its paid or self-hosted service) before any commercial use.
Used in: lib/core/drive_env_cache.dart, lib/ui/report/drive_weather_section.dart.
