<!--
ORIX OS Automation
File: docs/api/tool-api.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Tool API and capability manifest

The per-tool reference (arguments, outputs, tiers) is generated from the code: [`tools.md`](tools.md). This page
describes the contract every tool obeys. The types live in `Packages/ORIXCore/Sources/ORIXCore/Tools.swift` and
`Security.swift`.

## The contract

```swift
public protocol ORIXTool: Sendable {
    var identifier: String { get }
    var manifest: ToolManifest { get }
    func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements
    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult
}
```

`requirements` is pure. It validates the meaning of the arguments, resolves every path with
`PathResolver.canonical` (tilde, relative to the run's working directory, `..` removed, symlinks resolved) and
returns the exact capabilities, the tier of this call, and one sentence describing what will happen. `execute`
then acts only on those resolved targets.

A tool never checks policy, never asks for approval and never redacts. `ToolExecutor` does all three around it.

## Manifest

| Field | Meaning |
|---|---|
| `identifier` | `family.action`, unique |
| `name`, `version`, `summary` | Shown to people and to the model |
| `family` | `filesystem`, `shell`, `git`, `http`, `documents`, `python`, `script`, `system`, `applescript`, `accessibility`, `screen`, `browser`, `skill` |
| `inputSchema`, `outputSchema` | JSON Schema subset: `type`, `properties`, `required`, `additionalProperties`, `items`, `enum`, numeric and length bounds, `pattern` |
| `sideEffect` | `read`, `write`, `external`, `destructive`, `privileged` |
| `defaultTier` | 0–3; a call can state its own tier in `requirements` |
| `macPermissions` | macOS privacy permissions the tool depends on |
| `defaultTimeoutSeconds`, `maxOutputBytes` | Limits applied by the executor |
| `concurrency` | `unlimited`, `serial` (one call of this tool at a time), `exclusive` (GUI control) |
| `supportsDryRun` | The tool can describe what it would do without doing it |
| `idempotent` | Repeating the call cannot add effects. Only idempotent steps are retried automatically |
| `redactedInputKeys` | Argument keys hidden in logs, events and approval sheets |
| `outputIsUntrusted` | Output carries outside content and is framed as data when returned to a model |

`ToolManifest.problems()` rejects inconsistent manifests (a read tool above tier 0, a destructive tool below
tier 2, a malformed identifier). The registry refuses to register such a tool.

## Capabilities

A capability is one specific authority: `fileRead(path)`, `fileWrite(path)`, `fileDelete(path)`,
`processExec(executable)`, `scriptRuntime(name)`, `appAutomation(bundleID)`, `accessibility(bundleID)`,
`screenCapture(scope)`, `network(host)`, `browser(host)`, `secret(reference)`, `clipboardRead`, `clipboardWrite`,
`notify`, `externalSend(channel)`, `appControl(bundleID)`, `skill(id)`.

`Capability.covers` never widens: write does not imply read or delete; a path covers itself and its descendants
by whole components; a host covers only itself, or its subdomains with `*.`.

## Tiers

| Tier | Meaning | Who can allow it |
|---|---|---|
| 0 | Read-only | A grant, or an approval |
| 1 | Reversible local write (new files, in-place edits with a backup, move to Trash) | A grant of tier ≥ 1, or an approval |
| 2 | Consequential (scripts, network sends, app control, GUI input, git push, installs) | A grant of tier 2 (for example accepted workflow permissions), or an approval |
| 3 | High-risk or irreversible (permanent deletion, force push) | Only a contemporaneous approval of that exact call |

## What the executor does with a call

1. Unknown tool → `failed / not_found`.
2. Arguments against `inputSchema` → `invalidInput`; nothing runs.
3. `requirements`; a file capability in a protected location → `denied`, audited as a policy violation.
4. Capabilities inside the run's artifacts folder are granted implicitly; the rest go to the policy engine.
5. `deny` → `denied`. `needsApproval` → the approval broker; no answer or a refusal → `notApproved`.
6. An idempotency key already executed successfully in this run returns the stored result.
7. Concurrency gate, then execution with a timeout; cancellation and emergency stop end it.
8. Thrown `ToolError` → structured result. Output against `outputSchema`. Redaction. Truncation.
9. Single-use grants are consumed; the call is audited; `toolRequested` / `toolFinished` events are stored.

`invoke` never throws. Every outcome is a `ToolResult` whose `status` is one of `succeeded`, `simulated`, `failed`,
`denied`, `notApproved`, `blockedPermission`, `timedOut`, `canceled`, `invalidInput`, `unsupported`.

## Subprocesses

Tools that start programs use `ProcessRunner`: explicit argument vector (no shell), minimal environment, explicit
working directory, own process group, timeout, SIGTERM then SIGKILL of the group, bounded output. Script tools
(`shell.script`, `python.run`, `script.swift`, `script.javascript`, skills) run inside a generated Seatbelt profile:
writes only in the granted folders and the run's artifacts folder, no network unless a host was granted, no access
to credential stores. Seatbelt cannot filter by host: a confined process with network access can reach any host.

## Adding a tool

Add a type conforming to `ORIXTool` in the package of its family, list it in that package's `…Tools.all()`, and
write an integration test that runs it for real. If it needs authority that does not map to an existing
capability, that is a change to `ORIXCore` and to the policy engine, not something to approximate.
