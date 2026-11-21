<!--
ORIX OS Automation
File: docs/release/runbook.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Release and notarization runbook

Distribution is direct (Developer ID + notarization). The app is not sandboxed; it uses the Hardened Runtime and
one entitlement, `com.apple.security.automation.apple-events`.

## Prerequisites on the build Mac

- Xcode with the macOS SDK, `xcodegen`, `create-dmg`.
- A **Developer ID Application** identity in the login keychain (`security find-identity -v -p codesigning`).
- A notarytool keychain profile. The scripts use `NOTARY_PROFILE` (default `MacLustr-Notarize`) and never create,
  print or modify credentials. Check it answers: `xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"`.

## Steps

```bash
# 1. Version: edit MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml, update CHANGELOG.md
# 2. Everything in one command:
Scripts/release/release.sh
```

`release.sh` stops at the first failure and does, in order:

1. `Scripts/test/test-all.sh` — every package; writes `docs/release/test-report.json`.
   (Run it under `Scripts/test/with-dev-keys.sh` beforehand to include the live provider suites.)
2. `Scripts/check-headers.sh`.
3. `Scripts/build/build.sh release` — XcodeGen, Release build (arm64 + x86_64), Developer ID signing with a secure
   timestamp, into `dist/ORIX OS Automation.app`.
4. `Scripts/release/secret-scan.sh "dist/ORIX OS Automation.app"` — fails on credential-shaped strings in the
   repository, its history or the bundle; on the development credential adapter being present in the binary; on
   internal host names.
5. `Scripts/release/sign.sh` — verifies identity, Hardened Runtime, timestamp, bundle identifier, deep signature,
   and that no debug entitlement is present.
6. `Scripts/release/notarize.sh <app> app` — `notarytool submit --wait`; on `Accepted`, staples. Anything else
   stops the release and leaves Apple's log in `build/notary/app-log.json`.
7. `Scripts/release/package.sh all` — ZIP and a signed DMG.
8. `Scripts/release/notarize.sh <dmg> dmg` — notarizes and staples the disk image.
9. Checksums, `spctl` assessment of the app and the DMG.
10. Writes `docs/release/release-<version>-<build>.md` from the tools' own output (signature, architectures,
    entitlements, submission ids and statuses, staple validation, Gatekeeper verdicts, SHA-256).

"Notarized" is only ever printed after Apple answered `Accepted`.

## After the build

- Open the DMG on another Mac or another user account: drag to Applications, launch, go through the welcome
  guide, confirm the Keychain item is created on key entry, enable and disable the background agent, quit.
- Publish the DMG, the ZIP, `SHA256SUMS.txt` and the release notes together.

## If notarization is rejected

Read `build/notary/<name>-log.json`. Usual causes: an unsigned or ad-hoc-signed nested binary, a missing secure
timestamp, the Hardened Runtime disabled on a helper, a debug entitlement (`get-task-allow`). Fix the cause and
run the release again; never disable the Hardened Runtime or strip the signature check to get through.

## Updates

This version has no automatic updater. Sparkle 2 (EdDSA-signed appcasts, the installer running as an XPC
service) is the candidate; it would be the first third-party dependency and needs its own review before it is
added. Until then, updates are installed by replacing the app from a new notarized DMG.
