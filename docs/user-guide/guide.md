<!--
ORIX OS Automation
File: docs/user-guide/guide.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# User guide

## Install and first run

1. Open the disk image and drag **ORIX OS Automation** to Applications. The app is signed with a Developer ID and
   notarized; macOS opens it without a warning.
2. The welcome guide offers five short steps, all skippable: how control works, a provider key, a workspace
   folder and default mode, macOS permissions, a first task.
3. Nothing is requested from macOS until you press a "Request" button or use a feature that needs it.

Requirements: macOS 15 or later. Built and tested on macOS 27 (Apple Silicon); the Intel slice is built but has
not been run.

## Providers and your keys (BYOK)

ORIX has no account and no server. You bring a key from Anthropic, OpenAI or OpenRouter.

- **Settings › Providers**: paste a key. It is written to the login Keychain of this Mac (service
  `ai.spboucher.orix.automation`) and never shown in full again; only a masked form such as `sk-…a1b2`.
- **Test connection** sends one minimal request (at most 8 output tokens) and shows the latency or the exact error.
- Choose a **default model**; optionally a planner model (used to draft workflows) and a verifier model (a second
  model that audits a finished run and can only lower its status).
- **Spending**: a daily limit and a per-run budget (turns, time, tokens, cost, tool calls). A run stops with
  `BUDGET_EXCEEDED` when it reaches a limit. When a provider reports no price for a model, the cost is shown as a
  lower bound ("≥") and the receipt says the cost limit could not be fully enforced.
- Requests go directly from this Mac to the provider you chose. Tool output is redacted for credential-shaped
  strings before it is sent back to a model. Screen content is sent only if you turned that on in Settings › Privacy.

OpenAI is used through the Chat Completions endpoint; models that exist only on the Responses API are not listed.

## How a task runs

You state an objective in **Agent**, pick the folder it works in and how much it may do there:

| Folder access | Effect |
|---|---|
| Ask every time | Every read and write asks |
| May read this folder | Reads inside it do not ask; writes do |
| May read and change this folder | Reads and reversible writes inside it do not ask |

| Mode | Behaviour |
|---|---|
| Quick | One task; asks for anything not already allowed |
| Guided | The agent must present a plan; nothing is changed until you approve it |
| Autonomous | Acts inside what is already allowed; still asks beyond that |
| Review | Read-only; tools that change things are unavailable or simulated |

When something needs your decision, an **approval card** shows a sentence written by the tool itself (not by the
model), the capability needed, the tier and the arguments with secrets hidden. You can allow once, for the rest of
the run, or (for low tiers) always. Tier 3 actions are allowed one call at a time and require typing APPROVE.

At the end, the **receipt** lists the checks the runtime performed itself (files exist, contain what was asked,
checksums), every tool call, approvals, artifacts and cost. The status comes from those checks. The agent's closing
statement is shown separately, labelled as a claim.

**Emergency stop** (toolbar, menu bar, ⌃⌥⌘.) cancels every run, kills every child process group and refuses every
pending approval.

## Workflows: three views of one document

A workflow is one validated document. **Agent** can draft it from a description, **Workflow Studio** edits it as a
graph, **Code Studio** edits its YAML or JSON. All three read and write the same stored source; the language is
described in [`docs/workflows/language-reference.md`](../workflows/language-reference.md), the built-in examples in
[`docs/workflows/examples.md`](../workflows/examples.md).

- A workflow **declares its permissions**. Before the first run you review them; accepting turns them into grants
  that apply to that workflow only. Changing the declared permissions in a later version withdraws the acceptance.
- **Dry run** executes nothing that changes state and reports what was simulated and what was not executed.
- **Debug** starts paused; you set breakpoints, step, and inspect variables.
- YAML comments are not kept when the canvas rewrites the source; the app tells you before it does.

## Permissions and privacy

Two layers decide what happens:

1. **macOS** decides what the app may do at all (Automation of each app, Accessibility, Screen Recording,
   Notifications, protected folders). Only you can grant these, in the system prompt or in System Settings. ORIX
   shows their status in **Permissions** and never tries to grant or bypass them.
2. **ORIX grants** decide what an agent or workflow may do: a specific folder, host, app, program or secret, at a
   maximum tier, for one call, one run, one workflow, or until revoked. Everything is denied unless a grant covers
   it. **Permissions** lists every grant; revoke one or all at any time.

Never available, whatever is granted: Keychains, `~/.ssh`, cloud credential folders, the TCC database, `/System`;
`sudo`; scripting macOS privacy prompts; reading secure text fields.

Data stays on this Mac in `~/Library/Application Support/ORIX Automation/`: the database, the audit log, run
artifacts, skills. There is no telemetry. The audit log is hash-chained; **Settings › Storage › Verify integrity**
detects an edited or removed entry.

## Scheduling and background operation

- Triggers: a cron schedule with a time zone, a one-time date, an interval, a change in a folder, login, an app
  launching, power connected, network available.
- Schedules run while the Mac is on and awake and either the app or the **background agent** is running. The
  background agent is optional (Settings › General); macOS lists it under Login Items and you can turn it off there.
- After sleep or a restart, each schedule's **missed-run policy** decides: skip, run once, or run up to N missed
  occurrences. ORIX never claims a run happened while the Mac was off.
- Daylight saving: a local time skipped in spring fires once at the first valid moment; a local time repeated in
  autumn fires once. Schedules that run every hour or more often keep their elapsed-time rhythm instead.
- A scheduled run has nobody to ask. Anything not covered by accepted permissions stops it as
  `WAITING_APPROVAL`; a notification tells you, and nothing is approved automatically.
- Steps that operate the screen (Accessibility, screen capture, browser windows) need an unlocked session.
  File, script and network steps do not.

## Automation notes by tool family

- **AppleScript and JXA** run out of process through `osascript`. A script must list the apps it addresses;
  one that addresses an unlisted app is refused before it runs. The first event to each app triggers the macOS
  Automation prompt. Scripts that shell out need the shell runtime as well and are tier 2.
- **Shell**: `shell.run` takes a program and an argument list — no shell, so nothing is interpolated. Inline
  interpreter forms (`bash -c`, `python -c`, …) are refused; use `shell.script`, which is tier 2 and sandboxed.
- **Python** uses a managed environment under the data folder, never the system installation. Packages are
  installed only as exact pins (`name==1.2.3`), as a separate consequential step.
- **Browser** tools drive ORIX's own WebKit view with a private, non-persistent store: no access to Safari's
  cookies or sessions. Navigation is limited to granted hosts, including redirects. Password fields can only be
  filled from a secret reference and their values are never read back. Subresources of a granted page are not
  host-filtered.
- **Accessibility** tools find elements by role and title, re-check the element and the frontmost app right
  before acting, and refuse secure fields. Apps with poor accessibility support may not be controllable.
- **Git**: status, diff, log, branches, commit, patch, push. Push needs approval; force push is tier 3. There are
  no reset, clean or rebase tools.

## Troubleshooting macOS permissions

| Symptom | Cause and fix |
|---|---|
| A step ends `BLOCKED_PERMISSION` naming Automation | You declined or never saw the prompt for that app. System Settings › Privacy & Security › Automation › ORIX OS Automation, enable the app. |
| Accessibility tools report "not trusted" | System Settings › Privacy & Security › Accessibility, enable ORIX OS Automation. If it is already on after an update, turn it off and on again. |
| Screen capture is refused | Privacy & Security › Screen & System Audio Recording. macOS may ask you to quit and reopen the app. Capture is also refused while a password field has secure input. |
| No notifications | System Settings › Notifications › ORIX OS Automation, and Settings › General in the app. |
| A folder cannot be read although a grant exists | macOS protects Desktop, Documents and Downloads separately: answer the system prompt, or enable the folder under Privacy & Security › Files and Folders. |
| The background agent does not start | System Settings › General › Login Items: allow ORIX OS Automation under "Allow in the Background". |
| The prompt never appears again | macOS remembers a refusal. Change it in System Settings; ORIX cannot reset it. |

## Backup, migration and recovery

- **Back up database** writes a consistent copy of the SQLite store. **Export workflows and settings** writes one
  JSON file with workflows (all versions) and settings; grants, run history and anything secret are never
  included, and credential-shaped strings are replaced.
- To move to another Mac: export, install the app there, import, then enter your provider keys again and review
  each workflow's permissions (grants do not travel).
- If the database file is damaged, ORIX sets it aside as `orix.sqlite.corrupt-<date>`, starts with an empty one
  and tells you. The damaged file is kept.
- A run interrupted by a crash or a forced quit is marked `RECOVERY_REQUIRED`. Opening it offers to continue
  from its last checkpoint. A step that was changing something when the app stopped is never repeated
  automatically: you choose whether the agent inspects and continues, or the run stays stopped.
- Uninstall: quit the app, turn off the background agent in Settings (or in Login Items), delete the app, and
  delete `~/Library/Application Support/ORIX Automation/` and the Keychain items of the service
  `ai.spboucher.orix.automation` if you want nothing left.
