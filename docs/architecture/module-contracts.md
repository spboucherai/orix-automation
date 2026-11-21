<!--
ORIX OS Automation
File: docs/architecture/module-contracts.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Module contracts

Binding for everyone writing a package in this repository. The product brief is `CLAUDE.md` at the repository root
(read §5–§9, §13, §16, §17, §19 for the package you own). `~/Desktop/Cluster/apple/CLAUDE.md` (KHAELOR) is an unrelated
project that happens to sit in a parent folder: **ignore it**, except that this repository uses the same file-header convention.

## Ground rules

- Swift 6 language mode, strict concurrency, macOS 15+, **no third-party dependency**. System frameworks only.
- Every source file starts with the header (see any file in `Packages/ORIXCore`): product name `ORIX OS Automation`,
  `File:` (path from repo root), `Description:`, `Author: Simon-Pierre Boucher`, `Contact: contact@spboucher.ai`.
- One Swift package per module under `Packages/<Name>/` (own `Package.swift`, `Sources/`, `Tests/`), depending on
  `../ORIXCore` by path and on nothing else unless listed below. `swift-tools-version: 6.0`, `swiftLanguageModes: [.v6]`.
- **`Packages/ORIXCore` is frozen.** Read all of `Packages/ORIXCore/Sources/ORIXCore/*.swift` first; conform to those
  protocols and reuse those types. If a contract is genuinely missing, do not edit Core: add what you need in your own
  package and list it under "Contract requests" in your final report.
- Real behaviour only. No stub that returns canned success, no `TODO` body. What cannot work on this Mac returns a typed,
  honest error (`ToolError.unsupported`, `.tccBlocked`, …). Never fake a result.
- Tests use Swift Testing (`import Testing`). Unit tests plus **real integration tests** (real files in a
  `TempDirectory`, real subprocesses, real SQLite, real WKWebView…). Name suites so mocked vs integration is obvious.
  Tests must not need user interaction and must not touch anything outside temp directories. A test that needs a macOS
  privacy permission must detect its absence and record the skip reason with `withKnownIssue`/early return + a printed
  `SKIPPED(<reason>)` line — never pass vacuously in silence.
- Never run `pkill -f` or kill processes you did not start. Never print, log or write secrets. Never `git commit`
  (the lead commits). Stay inside your package directory (plus the files explicitly assigned to you).
- Build and test with `swift build` / `swift test` **inside your package directory** until both are clean (zero
  warnings in your code is the goal). Your final report must give: public API summary (types + signatures the app
  will call), test counts (unit / integration / skipped with reasons), known limitations, contract requests.
- This Mac's system language is French: use `LC_ALL=C` when parsing tool output; do not rely on localized strings.

## Packages and owners

| Package | Depends on | Content |
|---|---|---|
| `ORIXCore` (frozen) | — | contracts, JSON, schema, redaction, path resolution, `ORIXTestingSupport` |
| `ORIXSecurity` | Core | `PolicyEngine`, `KeychainStore`, `AuditLog` |
| `ORIXPersistence` | Core | SQLite `ORIXStore` |
| `ORIXProviderAdapters` | Core | Anthropic, OpenAI, OpenRouter clients |
| `ORIXToolRegistry` | Core | registry, `ToolExecutor`, `ProcessRunner`, filesystem/shell/git/http/documents/python/script/system-info tools |
| `ORIXAppleAutomation` | Core | AppleScript/JXA, Accessibility, screen, app control, clipboard, notifications tools + permission status |
| `ORIXBrowserAutomation` | Core | WKWebView browser tools |
| `ORIXScheduler` | Core | cron/DST math, triggers, file watchers, durable queue engine |
| `ORIXWorkflowEngine` | Core | workflow IR, YAML/JSON codec, validator, executor, graph projection |
| `ORIXAgentRuntime` | Core | agent loop (lead) |

## Tool rules (every tool package)

- A tool is a `struct`/`final class` conforming to `ORIXTool`. `requirements(for:context:)` is pure: it validates
  semantics, canonicalises every path with `PathResolver.canonical(_:relativeTo: context.workingDirectory)` and returns
  the exact `Capability` list + tier + a one-sentence human summary built from the arguments. `execute` then acts **only
  on those canonical paths / hosts / bundle ids**.
- Tools never check policy and never ask for approval: `ToolExecutor` does, before `execute`. Tools never read
  `Redactor` either; the executor redacts.
- Tier guide: reading = 0; creating/modifying files in place, moving to Trash, clipboard write, notifications = 1;
  network sends, running scripts/arbitrary processes, app control/automation, GUI input, git commit to a repo = 2
  (git commit is 1), git push = 2 with `.externalSend(channel: "git-push")`; permanent deletion, force push, anything
  privileged = 3. `sudo`, `rm -rf /`-class commands, writing protected paths: unsupported, refused in `requirements`.
- Tools honour `Task` cancellation and `context.timeoutSeconds`; subprocesses go through `ProcessRunner` only.
- Output is a JSON object matching `manifest.outputSchema`; large text is truncated with `String.truncated(maxBytes:)`
  and `ToolResult.truncated = true`. Set `outputIsUntrusted`/`untrusted` for content read from files, web, apps, processes.
- Dry run (`input.dryRun`) when `supportsDryRun`: return `ToolResult.simulated` describing exactly what would change.
- Each package exposes `public enum <Package>Tools { public static func all(...) -> [any ORIXTool] }`.

### Canonical tool identifiers (do not rename)

- `filesystem.` `list search read write mkdir copy move metadata checksum compare trash delete archive unarchive waitForChange`
- `shell.` `run` (argv array, no shell) · `script` (bash text, tier 2)
- `git.` `status diff log branches commit createPatch push`
- `http.` `request`
- `documents.` `csvRead csvWrite jsonQuery pdfText pdfInfo renderPDF imageInfo imageConvert xlsxRead textStats`
- `python.` `run envInfo` · `script.` `swift javascript`
- `system.` `info processes diskUsage powerState networkState` (ToolRegistry) · `apps frontmost windows launchApp quitApp` (AppleAutomation)
- `clipboard.` `read write` · `notifications.` `post`
- `applescript.` `run dictionary` · `jxa.` `run`
- `accessibility.` `status tree find press setValue focus typeText waitFor`
- `screen.` `capture ocr compare`
- `browser.` `open read fill click waitFor screenshot download close`

Argument naming: `path`, `source`, `destination`, `paths`, `content`, `pattern`, `recursive`, `overwrite`, `url`,
`bundleID`, `selector`, `script`, `args`, `cwd`, `timeoutSeconds`, `maxBytes`. camelCase everywhere.

## ToolExecutor pipeline (ORIXToolRegistry)

`invoke(call, context)` never throws and always returns a `ToolResult` with `durationMs`:

1. Look up the tool (unknown → `failed/not_found`).
2. Validate `call.arguments` against `manifest.inputSchema` (→ `invalidInput`, nothing runs).
3. `tool.requirements(...)`; any capability path with `PathResolver.isProtected` → `denied` + audit `policyViolation`.
4. Capabilities under `context.artifactsDirectory` are implicitly granted; build an `AccessRequest` (arguments preview
   redacted with `manifest.redactedInputKeys`) for the rest and call `policy.evaluate`.
5. `.deny` → `denied`. `.needsApproval` → emit `approvalRequested`, call the `ApprovalBroker`; `.unanswered`/`.deny` →
   `notApproved` (failure code `not_approved`); approval → `policy.recordApproval`.
6. Idempotency: if `call.idempotencyKey` was already executed successfully in this run, return the stored result
   without executing again. Non-idempotent tools are never auto-retried by the executor.
7. Concurrency gate per `manifest.concurrency`; execute with `min(manifest.defaultTimeoutSeconds, context.maxToolSeconds)`
   (or the call's own `timeoutSeconds` argument when smaller); timeout → cancel task, `timedOut`.
8. Convert thrown `ToolError` to its `ToolResult`; validate success output against `outputSchema` (violation →
   `failed/output_invalid`); redact output and summary with `Redactor`; truncate to `maxOutputBytes`.
9. `policy.consume`, audit (`toolExecuted`/`toolFailed`/`toolDenied`), emit `toolRequested`/`toolFinished` run events
   (`data`: `callID`, `toolID`, `arguments` (redacted), `status`, `tier`, `durationMs`, `summary`).

Emergency stop: `ToolExecutor.cancelAll()` cancels every in-flight call and `ProcessRunner.killAll()` terminates every
child process group.

## ProcessRunner (ORIXToolRegistry)

`posix_spawn`/`Process` with: explicit argv (no shell), explicit environment (minimal allowlist: `PATH`, `HOME`,
`LANG`, `TMPDIR` + caller-supplied), explicit cwd, new process group, timeout, SIGTERM then SIGKILL of the whole
group on timeout/cancel, bounded stdout/stderr capture with streaming callback, exit code. Optional **Seatbelt
confinement** through `/usr/bin/sandbox-exec -p <profile>` generated from a `Confinement`: deny by default file
writes outside `writeRoots` (+ the process temp dir), deny network unless `allowsNetwork`, always deny reads of the
protected locations in `PathResolver.isProtected`. Confinement is ON for `shell.script`, `python.run`,
`script.swift`, `script.javascript` and skills; `shell.run`/`git.*` use it too unless the executable needs otherwise.
