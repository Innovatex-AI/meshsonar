# Working rules for agents on meshsonar (read first)

Flutter app (iOS/Android/desktop), version in `pubspec.yaml` (0.7.3+11). Platform state and open items: `meshsonar-infra/docs/HANDOFF.md`. Docs index: README.md "Documentation".

- **Privacy is non-negotiable.** On-air ping text is exactly `MS:` + 10 random chars (`lib/radio/wardrive_engine.dart`: `newPingTag`, `formatPingText`). Never put position, power, name or any identifier in it. Legacy `@[MapperBot]` fixtures in tests are captured packets; keep them.
- Layers: `lib/core` and `lib/radio` are pure Dart (no Flutter imports); UI in `lib/ui`; platform seams in `lib/platform`. Save-first: a ping is on disk before anything else happens (docs/ARCHITECTURE.md).
- Hex cells: display res 9 = `cellToParent(geoToCell(res 11))`, never a direct res-9 lookup (about 6% differ). Ids are BigInt in Dart, lowercase hex strings on the wire. `test/hex_cells_test.dart` needs `brew install h3`.
- Wire contract with the website: `docs/MESHSONAR_DRIVE_FORMAT.md` in meshcore-insights; JSON keys are pinned by a golden test (`test/core/antenna_profile_test.dart`). Changing a field means updating the website validator too.
- Always run `flutter analyze` and `flutter test` (522 tests) before a PR; bump `pubspec.yaml` and `test/app/app_version_test.dart` together; add a `docs/CHANGELOG.md` entry; update PROTOCOL/ARCHITECTURE/FEATURES if behaviour changed.
- Installing on Andy's phone/iPad: `flutter build ios --release`, then `xcrun devicectl device install app --device <id> build/ios/iphoneos/Runner.app`. NEVER `flutter install` (uninstalls first, wipes local drives and the driver key). Device ids and details: HANDOFF.md section 4.
- The cloud sandbox has no Flutter; build, test and device work happen on Andy's Mac. Use `git clone` + `gh api` REST (GraphQL is blocked) from the sandbox.
- Never commit secrets or driver keys. Owner preferences: no apologies ("Yes sir" and fix), blunt, never assume, quality over speed.
