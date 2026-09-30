# CLAUDE.md – PrintShare iOS (native)

Native Swift 6 + SwiftUI port of the Expo app in `mobile/` of the PrintShare project
(server: https://github.com/halvar20000/printshare, working fork `iDomi94/printshare`). Read `README.md`
(build, test, sign), `PORTING_NOTES.md` (decisions, guesses) and the server docs first.

## Native iOS app (this repository)

State (2026-09-30): all screens and flows of the Expo app are written (Home, Discover, Model detail,
Prepare, Job with review and confirmation, Preview, Jobs, Printers, Settings, Connect/QR), plus the share extension.
Same bundle id / App Group / URL scheme as the Expo build. Caught up with **server 0.6.0** (upstream `507fff4`):
bed leveling per print (`leveling`), multicolour 3MF projects (`/api/inspect`, `options.filaments`, grams per colour),
preview format 2 (`?format=2`, filament per path, `bounds`, `filament_colors`), G-code sharing (`/api/jobs/<id>/gcode`).
Beyond the Expo app: camera picture inside the app (MJPEG, issue #3), model files in 3D before slicing (tap "X printable
files" on the model page; STL via own reader, OBJ via ModelIO, shown with SceneKit, needs server 0.8.1 `/api/model-file`), manual TestFlight workflow.
Texts are generated from the 0.6.0 `i18n.ts`.

**Verified:** CI (macos-latest): builds without errors or warnings in Swift 6 mode, all unit tests green. Unit tests cover URL normalisation,
pairing links, the friendly-error rules and their order, formats, decoding of every endpoint (incl. unknown enum
values, preview format 1 and 2, inspect, colours per job), request shapes (`leveling` only with a print start, preview /
inspect / G-code URLs), the API client's home/away routing with a `URLProtocol` stub (probe picks the faster address,
401 wins, GET repeated on the other address, POST never, timeouts), the shared-inbox cleanup and that every text
exists in DE and EN. Wire formats were checked against the 0.6.0 server code (`printshare/api.py`, `gcode_preview.py`,
`model_info.py`); fixtures `preview_v2.json` is real output of `gcode_preview.parse`.

**Not verified:** no simulator or device run, no real server, no share extension on a device, no QR scan, no
TestFlight upload (workflow `testflight.yml` exists, needs the secrets listed in it), no camera stream from a real
printer, Keychain migration: the key layout was checked against the expo-secure-store 57 source, but its test is skipped in the
unsigned CI (no keychain) and it was never run against a real Expo install.

## Rules

- Never start a print without the confirmation dialog (NF-05); never cancel a print without confirmation; never
  repeat a POST/DELETE automatically (only GETs are retried on the other address).
- No third-party packages. English code and comments, user texts German first + English.
- `Localizable.xcstrings` and `L10nKeys.swift` are generated (`scripts/gen_l10n.py`); edit the script, not the output.
- No secrets, tokens, team ids or IP addresses in the repository (`DEVELOPMENT_TEAM` comes from the environment).
- Do not start a print on a real printer while testing.
- Commit trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`.
