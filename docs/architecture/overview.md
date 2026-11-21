<!--
ORIX OS Automation
File: docs/architecture/overview.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Architecture

## Layers

```
┌──────────────────────────── ORIX OS Automation.app (SwiftUI + AppKit) ────────────────────────────┐
│ Dashboard · Agent Chat · Workflow Studio · Code Studio · Runs · Agents · Skills · Scheduler ·      │
│ Permissions · Settings · Onboarding · Menu-bar item · Command palette · Approval sheets            │
└───────────────▲──────────────────────────────▲───────────────────────────────▲─────────────────────┘
                │ observes                      │ answers approvals             │ edits
        ┌───────┴────────┐              ┌───────┴────────┐              ┌───────┴─────────┐
        │ ORIXPersistence│◀─ events ────│   AppServices  │── documents ▶│ ORIXWorkflow    │
        │ SQLite (WAL)   │              │ (composition)  │              │ Engine (IR)     │
        └───────▲────────┘              └───┬───────┬────┘              └───────┬─────────┘
                │                           │       │                           │ tool + agent steps
                │                 ┌─────────▼──┐  ┌─▼──────────────┐            │
                │                 │ ORIXAgent  │  │ ORIXScheduler  │            │
                │                 │ Runtime    │  │ (queue, cron)  │            │
                │                 └─────┬──────┘  └───────┬────────┘            │
                │     model turns       │ tool calls      │ launches runs       │
        ┌───────┴────────┐        ┌─────▼────────────────────────────────────────▼─────┐
        │ ORIXProvider   │        │            ToolExecutor (ORIXToolRegistry)          │
        │ Adapters       │        │ schema → requirements → policy → approval → run →   │
        │ (URLSession)   │        │ redact → audit                                      │
        └────────────────┘        └──┬──────────────┬─────────────────┬────────────────┘
                                     │ PolicyEngine │ Tools           │ ProcessRunner
                                     │ (ORIXSecurity)│ files, shell,  │ process groups,
                                     │ grants, tiers │ git, http, docs│ timeouts, Seatbelt
                                     │ AuditLog      │ Apple, browser │
                                     └──────────────┴─────────────────┴────────────────
```

## Separation that the code enforces

| Concern | Lives in | Cannot do |
|---|---|---|
| Reasoning | `ORIXAgentRuntime` + provider adapters | Touch the machine. Its only door is `ToolInvoking`. |
| Permission | `ORIXSecurity.PolicyEngine` | Execute anything. It only answers allow / ask / deny. |
| Execution | `ORIXToolRegistry.ToolExecutor` + tools | Decide policy or approve itself. |
| Audit | `ORIXSecurity.AuditLog`, run events in the store | Be rewritten silently: the log is hash-chained. |
| UI | the app | Run a tool directly: it submits runs and answers approval requests. |

`ORIXCore` holds the contracts between them (protocols and value types only), so each layer can be tested alone and
none can reach around another.

## One model, three views

A workflow is one `WorkflowDocument` (the IR). The code view edits its YAML/JSON text; the visual view applies edit
operations to the document; the agent view asks a model to produce or change the same document. Every view parses
or emits through `WorkflowCodec`, and `WorkflowValidator` judges the result. What a view cannot represent (comments
in YAML when the canvas rewrites the text) is reported before the rewrite.

## Processes

- **The app** owns the UI, answers approvals, and runs foreground work.
- **The background agent** is the same signed executable started by launchd with `--background-agent`
  (registered with `SMAppService`, opt-in). It runs the scheduler and headless workflows. It is the same binary on
  purpose: identical code signature means identical Keychain access without widening any access list, and no second
  executable to keep entitlement-minimal. It has no window and cannot answer approvals: anything not pre-granted
  parks as `WAITING_APPROVAL` and is surfaced by a notification and in the app.
- Both share one SQLite database (WAL). A lease row ensures a single active scheduler. Changes are announced with a
  Darwin notification so the other process refreshes.
- **Subprocesses** (scripts, git, python…) are children of whichever process runs the tool, each in its own process
  group, confined with a generated Seatbelt profile where applicable, killed as a group on timeout, cancel or
  emergency stop.

## Data on disk

`~/Library/Application Support/ORIX Automation/`: `orix.sqlite` (runs, events, workflows and versions, grants,
schedules, queue, agents, memory), `audit.jsonl` (hash-chained), `artifacts/<runID>/`, `skills/<id>/<version>/`,
`python-env/`. Provider keys and user secrets: login Keychain only (service `ai.spboucher.orix.automation`).

## Decisions

1. **No third-party code.** YAML subset codec, SQLite wrapper, SSE parser, PDF rendering and the editor are written
   against system frameworks. Nothing to license, pin or audit beyond Apple's SDK.
2. **SQLite, not SwiftData.** Two processes write the same store; explicit migrations, WAL, leases and
   corrupt-file quarantine need direct control.
3. **Same-binary background agent** (see above) rather than a helper tool or an XPC service. There is no XPC surface
   to authenticate because there is no XPC: the processes cooperate through the database.
4. **Seatbelt (`sandbox-exec`) for scripts.** Deprecated as a public tool but present and functional on macOS 27;
   it is the only supported way for a non-sandboxed parent to confine an arbitrary child. If Apple removes it,
   script tools must refuse to run unconfined unless the user explicitly accepts (tracked in the risk register).
5. **OpenAI through Chat Completions.** One wire format shared with OpenRouter. The Responses API is future work.
6. **Verification decides status.** A run is `SUCCEEDED` only from tool results and runtime-checked postconditions;
   the model's closing statement is stored as a claim.
