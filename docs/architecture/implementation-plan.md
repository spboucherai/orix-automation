<!--
ORIX OS Automation
File: docs/architecture/implementation-plan.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Implementation plan

Status of each milestone is tracked in `docs/implementation-status.md`; this file is the plan and does not change
when work lands.

## Milestones and gates

| # | Deliverable | Gate (how it is checked) |
|---|---|---|
| M0 | Audit, contracts (`ORIXCore`), credential broker, threat model, build/test scripts | `Scripts/build/test-all.sh` green for Core; security boundaries documented |
| M1 | App shell, design system, onboarding, settings, Keychain, SQLite store, console, permission center | App launches; settings persist across relaunch; Keychain integration tests pass |
| M2 | Three provider adapters, agent loop, budgets, cancel, approval UI | Fixture suites pass; one live smoke per provider; a real tool call through the executor |
| M3 | Filesystem, shell, git, http, documents, python, scripts, AppleScript/JXA, Accessibility, screen, browser | End-to-end tasks with runtime-checked postconditions |
| M4 | Workflow IR + codec + validator + engine, canvas, code editor, debugger, templates | Create → edit visually → edit as code → save → reopen → run, no semantic loss (round-trip tests) |
| M5 | Background agent, scheduler, file watchers, durable queue, export/import | A scheduled workflow runs with the window closed; missed-run policy tested with a manual clock |
| M6 | Delegation, scoped memory, skill packages, skill generation pipeline | An agent proposes a skill; it is analysed, tested confined, approved, installed, run |
| M7 | Watch & Learn recorder → proposed workflow, accessibility and performance passes | A recording becomes a replayable workflow after approval; secure fields never captured |
| M8 | Regression, security review, docs with real screenshots, signed + notarized DMG | `spctl` accepts the stapled artifact; evidence in `docs/release/` |

## Test strategy

- Each package: unit tests + integration tests against the real thing (files, subprocesses, SQLite, WKWebView,
  osascript). Suite names say `Fixture`/`Mock` when a double stands in for a provider.
- Live provider tests run only through the credential broker and print `SKIPPED(...)` without it.
- Tests needing a TCC permission check the real status and print what they skipped; they never prompt.
- Security tests map one-to-one to the ten threat scenarios (`docs/security/threat-model.md`).
- End-to-end: `orixctl` (command-line front end to the same services as the app) drives agent and workflow runs in a
  temp workspace; XCUITest drives the app itself.
- `Scripts/test/test-all.sh` runs every package and writes `docs/release/test-report.json` with counts per package
  and per class (unit / integration / live / skipped).

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| A model is steered by content it reads (prompt injection) | High | High | Tool output framed as data; no capability comes from text; network/file tools gated by grants; consequential tiers need approval; tests per scenario |
| Secret reaches a prompt, log or artifact | Medium | High | Keys only in Keychain; resolved inside the executor; `Redactor` on events, results, receipts; release secret scan |
| `sandbox-exec` removed or changed by Apple | Low now | High | Profile verified by tests on this OS; script tools fail closed if confinement cannot be applied |
| TCC permission missing in the field | Certain | Medium | Non-prompting status checks, guided onboarding, `BLOCKED_PERMISSION` with the exact pane to open |
| Background agent acts with stale authority | Medium | High | Grants carry expiry/revocation; scheduled mode never auto-approves; revoke-all stops and clears |
| GUI automation hits the wrong window | Medium | High | Semantic AX targeting, re-resolve + focus check before every action, exclusive concurrency, emergency stop |
| Provider API drift (models, fields) | High | Medium | Model discovery at runtime; registry dated; adapters tolerate unknown fields; live smoke tests |
| Cost runaway | Medium | Medium | Per-run budgets enforced in the loop from reported usage; unknown prices flagged as incomplete, not guessed |
| Two processes corrupt shared state | Low | High | SQLite WAL + busy timeout, leases, per-run sequence assigned in a transaction, quarantine of a corrupt file |
| Scope: the brief is very large | Certain | Medium | Milestones in order, each usable; status file states what is unverified or missing rather than implying completeness |

## Definition of done

As in the brief (§23). Anything short of it is listed under "Not done" in `docs/implementation-status.md` with the
reason and what it needs.
