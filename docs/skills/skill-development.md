<!--
ORIX OS Automation
File: docs/skills/skill-development.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Writing a skill

A skill is a small local program that becomes a tool named `skill.<name>`. It runs as a separate, confined
process. It can be written by you, imported from a folder, or proposed by an agent; in every case it is first a
**draft** that is analysed and tested, and it is installed only after you approve it.

## Package

```
my-skill/
├── skill.json      manifest
└── main.py         entry file (Python or Bash)
```

`skill.json`:

```json
{
  "id": "skill.wordCount",
  "name": "Word count",
  "version": "1.0.0",
  "summary": "Counts the words and lines of a text file.",
  "runtime": "python",
  "entry": "main.py",
  "inputSchema": { "type": "object", "properties": { "path": { "type": "string" } }, "required": ["path"], "additionalProperties": false },
  "outputSchema": { "type": "object", "properties": { "words": { "type": "integer" }, "lines": { "type": "integer" } }, "required": ["words", "lines"] },
  "permissions": { "fileRead": ["$input.path"], "fileWrite": [], "network": [] },
  "timeoutSeconds": 30,
  "author": "you",
  "tests": [
    { "name": "three words", "input": { "path": "$fixture/a.txt" }, "files": { "a.txt": "one two three\n" }, "expectOutput": { "words": 3, "lines": 1 } }
  ],
  "checksums": { "main.py": "<sha-256 of the file>" }
}
```

- `id` must be `skill.` followed by a camelCase name. A skill cannot take the name of a built-in tool.
- `version` is `major.minor.patch`. Installed content under a version number can never change; raise the version.
- `runtime` is `python` (the system `python3`, standard library, isolated mode) or `bash`.
- `checksums` lists every file except `skill.json`. A file that is missing, extra or different makes the package
  invalid. Symbolic links are refused. (Drafts created in the app or by an agent get their checksums computed for you.)

## Protocol

The process receives the input object as JSON on standard input and prints one JSON object on standard output.
A non-zero exit status is a failure; standard error is kept for the error message. The environment contains
`ORIX_SKILL_ID` and `ORIX_ARTIFACTS_DIR` (a folder the skill may always write to).

```python
import json, sys
data = json.load(sys.stdin)
text = open(data["path"], encoding="utf-8").read()
print(json.dumps({"words": len(text.split()), "lines": text.count("\n")}))
```

## Permissions

| Entry | Meaning |
|---|---|
| `fileRead`, `fileWrite` | Absolute paths, `~/…` paths, or `$input.<field>`: the path the caller passes in that input field |
| `network` | Host names. Empty means the process runs with networking denied |

The tier is derived, not chosen: no write and no network → tier 0; a write location → tier 1; a network host →
tier 2. Protected locations (Keychains, `~/.ssh`, …) are refused in the manifest.

Each call needs the `skill` capability for that skill, the script runtime, and the concrete paths and hosts
resolved from its arguments. Declaring a permission does not grant it: the policy engine still decides per call.

At run time the Seatbelt profile allows writes only to the resolved write paths and the artifacts folder, and
network only when hosts are declared. Reads are limited by policy on the declared paths and by the profile's
denial of credential stores; the profile does not otherwise restrict reads.

## Tests

Every skill needs at least one test. Each test runs in a fresh scratch folder containing its `files`; `$fixture`
in the input is replaced by that folder. Tests always run with networking denied and may only touch their scratch
folder. A test passes when the status, every `expectOutput` path and every `expectFiles` entry match.

## Review, install, roll back

1. **Propose**: Skills › New skill, Skills › Import, the Code Studio "Save as skill", or an agent calling
   `skills.propose`. The draft is analysed and its tests are run.
2. **Review** the draft in Skills: source, requested permissions, findings, test results.
3. **Install** (the user's action; an agent calling `skills.install` triggers an approval that shows the same
   summary). Drafts with a blocking finding, a failing test or no test cannot be installed.
4. Installed versions are kept. **Roll back** makes the previous version current; **Disable** removes the tool
   without deleting it; **Uninstall** deletes it.

Before every run the package is re-verified against its checksums. A skill that changed on disk does not run.

## Security review checklist

- [ ] The summary says what the skill does, and the source does only that.
- [ ] Every path the source touches comes from a declared permission; none is built from unrelated input.
- [ ] No network use unless hosts are declared, and the hosts are the ones you expect.
- [ ] No `eval`, `exec`, dynamic import or decoding of embedded code.
- [ ] No reference to credential stores, `sudo`, `osascript`, `launchctl` or other system control.
- [ ] Subprocess use is explained by the task and takes an argument list, not a shell string.
- [ ] Input from files or the caller is treated as data (no shell interpolation, no path concatenation without checks).
- [ ] The tests cover the failure cases you care about, not just the happy path.
- [ ] The output schema matches what the code prints.

The analyser checks several of these mechanically and reports findings as `info`, `warning` or `blocker`. It is
a reading aid: it can be evaded by code written to evade it. The sandbox and the policy engine are what bound a
skill, which is why undeclared writes and network use fail at run time even when the analyser misses them.
