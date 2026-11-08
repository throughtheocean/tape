# Tape: operations

## Release

1. Bump `MARKETING_VERSION` (what users see, for example 0.11.0) and `CURRENT_PROJECT_VERSION` (a build number, always up by one) in `project.yml`.
2. Commit, then tag: `git tag v<version>`, for example `git tag v0.11.0`.
3. `scripts/release.sh`. It stops on uncommitted changes to tracked files, builds Release, copies `Tape.app` to `dist/`, signs it with the Developer ID identity it finds in the keychain (Hardened Runtime, secure timestamp, the app's entitlements), checks the signature, sends a zip to Apple's notary service and waits, staples the ticket, checks it with `spctl`, zips the stapled app, then builds a DMG and signs, notarizes, staples and checks that too. It is safe to run again; it replaces the files of the same version in `dist/`.
4. The results are `dist/Tape-<version>.zip` and `dist/Tape-<version>.dmg`. `spctl` must print `accepted` and `source=Notarized Developer ID`; the script stops otherwise. `dist/` is not committed.

If notarization does not say `Accepted`, the script prints the notary log and stops. By hand: `xcrun notarytool log <submission id> --keychain-profile notary`.

## Install on another Mac

1. Unzip `Tape-<version>.zip`, or open `Tape-<version>.dmg`.
2. Drag `Tape.app` to Applications and open it. There is no Gatekeeper warning; the app is notarized and the ticket is stapled, so this also works offline.
3. The first recording (or the first input meter) asks for microphone access. Without it Tape plays and edits but cannot record.

Apple Silicon only. Settings live in the `com.runningoncliffs.tape` defaults domain, untitled documents in `~/Library/Application Support/Tape/Untitled`.

## Certificates

- Release builds sign with **Developer ID Application: Maik Bluhm (PRQ9CL3URA)**, team `PRQ9CL3URA` (in `project.yml`; the script reads the identity from the keychain). Hardened runtime on, no sandbox, one entitlement: `com.apple.security.device.audio-input`.
- The certificate with its private key is exported as `.p12` in the password manager. A team can have at most five Developer ID Application certificates, and a lost private key means making a new one; keep the `.p12`.
- Notarization uses the keychain profile `notary` (`xcrun notarytool store-credentials notary --apple-id <apple id> --team-id PRQ9CL3URA`, with an app-specific password from appleid.apple.com). The script uses the profile name only, never the password.
- Debug builds sign ad hoc (`App/Debug.xcconfig`), so they build without any certificate. An untracked `Local.xcconfig` next to `project.yml` can name a real identity instead (`CODE_SIGN_IDENTITY = Apple Development: ...`); with an ad-hoc signature macOS asks for the microphone again after every build.
