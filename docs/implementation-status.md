<!--
ORIX OS Automation
File: docs/implementation-status.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Implementation status — 1.0.0 (1), 2026-11-21

Built and tested on one Mac: macOS 27.0, Apple Silicon, Xcode 27.2. "Verified" below means it was run for real on
that Mac on this date. Anything not listed as verified is not claimed.

## Milestones

| # | Milestone | State |
|---|---|---|
| M0 | Audit, contracts, credential broker, threat model, scripts | Done |
| M1 | App shell, design system, onboarding, settings, Keychain, store, console, permission center | Done; app launched and driven by UI tests |
| M2 | Three providers, agent loop, budgets, cancel, approvals | Done; live smoke tests passed for all three providers |
| M3 | Core macOS tools (77) | Done; integration-tested per family |
| M4 | Workflow engine, Workflow Studio, Code Studio | Done; live gestures in a real window not exercised |
| M5 | Scheduler, background agent, queue, export/import | Engine done and tested with a manual clock; **background agent registration and an unattended scheduled run were not exercised end to end** |
| M6 | Delegation, memory, skills, skill proposal pipeline | Done; the pipeline was run through services and the UI model, **not by a live model proposing a skill** |
| M7 | Watch & Learn, accessibility and performance passes | Recorder and conversion built and unit-tested; **never used on a real recording; no VoiceOver pass** |
| M8 | Regression, security review, docs, signed and notarized release | Done: app and DMG notarized, stapled, accepted by Gatekeeper |

## Tests (2026-11-21)

`Scripts/test/with-dev-keys.sh Scripts/test/test-all.sh` → all 18 packages passed, 789 tests
(`docs/release/test-report.json`). `xcodebuild test` → 2 UI tests passed against the real app.

| Package | Tests | Kind |
|---|---|---|
| ORIXCore | 20 | unit |
| ORIXSecurity | 33 | unit + real Keychain (test-only service) + real audit files |
| ORIXPersistence | 24 | real SQLite, including corruption recovery and two connections |
| ORIXProviderAdapters | 68 | 57 fixture (mocked HTTP) + 11 live (3 providers) |
| ORIXToolRegistry | 115 | 36 unit, 63 integration, 16 security |
| ORIXAppleAutomation | 53 | 21 unit, 32 integration (osascript, AX, ScreenCaptureKit, Vision) |
| ORIXBrowserAutomation | 25 | real WKWebView against a loopback site |
| ORIXScheduler | 71 | cron/DST unit tests, real FSEvents, manual-clock engine |
| ORIXWorkflowEngine | 166 | codec, expressions, validator, engine (mock tools), graph, examples |
| ORIXAgentRuntime | 25 | scripted (mock) provider, real temp files |
| ORIXSkills | 9 | real confined processes |
| ORIXServices | 20 | the 15 examples end to end + headless refusals |
| ORIXAppUI, ORIXFeatureChat/Workflow/Code/Runs/Manage | 160 | view models on real services, render tests, performance measurements |
| App (XCUITest) | 2 | onboarding on first launch, all 11 sections, command palette |

Mocked versus real is stated in each suite name (`Fixture`, `Mock provider`, `Integration`, `Live`).

### Live provider status

| Provider | Model | Result |
|---|---|---|
| Anthropic | `claude-haiku-5-5` | list models, streamed text, tool round trip, tool round trip with thinking: pass |
| OpenAI | `gpt-4o-mini` | list models, streamed text, tool round trip: pass |
| OpenRouter | `openai/gpt-4o-mini` | list models, streamed text, tool round trip, cost reporting: pass |

Only these models were exercised live. Prompt caching, structured outputs, images, rate-limit handling and the retry
wrapper have mocked tests only. Cost of one full live pass: under US$0.02 including the agent examples.

### End-to-end runs verified

- `orixctl agent run` with Anthropic Haiku: read a CSV, wrote a result file, runtime-verified content (3 turns, $0.004), twice.
- 13 of 15 example workflows by real runs (files, PDFs, images, archive and restore, Python in the sandbox, git,
  HTTP on loopback, WebKit data entry, window capture, three with a live agent step).
- Headless run without accepted permissions ends `WAITING_APPROVAL` and changes nothing (3 examples).
- The app: launched (Debug and the notarized Release build), every section opened, real run history and workflows shown.

### Skipped or not verified

- **Calendar example**: Automation consent for Calendar was never given on this Mac; the run was not attempted to avoid triggering the prompt.
- **Notifications**: never seen delivered (tests and `orixctl` have no app bundle; in the app it was not exercised).
- **Background agent**: the launchd plist is bundled and the process starts and exits correctly when the setting is off; `SMAppService` registration and a schedule firing with the app closed were not exercised.
- **Accessibility actions**: `press` verified live; `setValue`, `focus` and successful `typeText` only through refusal paths and dry runs.
- **Watch & Learn**: no real recording session.
- **Intel slice** (built, never run), **macOS 15–26** (never run), **a second Mac or clean user account** (DMG never opened elsewhere).
- **VoiceOver**: labels and identifiers are in place; nobody listened to the app.
- **French**: about 1,800 strings translated; roughly 95 strings flagged by `Scripts/localize.py --missing` remain English (some are false positives); not proofread by a person.
- Cold-launch time and memory footprint were not measured. Measured: canvas frame time with 200 nodes (5–10 ms), editor keystroke latency on 5,000 lines (0.3 ms), console with 50,000 lines (11 ms per 500-line burst).

## Security test outcomes

| Threat scenario | Test | Outcome |
|---|---|---|
| 1 Web page asks to upload secrets | protected-path denial, network-grant and browser navigation-block tests | pass |
| 2 Fake system instructions in a document | untrusted framing, wrapper cannot be closed from inside | pass |
| 3 Skill exceeds its manifest | undeclared write and network denied by the sandbox; analyser blocker | pass |
| 4 Shell injection in tool output | literal argv, inline-interpreter refusal, marker file never created | pass |
| 5 Retrying an irreversible action | repeat of a succeeded tier ≥ 2 call blocked; non-idempotent steps not auto-retried | pass |
| 6 Invented success | status from runtime checks; claimed artifacts inspected | pass |
| 7 Key in console output | redaction of registered and key-shaped strings in results, events, receipts | pass |
| 8 Focus shift before input | re-resolve and frontmost check before each action; unfocused typing refused | pass (refusal paths) |
| 9 Stale permission after restart | expiry/revocation at every call; in-flight side effect → `RECOVERY_REQUIRED` | pass |
| 10 Hostile remote content | cross-host redirects not followed without a new decision (HTTP, browser, downloads) | pass |

Release scan: no credential-shaped string in non-test sources or history, none of the real development keys in the
repository, its history or the bundle, no development credential adapter and no internal host name in the binary.

## Known defects and gaps

| Item | Severity |
|---|---|
| `secret("ref")` in workflow expressions produces a placeholder that no tool resolves; secrets work only through tools with explicit secret arguments (`http.request` secret headers, `browser.fill` secretRef) | Medium |
| Tool output and subprocess output are not persisted: a finished run shows summaries and events, not full output; workflow tool steps do not stream to the live console | Medium |
| Values of workflow `output:` steps are not stored in the receipt | Medium |
| Retry in Runs is hidden for parameterised workflows without a checkpoint (parameters are not on the run record) | Low |
| Skill drafts are kept in memory and lost on quit | Low |
| A workflow run that finishes within milliseconds may not expose step outputs in the Studio | Low |
| Seatbelt cannot filter network by host; the embedded browser does not filter subresources | Documented limit |
| Static analysis of scripts and skills is heuristic | Documented limit |
| Dry runs of two examples (backup, website monitor) end `FAILED` because later steps need files earlier steps would create | Low |
| The chat transcript showed an unexplained vertical gap in one off-screen render; not checked in the running app | Low |

## Not built

- Automatic updates (candidate and reasoning in `docs/release/runbook.md`).
- OpenAI Responses API; server-side tools of any provider.
- Vision-guided clicking (screen capture, OCR and image comparison exist; nothing clicks from pixels).
- Code Studio: debugger for scripts, multi-file projects, source-control view, formatters and validation for script languages.
- Cancelling a queued scheduled item from the UI; "run now" through the scheduler queue.
- Per-app Automation request button (macOS prompts on first use instead).
- Mac App Store build (not targeted; see the environment audit).
- Continuous-integration workflow files.

## Human decisions and approvals outstanding

1. Publishing: the repository has no remote and the DMG has not been uploaded anywhere.
2. Enable the background agent once in the installed app to exercise `SMAppService` and a closed-window scheduled run.
3. Grant Automation for Calendar if the calendar example should be verified.
4. A VoiceOver pass and a French proofreading pass.
5. Whether to add Sparkle (first third-party dependency) for updates.
6. The development keys used for testing are the SP Chat deployment's keys; testing spent a few cents.

## Release

| Item | Value |
|---|---|
| Artifact | `dist/ORIX-OS-Automation-1.0.0.dmg` (18 MB), `dist/ORIX-OS-Automation-1.0.0.zip` |
| Signature | Developer ID Application, team 3YM54G49SN, Hardened Runtime, secure timestamp |
| Architectures | arm64 + x86_64 |
| Entitlements | `com.apple.security.automation.apple-events` only |
| Notarization | app `54cc40eb-6138-45d6-ac41-0254116a7a31` Accepted; DMG `0b78f699-f6b9-437c-b8e6-a495059674e3` Accepted; both stapled |
| Gatekeeper | app and DMG: accepted, source = Notarized Developer ID |
| Evidence | `docs/release/release-1.0.0-1.md` (generated from the tools' output) |
