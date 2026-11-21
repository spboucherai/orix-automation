<!--
ORIX OS Automation
File: docs/architecture/environment-audit.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Environment audit — 2026-11-21

Everything below was observed with metadata-only commands on the development Mac. No secret value was read into a
terminal, a log or this repository.

## Repository

- No project existed. A new repository was created next to the other ORIX applications of the owner
  (`…/apple/ORIXAutomation`), following their conventions: XcodeGen `project.yml` (the `.xcodeproj` is generated, not
  committed), Swift packages under `Packages/`, release scripts under `Scripts/`, file headers, `dist/` + `build/` ignored.
- A parent folder carries an unrelated `CLAUDE.md` (another product). It is ignored, apart from the shared header convention.
- Git: local repository, branch `main`, no remote yet. Publishing to a remote is a decision left to the owner.

## Toolchain

| Item | Value |
|---|---|
| macOS | 27.0 (build 26A5425a), Apple Silicon (arm64) |
| Xcode | 27.2 (27B52), macOS SDK 27.2 |
| Swift | 6.4.2, language mode 6, strict concurrency |
| Tools present | `xcodegen`, `create-dmg`, `python3` (Homebrew), `node`, `/usr/bin/sandbox-exec`, JavaScriptCore `jsc` helper |
| Deployment target chosen | macOS 15.0 (same as the sibling apps); built and tested on 27.0 only |

## Signing and notarization (metadata only)

- `security find-identity -v -p codesigning`: one **Developer ID Application** identity (team `3YM54G49SN`) and two
  Apple Development identities. Hashes are not recorded here.
- `xcrun notarytool history --keychain-profile MacLustr-Notarize`: the existing keychain profile answers and lists
  accepted submissions from earlier today for sibling apps. It is reused as is; no credential was created, replaced,
  printed or exported.
- Sibling release scripts (`sign.sh`, `notarize.sh`, `package.sh`) were read and their approach is reused: Xcode signs
  the Release build with the Developer ID identity and Hardened Runtime, `notarytool submit --wait`, staple, `spctl`.

## Distribution assessment

| Channel | Verdict |
|---|---|
| Direct distribution (Developer ID + notarization) | **Chosen.** Required for Apple Events to arbitrary apps, Accessibility control, child processes, Seatbelt confinement of scripts and a user LaunchAgent. |
| Mac App Store | **Not targeted.** The App Sandbox forbids most of what the product does (unrestricted Apple Events, Accessibility control of other apps, spawning arbitrary tools, reading user-chosen folders from a background agent without bookmarks per file). No claim of App Store compliance is made. |

The app is therefore **not sandboxed**. It runs with the Hardened Runtime and one entitlement,
`com.apple.security.automation.apple-events` (needed to send Apple Events under the Hardened Runtime). Its own
permission model (policy engine, grants, Seatbelt confinement of subprocesses) is what bounds the agent; macOS TCC
bounds the app.

## macOS privacy permissions (TCC)

None can be granted programmatically, and the app never tries. Each is requested through the standard system flow
when a feature first needs it, and its absence is reported as `BLOCKED_PERMISSION`:

| Permission | Used by | How it is obtained |
|---|---|---|
| Automation (Apple Events), per target app | `applescript.*`, `jxa.*` | System prompt on first event to each app |
| Accessibility | `accessibility.*`, Watch & Learn | User enables the app in System Settings |
| Screen Recording | `screen.capture`, window titles | System prompt, then System Settings |
| Notifications | approvals, run summaries | System prompt |
| Files and Folders / Full Disk Access | reading protected folders | System prompt per folder; Full Disk Access is never required |

Status during development: the test processes (`swift test` under the terminal) and the app have whatever the
terminal/app was granted on this Mac; each test suite prints which permission it had and what it skipped.

## Development provider credentials (SP Chat)

- Located through the owner's deployment tooling: the SP Chat deployment is a Node service on a cluster node, with
  provider keys injected as process environment variables from a deployment manifest. Variable **names** observed:
  `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY` (plus others not used here). Values were only ever
  displayed as lengths.
- The operator keeps a copy of that environment in a secrets file outside any repository on this Mac.
- **Strategy:** `Scripts/test/with-dev-keys.sh` is a broker: it reads the three values from that file and places them
  in the environment of one child process (`ORIX_DEV_*_API_KEY`). Nothing is copied into this repository, a `.env`
  file, the Keychain, the app bundle, a fixture or a log. `--check` reports presence by length only (all three present).
- The only code that reads those variables is `DevEnvironmentCredentials`, compiled under `#if DEBUG` and absent from
  Release builds. The shipped app is BYOK: keys typed by the user, stored in the login Keychain.
- **Authorization and cost:** the product owner's brief designates these keys as the development test configuration.
  Live tests are smoke tests on the cheapest models with hard token caps; the whole live suite is budgeted well under
  US$0.05 per run. Results are recorded in `docs/release/live-provider-smoke.md`.

## Constraints noted

- The system language is French: scripts force `LC_ALL=C` when parsing tool output; UI tests pass
  `-AppleLanguages "(en)"` for English screenshots.
- Other sessions may use the screen: GUI automation tests are gated on real permission status and never prompt.
