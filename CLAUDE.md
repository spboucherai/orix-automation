# ORIX OS AUTOMATION — CLAUDE.md

> **Mission:** Build the most capable, trustworthy, elegant native macOS agentic automation studio possible. This is a production engineering mandate, not a mockup, proof of concept, or collection of disconnected demos.
>
> **Product:** ORIX OS Automation
> **Platforms:** macOS, native Swift and SwiftUI, with native helper processes as needed.
> **Operating principle:** The user states an objective; ORIX plans, asks for necessary permissions, executes real tools, observes results, recovers from errors, and produces verifiable outcomes.
> **Language:** User-facing app should support English and French; engineering documentation and code may use English.

---

## 0. NON-NEGOTIABLE EXECUTION DIRECTIVE

You are Claude Code, acting as principal macOS engineer, agent systems architect, security engineer, product designer, QA lead, and release engineer. Implement this product in the actual repository and on the actual development Mac. Do not merely write a plan. First inspect the environment, then execute in measured, testable increments. Never claim something works unless it has been tested. Never fake agent runs, successful tool calls, screenshots, permissions, or notarization.

Do not erase or replace an existing product without explicit authorization. Inspect the current repository and preserve useful conventions. If no project exists, create a clean, production-grade native Xcode project. Track assumptions, decisions, known limitations, tests, and follow-up work. When blocked by Apple permissions, credentials, user consent, or unavailable external services, report the precise blocker and proceed with independently testable parts.

### Critical instructions from product owner

1. **Development API credentials:** Existing Anthropic/Claude, OpenAI, and OpenRouter API configuration used for testing is associated with the deployment of the existing **SP Chat** application. Locate the SP Chat deployment and inspect its *configuration structure and authorized secret references* before inventing any new test setup. The existence of usable keys must be verified, not assumed. Never dump, print, commit, log, embed in screenshots, or ship these secrets. Do not copy them into source files, .env files in the repo, app bundles, test fixtures, or release artifacts. Prefer a scoped local test credential broker, environment injection by the existing deployment, or securely provisioned developer Keychain items. Do not use a production credential without confirming that development testing is authorized. Limit tests to low-cost, controlled requests. The production ORIX application is **BYOK**: each user enters their own provider keys, which are stored in their local Keychain.
2. **Apple signing and notarization:** Existing developer signing/notarization configuration is **on the development Mac**. Discover the available signing identities, Xcode team settings, existing keychain-backed notary profiles, and release scripts using metadata-only commands. Reuse authorized configuration where possible. Never reveal or export private keys, passwords, App Store Connect credentials, API key contents, or sensitive profile data. Do not create or replace credentials unnecessarily. Verify signing and notarization with Apple tools and save non-sensitive receipts. If signing or notarization cannot proceed, state exactly what human approval or missing capability is needed.
3. Build real native macOS software, not an Electron wrapper or web page dressed as a Mac application.
4. Make the interface visually exceptional, responsive, accessible, and consistent with macOS conventions.
5. Preserve a strict separation between agent reasoning, tool permissions, execution, audit logging, and UI.
6. Make the agent genuinely flexible: it may compose tools and write scripts, but every capability must remain inside explicit user-granted authority and enforceable runtime controls.
7. Never bypass macOS privacy protections, TCC consent, code-signing restrictions, app sandbox restrictions, or system security controls.

---

## 1. PRODUCT VISION

ORIX OS Automation is an agentic operating layer for the Mac. It unifies conversational automation, visual workflows, editable code, system tools, browser interaction, scheduling, and autonomous recovery.

A user should be able to request:

- “Every morning, summarize the PDFs added to this folder and generate a report.”
- “Open my spreadsheet, analyze the data using Python, create charts, and export a PDF.”
- “Monitor my Git repository, run tests when a branch changes, and prepare a patch for review.”
- “Organize my Downloads folder without deleting anything, and show me what changed.”
- “Prepare a weekly briefing from permitted local files and selected websites.”
- “Observe me completing this repetitive task and propose a reusable workflow.”
- “Create a new tool for this application if an existing integration is unavailable.”

The user can operate the same automation through three synchronized views:

1. **Agent:** natural-language chat and execution timeline.
2. **Visual:** node-and-edge workflow editor with live status.
3. **Code:** editable declarative workflow plus individual script/tool source.

These are representations of a common validated workflow model, not separate incompatible implementations. Round-tripping should preserve semantics; warn when an advanced feature cannot be represented losslessly in a simpler view.

### Product principles

- Real execution over theatrical simulation.
- Powerful defaults, transparent boundaries.
- Human control for consequential actions.
- Native quality over cross-platform compromises.
- Verifiable outcomes over plausible-sounding summaries.
- Minimal friction without sacrificing security.
- Recoverability and reproducibility by design.
- Local-first data, cloud model inference only when selected.
- No mandatory ORIX account or hosted ORIX backend.
- Users own their workflows, history, and keys.

---

## 2. FIRST ACTION: DISCOVERY AND ENVIRONMENT AUDIT

Before writing product code:

1. Identify repository root, branch, remotes, status, project files, existing architecture, license, README, build scripts, and tests.
2. Identify macOS version, CPU architecture, Xcode version, Swift toolchain, available SDKs, deployment target constraints, and Apple Developer signing identities.
3. Find the SP Chat repository/deployment through known workspace paths, local service definitions, documented deployment manifests, or authorized administration tooling. Inspect only necessary metadata and configuration references. Do not conduct broad filesystem or Keychain secret scraping.
4. Determine how to obtain scoped test access to Anthropic, OpenAI, and OpenRouter without moving secrets into ORIX source control. Confirm allowed provider use and any cost limits.
5. Inspect existing local signing/notarization setup using `security find-identity -v -p codesigning`, `xcrun notarytool history` where authorized, Xcode build settings, and existing named keychain profiles. Avoid commands that reveal secrets. Do not modify unrelated projects.
6. Assess whether a direct-distribution notarized build, Mac App Store build, or both are feasible. Default to a direct-distribution build because deep automation may conflict with App Store sandbox requirements. Document tradeoffs instead of promising App Store approval.
7. Identify available macOS Automation, Accessibility, Screen Recording, Files and Folders, Full Disk Access, Apple Events, and browser automation permissions. Ask for user consent through standard macOS flows where required.
8. Record findings in `docs/architecture/environment-audit.md`, redacting sensitive paths, identifiers, and credentials as appropriate.
9. Produce an implementation plan with executable milestones, risk register, test strategy, and definition of done.
10. Start implementation immediately after discovery; do not stop at a planning document.

### Suggested repository structure

```text
ORIX-OS-Automation/
├── CLAUDE.md
├── README.md
├── LICENSE
├── ORIXAutomation.xcodeproj/
├── Apps/
│   └── ORIXAutomationMac/
│       ├── App/
│       ├── DesignSystem/
│       ├── Features/
│       │   ├── Dashboard/
│       │   ├── AgentChat/
│       │   ├── WorkflowStudio/
│       │   ├── CodeStudio/
│       │   ├── Console/
│       │   ├── Runs/
│       │   ├── Agents/
│       │   ├── Skills/
│       │   ├── Scheduler/
│       │   ├── Permissions/
│       │   ├── Providers/
│       │   ├── Settings/
│       │   └── Onboarding/
│       └── Resources/
├── Packages/
│   ├── ORIXCore/
│   ├── ORIXAgentRuntime/
│   ├── ORIXProviderAdapters/
│   ├── ORIXWorkflowEngine/
│   ├── ORIXToolRegistry/
│   ├── ORIXSecurity/
│   ├── ORIXPersistence/
│   ├── ORIXObservability/
│   ├── ORIXAppleAutomation/
│   ├── ORIXBrowserAutomation/
│   ├── ORIXScriptRuntime/
│   ├── ORIXScheduler/
│   └── ORIXTestingSupport/
├── Helpers/
│   ├── ORIXExecutionHelper/
│   └── ORIXBackgroundAgent/
├── Workflows/
│   ├── Examples/
│   └── Schemas/
├── Skills/
│   ├── BuiltIn/
│   └── Examples/
├── Tests/
│   ├── Unit/
│   ├── Integration/
│   ├── EndToEnd/
│   ├── Security/
│   └── Fixtures/
├── Scripts/
│   ├── build/
│   ├── test/
│   ├── sign/
│   └── release/
├── docs/
│   ├── architecture/
│   ├── security/
│   ├── api/
│   ├── workflows/
│   ├── skills/
│   ├── user-guide/
│   └── release/
└── .github/
    └── workflows/
```

Adapt the structure to existing repository conventions. Do not create empty decorative modules that have no purpose.

---

## 3. TECHNOLOGY CHOICES

- Swift and SwiftUI for the main macOS app.
- AppKit interoperability for advanced windows, native text editing, menu bar integration, keyboard shortcuts, drag-and-drop, and accessibility.
- Swift Concurrency (`async/await`, actors, structured tasks) for execution and cancellation.
- SwiftData or SQLite with explicit migrations for durable state; choose based on concurrency and observability needs.
- Keychain Services for provider credentials and local secrets.
- Security-scoped bookmarks for user-selected file/folder access where applicable.
- XPC and launch agents/helpers where justified; design narrow, authenticated interfaces.
- Apple Events, AppleScript/JXA, `NSAppleScript` or `osascript` when appropriate.
- Accessibility API (`AXUIElement`) for permitted UI automation.
- ScreenCaptureKit and Vision for explicitly authorized visual observation; do not record silently.
- Process/posix_spawn for subprocesses with cancellation, timeouts, process groups, bounded output, and explicit working directories.
- WKWebView only where it genuinely helps; use supported browser automation approaches and respect website terms.
- Native URLSession provider clients with structured decoding, streaming, retries, rate limiting, and timeout handling.
- Optional Python runtime via managed user-approved environment; never silently mutate system Python.
- OSLog with privacy-safe structured logging and redaction.
- XCTest/Swift Testing and macOS UI automation tests.
- Developer ID signing, hardened runtime, notarization, and stapling for direct distribution.

Do not choose a dependency because it is fashionable. Prefer maintainable, inspectable, minimally privileged implementations. Document third-party license compliance and supply-chain risks.

---

## 4. NATIVE DESIGN SYSTEM: ORIX AESTHETIC

Create a polished, original visual identity:

- Premium graphite/dark surfaces with restrained electric violet/blue accents; support light appearance and system appearance.
- Strong hierarchy, excellent typography, precise alignment, generous whitespace, native vibrancy where appropriate.
- Sophisticated transitions and spring animations, respecting Reduce Motion.
- Custom iconography consistent with SF Symbols and Apple HIG.
- Beautiful empty states, loading states, skeletons, inline validation, and error recovery.
- Smooth workflow canvas with zoom, pan, minimap, snapping, selection, multi-select, keyboard navigation, grouping, and undo/redo.
- Meaningful live indicators for running, paused, waiting approval, failed, succeeded, canceled, and recovering.
- Inspector panels with input/output schemas, tool permissions, runtime metrics, and last-run data.
- Native searchable command palette and global keyboard shortcuts.
- User-configurable sidebar, resizable panels, multiple windows, and workspace persistence.
- Responsive behavior across compact laptop displays and large external monitors.
- Dynamic Type/accessibility accommodations, VoiceOver labels, high contrast, full keyboard navigation.
- Performance budgets for animation, list virtualization, logs, and graph rendering.

### Primary application sections

**Dashboard:** active runs, success/failure history, recent workflows, provider status, cost and token usage, scheduled jobs, attention-required approvals.

**Agent Chat:** model selector, provider icon, streaming reasoning summaries (not hidden private chain-of-thought), tool activity, approvals, artifacts, file references, execution timeline, stop/retry buttons.

**Workflow Studio:** visual DAG and controlled cycles, conditionals, loops, fan-out/fan-in, manual gates, retries, variables, triggers, tool nodes, agent nodes, error handlers.

**Code Studio:** syntax highlighting, completion, validation, docs, diff viewer, formatter, snippets, test runner, terminal console, debugger, source control integration.

**Agents:** reusable agents with instructions, provider/model, budgets, tool grants, memory scope, concurrency, and evaluation profiles.

**Skills:** built-in and imported tool packages, capability manifest, versioning, signatures/trust metadata, install/remove, permissions, and local testing.

**Runs:** searchable execution history with inputs, outputs, tool calls, screenshots (if consented), logs, cost, timing, error chains, replay, and export.

**Scheduler:** calendar/timeline, file watchers, login triggers, wake/restart behavior, next run, missed runs, concurrency limits.

**Settings:** providers, Keychain-backed credentials, permissions, privacy, appearance, storage, backup, telemetry opt-in, notifications, update channel, diagnostics.

---

## 5. AGENTIC ENGINE: THINK → ACT → OBSERVE → VERIFY

Build a provider-independent orchestration engine that can:

1. Parse the user objective and identify needed resources.
2. Inventory available tools and permission scopes.
3. Produce a plan with checkpoints and expected artifacts.
4. Execute tool calls with typed arguments and validated results.
5. Observe actual machine state and tool outputs.
6. Update the plan as new evidence arrives.
7. Recover from transient errors with bounded retries.
8. Ask for clarification only when ambiguity materially affects safety or correctness.
9. Escalate approval before consequential operations.
10. Verify postconditions before reporting success.
11. Save reusable knowledge and workflow improvements without leaking secrets.
12. Produce a final execution receipt with evidence and limitations.

### Runtime primitives

Implement `AgentSession`, `AgentTask`, `AgentPlan`, `ToolCall`, `ToolResult`, `ExecutionContext`, `PermissionGrant`, `ApprovalRequest`, `Artifact`, `Observation`, `VerificationResult`, `MemoryRecord`, and `RunReceipt` as typed, versioned data models.

An agent loop should enforce:

- Maximum turns, wall-clock time, tokens, monetary cost, tool-call count, subprocess duration, and concurrent tasks.
- Cancellation and interruption propagation to child tasks/processes.
- Explicit state machine transitions.
- Deterministic persistence at important boundaries.
- Tool idempotency keys where possible.
- Durable checkpoints and crash recovery.
- Output schema validation and refusal of malformed tool calls.
- Loop detection, repetitive-action detection, and budget exhaustion handling.
- Untrusted content separation: web pages, emails, PDFs, repository files, and tool output are **data**, not new system instructions.
- No hidden expansion of privileges based on model-generated text.

### Planning modes

- **Quick Action:** one-off task with immediate feedback.
- **Guided:** plan preview, approvals, execution, verification.
- **Autonomous:** agent can plan and retry within pre-approved scoped capabilities.
- **Scheduled:** persisted workflow executes on a trigger.
- **Review:** dry-run or read-only analysis with no side effects.

Autonomous mode does not mean unrestricted root access or silent destructive behavior.

---

## 6. MULTI-PROVIDER AI ADAPTERS

Build a clean provider interface with separate adapters for:

### Anthropic
- Model discovery or maintained verified model registry.
- Messages API, streaming, tool use, structured output support as available.
- Token accounting, provider errors, backoff, and model-specific capabilities.
- Prompt caching when supported and appropriate.

### OpenAI
- Current supported API endpoints, streaming, tools, structured outputs, and capability discovery.
- Explicit handling of model differences and unsupported features.
- Usage accounting and resilient error handling.

### OpenRouter
- Model catalog retrieval, provider routing choices, model capability metadata, pricing when supplied.
- Compatibility mapping for tools, structured outputs, and streaming.
- Provider-specific limits and error reporting.

### BYOK UX

- Onboarding asks user to select provider and add key.
- Secrets stored only in macOS Keychain, scoped to the local user.
- Test connection with a minimal, explicit request; show cost warning if appropriate.
- Provider availability and latency indicators.
- Separate models for planner, executor, verifier, and specialist agents.
- Configurable max spend per task/day, token ceilings, concurrency, and retries.
- Never display full keys after entry; support rotate, replace, and delete.
- No hardcoded test credentials in binary, test data, or git history.

### SP Chat development testing integration

Inspect SP Chat deployment metadata and identify its provider credential injection pattern. Create an **optional developer-only** test adapter that references an approved existing secret source without extracting or duplicating values. Test the three providers independently with low-token, low-cost requests and explicit budget caps. If access is unavailable, use recorded sanitized fixtures and document that live provider verification is pending. Never ship the development adapter enabled in release builds.

---

## 7. TOOL REGISTRY AND EXECUTION CONTRACT

Every tool must expose:

```swift
protocol ORIXTool: Sendable {
    var identifier: String { get }
    var manifest: ToolManifest { get }
    func execute(
        input: ToolInput,
        context: ToolExecutionContext
    ) async throws -> ToolResult
}
```

The manifest should include:

- Human-readable description and version.
- JSON-compatible input/output schemas.
- Side-effect classification: read, write, external communication, destructive, privileged.
- Required macOS permissions and file/app scopes.
- Allowed working directories and network destinations.
- Default timeout, resource limits, and concurrency policy.
- Approval policy and dry-run support.
- Redaction rules for inputs/outputs.
- Test fixtures and verification hooks.

Tools must never treat the model's requested action as permission in itself.

### Built-in tool families

**Filesystem:** list, search, read, write, copy, move, rename, metadata, checksums, compare, watch, archive, and restore. Trash by default for user-facing delete operations; confirm irreversible deletion.

**Shell:** run allowlisted/scoped commands or user-approved scripts with explicit environment, working directory, process lifetime, stdout/stderr limits, and approval gates.

**AppleScript/JXA:** discover scripting dictionaries, execute scripts, inspect results, report Apple Events authorization errors, and support reusable app adapters.

**Accessibility:** inspect accessibility tree, locate controls, click, type, select, scroll, focus, and wait for state transitions after user authorization.

**Screen/Vision:** capture authorized windows or regions, identify visual elements, compare before/after, annotate screenshots, and request user confirmation when uncertain.

**Browser:** navigate permitted sites, inspect accessible page structure, interact with forms, download artifacts, and validate navigation. Prefer supported automation interfaces over brittle pixel clicking.

**Python:** execute managed Python scripts with dependency manifests, isolated environments, package allow/deny policies, resource quotas, and saved artifacts.

**Swift/JavaScript:** run explicitly scoped scripts with validation, timeouts, and capability controls; avoid unsafe in-process execution of untrusted code.

**Documents:** read and transform text, CSV, JSON, Markdown, spreadsheets, images, and PDFs using local libraries where feasible.

**Git:** status, diff, branches, commits, tests, and patch creation; require confirmation before push, force operations, or destructive history rewrites.

**System:** app launch/quit, notifications, clipboard with explicit consent, window management, process status, power/network state observation.

**HTTP:** typed requests with explicit domain allowlists and credentials isolated from prompts and logs.

**Notifications:** local alerts, actionable approval notifications, run completion summaries.

For each family, implement real tools with real integration tests and explicit capability declarations. Unsupported operations must return honest structured errors.

---

## 8. MACOS COMPUTER CONTROL

Implement a hybrid control strategy with ordered fallback:

1. Native application API or documented integration.
2. Apple Events / AppleScript / JXA when app supports scripting.
3. Accessibility API with semantic element identification.
4. Vision-assisted UI interaction only with explicit screen access and verification.
5. Keyboard/mouse emulation as a last resort, with focus and state checks.

### Essential engineering details

- Correctly detect frontmost application and focused window.
- Track display scaling, multi-monitor layouts, window movement, and coordinate transforms.
- Avoid clicking based on stale screenshots.
- Inspect accessible labels, roles, and values before action.
- Wait for observable postconditions rather than arbitrary sleeps.
- Recover from dialogs, permission prompts, unexpected windows, and application restarts.
- Avoid recording sensitive windows, passwords, payment forms, and secure text fields.
- Expose a visible screen-control indicator and emergency stop shortcut.
- Support a pause button that stops the agent before the next side-effecting action.
- Never attempt to automate macOS privacy consent prompts by bypassing user interaction.
- Explain limitations of apps that do not expose reliable accessibility or scripting interfaces.

### Application integration candidates

Finder, Safari, Mail, Calendar, Notes, Reminders, Preview, Numbers, Pages, Keynote, Terminal, Xcode, browsers, and user-installed third-party apps. Verify actual capabilities per app/version; do not claim universal compatibility.

---

## 9. WORKFLOW ENGINE AND VISUAL STUDIO

Use a versioned, serializable workflow intermediate representation (IR).

### Node categories

- Trigger: manual, schedule, file event, app event, webhook/local HTTP listener if explicitly enabled, system event.
- Agent: planner, worker, specialist, verifier, reviewer.
- Tool: shell, AppleScript, Python, browser, file, app, document, HTTP.
- Logic: condition, switch, loop, foreach, map, reduce, filter, transform.
- Parallelism: fork, join, concurrency limiter, queue.
- Data: variable, constant, secret reference, file, JSON parser, schema validator.
- Control: approval, delay, retry, timeout, pause, cancel, fallback.
- Output: notification, document, artifact, log, report, clipboard with consent.
- Error: catch, compensate, rollback where possible, alert, escalate.

### Workflow features

- Typed ports and connection validation.
- Schema-aware autocompletion.
- Editable expressions with safe evaluation semantics.
- Named variables and secrets by reference only.
- Subworkflows, templates, reusable components.
- Version history, draft/published states, diffs, rollback.
- Import/export with validation and secret stripping.
- Dry-run with explicit indication of what is simulated.
- Step-by-step execution and breakpoints.
- Retry policy per node, backoff, timeout, and error routes.
- Compensation actions where reversible; never promise rollback for irreversible external actions.
- Live node highlighting, progress, timing, and result inspection.
- Scheduling and dependency management.
- Local template gallery.

### Example declarative workflow (illustrative; define and validate actual grammar)

```yaml
apiVersion: orix.ai/v1
kind: Automation
metadata:
  name: weekly-research-report
spec:
  trigger:
    type: schedule
    cron: "0 9 * * MON"
    timezone: America/Toronto
  permissions:
    filesystem:
      read: ["~/Documents/Research"]
      write: ["~/Documents/Reports"]
    processes: ["python"]
  budget:
    maxDurationSeconds: 1800
    maxProviderCostUSD: 2.00
  steps:
    - id: discover
      tool: filesystem.list
      with:
        path: "~/Documents/Research"
    - id: analyze
      agent: research-analyst
      needs: [discover]
    - id: render
      tool: document.renderPDF
      needs: [analyze]
    - id: verify
      verifier: artifact-exists
      needs: [render]
```

Do not assume `~` expansion, cron syntax, or paths are safe without implementing explicit resolution and validation.

---

## 10. CODE STUDIO AND SCRIPT AUTHORING

Provide an advanced native IDE-like experience:

- Editor with syntax highlighting for YAML/JSON, AppleScript, Bash, Python, Swift, JavaScript.
- Language-aware validation and formatting.
- Search/replace, command palette, multi-file project view, diagnostics.
- Integrated terminal with explicit sandbox/scoping and visible process controls.
- Script templates, snippets, autocomplete, inline tool docs.
- Run selected script, test script, inspect stdout/stderr, save as skill.
- Test fixtures, mock tool responses, and live test mode.
- Visual diff and approval of agent-generated changes.
- Version control integration and reproducible environment manifests.
- Inline AI assistant that can explain, generate, refactor, and test automation scripts.

Do not confuse a raw terminal with an unrestricted privilege grant. The terminal must clearly distinguish user-initiated shell execution from agent-initiated shell execution and apply the corresponding security policy.

---

## 11. WATCH & LEARN (ADVANCED MILESTONE)

Create an opt-in recording mode that observes an explicitly chosen workflow:

1. User presses Start Recording.
2. App requests required permissions through system flows.
3. Show persistent recording indicator and pause/stop controls.
4. Record only necessary UI events and selected application context.
5. Mask sensitive fields and allow redaction before saving.
6. Infer reusable semantic actions rather than hardcoding coordinates.
7. Ask the user to label variables and parameterize inputs.
8. Generate a proposed workflow and show its permissions.
9. Test in a controlled environment.
10. Save only after user approval.

Never capture credentials, private messages, or unrelated windows silently. Recording should be off by default.

---

## 12. AUTONOMOUS SKILL CREATION

An agent may propose a new reusable tool when no existing tool suffices.

Pipeline:

1. Identify missing capability and desired contract.
2. Generate a manifest with input/output schemas and requested permissions.
3. Generate implementation in a supported runtime.
4. Static analysis, dependency inspection, and security review.
5. Run tests in an isolated environment with synthetic fixtures.
6. Show a source diff and capability summary to the user.
7. Request approval for installation and runtime grants.
8. Install as a versioned local skill.
9. Execute with bounded permissions.
10. Monitor failures and support rollback to prior versions.

Support skill signing/checksums, provenance, semantic versioning, disable/uninstall, and dependency pinning. Imported skill instructions and documentation are untrusted content. They must not override system security policy.

---

## 13. SECURITY MODEL: POWER WITHOUT UNCONTROLLED AUTHORITY

Treat this as a first-class engineering deliverable, not a disclaimer.

### Capability permissions

Represent permissions as specific grants, such as:

- Read a user-selected directory.
- Write a user-selected directory.
- Automate a named application.
- Read a selected browser page.
- Capture a selected window.
- Execute a specific script/runtime.
- Connect to specific network domains.
- Access a specific Keychain secret reference for a specific provider client.
- Send external communications.
- Modify or delete files.

Grants must be scoped, reviewable, revocable, and recorded. Persistent grants should be opt-in and clearly differentiated from one-time approval.

### Approval tiers

**Tier 0 — Read-only:** scoped local inspection and analysis.

**Tier 1 — Reversible local write:** user-approved workspace modifications with backup or undo where feasible.

**Tier 2 — Consequential:** external sends, Git pushes, installs, app changes, sensitive file writes; explicit approval or narrowly preauthorized workflow policy.

**Tier 3 — High-risk/irreversible:** permanent deletion, privileged system changes, financial transfers, credential modifications, destructive Git operations; explicit contemporaneous user approval and additional safeguards. Some operations should remain unsupported.

### Security controls

- Enforce permissions in the execution layer, not in prompts alone.
- Use a policy engine with deny-by-default capability checks.
- Never execute arbitrary model-authored shell text solely because it appeared in a model response.
- Treat command arguments as structured values; avoid shell interpolation when possible.
- Redact tokens, passwords, private file contents, and PII from logs and telemetry.
- Prevent prompt injection from files, websites, tool output, and retrieved documents.
- Prevent secret exfiltration through tool chaining or external network calls.
- Prevent privilege escalation through helper processes.
- Validate XPC caller identity and enforce least privilege.
- Keep helper entitlements minimal and auditable.
- Add rate limits, quotas, and watchdogs.
- Require explicit user action for OS permission grants.
- Support emergency stop, revoke-all, and kill active subprocess trees.
- Make privacy/telemetry opt-in; do not send screen captures to a provider without clear user consent.
- Encrypt sensitive persisted data where needed and use Keychain for secrets.
- Maintain an append-only or tamper-evident local audit trail for consequential actions where practical.
- Audit third-party dependencies and ensure signed release artifacts.

### Threat-model scenarios to test

1. Malicious web page instructs agent to upload local secrets.
2. PDF contains fake system instructions.
3. Skill package requests broader access than its manifest declares.
4. Tool output includes shell injection payload.
5. Agent repeatedly retries an irreversible action.
6. Model invents success after tool failure.
7. Provider key accidentally appears in console output.
8. Browser focus shifts before a click.
9. Background workflow resumes after reboot with stale permission.
10. Remote service returns hostile content that attempts privilege escalation.

Document mitigations and residual risks.

---

## 14. MEMORY, CONTEXT, AND KNOWLEDGE

Implement a durable, local-first memory architecture:

- Session memory for the current task.
- Workflow memory for stable run parameters and learned fixes.
- User-approved preferences and reusable conventions.
- Skill knowledge, manifests, examples, and tool documentation.
- Execution memory with verified observations and artifact pointers.
- Retrieval over locally indexed approved data; scope access per workflow.
- Summarization/compaction to manage context windows.
- Provenance and timestamps for remembered facts.
- Explicit delete/export controls.
- No silent long-term retention of sensitive screen content.
- No persistence of secrets in prompts, memory summaries, or embeddings.

Memory is advisory, not authorization. A remembered approval does not grant a new capability.

---

## 15. SCHEDULER AND ALWAYS-ON SERVICE

Build a robust background execution system using appropriate macOS launchd/SMAppService patterns and explicit user opt-in.

Support:

- Manual runs.
- One-time schedules.
- Recurring schedules with timezone and daylight-saving behavior.
- File/directory changes with debouncing.
- Login/startup triggers.
- Application lifecycle events where supported.
- Network/power state triggers where feasible.
- Missed-run policy after sleep/restart.
- Durable queue, retry, deduplication, idempotency.
- Concurrent run limits and per-workflow locks.
- Pause/resume, cancel, run now, disable.
- Visible menu-bar status and notifications.
- Approval-required state that waits safely for user interaction.

Do not promise execution while the Mac is powered off. Handle sleep, locked sessions, and GUI automation restrictions honestly: headless background jobs can run in more situations than UI automation.

---

## 16. OBSERVABILITY, COSTS, AND EVIDENCE

Every run should expose:

- Run ID, workflow version, start/end times, status.
- Agent/provider/model choices.
- Tool calls, sanitized arguments, results, duration.
- Token usage and estimated/actual provider costs where available.
- Error classification and retry history.
- Permissions used and approvals granted.
- Produced artifacts and hashes when appropriate.
- Verification assertions and outcomes.
- Resource usage, queue time, and concurrency.
- Screenshots only when explicitly authorized.
- Final machine-readable and human-readable execution receipt.

### Outcome statuses

`SUCCEEDED`, `PARTIALLY_SUCCEEDED`, `FAILED`, `CANCELED`, `TIMED_OUT`, `WAITING_APPROVAL`, `BLOCKED_PERMISSION`, `BUDGET_EXCEEDED`, `RECOVERY_REQUIRED`.

Never mark success solely because the language model says it succeeded. Verify the relevant postcondition.

---

## 17. ERROR RECOVERY AND RESILIENCE

- Typed errors for provider, tool, permission, OS, network, parsing, timeout, and validation failures.
- Bounded exponential backoff with jitter for transient network errors.
- No blind retries for non-idempotent actions.
- Workflow checkpointing and restart recovery.
- Human-readable error explanations with actionable fixes.
- Automatic recovery only within the original permission scope.
- Compensation/undo for supported reversible operations.
- Safe cancellation of subprocess groups.
- Disk-space and resource-pressure monitoring.
- Schema migration and corrupt database recovery.
- Backup/export/import for workflows and user data.
- Offline mode for local tools, with provider-dependent features clearly marked unavailable.

---

## 18. BUILT-IN AUTOMATIONS TO SHIP

Ship tested, editable examples:

1. Smart Downloads Organizer.
2. PDF to structured data and report.
3. Weekly research digest from selected local files.
4. Git repository test-and-review assistant.
5. CSV cleanup and chart generation.
6. Batch image conversion and naming.
7. Calendar-based preparation workflow (where integration is permitted).
8. Folder backup and verification.
9. Website change monitoring using approved access.
10. Local system health report.
11. Meeting notes organization from user-provided transcripts.
12. Document metadata extraction and cataloging.
13. Scheduled screenshot of a selected app/window, with consent.
14. Automated spreadsheet validation.
15. Multi-step browser data-entry workflow on a test site.

Each example needs: description, permissions, configurable parameters, sample data, tests, expected artifacts, and explicit limitations.

---

## 19. QUALITY ASSURANCE AND TESTING

Create an automated test pyramid:

### Unit tests
- Workflow schema validation and migrations.
- Graph execution order, cycles, branches, and retries.
- Provider response parsing and stream handling.
- Tool manifest validation.
- Permission policy decisions.
- Budget enforcement and cancellation.
- Secret redaction and log filtering.
- Scheduler timezone and DST behavior.
- Persistence and crash recovery.

### Integration tests
- Real filesystem operations inside temporary directories.
- Real subprocess execution and cancellation.
- AppleScript interaction with a safe test app or supported built-in app.
- Accessibility tree inspection under granted permission.
- Provider smoke tests using approved SP Chat-backed developer credentials.
- Local browser automation against a controlled test page.
- Keychain create/read/delete using test-only entries.
- Background agent communication and lifecycle.

### End-to-end tests
- Onboard with a test provider.
- Create workflow from natural language.
- Review permissions and approve.
- Run and inspect live tool events.
- Generate and verify an artifact.
- Save, reopen, modify, and rerun workflow.
- Schedule and observe a background run.
- Cancel a running job and verify subprocess cleanup.
- Recover from simulated provider and tool failures.
- Export/import workflow without secrets.

### Security tests
- Prompt injection attempts.
- Path traversal and symlink escape.
- Command injection.
- Credential redaction.
- Unauthorized tool escalation.
- Excessive token/tool loops.
- Unexpected GUI focus change.
- Malicious skill manifests.
- Non-idempotent retry protection.

### Performance tests
- Cold launch and warm launch.
- Memory footprint while idle and running.
- Large workflow graph rendering.
- Large log streaming and virtualization.
- Long-running background jobs.
- UI responsiveness during provider streaming and subprocess output.

Do not substitute mocked tests for live integrations. Distinguish mocked, integration, and verified-on-device results in test reports.

---

## 20. APPLE SIGNING, NOTARIZATION, AND DISTRIBUTION

The development Mac is expected to already contain signing/notarization configuration. Discover and reuse it securely.

### Release pipeline

1. Validate Xcode scheme, bundle ID, version/build numbers, minimum macOS target, and entitlements.
2. Build Release configuration for intended Apple Silicon and, if feasible, Intel architectures.
3. Run all automated tests and static checks.
4. Verify no API keys, tokens, internal hostnames, private test fixtures, or development secrets are embedded.
5. Sign app and bundled helpers with the appropriate Developer ID identity and hardened runtime.
6. Validate entitlements and code signatures using `codesign` and `spctl`.
7. Package as a signed installer or DMG as appropriate.
8. Submit to Apple notarization via `xcrun notarytool` using an existing authorized keychain profile.
9. Wait for and inspect Apple's notarization result; handle rejection logs.
10. Staple the notarization ticket where supported.
11. Validate Gatekeeper acceptance on the finished artifact.
12. Generate checksums, release notes, version metadata, and installation instructions.
13. Test first launch, permissions onboarding, updates, helper registration, and uninstall on a clean Mac/user profile where possible.
14. Store non-sensitive release evidence in `docs/release/`.

### Strict release requirements

- No secret export from Keychain.
- No embedding SP Chat credentials in distributed binaries.
- No false claim of notarization before Apple accepts the submission.
- No silent disabling of hardened runtime or Gatekeeper.
- No entitlement escalation without explicit technical justification.
- No claim of Mac App Store compliance without an actual policy and entitlement review.
- Never publish a release without verifying the final artifact.

Investigate a secure update mechanism (for example, a well-maintained signed updater) and verify its security model. Do not implement insecure self-update downloads.

---

## 21. DOCUMENTATION REQUIREMENTS

Produce comprehensive, accurate documentation:

- Product README with screenshots from the actual running app.
- Installation and first-run onboarding.
- Provider setup for Anthropic, OpenAI, OpenRouter.
- Explanation of local BYOK security.
- Permissions and privacy guide.
- Workflow language reference and JSON/YAML schema.
- Tool API and capability manifest specification.
- AppleScript, JXA, Shell, Python, and browser automation guides.
- Skill development tutorial and security review checklist.
- Visual editor tutorial.
- Scheduling and background operation guide.
- Troubleshooting common TCC/Accessibility/Apple Events issues.
- Threat model and security architecture.
- Backup, migration, and recovery guide.
- Release and notarization runbook.
- Changelog, known limitations, roadmap.

Document actual implementation behavior, not aspirational features.

---

## 22. MILESTONE PLAN — IMPLEMENT IN ORDER

### M0 — Discovery, architecture, security foundations

Deliver environment audit, provider credential strategy, signing/notary discovery, threat model, repository setup, project architecture, CI/build scripts, test harness, design tokens.

**Gate:** project builds cleanly and security boundaries are documented.

### M1 — Native app foundation

Deliver window system, navigation, dashboard, design system, onboarding, settings, Keychain, local database, run/event models, console UI, permission center.

**Gate:** native app launches and persists user settings; Keychain tests pass.

### M2 — Providers and agent loop

Deliver Anthropic/OpenAI/OpenRouter adapters, model selection, streaming chat, tool-calling protocol, execution state machine, budget controls, cancellation, approval UI.

**Gate:** provider fixtures pass and at least one authorized live smoke test per accessible provider succeeds; real tool calls work.

### M3 — Core macOS tools

Deliver filesystem, shell, AppleScript/JXA, app control, Accessibility integration, local browser interaction, Python execution, artifact verification.

**Gate:** end-to-end tasks execute on the Mac with real postcondition checks.

### M4 — Workflow studio and code studio

Deliver versioned workflow IR, graph canvas, visual editing, declarative editor, validation, step debugger, live execution visualization, templates.

**Gate:** create/edit/save/reopen/run workflow across modes without losing semantics.

### M5 — Background scheduling and reliability

Deliver launch agent/service, scheduled jobs, file watchers, durable queue, resume policy, notification center, retry/recovery, export/import.

**Gate:** scheduled workflow survives app-window closure and handles sleep/restart appropriately.

### M6 — Multi-agent and self-extending skills

Deliver agent orchestration, specialist delegation, scoped memory, skill SDK, skill generation pipeline, source review, sandboxed test harness, versioned installs.

**Gate:** an agent can propose, test, approve, install, and run a new skill safely.

### M7 — Watch & Learn and advanced polish

Deliver consent-based observation, workflow inference, parameterization, sophisticated animations, accessibility audit, performance optimization.

**Gate:** recorded workflow is replayable with user approval and sensitive information is protected.

### M8 — Production hardening and release

Deliver full regression tests, security review, documentation, signed release, Apple notarization, stapling, Gatekeeper verification, DMG/installer, release notes.

**Gate:** reproducible, verified distribution artifact; report any Apple/account blockers honestly.

Do not prematurely call the product complete if advanced milestones remain unimplemented. Deliver incremental usable builds.

---

## 23. DEFINITION OF DONE

The project is done only when:

- A genuine native SwiftUI macOS app exists and builds.
- Onboarding, provider selection, and Keychain-backed BYOK work.
- Anthropic, OpenAI, and OpenRouter integrations are implemented and tested at the appropriate level.
- The agent can plan, call real tools, observe, and verify results.
- macOS automation uses supported APIs and respects consent.
- Users can create and run workflows in natural language, visual, and code views.
- The scheduler and background worker execute reliable persisted jobs.
- The console shows real logs, costs, tool calls, errors, and artifacts.
- Dangerous operations are gated by enforceable permission checks.
- Skills are installable, testable, versioned, and permission-scoped.
- Built-in examples work with actual fixtures and clear setup instructions.
- Automated tests and at least one full end-to-end Mac execution pass.
- Documentation is accurate and includes screenshots of the real app.
- Release builds do not contain development credentials.
- Signing and notarization have been genuinely completed or their blockers explicitly reported.

---

## 24. ENGINEERING DISCIPLINE AND AUTONOMOUS EXECUTION

At every significant step:

1. Inspect existing code and dependencies.
2. State a small implementation objective.
3. Make coherent changes.
4. Build and run relevant tests.
5. Investigate failures rather than hiding them.
6. Update documentation and architecture decisions.
7. Commit logical milestones if repository policy allows.
8. Continue to the next independently achievable milestone.

Maintain `docs/implementation-status.md` with:

- Completed and verified capabilities.
- In-progress work.
- Known defects and severity.
- Required human approvals.
- Live integration test status by provider.
- Security test outcomes.
- Release readiness and notarization status.

Do not pad progress with empty files, cosmetic demos, or unimplemented buttons. A button that claims to run, save, stop, retry, or export must perform that action. UI states must be connected to actual runtime state.

### Final deliverables

1. Complete native macOS source project.
2. Real functional app and background helper.
3. Provider integrations and safe developer test configuration.
4. Visual workflow editor and code IDE.
5. Tool/skill SDK and built-in automations.
6. Test suite and security audit results.
7. Full documentation and screenshots.
8. Signed/notarized release artifact when authorized configuration permits.
9. Concise final engineering report: features, tests, known limitations, security decisions, distribution status, and next steps.

---

## 25. START NOW

**Begin by auditing the current repository, local macOS/Xcode environment, SP Chat deployment's authorized provider test configuration, and existing Apple signing/notarization metadata. Then create the implementation plan and immediately build the first working native application milestone.**

Do not ask the product owner to repeat information already discoverable in authorized local configuration. Ask only when permission, an external credential authorization, a consequential action, or an architectural decision truly requires a human choice. Never mistake discoverability for permission to use a secret or perform an irreversible action.

**ORIX OS Automation should feel like a powerful, trustworthy extension of macOS: the user defines the goal, the system carries out authorized work, and every result can be inspected and verified.**

<!-- spb-source-governance:start -->
## Source header policy (SP Boucher)

When creating or modifying eligible first-party source files, follow the SP Boucher Source Header
Policy. Preserve existing copyright and license notices, select the correct language-specific
template, and avoid adding identifying information to anonymous academic submission artifacts.

- Repository policy: `.spb-source-governance.toml` (project, contact, verified rights, license).
- Add or refresh headers with `spb-header apply --repo .`; verify with `spb-header check --repo .`.
- Never hand-write a header, never add one to generated, vendored, third-party or data files.
<!-- spb-source-governance:end -->
