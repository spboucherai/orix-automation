// ORIX OS Automation
// File: Packages/ORIXFeatureCode/Tests/ORIXFeatureCodeTests/CompletionTests.swift
// Description: Unit tests of completion: context detection at the cursor and the candidates built from tool manifests and the document.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAppUI
import Testing
@testable import ORIXFeatureCode

/// Analyses `text` with the cursor at the `|` marker.
func analyze(_ marked: String, format: WorkflowFormat = .yaml) -> (CompletionRequest, String) {
    let cursor = (marked as NSString).range(of: "|").location
    let text = (marked as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "")
    return (CompletionAnalyzer.analyze(text: text, cursor: cursor, format: format), text)
}

let sampleTools: [ToolManifest] = [
    ToolManifest(identifier: "filesystem.list", name: "List", summary: "Lists the entries of a folder.", family: "filesystem",
                 inputSchema: .object(["path": .string("Folder to list."), "recursive": .boolean("Descend into subfolders."), "limit": .integer("Maximum entries.")], required: ["path"]),
                 outputSchema: .object(["entries": .array(of: .string()), "count": .integer()]), sideEffect: .read, defaultTier: .readOnly),
    ToolManifest(identifier: "filesystem.write", name: "Write", summary: "Creates or overwrites a file.", family: "filesystem",
                 inputSchema: .object(["path": .string("File."), "content": .string("Text.")], required: ["path", "content"]), sideEffect: .write, defaultTier: .reversibleWrite),
    ToolManifest(identifier: "shell.run", name: "Run", summary: "Runs one executable with arguments.", family: "shell",
                 inputSchema: .object(["command": .string(), "args": .array(of: .string())], required: ["command"]), sideEffect: .external, defaultTier: .consequential),
]

let document = """
apiVersion: orix.ai/v1
kind: Automation
metadata:
  id: demo
  name: Demo
spec:
  parameters:
    - name: folder
      type: path
    - name: limit
      type: number
  variables:
    target: ~/out
  steps:
    - id: list
      tool: filesystem.list
      with:
        path: ${{ params.folder }}
    - id: write
      needs: [list]
      tool: filesystem.write
      with:
        path: ~/out/a.txt

"""

@Suite("Unit · completion") struct CompletionTests {
    @Test func toolIDAfterToolKey() {
        let (r, text) = analyze(document + "    - id: more\n      tool: files|")
        #expect(r.context == .toolID(prefix: "files"))
        #expect(r.automatic)
        #expect((text as NSString).substring(with: r.replaceRange) == "files")
        let items = CompletionEngine.candidates(r.context, catalog: CompletionCatalog(tools: sampleTools))
        #expect(items.map(\.label) == ["filesystem.list", "filesystem.write"])
        #expect(items[0].documentation == "Lists the entries of a folder.")
        #expect(items[0].detail.contains("tier 0"))
        // A dash-led step and an empty prefix.
        #expect(analyze("steps:\n  - tool: |").0.context == .toolID(prefix: ""))
        // Contains-matches come after prefix matches.
        #expect(CompletionEngine.candidates(.toolID(prefix: "run"), catalog: CompletionCatalog(tools: sampleTools)).map(\.label) == ["shell.run"])
        // Nothing when the only candidate is what is already typed.
        #expect(CompletionEngine.candidates(.toolID(prefix: "shell.run"), catalog: CompletionCatalog(tools: sampleTools)).isEmpty)
    }

    @Test func argumentNamesInsideWith() {
        let (r, _) = analyze(document.replacingOccurrences(of: "        path: ${{ params.folder }}\n", with: "        path: ${{ params.folder }}\n        |\n"))
        #expect(r.context == .argumentName(tool: "filesystem.list", prefix: "", existing: ["path"]))
        #expect(r.automatic)
        let items = CompletionEngine.candidates(r.context, catalog: CompletionCatalog(tools: sampleTools))
        #expect(items.map(\.label) == ["limit", "recursive"])
        #expect(items[1].insertText == "recursive: ")
        #expect(items[1].detail == "boolean")
        #expect(items[1].documentation == "Descend into subfolders.")
        // Required arguments come first and say so; `tool:` may come after `with:`.
        let (r2, _) = analyze("steps:\n  - id: w\n    with:\n      c|\n    tool: filesystem.write\n")
        #expect(r2.context == .argumentName(tool: "filesystem.write", prefix: "c", existing: []))
        let all = CompletionEngine.candidates(.argumentName(tool: "filesystem.write", prefix: "", existing: []), catalog: CompletionCatalog(tools: sampleTools))
        #expect(Set(all.map(\.label)) == ["path", "content"])
        #expect(all.allSatisfy { $0.detail == "string · required" })
        // A step written with the dash on the tool line.
        let (r3, _) = analyze("steps:\n  - tool: shell.run\n    with:\n      |")
        #expect(r3.context == .argumentName(tool: "shell.run", prefix: "", existing: []))
        #expect(CompletionEngine.candidates(r3.context, catalog: CompletionCatalog(tools: sampleTools)).map(\.label) == ["command", "args"])
    }

    @Test func needsInFlowAndBlockForm() {
        let (r, text) = analyze(document + "    - id: third\n      needs: [list, wr|")
        #expect(r.context == .stepReference(prefix: "wr", listed: ["list"], currentStep: "third"))
        let catalog = CompletionCatalog.scrape(text, tools: sampleTools)
        #expect(catalog.stepIDs == ["list", "write", "third"])
        #expect(catalog.stepTools == ["list": "filesystem.list", "write": "filesystem.write"])
        #expect(catalog.parameters == ["folder", "limit"])
        #expect(catalog.variables == ["target"])
        #expect(CompletionEngine.candidates(r.context, catalog: catalog).map(\.label) == ["write"])
        let (b, _) = analyze(document + "    - id: third\n      needs:\n        - list\n        - |")
        #expect(b.context == .stepReference(prefix: "", listed: ["list"], currentStep: "third"))
        #expect(CompletionEngine.candidates(b.context, catalog: catalog).map(\.label) == ["write"])
    }

    @Test func expressions() {
        let catalog = CompletionCatalog.scrape(document, tools: sampleTools)
        let (root, _) = analyze("with:\n  path: ${{ pa|")
        #expect(root.context == .expressionRoot(prefix: "pa"))
        #expect(root.automatic)
        #expect(CompletionEngine.candidates(root.context, catalog: catalog).map(\.label) == ["params", "joinPath"])   // prefix matches first, then contains
        let empty = CompletionEngine.candidates(.expressionRoot(prefix: ""), catalog: catalog)
        #expect(empty.prefix(4).map(\.label) == ["params", "vars", "steps", "env"])
        #expect(WorkflowExpression.functionNames.allSatisfy { name in empty.contains { $0.label == name && $0.insertText == name + "(" } })

        #expect(analyze("x: ${{ params.|").0.context == .expressionMember(path: ["params"], prefix: ""))
        #expect(CompletionEngine.candidates(.expressionMember(path: ["params"], prefix: "f"), catalog: catalog).map(\.label) == ["folder"])
        #expect(CompletionEngine.candidates(.expressionMember(path: ["vars"], prefix: ""), catalog: catalog).map(\.label) == ["target"])
        #expect(CompletionEngine.candidates(.expressionMember(path: ["env"], prefix: "DA"), catalog: catalog).map(\.label) == ["DATE", "DATETIME"])
        #expect(analyze("x: \"a ${{ len(steps.li|").0.context == .expressionMember(path: ["steps"], prefix: "li"))
        #expect(CompletionEngine.candidates(.expressionMember(path: ["steps"], prefix: ""), catalog: catalog).map(\.label) == ["list", "write"])
        #expect(analyze("x: ${{ steps.list.|").0.context == .expressionMember(path: ["steps", "list"], prefix: ""))
        #expect(CompletionEngine.candidates(.expressionMember(path: ["steps", "list"], prefix: ""), catalog: catalog).map(\.label) == ["output", "status", "error", "attempts"])
        #expect(CompletionEngine.candidates(.expressionMember(path: ["steps", "list", "output"], prefix: ""), catalog: catalog).map(\.label) == ["count", "entries"])
        // A dash-named step, a closed expression, and a string literal inside an expression.
        #expect(analyze("x: ${{ steps.fetch-da|").0.context == .expressionMember(path: ["steps"], prefix: "fetch-da"))
        #expect(analyze("x: ${{ a }} and |").0.context == .none)
        #expect(analyze("x: ${{ contains(a, \"par|").0.context == .none)
        // A second expression on the line.
        #expect(analyze("x: ${{ a }}/${{ va|").0.context == .expressionRoot(prefix: "va"))
    }

    @Test func stepAndMappingKeys() {
        let (s, _) = analyze(document + "    - |")
        #expect(s.context == .stepKey(prefix: "", existing: []))
        #expect(!s.automatic)
        let fresh = CompletionEngine.candidates(s.context, catalog: CompletionCatalog())
        #expect(fresh.first?.label == "id")
        #expect(CompletionEngine.stepKinds.allSatisfy { kind in fresh.contains { $0.label == kind.0 && $0.kind == .keyword } })

        let (k, _) = analyze(document.replacingOccurrences(of: "      needs: [list]\n", with: "      needs: [list]\n      ti|\n"))
        #expect(k.context == .stepKey(prefix: "ti", existing: ["needs", "id", "tool", "with"]))
        let fields = CompletionEngine.candidates(k.context, catalog: CompletionCatalog())
        #expect(fields.map(\.label) == ["timeoutSeconds", "continueOnError"])
        // Once a kind is chosen the other kinds are not offered, its own fields are.
        let agent = CompletionEngine.candidates(.stepKey(prefix: "", existing: ["id", "agent"]), catalog: CompletionCatalog()).map(\.label)
        #expect(agent.contains("objective") && !agent.contains("tool") && !agent.contains("id"))

        #expect(analyze("apiVersion: orix.ai/v1\n|").0.context == .mappingKey(parent: "", prefix: "", existing: ["apiVersion"]))
        #expect(CompletionEngine.candidates(.mappingKey(parent: "", prefix: "", existing: ["apiVersion"]), catalog: CompletionCatalog()).map(\.label) == ["kind", "metadata", "spec"])
        #expect(analyze("metadata:\n  id: a\n  na|").0.context == .mappingKey(parent: "metadata", prefix: "na", existing: ["id"]))
        let (spec, _) = analyze("spec:\n  triggers: []\n  |\n  steps: []\n")
        #expect(spec.context == .mappingKey(parent: "spec", prefix: "", existing: ["triggers", "steps"]))
        #expect(analyze("spec:\n  permissions:\n    filesystem:\n      |").0.context == .mappingKey(parent: "filesystem", prefix: "", existing: []))
        #expect(analyze("spec:\n  parameters:\n    - name: a\n      |").0.context == .mappingKey(parent: "parameter", prefix: "", existing: ["name"]))
        // A nested step list (foreach body).
        #expect(analyze("steps:\n  - id: each\n    foreach: ${{ vars.x }}\n    steps:\n      - id: inner\n        |").0.context == .stepKey(prefix: "", existing: ["id"]))
        // A value position offers nothing.
        #expect(analyze("metadata:\n  name: Dem|").0.context == .none)
    }

    @Test func jsonSource() {
        let (r, _) = analyze("{\n  \"spec\": { \"steps\": [ { \"id\": \"a\", \"tool\": \"shell.|", format: .json)
        #expect(r.context == .toolID(prefix: "shell."))
        #expect(analyze("{ \"path\": \"${{ steps.|", format: .json).0.context == .expressionMember(path: ["steps"], prefix: ""))
        #expect(analyze("{ \"na|", format: .json).0.context == .none)
        #expect(CompletionCatalog.scrape("{\"spec\": {\"steps\": [{\"id\": \"one\"}, {\"id\": \"two\"}]}}", tools: []).stepIDs == ["one", "two"])
    }

    @Test func toolDocumentation() {
        let text = ToolDocs.text(sampleTools[0])
        #expect(text.contains("filesystem.list — List"))
        #expect(text.contains("Arguments: path*: string, limit: integer, recursive: boolean"))
        #expect(text.contains("Tier 0"))
        #expect(text.contains("side effect: read"))
        let ranges = ToolDocs.ranges(in: document)
        #expect(ranges.map(\.id) == ["filesystem.list", "filesystem.write"])
        let offset = (document as NSString).range(of: "filesystem.write").location + 4
        #expect(ToolDocs.toolID(in: document, at: offset)?.id == "filesystem.write")
        #expect(ToolDocs.toolID(in: document, at: 3) == nil)
        #expect(ToolDocs.ranges(in: "{\"tool\": \"shell.run\"}").map(\.id) == ["shell.run"])
    }
}
