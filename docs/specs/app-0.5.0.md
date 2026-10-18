# Spec: MeshSonar 0.5.0+6 (server move, MeshSonar brand)

Branch `release/0.5.0` (from main 5d9abc6, 0.4.0+5). Owner: Andy. Bundle id `com.meshsonar.app` (unchanged since 0.4.0).

## 1. Why

The website moved from Lovable (`cmh-meshcore.lovable.app`) to MeshSonar's own server, with the same `/api/cmh/*` API
and a copy of the same database. `https://meshsonar.com` (the hub) and `https://cmh.meshsonar.com` both serve it. Phones
on 0.4.0 have the Lovable address saved in `settings.json`, and changing the server URL removes the driver key.

## 2. Server URL

- **AC-1** Default `server_url` is `https://meshsonar.com` (new install, and a settings file without the field).
- **AC-2** At launch, a saved URL whose host is `cmh-meshcore.lovable.app` (any scheme, case, path, trailing slash) is
  rewritten to `https://meshsonar.com` and saved. The driver key, its status and display name are **kept**.
- **AC-3** The rewrite is idempotent (second launch: no change, no save) and touches no other host.
- **AC-4** Same-server aliases: `{cmh-meshcore.lovable.app, meshsonar.com, cmh.meshsonar.com}`. A user-initiated change
  between two of them keeps the key and shows no "remove your key?" question, **only** when both addresses are
  `https`, on the default port (none or 443), with no userinfo, no query or fragment, and an empty path or `/`.
  Anything else (http, `:8443`, `user@`, `/api`, other `*.meshsonar.com` hosts, look-alikes) removes the key and asks
  first, as in 0.4.0.
- **AC-2a** The launch rewrite applies to the retired host from http or https (always to https), but not when the saved
  URL has userinfo or a non-default port. The rewrite is written to the app log (problem-report log); a failed save is
  logged there too (and to the debug console), and the new address is still used for that run.
- One place: `lib/core/server_url.dart` (`defaultServerUrl`, `sameServerHosts`, `retiredServerHosts`).

## 2a. Release precondition

**meshsonar.com must serve /api/cmh/* and /me/devices before install.** The apex DNS cut-over is owned by the
coordinator and happens before 0.5.0 goes on any device; until then the rewritten URL would not resolve (pings stay on
the phone, the key is kept, nothing uploads).

## 3. Brand

- **AC-5** After comments are stripped, no whole-word all-caps `CMAT` remains in `lib/**/*.dart` (code or string
  literals, with escapes decoded, interpolations, multi-line bodies and adjacent/`+`-joined literals included), in
  `android/app/src/main/res`, in `ios/Runner/*.plist` (and macOS), or in the pubspec description. The website is
  "MeshSonar" (badge, report tags and lines, repeater sheet, onboarding). Identifiers (`CmatClient`, `RepeaterSource.cmat`, `cmat_client.dart`) and comments stay.
- **AC-6** No wire or contract value changes. The app already sends `app.name: "MeshSonar"` in uploads and problem
  reports; the website's own `WEB_APP_WIRE_NAME = "CMAT"` is the website's, not the app's. A wire literal that must
  contain CMAT would go in the allow-list in `test/core/no_cmat_strings_test.dart`.

## 4. Tests

`test/core/server_url_test.dart` (AC-1–4, pure), `test/app/server_migration_test.dart` (AC-2–4 through AppState),
`test/ui/fixes_ui_test.dart` (AC-4 in Settings), `test/core/no_cmat_strings_test.dart` (AC-5–6),
`test/integration/hosts_static_test.dart` (allow-list = the alias hosts + map.meshcore.io + OSM tiles; checked
against `sameServerHosts`).
