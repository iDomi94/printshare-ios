# Porting notes

Decisions and deviations while porting `mobile/` (Expo) to Swift + SwiftUI. Rule used: what `mobile/src` does is right;
if it contradicts `printshare/api.py` the server wins; otherwise the simplest idiomatic SwiftUI solution.

## Where things are

- The native app lives in its own repository (`iDomi94/printshare-ios`), so the project is at the **repository root**,
  not in an `ios-native/` folder. `mobile/` and `printshare/` are not part of this repository and were not touched.
- No pull request against `halvar20000/printshare` was opened: this repository is separate and the run was
  limited to `printshare-ios` (pushing to its `main` was allowed).

## Source snapshot

- Ported from the working copy of `iDomi94/printshare` at `a2614f0` (server 0.4.0); on 2026-09-30 caught up with
  upstream `halvar20000/printshare` `507fff4` (**server 0.6.0**), read from the code this time:
  - **Bed leveling** (DO-01): `/api/printers` sends `leveling` (default, or null = no switch). The first port sent
    `level` in `POST /send`, which the server silently ignored; it is `leveling` and only sent with `start: true`,
    like the Expo app. The choice is remembered per printer (`ps_level_<id>`).
  - **Preview**: the app asks for `?format=2`; paths are `[type, tool, x0, y0, …]` in 1/`unit` mm (unit 20), plus
    `bounds` (model extent without start code) and `filament_colors`. Format 1 (servers 0.5.x, no `version` field)
    is still read. Colour mode (by filament) is the default when more than one filament is used, like the Expo app;
    the view opens on the last layer.
  - **Multicolour** (MA-04): for a chosen `.3mf` the prepare screen calls `/api/inspect`; with more than one used colour
    the single material row is replaced by one row per colour and `options.filaments` (one entry per project filament,
    `null` = the default material) is sent. Any inspect error falls back to the single-colour flow.
  - **G-code sharing** (SL-10): new in the native app (the Expo app has no button yet); the file is downloaded into
    the temp folder and handed to the share sheet.
- Pairing hint on the connect screen uses the container name `PrintShare`
  (`docker exec PrintShare printshare pair --url http://SERVER-IP:8484`).

- **Server 0.10.0** (upstream `7c03c58`, 2026-09-30), ported from the Expo app of the same commit:
  - **Lanes** (issue #6, 0.8.0): `status.lanes` (AFC / CANVAS). The job screen has a section "Spuren" with one row per
    colour; default and warnings follow `job/[id].tsx` (`LanePlan`): loaded lane with the profile's material and the
    closest colour, else T(n-1), else any loaded lane. An empty lane blocks "Print" (red), another material warns
    (yellow). `send` carries `lanes {"<colour>": <tool>}` when the printer has lanes, for uploads too.
  - **Slots before slicing** (native only, Dominique's feedback 2026-09-30): the Expo app picks a material per colour
    and the lane only after slicing. Here, when the chosen printer reports lanes, the prepare screen shows "Slot N" per
    colour instead (N = the physical number from the lane id, `CANVAS_1` = Slot 1, not the tool: on his CANVAS Slot 1
    is T3; lane ids when the numbers are missing or repeat). Material and colour come from the printer; the slicing
    preset follows the slot's material (`LanePlan.preset`: preset named like the lane's filament, else the last choice,
    else the default, else the first of that material). Long-press a colour (or the material row for one colour) to
    pick the preset by hand. The chosen tools go to the job screen as its default (`AppModel.plannedSlots`, memory
    only) and are still changeable there without re-slicing. The upstream wording "Spur/Lane" is shown as "Slot".
  - **Camera** (issue #3, 0.9.0): no longer straight from the printer. `CameraView` shows live MJPEG from
    `/api/printers/<id>/camera/stream` (our own parser, token as header - no WebView needed) or still images from
    `/camera/snapshot?w=`; away (route "remote") it starts with still images (every 3 s) to save mobile data. The
    printers tab shows a thumbnail (every 5 s) for printers whose `/camera` says `available`; the job screen offers
    the camera after a start.
  - **Printer control** (issue #5, 0.10.0): `ControlView` (button "Steuerung" on the printers tab): heaters with a
    target picker and PLA / PETG / cool-down presets, history chart (Swift Charts, status every 3 s, history every
    10 s), fans in 25 % steps, lights, speed modes or 50-150 %. Heater changes and fan off during a print, and high
    targets (nozzle ≥ 260, bed ≥ 100, chamber ≥ 50 °C), are confirmed first. A 409 from the server (print started
    since the last poll) turns into the same question; the change is only sent again after the user agrees.
  - **Own printer profile** (issue #2, 0.7.0): Settings → printer → `PrinterProfileView`: standard or uploaded
    profile, upload via the document picker (JSON or preset bundle zip, raw body, used for this printer right away),
    delete via long press (context menu).
  - Texts from the 0.10.0 `i18n.ts`, including the name tables for heaters, fans, lights and speed modes.

- **Model files in 3D** (not in the Expo app): the file row on the model page opens a sheet with the files of
  `/api/files` (same order and index as the prepare screen). STL is read by `STLReader` (binary + ASCII; ModelIO returned no mesh for STL on CI), OBJ with ModelIO (`MDLAsset`), and shown
  in a SceneKit `SceneView` (rotated from Z-up, centred, one material); 3MF/STEP show a note instead. "Prepare print"
  opens the prepare screen with that file preselected. The file comes from `GET /api/model-file` (server 0.10.1, upstream PR #11); older
  servers answer 404 and the app says the server is too old.

## Verification

- The session that wrote this code had **no macOS, no Xcode and no Swift toolchain** (download of a toolchain is
  blocked by the sandbox proxy). No simulator run took place and nothing was compiled locally. The GitHub Actions
  workflow (macos-latest) is the compiler and test runner: build with Swift 6 / complete strict concurrency and all
  unit tests are green, with no compiler warnings (last checked at run #3).
- Not verified on device or simulator: any screen, the share extension, the QR scanner, TestFlight upload,
  Keychain migration from the Expo build.

## Decisions

- **Project file**: XcodeGen `project.yml`; `.xcodeproj`, generated `Info.plist` and entitlements are gitignored.
  `DEVELOPMENT_TEAM` is read from the environment (`${DEVELOPMENT_TEAM}`); CI passes it empty and disables signing.
- **Version**: `MARKETING_VERSION` 0.1.0 (version in `mobile/app.json` of the copy read), build 100.
- **Codable**: explicit `CodingKeys` per type instead of `.convertFromSnakeCase`, because that strategy also rewrites
  dictionary keys (`overrides`, `profiles`). Fields that are only informative decode leniently (a wrong type becomes
  `nil` instead of failing the whole response). Enums (`JobState`, `PrinterKind`) fall back to `unknown`.
  `PrinterKind` has an extra client-side case `offline` (TS uses `PrinterKind | "offline"`).
- **Texts**: `{name}` placeholders were kept (replaced in `L10n`) instead of `%@`, so the strings stay identical to
  `i18n.ts` and the generator stays trivial. Tables (job states, printer kinds, plate names) are flat keys such as
  `jobState.sliced`. The log translation rules are German-only, like the Expo app. Strings are loaded from the
  `<lang>.lproj` bundle of the chosen language.
- **Navigation**: one `NavigationStack` around the `TabView`, so Prepare / Job / Model / Preview open above the tab bar
  like in the Expo app; Connect is a sheet, the QR scanner a full-screen cover. Home and Discover hide the navigation
  bar (they have their own large title), the other tabs show it.
- **Components** are prefixed `PS…` (`PSSection`, …) to avoid clashes with SwiftUI types. Ionicons were mapped to SF Symbols.
  Segmented controls use the system picker style.
- **Route cache** (`RouteCache`) is an actor shared by all clients, keyed by `url|remoteUrl`, so it survives re-creating
  the client. The probe and retry rules are those of `api.ts`; POST and DELETE are never repeated automatically.
- **Timeouts**: 15 s default; 8 s info, 30 s options/createJob/search/model, 20 s status, 60 s files/preview, 600 s upload
  (the Expo upload had no explicit limit).
- **`ago`** uses `RelativeDateTimeFormatter` (units chosen by the system) instead of the hand-written second/minute/hour/day switch.
- **Share extension** hands over a JSON manifest plus copied file in the App Group (`inbox.json`, `Inbox/<uuid>/<name>`;
  file paths are stored relative to the container). It opens `printshare://share` through the responder chain
  (`openURL:options:completionHandler:` selector); if that fails the app picks the item up the next time it becomes
  active. A shared file is deleted from the App Group once the server has it; files of abandoned shares are purged
  after a day (`SharedInbox.purge`, when the inbox is processed).
- **Keychain migration** from `expo-secure-store`: checked against the expo-secure-store 57.0.4 source
  (`ios/SecureStoreModule.swift`). Items live under service `app:no-auth` (older versions: `app`), with account and
  generic attribute set to the key as UTF-8 **data**. The first port looked only at service `app` and read the account
  as a string, so it would have found nothing; fixed. `KeychainMigrationTests` writes an item the way Expo does, but
  the unsigned CI test host has no keychain access, so that test is skipped there (run it in Xcode with a team set).
  Still not tried on a phone that has the Expo build installed.
- **Tests**: XCTest. The test target compiles in Swift 5 language mode (mutable URLProtocol test doubles); the app itself is
  Swift 6 with complete strict concurrency.
- **Jobs list** has no swipe-to-delete, because the Expo list does not offer it either.
- **Idle timer**: the screen stays on while a job is slicing/sending (`isIdleTimerDisabled`), reset when leaving the screen.
- **Polling** (jobs, printers) runs in `.task(id:)` blocks that end when the screen disappears or the app leaves the
  foreground.

## Possible server problems seen while reading

- None that needed a note. `POST /api/jobs` receives no `file` key when it is `nil` (the Expo app sent `null`); the
  server model treats both the same.
