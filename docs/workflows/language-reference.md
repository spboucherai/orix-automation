<!--
ORIX OS Automation
File: docs/workflows/language-reference.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Workflow language reference

This document describes what `Packages/ORIXWorkflowEngine` implements, nothing more. The same model (`WorkflowDocument`)
backs the agent, visual and code views; the text form below is what the code view edits and what `WorkflowCodec.emit` writes.

- Schema of the canonical form: `Workflows/Schemas/automation.v1.schema.json` (`WorkflowSchema.automationV1()`). It uses no
  `$ref`: nested steps are described to 2 container levels (1 under `spec.onError`); deeper steps are accepted as any object.
- Examples: `Workflows/Examples/*.yaml` (also shipped as package resources, `BuiltInWorkflows.all()`).

## 1. Document

```yaml
apiVersion: orix.ai/v1          # required value
kind: Automation                # required value
metadata:
  id: weekly-report             # [A-Za-z_][A-Za-z0-9_-]*; defaults to a slug of `name`
  name: Weekly report
  description: …
  tags: [reports]
spec:
  triggers: […]                 # optional; `trigger:` (one mapping or a list) is accepted and normalised
  parameters: […]
  permissions: {…}
  budget: {…}
  variables: {…}
  steps: […]
  onError: […]                  # workflow-level handler steps
  layout: {stepId: {x: 0, y: 0}}
```

Unknown fields are errors (`unknown-field`), with line and column.

### Triggers

| `type` | Fields | Notes |
|---|---|---|
| `manual` | — | may be written as the bare string `manual` |
| `schedule` | `cron`, `timezone?` | five-field cron; IANA time zone |
| `once` | `at` | ISO 8601 date-time |
| `interval` | `seconds` | > 0 |
| `fileChange` | `path`, `glob?`, `debounceSeconds?` | absolute or `~/` path |
| `login` | — | may be written as the bare string `login` |
| `appLaunch` | `bundleID` | |

The engine does not fire triggers (that is `ORIXScheduler`); it validates them and carries them in the model.

### Parameters

`name` (`[A-Za-z_][A-Za-z0-9_]*`), `type` (`string`, `number`, `integer`, `boolean`, `path`, `array`, `object`; default
`string`), `default?`, `description?`, `required?`. At run time supplied values are type-checked, unknown names are
refused, defaults are interpolated (they may read earlier parameters and `env`), and a missing required parameter fails
the run before anything executes. Parameters are read as `params.<name>`.

### Permissions

```yaml
permissions:
  filesystem: {read: [paths], write: [paths], delete: [paths]}
  processes: [git]                         # executables
  scripts: [bash, python]                  # bash python swift javascript applescript jxa (`runtimes:` accepted)
  apps: {automation: [bundle ids], accessibility: [bundle ids], control: [bundle ids]}
  network: [api.example.com, "*.example.org"]   # hosts only (`{hosts: […]}` accepted)
  browser: [localhost]
  secrets: [smtp-password]                 # Keychain reference names
  clipboard: {read: true, write: true}     # `clipboard: true` accepted
  notifications: true
  screen: [display, "window:com.apple.Safari"]   # `screen: true` accepted (= [display])
```

Paths must be absolute or start with `~/`; `~user` and relative paths are errors. An entry may contain
`${{ params.<name> }}` and nothing else from the expression language (permissions cannot depend on run-time values).
`doc.declaredCapabilities(home:parameters:)` expands `~` against the given home, substitutes parameters (defaults when not
supplied), canonicalises paths with `PathResolver` and returns Core `Capability` values; unresolvable entries are left
out. `doc.proposedGrants(workflowID:)` turns them into `PermissionGrant`s of scope `.workflow` with a maximum tier of 0
(file read, clipboard read, screen capture), 1 (file write, move to Trash, clipboard write, notifications) or 2
(everything else). Tier 3 is never proposed. Declaring a permission grants nothing by itself: the policy engine decides.

### Budget

`maxDurationSeconds`, `maxProviderCostUSD`, `maxToolCalls`, `maxTokens` (all optional). See §6 for enforcement.

## 2. Steps

Every step has `id` (unique in the whole document, nested steps included; `[A-Za-z_][A-Za-z0-9_-]*`) and exactly one
kind key. Common fields:

| Field | Meaning |
|---|---|
| `name` | display name |
| `needs: [ids]` | steps of the **same list** that must finish first. Must form a DAG |
| `when` | expression; falsy → the step is skipped |
| `retry: {maxAttempts, backoffSeconds, backoffMultiplier, force}` | `retry: 3` is shorthand for `maxAttempts: 3` |
| `timeoutSeconds` | real-time limit for one attempt |
| `continueOnError` | a failure does not stop the list |
| `onError: <id>` | step of the same list that handles the failure |

**Scheduling.** A step list is a dependency graph, not a script: every step whose `needs` are satisfied starts at once,
so steps without `needs` run concurrently. Order steps with `needs`.

| Kind key | Other fields | Behaviour and output (`steps.<id>.output`) |
|---|---|---|
| `tool: <tool id>` | `with: {…}` | invokes the tool through `ToolInvoking`; output = the tool's output |
| `agent: <profile>` or `agent: {instructions, model?, tools?}` | `objective`, `inputs`, `expect` | runs an agent through `AgentRunning`; output `{text, result, status}`. `model` is `provider/model`; inline `tools` defaults to none |
| `if: <expr>` | `then: [ids]`, `else: [ids]` | output `{result, branch}`; listed steps of the same list run only on their branch |
| `switch: <expr>` | `cases: [{value, steps: [ids]}]`, `default: [ids]` | first case whose value equals the expression; output `{value, matched, steps}` |
| `foreach: <expr or list>` | `as` (default `item`), `concurrency` (default 1), `collect?`, `steps` | runs the body once per item, `index` available; output `{results, count}`; a result is the output of the `collect` step or an object of all body outputs |
| `parallel: [{name, steps}]` | — | branches run concurrently, implicit join; output `{<branch>: {<step id>: output}}` |
| `while: <expr>` | `maxIterations` (required, ≥ 1), `steps` | condition checked before each iteration; `loop.index` available; body steps and the condition see the previous iteration's body results; output `{iterations, exhausted}` |
| `approval: <message>` | — | manual gate; output `{approved: true}` |
| `delay: <seconds or expr>` | — | waits |
| `set: {name: value}` | — | assigns workflow variables; output = the assigned values |
| `transform: <expr>` | `into?` | output = the value; `into` also stores it in a variable |
| `verify: [assertions]` | — | output `{passed, failed}`; any failed assertion fails the step |
| `subworkflow: <id or name>` | `inputs` | runs another workflow inline; output = its outputs |
| `notify: <message>` | `title?` | calls the tool `notifications.post` with `{title, body}` |
| `fail: <message>` | — | fails explicitly |
| `output: {name: value}` | `artifacts: [paths]` | declares workflow outputs and artifact files |

Shorthand accepted from the product brief and normalised: `verifier: <name>` becomes a `verify` step asserting
`stepSucceeded` for each of its `needs` (the verifier name is not kept).

### Assertions (`verify`, and `expect` of agent steps)

`fileExists: path`, `fileNonEmpty: path`, `fileContains: path` + `text:`, `dirNonEmpty: path`, `equals: [a, b]`,
`truthy: <expr or value>`, `stepSucceeded: <id>`. Agent `expect` accepts only the four file assertions (they are passed to
the agent runtime as Core `Expectation`s).

File assertions are evaluated by the engine against the real filesystem. A path is inspected only when it lies under the
workflow's declared `filesystem` permissions or the run's artifacts directory, and never when `PathResolver.isProtected`;
otherwise the assertion fails with that reason as evidence. `fileContains` reads at most 16 MiB.

### Errors

- A step that fails without `continueOnError` or `onError` stops its list: nothing new starts there, steps already running
  finish, and the failure becomes the failure of the enclosing container (which may itself have `continueOnError` /
  `onError`) or of the run.
- `continueOnError: true`: dependents run and can read `steps.<id>.status` / `.error`.
- `onError: h`: `h` is a **handler-only** step (it never runs in the normal flow, must not have `needs`, must not be in a
  branch list). It runs with `error = {stepID, message, status, code}`. If it succeeds the failure counts as handled
  (dependents run); if it fails the original failure stands.
- `spec.onError` steps run after the workflow failed (not after cancel, timeout or budget stop), with the same `error`
  value and read access to top-level step results. They do not change the final status.
- Skips propagate: a step whose `needs` was skipped, or whose condition/switch did not select it, is skipped.

### Retries

A step is retried only when `retry.maxAttempts > 1`, the attempt ended `failed` or `timedOut` with a retryable cause,
**and** the step is idempotent (tool manifest `idempotent: true`; pure steps such as `verify`) or `retry.force: true`.
Otherwise a `retry` event says the step was not retried and why. Agents, `notify` (unless the manifest says otherwise) and
containers count as not idempotent. Delay before attempt *n+1* = `backoffSeconds × backoffMultiplier^(n−1)`, no jitter.

## 3. Expressions

Used in `when`, `if`, `while`, `switch`, `foreach`, `delay`, `transform`, `truthy` (the whole text is an expression, with
or without `${{ }}`) and, as `${{ … }}` interpolations, in every string of `with`, `inputs`, `set`, `output`, messages,
paths and case values.

- A string that is exactly one `${{ … }}` yields the typed value; otherwise the results are concatenated into a string.
- `$${{` writes a literal `${{`.
- Interpolation is single-pass: text produced by an expression is data and is never scanned again.

```
expr     := or
or       := and ("||" and)*
and      := equality ("&&" equality)*
equality := compare (("==" | "!=") compare)*
compare  := sum (("<" | "<=" | ">" | ">=") sum)*
sum      := product (("+" | "-") product)*
product  := unary (("*" | "/" | "%") unary)*
unary    := ("!" | "-") unary | postfix
postfix  := primary ("." name | "[" expr "]")*
primary  := number | string | "true" | "false" | "null" | name | name "(" args ")" | "(" expr ")" | "[" exprs "]"
arg      := expr | name "=>" expr | "(" name ("," name)* ")" "=>" expr
```

Strings use single or double quotes with `\n \t \r \0 \\ \' \" \/ \uXXXX`. Lambdas exist only as function arguments.
There is no assignment, no statement, no object literal and no call on a value.

**Names.** `params.x`, `vars.x`, `steps.<id>.output…`, `steps.<id>.status`, `steps.<id>.error`, `steps.<id>.attempts`,
`env.<NAME>` with NAME in `HOME USER TMPDIR DATE TIME DATETIME TIMESTAMP` (date values are fixed at run start), and the
loop variables in scope: the `as` name and `index` in `foreach`, `loop.index` in `while`, `error` in handlers. After
`steps.` a name may contain dashes (`steps.fetch-data.output`); put spaces around a binary minus there.

**Semantics.** Missing properties and out-of-range indexes are `null`; unknown steps, parameters, `env` names and bare
names are errors. `+` adds numbers, concatenates lists, and concatenates as text when either side is a string. Integer
arithmetic stays integral and falls back to floating point on overflow; `/` yields an integer only when exact; division
by zero is an error. `==` compares structurally (`1 == 1.0`). `<` etc. compare numbers or strings. `&&`/`||`
short-circuit and return booleans. Truthiness: `null`, `false`, `0`, `""`, `[]`, `{}` are falsy.

**Functions.**

| Function | Result |
|---|---|
| `len(x)` | length of a string, list or object (`null` → 0) |
| `contains(x, y)` | substring, list member or object key |
| `startsWith(s, p)`, `endsWith(s, p)`, `lower(s)`, `upper(s)`, `trim(s)` | strings |
| `split(s, sep)`, `join(list, sep = ",")`, `replace(s, a, b)` | |
| `basename(p)`, `dirname(p)`, `extname(p)` (with the dot), `joinPath(a, b, …)` | lexical path helpers |
| `toJSON(v)`, `fromJSON(s)`, `number(v)`, `string(v)` | conversions |
| `default(a, b, …)` | first non-null |
| `keys(o)`, `values(o)` | sorted by key |
| `map(list, f)`, `filter(list, f)`, `count(list, f?)`, `sum(list, f?)` | `f` is `x => …`, `(x, i) => …` or a property path string |
| `reduce(list, (acc, x) => …, initial)` | |
| `first(list)`, `last(list)`, `slice(x, start, end?)` | negative indexes count from the end |
| `now()` | ISO 8601 UTC |
| `formatDate(value, pattern, timezone?)` | value = ISO 8601 string or Unix seconds; `DateFormatter` pattern |
| `secret("ref")` | the placeholder object `{"$secret": "ref"}` — never a value. The argument must be a literal |

**Bounds.** Source ≤ 16 384 characters, nesting ≤ 64, ≤ 256 chained operators, ≤ 200 000 evaluation steps, strings ≤ 1 MiB, lists ≤ 100 000
elements. An evaluation error fails the step (`errorCode: expression`) and is reported in `WorkflowOutcome.diagnostics`
with the step id.

## 4. YAML subset

`WorkflowCodec.parse` reads this subset (JSON is inside it and goes through the same parser, so both report positions):

- Block mappings and block sequences, including `- key: value` compact items and sequences at the indentation of their key.
- Flow sequences and mappings (`[a, b]`, `{a: 1}`), nested, possibly over several lines, with quoted keys.
- Plain, single-quoted (`''` escape) and double-quoted scalars (`\0 \a \b \t \n \v \f \r \e \" \/ \\ \N \_ \L \P \xXX
  \uXXXX \UXXXXXXXX`, surrogate pairs). Quoted scalars must end on the line where they start.
- Literal `|` and folded `>` block scalars with `-`/`+` chomping and an optional indentation digit.
- Comments (`# …` at the start of a line or after a space), blank lines, CRLF, one leading `---`.
- Plain scalar typing: `null`/`Null`/`NULL`/`~`/empty → null; `true`/`false` (three spellings) → booleans; decimal
  integers; decimals and exponents → numbers; `.inf`, `-.inf`, `.nan`. Everything else is a string: `yes`, `no`, `on`,
  `off`, `0x1F` and numbers with leading zeros (`007`) are strings. Mapping keys are always strings.

Rejected with a positioned error: anchors and aliases (`&`, `*`), tags (`!`), merge keys (`<<`), several documents or
`...`, directives (`%YAML`), complex keys (`? `), tabs in indentation, multi-line plain or quoted scalars, duplicate keys,
single-pair mappings inside flow sequences, plain scalars starting with `@`, `` ` `` or `%`.

### Canonical emission

`WorkflowCodec.emit` is deterministic: fixed key order (the order of this document), two-space indentation, defaults
omitted, free-form objects (`with`, `variables`, …) sorted by key, lists of scalars in flow style when they fit in 80
characters, strings unquoted when that is unambiguous and double-quoted otherwise, multi-line text as `|` / `|-` blocks
when it can be read back exactly. `parse(emit(doc)) == doc` for every document and `emit(parse(text))` is idempotent
(property-tested). JSON emission uses the same key order; non-finite numbers become `null` there.

The model does not keep comments or formatting. `WorkflowCodec.roundTripLoss(source:)` lists what rewriting the text from
the model would drop — comments (with lines), a leading `---`, shorthand forms that get normalised, non-canonical
formatting — so the UI can warn before a visual edit rewrites the code.

## 5. Diagnostics

`WorkflowDiagnostic {severity, code, message, line, column, stepID?, path}`. Parser and decoder diagnostics carry
positions; validator diagnostics carry a document path (`spec.steps[2].with.path`) that `WorkflowCodec.locate` or
`WorkflowCodec.diagnose` turns into a position.

| Code | Severity | Meaning |
|---|---|---|
| `syntax` | error | YAML/JSON syntax |
| `type-mismatch`, `missing-field`, `unknown-field`, `conflicting-fields`, `invalid-value` | error | structure |
| `invalid-step-kind`, `invalid-assertion` | error | zero or several kind keys; malformed assertion |
| `unsupported-version`, `unsupported-kind` | error | |
| `invalid-id`, `duplicate-id`, `duplicate-parameter`, `duplicate-branch` | error | identifiers |
| `self-need`, `unknown-need`, `unknown-branch-step`, `dependency-cycle` | error | graph; the cycle path is reported |
| `unknown-tool`, `invalid-argument` | error | tool id; literal `with` values against the tool's `inputSchema` |
| `unknown-agent`, `invalid-model`, `unknown-workflow`, `recursive-subworkflow` | error | |
| `expression-syntax`, `unknown-function`, `unknown-name`, `env-not-allowed`, `missing-parameter` | error | expressions |
| `unknown-step-reference`, `step-not-upstream` | error | `steps.x` must be upstream (through `needs`, a gate, the container, or the previous loop iteration) |
| `unbounded-loop` | error / warning | `maxIterations` missing or < 1; constant condition or huge bound |
| `invalid-cron`, `invalid-timezone`, `invalid-trigger` | error | |
| `parameter-default-type` | error | |
| `invalid-permission-path`, `invalid-permission-host`, `invalid-permission-expression` | error | |
| `invalid-handler` | error / warning | bad `onError` target |
| `invalid-budget` | error | non-positive limits |
| `unreachable-step` | error / warning | needs a handler-only step; comes after an unconditional `fail`; constant condition |
| `permission-missing` | warning | a literal path, host, executable, runtime, app, secret or notification is not covered by `permissions` |
| `broad-permission` | warning | `/`, `~` or `*` |
| `retry-not-idempotent` | warning | the declared retry will not happen |
| `unset-variable`, `missing-objective`, `empty-workflow`, `empty-body`, `empty-branches`, `empty-verify`, `ambiguous-branch`, `duplicate-case`, `stale-layout` | warning | |
| `budget-missing-cost-limit`, `budget-timeout-exceeds-duration`, `budget-too-small` | warning | |
| `budget-unused`, `parameter-required-default` | info | |

Permission sufficiency is a static, best-effort check on literal arguments (and `${{ params.x }}` substituted by its
default); the policy engine remains the authority at run time.

## 6. Execution

`WorkflowEngine` (actor) runs a document with injected `ToolInvoking`, `AgentRunning`, `RunEventSink`,
`WorkflowCheckpointStoring`, `SubworkflowLoading`, approval handler, agent-profile resolver and `WorkflowClock`.

- **Concurrency.** Independent steps really run in parallel. `maxConcurrentSteps` (default 4) bounds leaf steps (tool
  calls, agents) across all nesting levels; `foreach.concurrency` bounds iterations.
- **Timeouts** use real time and cancel the running attempt. `delay`, retry backoff, timestamps and the between-steps
  duration check use the injected clock.
- **Budget.** `maxToolCalls` is checked before each tool call; cost and tokens are taken from agent outcomes;
  `maxDurationSeconds` is enforced by a watchdog and before each step. An agent receives what is left of the workflow
  budget. Tool calls and cost stop the run with `BUDGET_EXCEEDED`; duration with `TIMED_OUT`.
- **Approval.** An `approval` step asks the injected handler: approved → continue; denied → the step fails; unanswered
  (or no handler) → `WAITING_APPROVAL`, resumable from the checkpoint.
- **Dry run** (`options.dryRun`). A tool whose manifest has `supportsDryRun` is invoked with `dryRun: true`; any other tool
  is **not executed** and reported as `simulated: not executed`. Agents are not run, approvals not requested, delays not
  waited, `verify` not evaluated, a `while` body walked at most once, a `foreach` over unknown items not entered. Pure
  steps (`set`, `transform`, `if`, `switch`, `output`) are evaluated. `WorkflowOutcome.simulations` lists one line per
  simulated step; the status says how the simulation went, not how a real run would.
- **Cancellation** cancels the run's task tree (tools and agents see task cancellation) and releases every waiter.
- **Debugger.** `WorkflowRun.pause()`, `resume()`, `stepOver()`, `cancel()`, `setBreakpoints(_:)`, `variables()`,
  `setVariable(_:to:)`, `inspect(_:)`, `state`, `states()`. A paused run holds steps before they start; running steps
  finish. `stepOver` releases one waiting step.
- **Checkpoints** are saved when a step starts and when it finishes (a `checkpoint` event follows each finish).
  `resume(from:)` does not run completed steps again, re-enters containers where they stopped (`foreach` items and the
  `while` iteration are stored), re-runs a step that was mid-flight only if it is idempotent, and otherwise ends at once
  with `RECOVERY_REQUIRED` until the caller supplies `inFlightResolutions` (`.rerun` or `.markSucceeded(output:)`).
- **Subworkflows** run inline with their own parameters, variables and step namespace; nesting is limited by
  `maxSubworkflowDepth` (default 8).
- **Events.** `statusChanged`, `stepStarted`, `stepFinished`, `retry`, `verification`, `checkpoint`,
  `approvalRequested`/`approvalResolved`, `usage`, `log`, all with `stepID` where one applies.

### Final status

| Situation | `RunStatus` |
|---|---|
| every step succeeded or was skipped, every executed `verify` passed | `SUCCEEDED` |
| some step failed but was continued (`continueOnError`) or handled (`onError`) | `PARTIALLY_SUCCEEDED` |
| unhandled failure (tool `failed`, `denied`, `invalidInput`, `unsupported`; failed `verify`; `fail`; denied approval) | `FAILED` |
| tool `notApproved`, or unanswered approval step | `WAITING_APPROVAL` |
| tool `blockedPermission` | `BLOCKED_PERMISSION` |
| unhandled step timeout, or `maxDurationSeconds` exceeded | `TIMED_OUT` |
| `maxToolCalls`, `maxProviderCostUSD` or `maxTokens` exceeded | `BUDGET_EXCEEDED` |
| `cancel()` | `CANCELED` |
| non-idempotent step was mid-flight in the resumed checkpoint | `RECOVERY_REQUIRED` |

Step instance keys identify repeated steps: `each[2]/copy` (foreach), `par(left)/a` (parallel), `poll#3/check` (while),
`call>/inner` (subworkflow), `!onError/alert` (workflow-level handler).

## 7. Graph projection, edits and diff

`WorkflowGraph(document:)` derives nodes and edges for the visual editor.

- Node ids are step ids; triggers are `trigger:<index>`. Categories: `tool`, `agent`, `parallelism` (`parallel`), `logic`
  (`condition`, `switch`, `foreach`, `loop`, `transform`, `subworkflow`), `data` (`set`, `verify`), `control`
  (`approval`, `delay`, `fail`), `output` (`notify`, `output`), `error` (any `onError` target and every `spec.onError`
  step), `trigger`.
- Ports: `in`; `out`; `then`/`else`; `case:<i>`/`default`; `body` for containers; `error` when the step has `onError`.
- Edges: `dependency` (`needs`), `branch` (labelled), `error`, `trigger` (to root steps without `needs` that are neither
  gated nor handlers). Container membership is `parentID` + `branch`.
- Positions come from `spec.layout` when present, else from a deterministic layered layout
  (`WorkflowGraph.autoLayout`): layer = longest path inside the list, rows in document order, nested steps relative to
  their container, triggers in a column at negative x.

`WorkflowEdit` operations return a new document or throw `WorkflowEditError`; none returns a structurally invalid
document: `addStep`, `removeStep`, `renameStep`, `connect`, `disconnect`, `moveNode`, `updateStep`, `setField`,
`duplicateStep`, `groupIntoParallel`, `wrapInForeach`, `reorder`.

- `renameStep` rewrites `needs`, branch lists, `onError`, `collect`, `stepSucceeded`, the layout key and
  `steps.<old>` / `steps["old"]` references in every expression.
- `removeStep` removes structural references; expressions that still read the step are left for the validator.
- `groupIntoParallel` / `wrapInForeach` move steps into a container; expressions outside that read a moved step become
  `step-not-upstream` errors (read the container's output instead).
- Every edit round-trips through the code view (`parse(emit(doc)) == doc`, property-tested over random edit sequences).

`WorkflowDiff.diff(old, new)` returns `WorkflowChange`s (steps matched by id; added, removed, modified with field names,
moved; metadata, triggers, parameters, permissions, budget, variables, `onError`, layout). `permissionsChanged` is the
change flagged `isSecurityRelevant`.

## 8. Limitations

- Triggers are data here; firing them is the scheduler's job.
- Step timeouts wait for the running tool to honour cancellation before the step is reported.
- The static permission check knows the argument names of the canonical tools only (`path`, `source`, `destination`,
  `paths`, `url`, `args`, `bundleID`, `cwd`).
- A subworkflow's own `permissions` and `budget` are not enforced separately: the calling run's budget and the policy
  engine apply.
- On resume the duration budget restarts from zero.
- Checkpoints hold the full result set; very large `foreach` runs make each save proportionally larger.
