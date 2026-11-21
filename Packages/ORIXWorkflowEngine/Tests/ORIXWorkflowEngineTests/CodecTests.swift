// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/CodecTests.swift
// Description: Unit and property tests of the YAML/JSON codec: subset coverage, error positions, rejected YAML features, canonical emission and round trips.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Testing
import ORIXCore
@testable import ORIXWorkflowEngine

/// The illustrative workflow of CLAUDE.md §9, verbatim.
let claudeSection9Workflow = """
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
"""

func parseYAML(_ text: String) throws -> JSONValue {
    var p = YAMLParser(text)
    return try p.parseDocument().json
}

func syntaxError(_ text: String) -> YAMLSyntaxError? {
    var p = YAMLParser(text)
    do { _ = try p.parseDocument(); return nil } catch let e as YAMLSyntaxError { return e } catch { return nil }
}

func minimal(_ stepsYAML: String) -> String {
    "apiVersion: orix.ai/v1\nkind: Automation\nmetadata:\n  id: t\n  name: T\nspec:\n  steps:\n" + stepsYAML
}

@Suite("YAML subset (unit)") struct YAMLSubsetTests {
    @Test func blockMappingsAndSequences() throws {
        let v = try parseYAML("a: 1\nb:\n  c: [x, y]\n  d:\n    - 1\n    - e: f\n      g: h\nlist:\n- same\n- indent\n")
        #expect(v == ["a": 1, "b": ["c": ["x", "y"], "d": [1, ["e": "f", "g": "h"]]], "list": ["same", "indent"]])
    }

    @Test func scalarTyping() throws {
        let v = try parseYAML("n: null\nt: ~\ne:\nb1: true\nb2: False\ni: -42\nf: 1.5\ng: 1e3\ns1: 007\ns2: yes\ns3: on\ns4: 0x1F\nq: \"12\"\nbig: 99999999999999999999\n")
        #expect(v["n"] == .null && v["t"] == .null && v["e"] == .null)
        #expect(v["b1"] == true && v["b2"] == false)
        #expect(v["i"] == .int(-42) && v["f"] == .number(1.5) && v["g"] == .number(1000))
        #expect(v["s1"] == "007" && v["s2"] == "yes" && v["s3"] == "on" && v["s4"] == "0x1F" && v["q"] == "12")
        #expect(v["big"] == .number(1e20))
    }

    @Test func quotedScalarsAndEscapes() throws {
        let v = try parseYAML(#"""
        a: "tab\there \"q\" \\ \n \u00e9 \x41 \U0001F680 \ud83d\ude80 \/"
        b: 'it''s # not a comment: really'
        "quoted key": 'v'
        c: plain # comment
        d: "a # b"
        """#)
        #expect(v["a"] == "tab\there \"q\" \\ \n é A 🚀 🚀 /")
        #expect(v["b"] == "it's # not a comment: really")
        #expect(v["quoted key"] == "v" && v["c"] == "plain" && v["d"] == "a # b")
    }

    @Test func blockScalars() throws {
        let v = try parseYAML("lit: |\n  line 1\n    indented\n\n  line 3\nstrip: |-\n  no newline\nkeep: |+\n  kept\n\nfold: >\n  folded\n  text\n\n  para\nfolds: >-\n  a\n  b\nlist:\n  - |\n    in list\n  - >-\n    x\n    y\n")
        #expect(v["lit"] == "line 1\n  indented\n\nline 3\n")
        #expect(v["strip"] == "no newline")
        #expect(v["keep"] == "kept\n\n")
        #expect(v["fold"] == "folded text\npara\n")
        #expect(v["folds"] == "a b")
        #expect(v["list"] == ["in list\n", "x y"])
    }

    @Test func blockScalarKeepsCommentLikeAndColonContent() throws {
        let v = try parseYAML("script: |\n  # not a comment\n  key: value\n  - item\nnext: 1\n")
        #expect(v["script"] == "# not a comment\nkey: value\n- item\n")
        #expect(v["next"] == 1)
    }

    @Test func flowCollectionsIncludingMultiLineAndJSON() throws {
        let v = try parseYAML("a: [1, two, \"3\", [n, m], {k: v}]\nb: {x: 1, y: [true, null], \"z z\": 'q'}\nc: [\n  1,\n  2 # c\n]\nd: {}\ne: []\n")
        #expect(v["a"] == [1, "two", "3", ["n", "m"], ["k": "v"]])
        #expect(v["b"] == ["x": 1, "y": [true, nil], "z z": "q"])
        #expect(v["c"] == [1, 2] && v["d"] == [:] && v["e"] == [])
        let json = try parseYAML("{\n\t\"a\": [1, 2.5, \"x\\n\"],\n\t\"b\": {\"c\": null, \"d\": false}\n}\n")
        #expect(json == ["a": [1, 2.5, "x\n"], "b": ["c": nil, "d": false]])
    }

    @Test func commentsAreCollected() throws {
        var p = YAMLParser("# top\na: 1 # trailing\n  # indented\nb: [1, # in flow\n  2]\n")
        _ = try p.parseDocument()
        #expect(p.comments.map(\.line) == [1, 2, 3, 4])
        #expect(p.comments[1].column == 6)
    }

    @Test(arguments: [
        ("a: &x 1\n", 1, 4, "anchors"),
        ("a: *x\n", 1, 4, "anchors"),
        ("a: !!str 1\n", 1, 4, "tags"),
        ("&k a: 1\n", 1, 1, "anchors"),
        ("a: 1\n---\nb: 2\n", 2, 1, "multiple YAML documents"),
        ("%YAML 1.2\n---\na: 1\n", 1, 1, "directives"),
        ("a: 1\n...\n", 2, 1, "document end marker"),
        ("a:\n  <<: {b: 1}\n", 2, 3, "merge keys"),
        ("? a\n: b\n", 1, 1, "complex mapping keys"),
        ("a: [1, *x]\n", 1, 8, "anchors"),
    ])
    func unsupportedYAMLIsRejectedWithPosition(source: String, line: Int, column: Int, fragment: String) {
        let e = syntaxError(source)
        #expect(e != nil, "expected a rejection for \(source.debugDescription)")
        #expect(e?.line == line && e?.column == column, "got \(e?.line ?? 0):\(e?.column ?? 0) \(e?.message ?? "")")
        #expect(e?.message.contains(fragment) == true, "message: \(e?.message ?? "")")
    }

    @Test(arguments: [
        ("a: 1\n\tb: 2\n", 2, 1, "tab"),
        ("a: \"open\n", 1, 4, "unterminated"),
        ("a: 'open\n", 1, 4, "unterminated"),
        ("a: [1, 2\n", 1, 4, "unterminated flow"),
        ("a: 1\na: 2\n", 2, 1, "duplicate key"),
        ("a: 1\n  b: 2\n", 2, 3, "unexpected indentation"),
        ("a: \"x\" y\n", 1, 8, "unexpected characters"),
        ("a: b: c\n", 1, 5, "': '"),
        ("a: \"\\q\"\n", 1, 5, "unknown escape"),
        ("a: {b 1}\n", 1, 8, "expected ':'"),
        ("- a\nb: 1\n", 2, 1, "unexpected content"),
        ("a: [1 2: 3]\n", 1, 8, "single-pair"),
    ])
    func syntaxErrorsCarryLineAndColumn(source: String, line: Int, column: Int, fragment: String) {
        let e = syntaxError(source)
        #expect(e != nil, "expected an error for \(source.debugDescription)")
        #expect(e?.line == line && e?.column == column, "got \(e?.line ?? 0):\(e?.column ?? 0) \(e?.message ?? "")")
        #expect(e?.message.contains(fragment) == true, "message: \(e?.message ?? "")")
    }

    @Test func leadingDocumentMarkerAndCRLFAreAccepted() throws {
        #expect(try parseYAML("---\r\na: 1\r\nb:\r\n  - x\r\n") == ["a": 1, "b": ["x"]])
    }
}

@Suite("Workflow codec (unit)") struct WorkflowCodecTests {
    @Test func parsesAndNormalisesTheIllustrativeWorkflow() throws {
        let doc = try WorkflowCodec.parse(claudeSection9Workflow)
        #expect(doc.metadata.id == "weekly-research-report" && doc.metadata.name == "weekly-research-report")
        #expect(doc.spec.triggers == [.schedule(cron: "0 9 * * MON", timezone: "America/Toronto")])
        #expect(doc.spec.permissions.filesystem.read == ["~/Documents/Research"])
        #expect(doc.spec.permissions.processes == ["python"])
        #expect(doc.spec.budget == WorkflowBudget(maxDurationSeconds: 1800, maxProviderCostUSD: 2))
        #expect(doc.spec.steps.map(\.id) == ["discover", "analyze", "render", "verify"])
        #expect(doc.spec.steps[0].kind == .tool(ToolStep(tool: "filesystem.list", arguments: ["path": "~/Documents/Research"])))
        #expect(doc.spec.steps[1].kind == .agent(AgentStep(agent: .profile("research-analyst"))))
        #expect(doc.spec.steps[3].kind == .verify(VerifyStep(assertions: [.stepSucceeded("render")])))
        let canonical = WorkflowCodec.emit(doc)
        #expect(canonical.contains("triggers:\n    - type: schedule\n      cron: 0 9 * * MON\n"))
        #expect(canonical.contains("    - id: verify\n      needs: [render]\n      verify:\n        - stepSucceeded: render\n"))
        #expect(try WorkflowCodec.parse(canonical) == doc)
        let loss = WorkflowCodec.roundTripLoss(source: claudeSection9Workflow)
        #expect(loss.contains { $0.contains("'spec.trigger'") })
        #expect(loss.contains { $0.contains("verifier: artifact-exists") })
        #expect(loss.contains { $0.contains("metadata.id") })
    }

    @Test func everyStepKindParses() throws {
        let src = minimal("""
            - id: t
              name: Tool
              tool: filesystem.list
              with: {path: ~/x, recursive: true}
              retry: {maxAttempts: 3, backoffSeconds: 1.5, backoffMultiplier: 2, force: true}
              timeoutSeconds: 12.5
              continueOnError: true
              onError: f
            - id: a
              agent: {instructions: Do it, model: anthropic/claude-sonnet-4-5, tools: [filesystem.*]}
              objective: Summarise
              inputs: {files: "${{ steps.t.output.entries }}"}
              expect:
                - fileNonEmpty: ~/out.md
            - id: c
              if: ${{ len(steps.t.output.entries) > 0 }}
              then: [a]
              else: [f]
            - id: sw
              switch: ${{ params.mode }}
              cases:
                - value: fast
                  steps: [d]
                - value: 2
                  steps: []
              default: [f]
            - id: fe
              foreach: ${{ steps.t.output.entries }}
              as: entry
              concurrency: 3
              collect: inner
              steps:
                - id: inner
                  transform: ${{ upper(entry.name) }}
            - id: p
              parallel:
                - name: left
                  steps:
                    - id: l1
                      delay: 1
                - name: right
                  steps: []
            - id: lo
              while: ${{ vars.n < 3 }}
              maxIterations: 5
              steps:
                - id: inc
                  set: {n: "${{ vars.n + 1 }}"}
            - id: ap
              approval: Proceed?
            - id: d
              delay: ${{ params.wait }}
            - id: tr
              transform: ${{ 1 + 2 }}
              into: three
            - id: v
              verify:
                - fileExists: ~/a
                - fileContains: ~/a
                  text: hello
                - dirNonEmpty: ~/d
                - equals: [1, "${{ vars.three - 2 }}"]
                - truthy: ${{ vars.three }}
                - stepSucceeded: tr
            - id: sub
              subworkflow: other
              inputs: {x: 1}
            - id: n
              notify: Done
              title: ORIX
            - id: f
              fail: Nope
            - id: o
              output: {count: "${{ steps.fe.output.count }}"}
              artifacts: [~/out.md]

        """)
        let doc = try WorkflowCodec.parse(src)
        #expect(doc.spec.steps.map(\.kind.name) == ["tool", "agent", "condition", "switch", "foreach", "parallel", "loop", "approval",
                                                    "delay", "transform", "verify", "subworkflow", "notify", "fail", "output"])
        #expect(doc.spec.steps[0].retry == WorkflowRetryPolicy(maxAttempts: 3, backoffSeconds: 1.5, backoffMultiplier: 2, force: true))
        #expect(doc.spec.steps[0].timeoutSeconds == 12.5 && doc.spec.steps[0].continueOnError && doc.spec.steps[0].onError == "f")
        guard case .foreach(let fe) = doc.spec.steps[4].kind else { Issue.record("not foreach"); return }
        #expect(fe.itemName == "entry" && fe.concurrency == 3 && fe.collect == "inner" && fe.steps.count == 1)
        guard case .verify(let v) = doc.spec.steps[10].kind else { Issue.record("not verify"); return }
        #expect(v.assertions.count == 6 && v.assertions[1] == .fileContains(path: "~/a", text: "hello"))
        let text = WorkflowCodec.emit(doc)
        #expect(try WorkflowCodec.parse(text) == doc)
        #expect(WorkflowCodec.emit(try WorkflowCodec.parse(text)) == text)
        let json = WorkflowCodec.emit(doc, format: .json)
        #expect(try WorkflowCodec.parse(json, format: .json) == doc)
        #expect(try WorkflowDocument(jsonValue: JSONValue.parse(json)) == doc)
    }

    @Test func structuralErrorsCarryPositionPathAndStep() {
        let src = minimal("""
            - id: one
              tool: filesystem.list
              wiht: {path: /x}
            - id: two
              tool: a.b
              agent: x
            - name: no id
              delay: 1
            - id: three
              while: "true"
              steps: []
            - id: four
              timeoutSeconds: soon
              delay: 1

        """)
        do { _ = try WorkflowCodec.parse(src); Issue.record("should not parse") }
        catch let e as WorkflowParseError {
            let byCode = Dictionary(grouping: e.diagnostics, by: \.code)
            let unknown = byCode["unknown-field"]?.first
            #expect(unknown?.line == 10 && unknown?.column == 7 && unknown?.stepID == "one" && unknown?.path == "spec.steps[0].wiht")
            #expect(byCode["invalid-step-kind"]?.first?.stepID == "two")
            #expect(byCode["invalid-step-kind"]?.first?.line == 11)
            #expect(byCode["missing-field"]?.contains { $0.path == "spec.steps[2]" && $0.line == 14 } == true)
            #expect(byCode["unbounded-loop"]?.first?.stepID == "three")
            let mismatch = byCode["type-mismatch"]?.first
            #expect(mismatch?.path == "spec.steps[4].timeoutSeconds" && mismatch?.line == 20 && mismatch?.column == 23)
        } catch { Issue.record("unexpected error \(error)") }
    }

    @Test func syntaxErrorsSurfaceAsDiagnostics() {
        #expect(throws: WorkflowParseError.self) { try WorkflowCodec.parse("a: &anchor 1\n") }
        do { _ = try WorkflowCodec.parse("metadata:\n  name: [unclosed\n") }
        catch let e as WorkflowParseError {
            #expect(e.diagnostics.first?.code == "syntax" && e.diagnostics.first?.line == 2 && e.diagnostics.first?.column == 9)
        } catch { Issue.record("unexpected error") }
        #expect(throws: WorkflowParseError.self) { try WorkflowCodec.parse("apiVersion: orix.ai/v9\nkind: Automation\nmetadata: {name: x}\nspec: {steps: []}\n") }
    }

    @Test func canonicalEmissionUsesMinimalQuotingAndLiteralBlocks() throws {
        var doc = WorkflowDocument(metadata: WorkflowMetadata(id: "q", name: "Quoting: test", description: "line one\nline two\n", tags: ["a", "true", "1"]))
        doc.spec.steps = [WorkflowStep(id: "run", kind: .tool(ToolStep(tool: "shell.script", arguments: [
            "script": "set -e\necho \"hi\"  # comment\n", "path": "~/ORIX Samples/x", "count": "12", "flag": true, "ratio": 2.0, "n": 3,
            "expr": "${{ params.a }}", "list": ["a b", "c,d", "${{ x }}"],
        ])))]
        let text = WorkflowCodec.emit(doc)
        #expect(text.contains("name: \"Quoting: test\"\n"))
        #expect(text.contains("  description: |\n    line one\n    line two\n"))
        #expect(text.contains("tags: [a, \"true\", \"1\"]\n"))
        #expect(text.contains("        script: |\n          set -e\n          echo \"hi\"  # comment\n"))
        #expect(text.contains("        path: ~/ORIX Samples/x\n"))
        #expect(text.contains("        count: \"12\"\n") && text.contains("        flag: true\n") && text.contains("        ratio: 2.0\n") && text.contains("        n: 3\n"))
        #expect(text.contains("        expr: ${{ params.a }}\n"))
        #expect(text.contains("        list: [a b, \"c,d\", \"${{ x }}\"]\n"))
        #expect(try WorkflowCodec.parse(text) == doc)
    }

    @Test func roundTripLossReportsCommentsFormattingAndNothingForCanonicalText() throws {
        let doc = try WorkflowCodec.parse(claudeSection9Workflow)
        let canonical = WorkflowCodec.emit(doc)
        #expect(WorkflowCodec.roundTripLoss(source: canonical).isEmpty)
        let commented = canonical.replacingOccurrences(of: "spec:\n", with: "spec: # the spec\n  # why this exists\n")
        let loss = WorkflowCodec.roundTripLoss(source: commented)
        #expect(loss.count == 1 && loss[0].hasPrefix("2 comments would be removed"))
        let reordered = "kind: Automation\napiVersion: orix.ai/v1\nmetadata: {id: x, name: 'X'}\nspec:\n  steps: []\n"
        #expect(WorkflowCodec.roundTripLoss(source: reordered).contains { $0.contains("canonical form") })
        #expect(WorkflowCodec.roundTripLoss(source: "a: [").first?.contains("does not parse") == true)
        #expect(WorkflowCodec.roundTripLoss(source: "---\n" + canonical).contains { $0.contains("'---'") })
    }

    @Test func sourcePositionsLocateValidatorPaths() throws {
        let src = minimal("    - id: a\n      tool: nope.tool\n      with:\n        path: /x\n")
        let positions = WorkflowCodec.sourcePositions(source: src)
        #expect(positions["spec.steps[0].tool"] == WorkflowSourcePosition(line: 9, column: 7))
        #expect(positions["spec.steps[0].with.path"] == WorkflowSourcePosition(line: 11, column: 9))
        let located = WorkflowCodec.locate([WorkflowDiagnostic(code: "x", message: "m", path: "spec.steps[0].with.missing.deeper")], in: src)
        #expect(located[0].line == 10 && located[0].column == 7)
    }

    @Test func codableBridgeRoundTrips() throws {
        let doc = try WorkflowCodec.parse(claudeSection9Workflow)
        let data = try JSONEncoder().encode(doc)
        #expect(try JSONDecoder().decode(WorkflowDocument.self, from: data) == doc)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkflowDocument.self, from: Data(#"{"kind":"Nope"}"#.utf8)) }
    }

    @Test func detectsFormat() {
        #expect(WorkflowCodec.detectFormat("  \n{\"a\": 1}") == .json)
        #expect(WorkflowCodec.detectFormat("apiVersion: x") == .yaml)
    }
}

@Suite("Workflow codec (property)") struct WorkflowCodecPropertyTests {
    @Test func parseOfEmitIsIdentityForRandomDocuments() throws {
        var generator = DocumentGenerator(seed: 0x0A1C)
        for i in 0..<400 {
            let doc = generator.document()
            for format in WorkflowFormat.allCases {
                let text = WorkflowCodec.emit(doc, format: format)
                let back: WorkflowDocument
                do { back = try WorkflowCodec.parse(text, format: format) }
                catch { Issue.record("iteration \(i) \(format): emitted text does not parse: \(error)\n\(text)"); return }
                if back != doc { Issue.record("iteration \(i) \(format): round trip changed the document\n\(text)"); return }
                #expect(WorkflowCodec.emit(back, format: format) == text)
            }
            #expect(WorkflowCodec.roundTripLoss(source: WorkflowCodec.emit(doc)).isEmpty)
        }
    }

    @Test func scalarStringsSurviveEveryPosition() throws {
        var generator = DocumentGenerator(seed: 7)
        for s in DocumentGenerator.trickyStrings + (0..<300).map({ _ in generator.string() }) {
            var doc = WorkflowDocument(metadata: WorkflowMetadata(id: s, name: s, description: s, tags: [s, s]))
            doc.spec.variables = [s: .string(s), "list": [.string(s), .string(s)], "nested": ["k": ["deep": .string(s)]]]
            doc.spec.steps = [WorkflowStep(id: "a", name: s, when: s, kind: .tool(ToolStep(tool: "x.y", arguments: [s: .string(s), "a": [.string(s)]])))]
            let text = WorkflowCodec.emit(doc)
            let back = try WorkflowCodec.parse(text)
            #expect(back == doc, "string \(s.debugDescription) did not survive:\n\(text)")
        }
    }

    @Test func emitOfParseIsIdempotentForHandWrittenSources() throws {
        for src in [claudeSection9Workflow, minimal("    - {id: a, delay: 1}\n    - id: b\n      needs: a\n      set:\n        x:   [1,2]\n")] {
            let once = WorkflowCodec.emit(try WorkflowCodec.parse(src))
            let twice = WorkflowCodec.emit(try WorkflowCodec.parse(once))
            #expect(once == twice)
        }
    }
}
