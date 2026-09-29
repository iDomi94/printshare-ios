# CLAUDE.md – PrintShare iOS (native)

Native Swift 6 + SwiftUI port of the Expo app in `mobile/` of the PrintShare project
(server: https://github.com/halvar20000/printshare, working fork `iDomi94/printshare`). Read `README.md`
(build, test, sign), `PORTING_NOTES.md` (decisions, guesses) and the server docs first.

## Native iOS app (this repository)

State (2026-09-29): all screens and flows of the Expo app 0.1.0 are written (Home, Discover, Model detail,
Prepare, Job with review and confirmation, Preview, Jobs, Printers, Settings, Connect/QR), plus the share extension.
Same bundle id / App Group / URL scheme as the Expo build.

**Verified:** only what CI reports (see the workflow runs of this repository). Unit tests cover URL normalisation,
pairing links, the friendly-error rules and their order, formats, decoding of every endpoint (incl. unknown enum
values), the API client's home/away routing with a `URLProtocol` stub (probe picks the faster address, 401 wins,
GET repeated on the other address, POST never, timeouts) and that every text exists in DE and EN.

**Not verified:** no simulator or device run, no real server, no share extension on a device, no QR scan, no
TestFlight upload, no Keychain migration from the Expo build. The preview and bed-leveling wire formats were
implemented from a description, not from the 0.5.0 server code – check them first (see PORTING_NOTES.md).

## Rules

- Never start a print without the confirmation dialog (NF-05); never cancel a print without confirmation; never
  repeat a POST/DELETE automatically (only GETs are retried on the other address).
- No third-party packages. English code and comments, user texts German first + English.
- `Localizable.xcstrings` and `L10nKeys.swift` are generated (`scripts/gen_l10n.py`); edit the script, not the output.
- No secrets, tokens, team ids or IP addresses in the repository (`DEVELOPMENT_TEAM` comes from the environment).
- Do not start a print on a real printer while testing.
- Commit trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`.
