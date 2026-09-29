# Porting notes

Decisions and deviations while porting `mobile/` (Expo) to Swift + SwiftUI. Rule used: what `mobile/src` does is right;
if it contradicts `printshare/api.py` the server wins; otherwise the simplest idiomatic SwiftUI solution.

## Where things are

- The native app lives in its own repository (`iDomi94/printshare-ios`), so the project is at the **repository root**,
  not in an `ios-native/` folder. `mobile/` and `printshare/` are not part of this repository and were not touched.
- No pull request against `halvar20000/printshare` was opened: this repository is separate and the run was
  limited to `printshare-ios` (pushing to its `main` was allowed).

## Source snapshot and open ends

- The TypeScript sources were read from the working copy of `iDomi94/printshare` at commit `a2614f0` (server 0.4.0).
  The upstream commit named in the task (`dd2bfe7`, 0.5.0) could not be read from this session. The 0.5.0 additions
  were therefore implemented from the task description, **not** from the code, and their wire format is a guess:
  - **G-code preview** (`Features/Preview`): `GET /api/jobs/{id}/preview`, response
    `{unit, types[], bed[w,h]?, layers[{z, paths[[typeIndex, x0, y0, x1, y1, …]]}]}` (coordinates in 1/`unit` mm, as in
    the task description). Bounds are computed from the paths instead of read from the server; bed defaults to
    256 × 256 mm. Line colours are chosen by Orca feature name (`PreviewColors`) with a fallback palette.
  - **Bed leveling per print**: `Printer.leveling` (present = printer can level; a Bool value is the default), toggle
    remembered per printer in `ps_level_<id>`, sent as `level` in `POST /api/jobs/{id}/send` only when the printer
    supports it.
  - Extra texts for these screens are listed in `scripts/gen_l10n.py` (`EXTRA`).
  Check these three points against `printshare/api.py` and `mobile/src/app/preview/[id].tsx` of 0.5.0 and adjust
  `Models.swift` / `APIClient.swift`.
- Pairing hint on the connect screen uses the container name `PrintShare`
  (`docker exec PrintShare printshare pair --url http://SERVER-IP:8484`), as named in the task; the 0.4.0 source of
  `connect.tsx` still says `printshare`.

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
  active. Shared files are not deleted after the upload (the OS reclaims nothing in the App Group container; add a
  cleanup if it grows).
- **Keychain migration** from `expo-secure-store` (service `app`, keys `ps_*`) is best effort and unverified: the
  layout of expo-secure-store items was assumed. If it does not find anything the user pairs again.
- **Tests**: XCTest. The test target compiles in Swift 5 language mode (mutable URLProtocol test doubles); the app itself is
  Swift 6 with complete strict concurrency.
- **Jobs list** has no swipe-to-delete, because the Expo list does not offer it either.
- **Idle timer**: the screen stays on while a job is slicing/sending (`isIdleTimerDisabled`), reset when leaving the screen.
- **Polling** (jobs, printers) runs in `.task(id:)` blocks that end when the screen disappears or the app leaves the
  foreground.

## Possible server problems seen while reading

- None that needed a note. `POST /api/jobs` receives no `file` key when it is `nil` (the Expo app sent `null`); the
  server model treats both the same.
