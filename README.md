# PrintShare for iOS (native)

Native **Swift 6 + SwiftUI** port of the Expo/React Native app in `mobile/` of
[halvar20000/printshare](https://github.com/halvar20000/printshare). Same features, same server API
(`printshare/api.py`), same bundle id (`io.github.halvar20000.printshare`), so it can replace the Expo build in
TestFlight / the App Store. Android keeps being built from `mobile/` of the main repository.

PrintShare is a self-hosted "Bambu Handy for everyone else": send a Printables/Thingiverse link from the phone, the
server slices it with OrcaSlicer and uploads the G-code to the printer. This app is the phone side.

- iOS 17+, iPhone and iPad, German and English (language can be switched in the app)
- No third-party packages, only Apple frameworks
- Share extension (links, text, files), QR pairing, home / away server address, 2D G-code preview (by line type or
  filament), multicolour 3MF projects (material per colour), G-code sharing, lane choice for AFC / CANVAS,
  printer camera, printer control (temperatures with history, fans, light, speed), own OrcaSlicer printer profile,
  model files in 3D
- Made for PrintShare server 0.10 (0.10.1 for the 3D view); older servers still work, newer features then say the
  server is too old

See [PORTING_NOTES.md](PORTING_NOTES.md) for decisions and deviations from the Expo app and [CLAUDE.md](CLAUDE.md)
for the state of the port (what is verified, what is not).

## Requirements

- macOS with Xcode 16 or newer (Swift 6) and the current iOS SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The Xcode project is generated from `project.yml` and not committed.

```bash
xcodegen generate
open PrintShare.xcodeproj
```

## Build and test

```bash
xcodegen generate
xcodebuild -project PrintShare.xcodeproj -scheme PrintShare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO build test
```

CI (`.github/workflows/ios.yml`) does the same on every push.

## Run against a server

```bash
# on the server (or your Mac): PrintShare with the fake printers from tests/fakes.py, or a real printer
printshare serve

# pair the simulator with a deep link
xcrun simctl openurl booted "printshare://connect?url=http://localhost:8484&token=YOUR_TOKEN"
```

On a real server the pairing QR code is shown by `docker exec PrintShare printshare pair --url http://SERVER-IP:8484`.

## Signing and TestFlight

The team id is never stored in the repository. Export it before generating and building:

```bash
export DEVELOPMENT_TEAM=ABCDE12345          # your Apple developer team id
xcodegen generate

xcodebuild -project PrintShare.xcodeproj -scheme PrintShare -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/PrintShare.xcarchive \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive -archivePath build/PrintShare.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
```

`ExportOptions.plist` (create it next to `project.yml`, it contains your team id, so it is not committed):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>ABCDE12345</string>
  <key>destination</key><string>upload</string>
</dict>
</plist>
```

With `destination` = `upload` the export uploads the build to App Store Connect / TestFlight directly. The bundle ids
`io.github.halvar20000.printshare` and `io.github.halvar20000.printshare.share-extension` and the App Group
`group.io.github.halvar20000.printshare` must exist in the developer account (automatic signing creates them).
`CURRENT_PROJECT_VERSION` starts at 100, above the EAS build numbers of the Expo app; raise it for every upload.

### TestFlight from GitHub Actions

`.github/workflows/testflight.yml` (Actions -> TestFlight -> Run workflow) archives and uploads without a Mac. It
needs the repository secrets `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (an App Store Connect API
key with the App Manager or Admin role, used for cloud signing). The build number is `100 + run number`.

## Layout

```
project.yml                XcodeGen spec (targets PrintShare, ShareExtension, PrintShareTests)
PrintShare/App             app entry, AppModel (state, navigation), deep links
PrintShare/API             models, API client (home/away routing), friendly errors
PrintShare/Storage         Keychain, per-printer prefs, shared inbox (App Group)
PrintShare/Pairing         pairing link parser, QR scanner
PrintShare/Util            texts (L10n), formats, theme, haptics
PrintShare/UI/Components   Card, Row, Badge, Banner, Section, Stat, Segmented, Empty, ...
PrintShare/Features        Home, Discover, ModelDetail, Prepare, Job, Preview, Jobs, Printers, Settings, Connect
PrintShare/Resources       asset catalog, Localizable.xcstrings, InfoPlist.xcstrings
ShareExtension             share sheet target
PrintShareTests            unit tests and JSON fixtures
scripts/gen_l10n.py        regenerates Localizable.xcstrings + L10nKeys.swift from the Expo app's i18n.ts
```

## Texts

`Localizable.xcstrings` and `PrintShare/Util/L10nKeys.swift` are generated from `mobile/src/lib/i18n.ts` (plus the few
keys only the native app has, listed in `scripts/gen_l10n.py`):

```bash
python3 scripts/gen_l10n.py path/to/printshare/mobile/src/lib/i18n.ts
```
