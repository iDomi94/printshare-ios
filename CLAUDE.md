# CLAUDE.md – PrintShare iOS (native)

Native Swift 6 + SwiftUI port of the Expo app in `mobile/` of the PrintShare project
(server: https://github.com/halvar20000/printshare, working fork `iDomi94/printshare`). Read `README.md`
(build, test, sign), `PORTING_NOTES.md` (decisions, guesses) and the server docs first.

## Native iOS app (this repository)

State (2026-09-30): all screens and flows of the Expo app are written (Home, Discover, Model detail,
Prepare, Job with review and confirmation, Preview, Jobs, Printers, Settings, Connect/QR), plus the share extension.
Own bundle id `com.dominiqueherbrigpersonalteam.printshare` and App Group `group.com.dominiqueherbrigpersonalteam.printshare`
(Dominique's account, since 2026-09-30; before: the Expo build's `io.github.halvar20000.printshare`), same URL scheme. Caught up with **server 0.36.0** (upstream `a738200`; 0.35-0.36 = Bambu Lab (LAN mode) and an own RTSP / HTTP camera per printer, both only through a bridge; 0.24-0.34 = bridges with sealed printer secrets, printers found on the Wi-Fi, Pi bridge pairing, jobs that follow the print, time-lapse, cloud bookings, send from OrcaSlicer, see PORTING_NOTES; 0.18-0.23 = Orca Cloud share-link import, SpoolmanDB presets for spools, MakerWorld card, Manyfold library, AI failure detection; OpenPrintTag NFC not ported (needs the NFC capability), see PORTING_NOTES; 0.16/0.17 = Spoolman (spool per colour, booking after the print), cloud spools, MakerWorld links, see PORTING_NOTES; 0.15 = PocketPrint3D cloud: e-mail login, account, printers reached by the app itself on the Wi-Fi via SDCP / Moonraker / PrusaLink / OctoPrint (`PrintShare/LAN/`), see PORTING_NOTES; earlier: 509c409 + PR #14, 0.11-0.14 in PORTING_NOTES: slot defaults, power via Home Assistant #9, own quality/material presets #7, visible name **PocketPrint3D**, copies / tilt / size per print):
bed leveling per print (`leveling`), multicolour 3MF projects (`/api/inspect`, `options.filaments`, grams per colour),
preview format 2 (`?format=2`, filament per path, `bounds`, `filament_colors`), G-code sharing (`/api/jobs/<id>/gcode`),
AFC lane choice (`status.lanes`, `send.lanes`, #6; shown as "Slot N", chosen already before slicing, see PORTING_NOTES), camera through the server (live MJPEG / stills, #3), printer control
(`/controls`, `/adjust`, `/temperatures`, #5), own printer profile (`/api/profiles`, `/api/printers/<id>/profile`, #2).
Beyond the Expo app: the sliced plate in 3D (preview switch "Modell / Ganze Platte / 3D", SceneKit ridges per path from preview format 2, `Plate3D.swift`), model files in 3D before slicing (tap "X printable files" on the model page; STL and 3MF via own
readers (3MF: own zip reader + XMLParser, Orca/Bambu/Prusa object colours), OBJ via ModelIO, shown with SceneKit, needs
server 0.10.1 `/api/model-file`, merged upstream), infill pattern per print with a 3 × 3 cm real-size picture of one layer (server 0.15.2, `InfillPattern.swift`), printables.com in a `WKWebView` with the user's own login (Discover → "Printables.com", `PrintablesWebView.swift`: persistent data store, "Mit PocketPrint3D drucken" on `/model/<id>`, site downloads redirected to the model page; no Printables API/OAuth for third parties, see the project's `analysen/printables-konto-favoriten.md`), TestFlight workflow on release tags `vX.Y.Z` (version from the tag, `CHANGELOG.md` section as "What to Test", like iDomi94/Lademonitor-App).
Texts are generated from the 0.36.0 `i18n.ts`. When upstream changes, compare `mobile/` and `printshare/api.py` since
the commit above and port the difference.

**Verified:** CI (macos-latest): builds without errors or warnings in Swift 6 mode, all unit tests green. Unit tests cover URL normalisation,
pairing links, the friendly-error rules and their order, formats, decoding of every endpoint (incl. unknown enum
values, preview format 1 and 2, inspect, colours per job), request shapes (`leveling` only with a print start, preview /
inspect / G-code URLs), the API client's home/away routing with a `URLProtocol` stub (probe picks the faster address,
401 wins, GET repeated on the other address, POST never, timeouts), the shared-inbox cleanup and that every text
exists in DE and EN, lane defaults and warnings, which printer changes need a confirmation, and the bodies of lanes /
adjust / profile requests. Wire formats were checked against the server code (`printshare/api.py`, `gcode_preview.py`,
`model_info.py`, `printers/moonraker.py`); fixture `preview_v2.json` is real output of `gcode_preview.parse`,
`status_cosmos.json` / `status_controls.json` / `controls.json` / `temperatures.json` are real output of the server's
Moonraker adapter (Dominique's recorded COSMOS + AFC and the server tests' fake Moonraker).

**Not verified:** no simulator or device run (the 3D plate view was never seen rendered, nor its performance on a big print), no real server, no share extension on a device, no QR scan, no
TestFlight upload (workflow `testflight.yml` exists, needs the secrets listed in it), no camera stream from a real
printer, no lane choice / printer control / profile upload against a real printer or server, Spoolman (own or cloud), Orca Cloud import, SpoolmanDB, Manyfold, AI failure detection, the booking after a print and MakerWorld links never tried for real, cloud login and the Wi-Fi printer clients (SDCP WebSocket, Moonraker, PrusaLink digest, OctoPrint) never run against the real cloud or a real printer (only the HTTP parts against stubs), Keychain migration: the key layout was checked against the expo-secure-store 57 source, but its test is skipped in the
unsigned CI (no keychain) and it was never run against a real Expo install.

## Rules

- Never start a print without the confirmation dialog (NF-05); never cancel a print without confirmation; never
  repeat a POST/DELETE automatically (only GETs are retried on the other address).
- No third-party packages. English code and comments, user texts German first + English.
- `Localizable.xcstrings` and `L10nKeys.swift` are generated (`scripts/gen_l10n.py`); edit the script, not the output.
- No secrets, tokens, team ids or IP addresses in the repository (`DEVELOPMENT_TEAM` comes from the environment).
- Do not start a print on a real printer while testing.
- Commit trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`.
