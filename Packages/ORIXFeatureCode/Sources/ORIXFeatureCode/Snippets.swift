// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/Snippets.swift
// Description      : Workflow snippets (one step skeleton per step kind, common
//                    patterns, a starter document) and script templates per
//                    workbench language.
// Module           : ORIXFeatureCode
// Repository       : https://git.spboucher.ai/orix-automation
// Created          : 2026-11-21
// Last Modified    : 2026-11-21
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : Proprietary, all rights reserved (see license file)
// License File     : LICENSE
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

import Foundation
import ORIXAppUI

public struct Snippet: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var body: String
}

public enum WorkflowSnippets {
    /// A small valid document for "New workflow".
    public static let starter = """
    apiVersion: orix.ai/v1
    kind: Automation
    metadata:
      id: new-workflow
      name: New workflow
      description: Lists a folder and checks the result.
    spec:
      triggers:
        - type: manual
      parameters:
        - name: folder
          type: path
          default: ~/Documents
          description: Folder to inspect.
      permissions:
        filesystem:
          read: ["${{ params.folder }}"]
      steps:
        - id: list
          tool: filesystem.list
          with:
            path: ${{ params.folder }}
        - id: check
          needs: [list]
          verify:
            - truthy: ${{ steps.list.status == "succeeded" }}

    """

    /// One skeleton per step kind, each a list item ready to sit in a `steps:` list.
    public static var stepKinds: [Snippet] {
        [
            Snippet(id: "tool", title: String(localized: "Tool step"), body: "- id: listFiles\n  tool: filesystem.list\n  with:\n    path: ~/Documents"),
            Snippet(id: "agent", title: String(localized: "Agent step"), body: "- id: summarize\n  agent: general\n  objective: Summarise what the earlier steps found.\n  inputs:\n    notes: \"\""),
            Snippet(id: "if", title: String(localized: "Condition (if / then / else)"),
                    body: "- id: decide\n  if: ${{ len(params.folder) > 0 }}\n  then: [whenTrue]\n  else: [whenFalse]\n- id: whenTrue\n  set:\n    branch: yes\n- id: whenFalse\n  set:\n    branch: no"),
            Snippet(id: "switch", title: String(localized: "Switch"),
                    body: "- id: route\n  switch: ${{ params.kind }}\n  cases:\n    - value: report\n      steps: [makeReport]\n  default: [fallback]\n- id: makeReport\n  set:\n    route: report\n- id: fallback\n  set:\n    route: other"),
            Snippet(id: "foreach", title: String(localized: "For each"),
                    body: "- id: each\n  foreach: ${{ steps.listFiles.output }}\n  as: file\n  concurrency: 1\n  collect: inspect\n  steps:\n    - id: inspect\n      tool: filesystem.metadata\n      with:\n        path: ${{ file.path }}"),
            Snippet(id: "parallel", title: String(localized: "Parallel branches"),
                    body: "- id: both\n  parallel:\n    - name: first\n      steps:\n        - id: firstTask\n          tool: system.info\n    - name: second\n      steps:\n        - id: secondTask\n          tool: system.diskUsage"),
            Snippet(id: "while", title: String(localized: "While loop"),
                    body: "- id: poll\n  while: ${{ loop.index < 3 }}\n  maxIterations: 3\n  steps:\n    - id: wait\n      delay: 5"),
            Snippet(id: "approval", title: String(localized: "Approval gate"), body: "- id: confirm\n  approval: Continue with the changes described above?"),
            Snippet(id: "delay", title: String(localized: "Delay"), body: "- id: pause\n  delay: 5"),
            Snippet(id: "set", title: String(localized: "Set variables"), body: "- id: prepare\n  set:\n    target: ~/Documents/Reports"),
            Snippet(id: "transform", title: String(localized: "Transform"), body: "- id: compute\n  transform: ${{ upper(\"value\") }}\n  into: result"),
            Snippet(id: "verify", title: String(localized: "Verify"), body: "- id: check\n  verify:\n    - fileNonEmpty: ~/Documents/Reports/report.md"),
            Snippet(id: "subworkflow", title: String(localized: "Subworkflow"), body: "- id: call\n  subworkflow: other-workflow-id\n  inputs:\n    folder: ~/Documents"),
            Snippet(id: "notify", title: String(localized: "Notification"), body: "- id: announce\n  notify: The workflow finished.\n  title: ORIX\n  continueOnError: true"),
            Snippet(id: "fail", title: String(localized: "Fail"), body: "- id: stop\n  fail: Nothing to process."),
            Snippet(id: "output", title: String(localized: "Output"), body: "- id: result\n  output:\n    report: ~/Documents/Reports/report.md\n  artifacts:\n    - ~/Documents/Reports/report.md"),
        ]
    }

    public static var patterns: [Snippet] {
        [
            Snippet(id: "foreach-files", title: String(localized: "For each file in a folder"),
                    body: "- id: files\n  tool: filesystem.list\n  with:\n    path: ~/Documents\n- id: perFile\n  needs: [files]\n  foreach: ${{ steps.files.output }}\n  as: file\n  collect: info\n  steps:\n    - id: info\n      tool: filesystem.metadata\n      with:\n        path: ${{ file.path }}"),
            Snippet(id: "approval-gate", title: String(localized: "Approval before a change"),
                    body: "- id: review\n  approval: Move the listed files to the Trash?\n- id: apply\n  needs: [review]\n  tool: filesystem.trash\n  with:\n    path: ~/Documents/Old"),
            Snippet(id: "verify-block", title: String(localized: "Verify the files that must exist"),
                    body: "- id: verifyResult\n  verify:\n    - fileExists: ~/Documents/Reports/report.md\n    - fileNonEmpty: ~/Documents/Reports/report.md\n    - fileContains: ~/Documents/Reports/report.md\n      text: Summary"),
            Snippet(id: "retry", title: String(localized: "Retry with backoff"),
                    body: "- id: fetch\n  tool: http.request\n  with:\n    url: https://example.com/data.json\n  retry:\n    maxAttempts: 3\n    backoffSeconds: 2\n    backoffMultiplier: 2\n  timeoutSeconds: 30"),
            Snippet(id: "error-handler", title: String(localized: "Handle a failure"),
                    body: "- id: risky\n  tool: filesystem.read\n  with:\n    path: ~/Documents/input.txt\n  onError: recover\n- id: recover\n  notify: Reading the input failed, ${{ error.message }}\n  title: ORIX"),
        ]
    }
}

/// Languages of the script workbench, each bound to the tool that runs it.
public enum WorkbenchLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case bash, python, applescript, jxa, swift, javascript
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bash: return "Bash"
        case .python: return "Python"
        case .applescript: return "AppleScript"
        case .jxa: return "JXA"
        case .swift: return "Swift"
        case .javascript: return "JavaScript"
        }
    }

    public var codeLanguage: CodeLanguage {
        switch self {
        case .bash: return .bash
        case .python: return .python
        case .applescript: return .applescript
        case .jxa, .javascript: return .javascript
        case .swift: return .swift
        }
    }

    public var toolID: String {
        switch self {
        case .bash: return "shell.script"
        case .python: return "python.run"
        case .applescript: return "applescript.run"
        case .jxa: return "jxa.run"
        case .swift: return "script.swift"
        case .javascript: return "script.javascript"
        }
    }

    /// The skill runtime this language can be packaged as, when skills support it.
    public var skillRuntime: String? {
        switch self {
        case .python: return "python"
        case .bash: return "bash"
        default: return nil
        }
    }

    public var usesTargets: Bool { self == .applescript || self == .jxa }

    /// Arguments of the tool call that runs `script`.
    public func arguments(script: String, workingDirectory: String, timeoutSeconds: Double, targets: [String]) -> JSONValue {
        switch self {
        case .python: return ["code": .string(script), "cwd": .string(workingDirectory), "timeoutSeconds": .number(timeoutSeconds)]
        case .bash, .swift, .javascript: return ["script": .string(script), "cwd": .string(workingDirectory), "timeoutSeconds": .number(timeoutSeconds)]
        case .applescript, .jxa: return ["script": .string(script), "targets": .array(targets.map(JSONValue.string)), "timeoutSeconds": .number(timeoutSeconds)]
        }
    }
}

public enum ScriptTemplates {
    public static func starter(_ language: WorkbenchLanguage) -> String { templates(language)[0].body }

    public static func templates(_ language: WorkbenchLanguage) -> [Snippet] {
        switch language {
        case .bash:
            return [
                Snippet(id: "bash.hello", title: String(localized: "List the working folder"),
                        body: "#!/bin/bash\nset -euo pipefail\n\necho \"Working in $(pwd)\"\nls -la | head -n 20\n"),
                Snippet(id: "bash.loop", title: String(localized: "Loop over files"),
                        body: "#!/bin/bash\nset -euo pipefail\n\nfor file in *; do\n    [ -f \"$file\" ] || continue\n    size=$(wc -c < \"$file\")\n    echo \"$file: $size bytes\"\ndone\n"),
                Snippet(id: "bash.artifact", title: String(localized: "Write a report to the run's artifacts"),
                        body: "#!/bin/bash\nset -euo pipefail\n\nreport=\"$ORIX_ARTIFACTS_DIR/report.txt\"\n{\n    echo \"Report generated on $(date)\"\n    echo \"Files: $(ls | wc -l)\"\n} > \"$report\"\necho \"Wrote $report\"\n"),
                Snippet(id: "bash.skill", title: String(localized: "Skill entry (JSON in, JSON out)"),
                        body: "#!/bin/bash\nset -euo pipefail\n\n# A skill reads its input object on stdin and prints one JSON object.\ninput=$(cat)\ncount=$(printf '%s' \"$input\" | wc -c | tr -d ' ')\nprintf '{\"bytes\": %s}\\n' \"$count\"\n"),
            ]
        case .python:
            return [
                Snippet(id: "python.hello", title: String(localized: "Summarise the working folder"),
                        body: "import os\n\nentries = sorted(os.listdir(\".\"))\nprint(f\"{len(entries)} entries in {os.getcwd()}\")\nfor name in entries[:20]:\n    print(\" -\", name)\n"),
                Snippet(id: "python.csv", title: String(localized: "Read a CSV file"),
                        body: "import csv\nimport sys\n\npath = sys.argv[1] if len(sys.argv) > 1 else \"data.csv\"\nwith open(path, newline=\"\") as handle:\n    rows = list(csv.DictReader(handle))\nprint(f\"{len(rows)} rows, columns: {', '.join(rows[0].keys()) if rows else 'none'}\")\n"),
                Snippet(id: "python.artifact", title: String(localized: "Write a JSON report to the run's artifacts"),
                        body: "import json\nimport os\n\nreport = {\"cwd\": os.getcwd(), \"entries\": len(os.listdir(\".\"))}\npath = os.path.join(os.environ[\"ORIX_ARTIFACTS_DIR\"], \"report.json\")\nwith open(path, \"w\") as handle:\n    json.dump(report, handle, indent=2)\nprint(\"Wrote\", path)\n"),
                Snippet(id: "python.skill", title: String(localized: "Skill entry (JSON in, JSON out)"),
                        body: "import json\nimport sys\n\n# A skill reads its input object on stdin and prints one JSON object.\ndata = json.load(sys.stdin)\ntext = str(data.get(\"text\", \"\"))\nprint(json.dumps({\"words\": len(text.split()), \"characters\": len(text)}))\n"),
            ]
        case .applescript:
            return [
                Snippet(id: "applescript.compute", title: String(localized: "Compute a value"),
                        body: "-- Pure computation: no application is addressed, so no target is needed.\nset total to 0\nrepeat with n from 1 to 10\n    set total to total + n\nend repeat\nreturn \"Sum of 1 to 10 is \" & total\n"),
                Snippet(id: "applescript.finder", title: String(localized: "Ask Finder (needs the target com.apple.finder)"),
                        body: "tell application \"Finder\"\n    return name of startup disk\nend tell\n"),
            ]
        case .jxa:
            return [
                Snippet(id: "jxa.compute", title: String(localized: "Compute a value"),
                        body: "// Pure computation: no application is addressed, so no target is needed.\nconst values = [1, 2, 3, 4, 5]\nconst total = values.reduce((sum, n) => sum + n, 0)\n`Total: ${total}`\n"),
                Snippet(id: "jxa.finder", title: String(localized: "Ask Finder (needs the target com.apple.finder)"),
                        body: "const finder = Application(\"Finder\")\nfinder.startupDisk.name()\n"),
            ]
        case .swift:
            return [
                Snippet(id: "swift.hello", title: String(localized: "List the working folder"),
                        body: "import Foundation\n\nlet folder = FileManager.default.currentDirectoryPath\nlet entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []\nprint(\"\\(entries.count) entries in \\(folder)\")\nfor name in entries.sorted().prefix(20) {\n    print(\" -\", name)\n}\n"),
                Snippet(id: "swift.json", title: String(localized: "Encode a value as JSON"),
                        body: "import Foundation\n\nstruct Report: Codable {\n    var title: String\n    var count: Int\n}\n\nlet data = try JSONEncoder().encode(Report(title: \"Example\", count: 3))\nprint(String(decoding: data, as: UTF8.self))\n"),
            ]
        case .javascript:
            return [
                Snippet(id: "javascript.hello", title: String(localized: "Compute and print"),
                        body: "// Runs in the JavaScriptCore shell: print() and readFile() exist, there is no Node API.\nconst values = [3, 1, 4, 1, 5, 9]\nconst sorted = [...values].sort((a, b) => a - b)\nprint(`Sorted: ${sorted.join(\", \")}`)\nprint(`Sum: ${values.reduce((a, b) => a + b, 0)}`)\n"),
                Snippet(id: "javascript.json", title: String(localized: "Transform JSON"),
                        body: "const input = '{\"items\": [{\"name\": \"a\", \"size\": 3}, {\"name\": \"b\", \"size\": 7}]}'\nconst data = JSON.parse(input)\nconst total = data.items.reduce((sum, item) => sum + item.size, 0)\nprint(JSON.stringify({ count: data.items.length, total }))\n"),
            ]
        }
    }
}
