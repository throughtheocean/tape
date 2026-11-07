# Tape: operations

## Release

1. Bump `MARKETING_VERSION` (what users see, for example 0.11.0) and `CURRENT_PROJECT_VERSION` (a build number, always up by one) in `project.yml`.
2. Commit, then tag: `git tag v<version>`, for example `git tag v0.11.0`.
3. `scripts/release.sh`. It stops when the working tree is not clean (untracked files count too), archives a Release build, exports it with Developer ID, sends a zip to Apple's notary service and waits, staples the ticket to the app, zips it again and checks it with `codesign` and `spctl`.
4. The result is `build/release/Tape-<version>.zip`. `spctl` must print `accepted` and `source=Notarized Developer ID`.

If notarization reports `Invalid`: `xcrun notarytool log <submission id> --keychain-profile tape-notary` says why.

## Install on another Mac

1. Unzip `Tape-<version>.zip`.
2. Drag `Tape.app` to Applications and open it. There is no Gatekeeper warning; the app is notarized and the ticket is stapled, so this also works offline.
3. The first recording (or the first input meter) asks for microphone access. Without it Tape plays and edits but cannot record.

Apple Silicon only. Settings live in the `com.runningoncliffs.tape` defaults domain, untitled documents in `~/Library/Application Support/Tape/Untitled`.

## Certificates

- Release builds sign with **Developer ID Application: Maik Bluhm (PRQ9CL3URA)**, team `PRQ9CL3URA` (in `project.yml` and `ExportOptions.plist`). Hardened runtime on, no sandbox, one entitlement: `com.apple.security.device.audio-input`.
- The certificate with its private key is exported as `.p12` in the password manager. A team can have at most five Developer ID Application certificates, and a lost private key means making a new one; keep the `.p12`.
- Notarization uses the keychain profile `tape-notary` (`xcrun notarytool store-credentials tape-notary --apple-id <apple id> --team-id PRQ9CL3URA`, with an app-specific password from appleid.apple.com). The script uses the profile name only, never the password.
- Debug builds sign ad hoc (`App/Debug.xcconfig`), so they build without any certificate. An untracked `Local.xcconfig` next to `project.yml` can name a real identity instead (`CODE_SIGN_IDENTITY = Apple Development: ...`); with an ad-hoc signature macOS asks for the microphone again after every build.
