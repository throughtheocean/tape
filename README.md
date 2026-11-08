# Tape

A macOS audio editor: record, cut and mix audio. Swift, AppKit and SwiftUI, Apple frameworks only. Apple Silicon, macOS 14 or later.

Build for development: `xcodegen generate`, then open `Tape.xcodeproj`, or `xcodebuild -project Tape.xcodeproj -scheme Tape -configuration Debug build`. Tests: `cd TapeCore && swift test`.

## Release

`scripts/release.sh` builds a signed, notarized and stapled release for distribution outside the Mac App Store:

```
scripts/release.sh
```

It builds Release, signs `Tape.app` with Hardened Runtime, sends it to Apple's notary service, staples the ticket, checks it with Gatekeeper (`spctl`), and writes `dist/Tape-<version>.zip` and `dist/Tape-<version>.dmg`. The version comes from `MARKETING_VERSION` in `project.yml`. Every check must pass or the script stops; if notarization fails it prints the notary log. It is safe to rerun.

Prerequisites:

- A **Developer ID Application** certificate with its private key in the login keychain. The script picks it up with `security find-identity -v -p codesigning` and requires exactly one.
- notarytool credentials stored under the keychain profile **notary**: `xcrun notarytool store-credentials notary --apple-id <apple id> --team-id <team id>` with an app-specific password. The script uses only the profile name.
- Xcode command line tools and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- No uncommitted changes to tracked files.

More detail, including installing on another Mac: `docs/betrieb.md`.
