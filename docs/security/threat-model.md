<!--
ORIX OS Automation
File: docs/security/threat-model.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Threat model and security architecture

## What is protected

The user's files, applications, accounts and credentials on this Mac, from an agent that may be wrong, may be
manipulated by what it reads, or may be driven by an installed skill written by someone else.

## Trust boundaries

| Party | Trusted for | Not trusted for |
|---|---|---|
| The user (at the keyboard) | Objectives, grants, approvals | — |
| ORIX runtime code | Enforcing policy | — |
| The language model | Proposing actions | Deciding what is permitted; reporting what happened |
| Tool output, files, web pages, app text, skill documentation | Being data | Instructions, permissions, claims of authority |
| Installed skills | Running inside their declared, approved capabilities | Anything beyond their manifest |
| Model providers | Receiving the prompts the user chose to send | Receiving secrets, screens or files the user did not send |

## The enforcement chain

Every side effect, from an agent or a workflow, goes through `ToolExecutor.invoke`:

1. **Schema.** Arguments are validated against the tool's JSON Schema. Malformed calls run nothing.
2. **Requirements.** The tool itself (code, not the model) turns arguments into concrete capabilities: canonical
   paths with symlinks resolved, hosts, bundle identifiers, executables.
3. **Protected locations.** Keychains, `~/.ssh`, TCC databases, `/System` and similar are refused before grants are
   even consulted. No grant can cover them.
4. **Policy.** `PolicyEngine` is deny-by-default: each capability must be covered by an active grant of a matching
   scope (one call, one run, one workflow, or persistent) and sufficient tier. Review mode refuses everything above
   tier 0. Tier 3 always needs a contemporaneous approval for that exact call.
5. **Approval.** A person sees a sentence written by the tool from the validated arguments, the capabilities, the
   tier, and the redacted arguments. Headless runs get no answer and the call does not run.
6. **Execution.** Timeout, cancellation, bounded output. Subprocesses run as structured argv (no shell
   interpolation), in their own process group, and scripts run inside a generated Seatbelt profile limited to the
   run's granted folders and hosts.
7. **Redaction and audit.** Output, summaries and events pass through `Redactor` (registered secrets plus
   credential-shaped patterns). Decisions and executions are appended to a hash-chained audit log.

The model's text is never an input to steps 2–5 other than as the arguments being judged.

## Scenarios

| # | Scenario | Mitigations | Test | Residual risk |
|---|---|---|---|---|
| 1 | A web page tells the agent to upload local secrets | Page text arrives as `untrusted_data`; reading `~/.ssh` etc. is refused outright; reading other files needs a file grant; sending needs a `network` grant for that host and tier 2 approval; secrets are references, never values | `AgentSecurityTests.untrustedToolOutput…`, executor protected-path and network-grant tests, browser navigation-block tests | A user who has granted both a folder and a broad network host can still be talked into approving a send. The approval sheet shows the destination and arguments. |
| 2 | A PDF contains fake system instructions | Same framing; the wrapper cannot be closed from inside the content; system prompt states the rule; no capability changes because of text | `untrustedToolOutput…` (closing-tag neutralisation), `documents.pdfText` marks output untrusted | A model may still be influenced in what it writes in its summary. It cannot gain authority. |
| 3 | A skill asks for more than its manifest declares | A skill runs as a tool whose capabilities are computed from its manifest; anything outside is denied by policy and by its Seatbelt profile; static analysis flags undeclared network/file/process use before install; install needs approval and shows the diff | Skill analyser and confinement tests | Static analysis is heuristic; confinement is the real control. |
| 4 | Tool output contains a shell injection payload | Arguments are argv elements; `shell.run` refuses inline-interpreter forms; scripts are a separate tier-2 tool, confined | Executor security tests (literal `; rm -rf ~` argument, marker file intact) | A user-approved script can do what its confinement allows. |
| 5 | The agent retries an irreversible action | Non-idempotent tools are never auto-retried by the executor or the workflow engine; the agent runtime blocks an identical tier ≥ 2 call that already succeeded, and an identical call that failed twice; idempotency keys | `consequentialActionIsNotRepeatedAfterSuccess`, engine retry tests | A different-looking call with the same effect is a new approval. |
| 6 | The model claims success after a failure | Status comes from tool results and runtime-checked postconditions; the closing statement is stored as a claim; claimed artifacts are stat-ed and hashed | `inventedSuccessIsReportedAsFailure`, `claimedArtifactOutsideTheWorkspace…` | Runs with no declared postcondition rest on tool results only; the receipt says so. |
| 7 | A provider key appears in console output | Keys are registered with `Redactor` when loaded; patterns catch key-shaped strings; redaction applies to events, tool results returned to the model, receipts, audit entries | `secretsInToolOutputNeverReach…`, Core redaction tests, release secret scan | A secret of an unknown shape shorter than 8 characters is not detected. |
| 8 | Focus shifts before a click or keystroke | Accessibility actions re-resolve the element and verify the frontmost app immediately before acting; GUI tools are mutually exclusive; typing into secure fields is refused; emergency stop | Accessibility tool tests (gated on permission) | A focus change in the last milliseconds cannot be fully excluded; actions are tier 2. |
| 9 | A background workflow resumes after reboot with stale permission | Grants have expiry and revocation checked at every call; scheduled mode never auto-approves; a call interrupted mid-flight leads to `RECOVERY_REQUIRED`, not a re-run; revoke-all | Policy expiry tests, `crashDuringASideEffect…`, scheduler missed-run tests | A persistent grant stays valid until the user revokes it; the Permissions section lists them with age and last use. |
| 10 | A remote service returns hostile content seeking more privilege | Identical to 1–2: content is data; HTTP redirects to another host are not followed without a new policy decision | `http.request` redirect test, browser redirect test | — |

## Secrets

- Provider keys and user secrets live only in the login Keychain. The UI shows a masked form after entry.
- Tools take a secret **reference**; the executor resolves it at the last moment and registers the value for redaction.
- Memory refuses text that the redactor would alter. Exports contain no grants and no secrets.
- The development credential broker and `DevEnvironmentCredentials` exist only for Debug builds and tests.

## What the product does not do

- It does not run as root, install privileged helpers, or use `sudo`.
- It does not click through or script macOS privacy prompts.
- It does not read secure text fields, and refuses screen capture while Secure Event Input is active.
- It does not send screen captures or files to a model provider unless a run the user started includes that step.
- It has no telemetry. Nothing leaves the Mac except requests to the provider the user configured and hosts the user granted.

## Known gaps

Tracked in `docs/implementation-status.md` under "Security". Confinement relies on `sandbox-exec`; subresource
loads in the embedded browser are not host-filtered; static skill analysis is heuristic.
