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
  - **3D preview** (beyond the Expo app, 2026-09-30): third segment "3D" next to "Modell / Ganze Platte". Built from the
    same preview paths (no G-code in the app): each path becomes a ridge (top at the layer's z, feet one layer height
    lower, 0.42 mm wide, mitred corners), one SceneKit node per layer so the slider hides the layers above, vertex
    colours by line type or filament. Above 300 000 visible segments it falls back to thin lines (memory). SCNView with
    turntable orbit around the model centre; the page doesn't scroll in 3D so dragging rotates.
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

- **Server 0.13.1** (upstream `509c409`, 2026-09-30), ported from the Expo app and `docs/API.md` of the same commit:
  - **Slots before slicing** (issue #12, 0.11): upstream took over the native design (`mobile/src/lib/lanes.ts`, "same
    rules as LanePlan.swift"). Back-port of its `defaultSlots`: each loaded slot is used once if possible, a colour
    without a colour value (single-colour model) gets the slot in the toolhead, the T(n-1) rule is gone. The printers
    tab shows the lane chips as "Slot N · material" in physical order.
  - **Power through Home Assistant** (issue #9, 0.12.0): `Printer.power`; the printers tab offers "Einschalten" for an
    offline printer with a plug (`POST /power {"on": true}`), then "Drucker startet …" for 120 s, then the "meldet sich
    noch nicht" hint and the button again. `ControlView` shows the plug state and "Ausschalten" (confirmation, locked
    during a print; the server refuses it with 409 anyway). The plug settings (`/power/config`, `/test`, `/entities`)
    are web-only, as upstream.
  - **Own quality / material presets** (issue #7, 0.13.0): `/options` `own` → pickers group them as "Eigene Profile";
    `PrinterProfileView` lists uploaded process / filament presets (long press deletes); an upload without a machine
    preset says so (`profileStoredOther`).
  - **Name PocketPrint3D** (0.13.1): visible texts, display name and usage descriptions. Kept on purpose, as upstream:
    the `printshare://` scheme, bundle ids / App Group, the container name `PrintShare` in the pairing command, the
    Swift target and module names.
  - Texts from the 0.13.1 `i18n.ts`; the native-only key `slotsHint` became `jobSlotsHint` (upstream now has its own).

- **Server 0.14.0** (upstream PR halvar20000/printshare#14, 2026-09-30): plate options per job. `JobOptions` got
  `copies`, `rotate_x`, `rotate_y`, `scale`, `orient`; `JobResult` `copies_requested` / `copies` (`knowsPlate` = the
  server sent `copies_requested`, older servers ignore the options silently, so the review only shows the plate row
  for 0.14+). `PlateOptions.swift` has the same choices as the Expo app's `lib/plate.ts` (one "Lage" picker for tilt
  / lay flat, copies 1-50, size 25-400 % in 25 steps). No Z rotation: OrcaSlicer's auto-arrange turns objects anyway.
  Texts from the 0.14.0 `i18n.ts`.

- **Server 0.15.1 / cloud mode** (upstream `bfee81d` = 0.15.2, 2026-10-01), ported from the Expo app of the same commit
  (`connect.tsx`, `cloud-printer/[id].tsx`, `lib/printerAccess.ts`, `lib/lan/*`):
  - **Login**: the connect sheet has "PocketPrint3D Cloud / Eigener Server". Cloud = e-mail code (`POST
    /api/auth/code` with `lang`, `POST /api/auth/login` with `device: "ios app"`) against `https://api.pocketprint3d.com`;
    the session token is stored like a pairing token, `Server` got `cloud` + `email` (older stored servers decode
    unchanged). Error texts in the order of `cloudError`; a 401 from a cloud request reads `errSession`.
  - **Settings in the cloud**: account (e-mail, slices today from `/api/auth/me`), change, log out (confirm),
    printers of the account (`CloudPrinterView`: name, type Centauri / Klipper, COSMOS switch, Wi-Fi address with a
    connection test, profile, remove with confirm), delete account (two confirmations, `DELETE
    /api/auth/account?confirm=true`).
  - **Printers on the Wi-Fi**: the Wi-Fi address stays on the phone (Keychain `ps_lan_<account>`, as the Expo key) and
    is never sent to the cloud. `LAN/SDCPPrinter.swift` (Centauri stock firmware: SDCP over `URLSessionWebSocketTask`
    :3030, chunked multipart upload :80 with MD5 from CryptoKit, file listing + start check + one more start like the
    server's finding 11) and `LAN/MoonrakerPrinter.swift` (address, then :7125; AFC lanes as on the server). Without
    a concurrent receive loop: each command sends and reads messages until its answer; a watchdog closes the socket
    on timeout, the next command opens a new one.
  - **Screens**: printers tab, prepare and job screen ask the printer directly in the cloud (`AppModel.printerStatus`);
    no address → "Adresse im Heimnetz" button. Print / upload in the cloud downloads `/api/jobs/<id>/gcode?lanes=…`
    (slots mapped by the server) and sends it from the phone with a progress banner; the server job stays "sliced",
    the screen remembers the result. Camera, control and power are hidden in the cloud, as upstream.
  - Texts from the 0.15.3 `i18n.ts` (the generator now also reads the `printerTypes`, `printerTypeHints` and
    `infillNames` tables). The 0.15.2 infill pattern came with PR #15, merged into this branch.
- **Server 0.15.3** (upstream `24b0770`, 2026-10-01): PrusaLink and OctoPrint printers in the cloud.
  - `LAN/PrusaLinkPrinter.swift`: digest auth (user `maker` + the password from the printer screen; `DigestAuth`,
    RFC 7616 MD5 with qop=auth, checked against the RFC 2617 example) or `X-Api-Key`; the first request without
    credentials gets the challenge, the same request is sent once more with them (the printer refused the first, so
    nothing runs twice). Upload = raw `PUT /api/v1/files/<storage>/<name>` with `Print-After-Upload`; FAT-safe names.
  - `LAN/OctoPrintPrinter.swift`: API key, multipart `POST /api/files/local` with `select`/`print`, state from the
    flags of `/api/printer` (409 = not connected), pause/resume/cancel through `POST /api/job`.
  - Moonraker takes an optional API key. What the app stores per printer is now `LanAccess` (address, PrusaLink
    password, API key) in the Keychain; the bare address strings of earlier builds still load.
  - `CloudPrinterView`: type picker with the four types and their hints, printer model from `GET /api/machines`
    (required for PrusaLink / OctoPrint, sent as `machine`), password / API key fields, connection test.
- **Server 0.16.0-0.17.1** (upstream `be72d42`, 2026-10-02), ported from the Expo app of the same commit
  (`lib/spoolman.ts`, `spoolman.tsx`, `spools.tsx`, `spool/[id].tsx`, `job/[id].tsx`, `printers.tsx`):
  - **Spoolman** (MA-07, 0.16.0): `Spoolman/Spoolman.swift` talks to the user's Spoolman directly (the address stays on
    the phone, `ps_spoolman_<account>` = `{url}`; without port or path `:7912` is tried too). Job screen: section
    "Spulen" with one spool per colour (picker grouped by material, "Keine Spule"), low-filament and material warnings.
    Default per colour: the user's choice, else the lane's `spool_id`, else Moonraker's active spool, else the last
    spool used on that printer (`ps_spools_<account>_<printer>`). Printers whose Moonraker has its own `[spoolman]`
    (`status.spoolman.connected`) book themselves: single colour → `spool_id` with `/send` (server) or
    `POST /server/spoolman/spool_id` before the upload (cloud relay); with AFC the slots' spools are shown, not
    chosen; multicolour without AFC → hint only. Other printers: the app stores a booking (`ps_bookings_<account>`,
    max 20, same JSON as the Expo app) and settles it on the printers tab with every status refresh (`Bookings.judge`:
    done → book; cancelled / error → ask with the printed share; gone after being seen at ≥ 99 % → book; never seen
    within 20 min or offline for 3 days → ask). Booked spools are removed from the booking one by one, so a retry
    never books twice.
  - **Cloud spools** (0.17.0): setting `"cloud"` = the same API under `<cloud>/spoolman` with the session token; list,
    add, edit, copy, archive, delete (`SpoolsView`, `SpoolFormView`). Only offered for cloud accounts.
  - **MakerWorld** (0.17.1): links (also from the share menu) open the model page; `download: "external"` hides the
    file row and "print", shows a button to MakerWorld; `variants` (print profiles) are listed. The 3MF comes back
    through the share menu.
  - Not verified against a real Spoolman, a Moonraker with `[spoolman]` or MakerWorld; only stubs and server shapes.

- **Server 0.18.0-0.23.0** (upstream `c9f9123`, 2026-10-02), ported from `docs/API.md`, `printshare/api.py` and the
  Expo app of the same commit:
  - **Orca Cloud share link** (0.18.0, issue #7): printer settings → "Aus der Orca Cloud" posts the link to
    `POST /api/profiles/orca-cloud`; the printer preset is used right away only when exactly one imported machine
    preset inherits this printer's machine, otherwise the user picks it from the list.
  - **SpoolmanDB** (0.19.0): spool form → "Aus Datenbank wählen" (`/api/filament-db/brands`, `/filaments?brand=`) fills
    brand, name, material, colour, weight and sends `filament.density` + `spool_weight`.
  - **MakerWorld card** (Discover) and MakerWorld links typed into the search field open the model page.
  - **Manyfold** (0.21.0, own servers only): Settings → Manyfold (`/api/manyfold/config`, key never shown, left out =
    kept). Hits carry `link` "manyfold:<id>" which is used for files and jobs; their images are server paths
    ("/api/…") and get the server address + `?token=` (`APIClient.imageURL`). No sort chips for Manyfold.
  - **AI failure detection** (0.23.0, own servers only): Settings → KI-Fehlererkennung
    (`/api/failure-detection/config`); printer card shows `status.watch` (line while watching, red box with the checked
    frame from `/watch/frame` on an alert, "Fehlalarm" → `POST /watch/mute`, "Pause" = the normal pause).
  - **Not ported**: OpenPrintTag NFC tags (0.20.x) need the "NFC Tag Reading" capability on the App ID (developer
    portal, by hand) and CoreNFC; the 3D G-code view of the Expo app (#4) - the native app has its own `Plate3D`.
    Thumbnails (0.20) and klipper_estimator (0.22) are server-side only.
  - Not verified against a real Orca Cloud link, SpoolmanDB, Manyfold or Obico ML API; only stubs and server shapes.

- **Server 0.24.0-0.34.0** (upstream `ae96cbd`, 2026-10-03), ported from `docs/API.md`, `docs/BRIDGE.md`,
  `printshare/api.py` and the Expo app of the same commit:
  - **Bridges** (0.24-0.27, cloud only): Settings → Erweitert → Brücken (`BridgesView`): pairing code (`POST
    /api/bridges/pair`, typed as `XXXX-XXXX`), list with online state and printers, remove. Printers with `bridge` go
    through the server like on an own server (`AppModel.viaServer`): status, control, camera, `send`. New bridge
    printers: the bridge searches its network (`/api/bridges/<id>/discover`), address / password / API key are sealed
    for the bridge (`Seal`, scheme "pp3d-seal-v1" with CryptoKit X25519 + HKDF-SHA256 + ChaCha20-Poly1305, zero nonce;
    checked against a blob made by the server's `seal.py`) and sent as `sealed`; this phone keeps nothing.
  - **Pi bridge on the Wi-Fi** (0.34): `GET /api/bridge/hello` on ports 80 / 8484 of the /24 network and
    `pocketprint3d.local`; "Verbinden" fetches `/api/bridge/local-code` and pairs with it.
  - **Printers on the Wi-Fi** (app feature of the same commits, `Discovery`): HTTP probes like the Expo app (Moonraker
    `/server/info` on 80 / 7125, COSMOS by its macros, PrusaLink 401 realm "Printer API", OctoPrint page). Centauri
    SDCP: iOS needs Apple's multicast entitlement for broadcasts, so "M99999" goes by unicast UDP to every address of
    the /24 (one BSD socket, answers collected for 2.5 s). Wi-Fi address from `getifaddrs` (en0).
  - **Jobs follow the print** (0.33): states `finished` / `cancelled` / `uploading`, `printer_file`; after a phone
    send `POST /api/jobs/<id>/relayed`, the printers tab posts LAN statuses to `POST /api/observe` (at most every
    30 s). "Nochmal drucken" on finished jobs. The plate-empty switch became the confirm question `confirmStartPlateQ`.
  - **Time-lapse** (0.32): switch on the review screen when the printer has a camera through the server, `send`
    `timelapse: true` with a start only; `job.timelapse` state; `TimelapseView` plays
    `/api/jobs/<id>/timelapse?token=` with AVKit and shares a downloaded copy.
  - **Cloud bookings** (0.29): with cloud spools the bookings live in the account (`/api/bookings`, `/observe`,
    `/<id>/resolve`); an own Spoolman keeps the phone's list as before.
  - **Send from OrcaSlicer** (0.31): cloud printer → "Aus OrcaSlicer senden" (`/api/printers/<id>/orca-upload`; the
    key is shown once).
  - Settings got the "Erweitert" section; home shows the first-printer card for a cloud account without printers and
    the "own server" link when not connected; new error texts (`friendlyError`, LAN / bridge / Orca rules first).
  - **Not ported**: the web app (0.28: cookies, drag & drop) and the Pi image itself; job persistence (0.30) is
    server-side only. Not verified against a real bridge, a real printer search on a phone, a time-lapse or Orca upload.

- **Model files in 3D** (not in the Expo app): the file row on the model page opens a sheet with the files of
  `/api/files` (same order and index as the prepare screen). STL is read by `STLReader` (binary + ASCII; ModelIO returned no mesh for STL on CI), 3MF by `ThreeMFReader` (own zip reader: stored/deflate via `NSData.decompressed(.zlib)`, zip64; `XMLParser` for the
  model files incl. Orca/Bambu `3D/Objects/*.model` components and build transforms; colour per object/part from
  `Metadata/model_settings.config` + `project_settings.config` or PrusaSlicer `Slic3r_PE*.config`; painted colours are
  not shown), OBJ with ModelIO (`MDLAsset`), and shown
  in a SceneKit `SceneView` (rotated from Z-up, centred, one material); 3MF/STEP show a note instead. "Prepare print"
  opens the prepare screen with that file preselected. The file comes from `GET /api/model-file` (server 0.10.1, upstream PR #11); older
  servers answer 404 and the app says the server is too old.

## Server 0.35.0-0.36.0 (upstream a738200)

- **Bambu Lab (0.35.0)**: `bambu_lan` is only offered for printers added through a bridge (`Lan.bridgeTypes`; the phone cannot
  do MQTT + FTPS). The access code travels as `password` in the sealed secrets, there is no API key. A found printer carries
  `machine` (model from the serial number), which preselects the model.
- **Own camera (0.36.0)**: sealed as `camera_url` (`""` removes it, so `Seal.Secrets.isEmpty` counts it as content). The URL
  check is the Expo app's (`rtsp(s)://` or `http(s)://` plus a host). The camera pictures use the existing camera endpoints.
- **Bridge search hint (0.35.1)**: `Discovery.subnet` turns the phone's Wi-Fi (/24 to /30, wider as /24) into the `subnet` the
  bridge search may take; the timeout is 75 s like in the Expo app.
- Not needed: Bambu camera (0.35.2) and the Bambu start check are server work.

## Server 0.36.1 (upstream af6524c)

- **Turned own camera (0.36.1)**: `#rotate=90|180|270` at the end of the own camera address turns the picture on the server.
  Nothing to port: the URL check already accepts the fragment, and the server then reports `stream: false`, so the app shows
  stills.
- **Not ported: Bambu Lab without a bridge** (Expo app only, upstream `0e0e8a7`, native Android module `bambu-lan`: MQTT over
  TLS, FTPS with TLS session resumption on the data channel, 3MF wrap). iOS would need its own MQTT and FTPS clients on
  Network.framework (no third-party packages); `bambu_lan` stays bridge-only here, so the 0.36.0 text "– nur über eine
  Brücke" is kept (upstream dropped it with that commit).

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
  Since the bundle id changed to `com.dominiqueherbrigpersonalteam.printshare` (2026-09-30) the app can no longer read
  the Expo build's keychain (another app id); the migration stays but finds nothing, users pair once more.
- **Tests**: XCTest. The test target compiles in Swift 5 language mode (mutable URLProtocol test doubles); the app itself is
  Swift 6 with complete strict concurrency.
- **Jobs list** has no swipe-to-delete, because the Expo list does not offer it either.
- **Idle timer**: the screen stays on while a job is slicing/sending (`isIdleTimerDisabled`), reset when leaving the screen.
- **Polling** (jobs, printers) runs in `.task(id:)` blocks that end when the screen disappears or the app leaves the
  foreground.
- **Infill pattern** (server 0.15.2, beyond the Expo app): `Features/Prepare/InfillPattern.swift` offers 12 of Orca's
  26 patterns (the others look the same from above or are special cases; the profile's own pattern is always listed).
  The 3 × 3 cm preview draws one layer in mm with Orca's spacing rule (line length × line width / area = density;
  unit test checks it within 15 %); patterns that turn per layer show the layer below faded. Lightning has no picture
  (it only fills under top surfaces). Real size: ppi by model identifier / `nativeScale` (`ScreenMetrics`), so
  Display Zoom is included; unknown future iPhones assume 460 ppi.

## Possible server problems seen while reading

- None that needed a note. `POST /api/jobs` receives no `file` key when it is `nil` (the Expo app sent `null`); the
  server model treats both the same.
