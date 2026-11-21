// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/ValidatorTests.swift
// Description: Unit tests of the static validator: one focused case per diagnostic code, plus capabilities, proposed grants and source positions.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Testing
import ORIXCore
@testable import ORIXWorkflowEngine

/// Builds a document from the body of `spec:` (written at two-space indentation) and validates it.
private func check(_ spec: String, tools: [ToolManifest]? = nil, agents: [String] = [], workflows: [String] = [],
                   sourceLocation: SourceLocation = #_sourceLocation) -> [WorkflowDiagnostic] {
    let source = "apiVersion: orix.ai/v1\nkind: Automation\nmetadata:\n  id: t\n  name: T\nspec:\n" + spec
    do {
        let doc = try WorkflowCodec.parse(source)
        return WorkflowValidator.validate(doc, tools: tools ?? validatorTools, agents: agents, workflows: workflows)
    } catch {
        Issue.record("test source does not parse: \(error.localizedDescription)", sourceLocation: sourceLocation)
        return []
    }
}

/// The canonical catalogue plus one tool with a strict input schema.
private let validatorTools: [ToolManifest] = CanonicalTools.manifests() + [
    ToolManifest(identifier: "test.strict", name: "Strict", summary: "Tool with a strict input schema for validator tests.", family: "test",
                 inputSchema: .object(["path": .string(), "count": .integer(minimum: 1), "tags": .array(of: .string())], required: ["path"]),
                 sideEffect: .read, defaultTier: .readOnly, idempotent: true),
]

private extension Array where Element == WorkflowDiagnostic {
    func with(_ code: String) -> [WorkflowDiagnostic] { filter { $0.code == code } }
    func has(_ code: String, _ severity: WorkflowDiagnostic.Severity = .error, step: String? = nil, containing text: String = "") -> Bool {
        contains { $0.code == code && $0.severity == severity && (step == nil || $0.stepID == step) && (text.isEmpty || $0.message.contains(text)) }
    }
    var errors: [WorkflowDiagnostic] { filter { $0.severity == .error } }
    var summary: String { map(\.description).joined(separator: "\n") }
}

@Suite("Workflow validator: identifiers and graph (unit)") struct ValidatorGraphTests {
    @Test func cleanDocumentHasNoDiagnostics() {
        let d = check("""
          steps:
            - id: a
              delay: 1
            - id: b
              needs: [a]
              transform: ${{ steps.a.status }}
        """)
        #expect(d.isEmpty, "\(d.summary)")
    }

    @Test func emptyWorkflowIsAWarning() {
        #expect(check("  steps: []\n").has("empty-workflow", .warning))
    }

    @Test func invalidIdentifiers() {
        let d = check("""
          steps:
            - id: 1bad
              delay: 1
            - id: "has space"
              delay: 1
            - id: ok-id_2
              delay: 1
        """)
        #expect(d.with("invalid-id").map(\.stepID) == ["1bad", "has space"])
        #expect(d.with("invalid-id").first?.path == "spec.steps[0].id")
        var doc = WorkflowDocument(metadata: WorkflowMetadata(id: "bad id", name: " "))
        doc.spec.steps = [WorkflowStep(id: "a", kind: .delay(DelayStep(seconds: 1)))]
        let m = WorkflowValidator.validate(doc, tools: [], agents: [], workflows: [])
        #expect(m.has("invalid-id", containing: "metadata.id") && m.has("missing-field", containing: "metadata.name"))
        #expect(WorkflowValidator.isValidIdentifier("a-b_1") && !WorkflowValidator.isValidIdentifier("-a") && !WorkflowValidator.isValidIdentifier(""))
    }

    @Test func duplicateIdsAreDocumentWideIncludingNestedSteps() {
        let d = check("""
          steps:
            - id: a
              delay: 1
            - id: loop
              foreach: [1, 2]
              steps:
                - id: a
                  delay: 1
        """)
        #expect(d.has("duplicate-id", step: "a", containing: "spec.steps[0]"))
        #expect(d.with("duplicate-id").first?.path == "spec.steps[1].steps[0].id")
    }

    @Test func selfNeedAndUnknownNeed() {
        let d = check("""
          steps:
            - id: a
              needs: [a, ghost]
              delay: 1
            - id: box
              foreach: [1]
              steps:
                - id: inner
                  delay: 1
            - id: b
              needs: [inner]
              delay: 1
        """)
        #expect(d.has("self-need", step: "a"))
        #expect(d.has("unknown-need", step: "a", containing: "'ghost'"))
        #expect(d.has("unknown-need", step: "b", containing: "another scope"))
        #expect(d.with("unknown-need").first?.path == "spec.steps[0].needs[1]")
    }

    @Test func unknownBranchStep() {
        let d = check("""
          steps:
            - id: c
              if: "true"
              then: [ghost]
              else: [c]
            - id: s
              switch: "1"
              cases:
                - value: 1
                  steps: [nowhere]
        """)
        #expect(d.with("unknown-branch-step").count == 3)
        #expect(d.has("unknown-branch-step", step: "s", containing: "'nowhere'"))
    }

    @Test func dependencyCycleReportsItsPath() {
        let d = check("""
          steps:
            - id: a
              needs: [b]
              delay: 1
            - id: b
              needs: [c]
              delay: 1
            - id: c
              needs: [a]
              delay: 1
            - id: free
              delay: 1
        """)
        let cycles = d.with("dependency-cycle")
        #expect(cycles.count == 1)
        #expect(cycles.first?.message.contains("c → b → a → c") == true, "\(cycles.first?.message ?? "")")
        #expect(cycles.first?.path == "spec.steps[0].needs" && cycles.first?.stepID == "a")
    }

    @Test func cycleThroughAConditionGateIsDetected() {
        let d = check("""
          steps:
            - id: gate
              needs: [target]
              if: "true"
              then: [target]
            - id: target
              delay: 1
        """)
        #expect(d.has("dependency-cycle"))
    }

    @Test func structuralErrorsOnlyReportGraphProblems() throws {
        let doc = try WorkflowCodec.parse("apiVersion: orix.ai/v1\nkind: Automation\nmetadata: {id: t, name: T}\nspec:\n  steps:\n    - id: a\n      needs: [zz]\n      tool: nope.tool\n")
        #expect(WorkflowValidator.structuralErrors(doc).map(\.code) == ["unknown-need"])
    }

    @Test func unreachableSteps() {
        let d = check("""
          steps:
            - id: work
              delay: 1
              onError: handler
            - id: handler
              delay: 1
            - id: afterHandler
              needs: [handler]
              delay: 1
            - id: stop
              fail: Always
            - id: afterFail
              needs: [stop]
              delay: 1
            - id: later
              needs: [afterFail]
              delay: 1
            - id: gate
              if: "false"
              then: [never]
              else: [always]
            - id: never
              delay: 1
            - id: always
              delay: 1
        """)
        #expect(d.has("unreachable-step", .error, step: "afterHandler", containing: "onError handler"))
        #expect(d.has("unreachable-step", .warning, step: "afterFail", containing: "unconditional fail step 'stop'"))
        #expect(d.has("unreachable-step", .warning, step: "later"))
        #expect(d.has("unreachable-step", .warning, step: "never", containing: "always false"))
        #expect(!d.with("unreachable-step").contains { $0.stepID == "always" || $0.stepID == "handler" || $0.stepID == "work" })
        let handled = check("""
          steps:
            - id: stop
              fail: Sometimes
              continueOnError: true
            - id: after
              needs: [stop]
              delay: 1
        """)
        #expect(handled.with("unreachable-step").isEmpty)
    }

    @Test func invalidHandlers() {
        let d = check("""
          steps:
            - id: a
              delay: 1
              onError: a
            - id: b
              delay: 1
              onError: ghost
            - id: c
              delay: 1
              onError: needy
            - id: needy
              needs: [a]
              delay: 1
            - id: d
              delay: 1
              onError: gated
            - id: gate
              if: "true"
              then: [gated]
            - id: gated
              delay: 1
              onError: last
            - id: last
              delay: 1
        """)
        let h = d.with("invalid-handler")
        #expect(h.contains { $0.stepID == "a" && $0.message.contains("its own") })
        #expect(h.contains { $0.stepID == "b" && $0.message.contains("'ghost'") })
        #expect(h.contains { $0.stepID == "c" && $0.message.contains("must not declare 'needs'") })
        #expect(h.contains { $0.stepID == "d" && $0.message.contains("branch") })
        #expect(h.contains { $0.stepID == "d" && $0.severity == .warning && $0.message.contains("not chained") })
    }

    @Test func staleLayoutEntry() {
        let d = check("""
          steps:
            - id: a
              delay: 1
          layout:
            a: {x: 1, y: 2}
            gone: {x: 3, y: 4}
            "trigger:0": {x: 0, y: 0}
        """)
        #expect(d.with("stale-layout").map(\.path) == ["spec.layout.gone"])
    }
}

@Suite("Workflow validator: tools, arguments and step rules (unit)") struct ValidatorStepTests {
    @Test func unknownToolNamesItsFamily() {
        let d = check("""
          steps:
            - id: a
              tool: filesystem.lst
            - id: b
              tool: document.renderPDF
        """)
        #expect(d.has("unknown-tool", step: "a", containing: "filesystem.list"))
        #expect(d.has("unknown-tool", step: "b"))
        #expect(d.with("unknown-tool").first?.path == "spec.steps[0].tool")
    }

    @Test func literalArgumentsAreCheckedAgainstTheInputSchema() {
        let d = check("""
          steps:
            - id: missing
              tool: test.strict
              with: {count: 2}
            - id: unexpected
              tool: test.strict
              with: {path: /x, colour: red}
            - id: wrongType
              tool: test.strict
              with: {path: 12, count: 0, tags: [a, 3]}
            - id: dynamic
              tool: test.strict
              with:
                path: ${{ params.p }}
                count: ${{ params.n }}
                tags: ["${{ params.p }}", 4]
          parameters:
            - {name: p, type: string, default: /x}
            - {name: n, type: integer, default: 1}
        """)
        let a = d.with("invalid-argument")
        #expect(a.contains { $0.stepID == "missing" && $0.message.contains("requires argument 'path'") })
        #expect(a.contains { $0.stepID == "unexpected" && $0.message.contains("no argument 'colour'") && $0.path == "spec.steps[1].with.colour" })
        #expect(a.contains { $0.stepID == "wrongType" && $0.message.contains("'path'") && $0.message.contains("expected string") })
        #expect(a.contains { $0.stepID == "wrongType" && $0.message.contains("'count'") && $0.message.contains("minimum") })
        #expect(a.contains { $0.stepID == "wrongType" && $0.message.contains("'tags.1'") })
        #expect(!a.contains { $0.stepID == "dynamic" }, "values containing ${{ }} are only known at run time")
    }

    @Test func unboundedLoops() {
        let d = check("""
          steps:
            - id: zero
              while: ${{ vars.go }}
              maxIterations: 0
              steps: [{id: z1, delay: 1}]
            - id: huge
              while: ${{ vars.go }}
              maxIterations: 50000
              steps: [{id: h1, delay: 1}]
            - id: constant
              while: "true"
              maxIterations: 3
              steps: [{id: c1, delay: 1}]
          variables: {go: true}
        """)
        #expect(d.has("unbounded-loop", .error, step: "zero"))
        #expect(d.has("unbounded-loop", .warning, step: "huge", containing: "effectively unbounded"))
        #expect(d.has("unbounded-loop", .warning, step: "constant", containing: "constant"))
    }

    @Test func invalidValuesOnSteps() {
        let d = check("""
          steps:
            - id: t
              delay: -1
              timeoutSeconds: 0
              retry: {maxAttempts: 0, backoffSeconds: -1}
            - id: fe
              foreach: [1]
              as: steps
              concurrency: 0
              collect: ghost
              steps: []
            - id: st
              set: {"bad name": 1}
            - id: tr
              transform: "1"
              into: 9x
            - id: empty
              set: {}
            - id: v
              verify: []
            - id: par
              parallel:
                - name: same
                  steps: []
                - name: same
                  steps: [{id: p1, delay: 1}]
        """)
        #expect(d.with("invalid-value").filter { $0.stepID == "t" }.count == 4)
        #expect(d.has("invalid-value", step: "fe", containing: "concurrency"))
        #expect(d.has("invalid-value", step: "fe", containing: "'as: steps'"))
        #expect(d.has("unknown-step-reference", step: "fe", containing: "'collect'"))
        #expect(d.has("empty-body", .warning, step: "fe") && d.has("empty-body", .warning, step: "empty") && d.has("empty-body", .warning, step: "par"))
        #expect(d.has("invalid-id", step: "st") && d.has("invalid-id", step: "tr"))
        #expect(d.has("empty-verify", .warning, step: "v"))
        #expect(d.has("duplicate-branch", step: "par"))
    }

    @Test func conditionAndSwitchWarnings() {
        let d = check("""
          steps:
            - id: c
              if: ${{ vars.x }}
            - id: both
              if: ${{ vars.x }}
              then: [t]
              else: [t]
            - id: t
              delay: 1
            - id: s
              switch: ${{ vars.x }}
              cases:
                - {value: 1, steps: [u]}
                - {value: 1, steps: []}
            - id: u
              delay: 1
            - id: s2
              switch: ${{ vars.x }}
          variables: {x: 1}
        """)
        #expect(d.has("empty-branches", .warning, step: "c") && d.has("empty-branches", .warning, step: "s2"))
        #expect(d.has("ambiguous-branch", .warning, step: "both"))
        #expect(d.has("duplicate-case", .warning, step: "s"))
    }

    @Test func retryOnNonIdempotentStepsIsFlagged() {
        let d = check("""
          steps:
            - id: read
              tool: filesystem.list
              with: {path: /tmp/x}
              retry: 3
            - id: move
              tool: filesystem.move
              with: {source: /tmp/x/a, destination: /tmp/x/b}
              retry: {maxAttempts: 3}
            - id: forced
              tool: filesystem.move
              with: {source: /tmp/x/a, destination: /tmp/x/b}
              retry: {maxAttempts: 3, force: true}
            - id: ag
              agent: {instructions: Do it}
              objective: Something
              retry: 2
            - id: box
              foreach: [1]
              retry: 2
              steps: [{id: b1, delay: 1}]
          permissions:
            filesystem: {read: [/tmp/x], write: [/tmp/x], delete: [/tmp/x]}
          budget: {maxProviderCostUSD: 1}
        """)
        let r = d.with("retry-not-idempotent")
        #expect(r.map(\.stepID) == ["move", "ag", "box"], "\(r.summary)")
        #expect(r.allSatisfy { $0.severity == .warning } && r[0].message.contains("'filesystem.move' is not idempotent"))
    }

    @Test func agentRules() {
        let d = check("""
          steps:
            - id: named
              agent: research-analyst
              objective: Research
            - id: unknown
              agent: nobody
              objective: Research
            - id: inline
              agent: {instructions: "  ", model: sonnet, tools: [filesystem.*, nope.*, "*"]}
              expect:
                - fileExists: ~/a
                - truthy: "true"
          budget: {maxProviderCostUSD: 1}
        """, agents: ["research-analyst"])
        #expect(d.with("unknown-agent").map(\.stepID) == ["unknown"])
        #expect(d.has("missing-field", step: "inline", containing: "instructions"))
        #expect(d.has("invalid-model", step: "inline", containing: "provider/model"))
        #expect(d.with("unknown-tool").map(\.path) == ["spec.steps[2].agent.tools[1]"])
        #expect(d.has("missing-objective", .warning, step: "inline") && !d.has("missing-objective", .warning, step: "named"))
        #expect(d.with("invalid-assertion").map(\.path) == ["spec.steps[2].expect[1]"])
    }

    @Test func subworkflowRules() {
        let d = check("""
          steps:
            - id: ok
              subworkflow: shared-cleanup
            - id: missing
              subworkflow: nowhere
            - id: selfByID
              subworkflow: t
            - id: selfByName
              subworkflow: T
        """, workflows: ["shared-cleanup"])
        #expect(d.with("unknown-workflow").map(\.stepID) == ["missing"])
        #expect(d.with("recursive-subworkflow").map(\.stepID) == ["selfByID", "selfByName"])
    }
}

@Suite("Workflow validator: expressions (unit)") struct ValidatorExpressionTests {
    @Test func syntaxErrorsAndUnknownFunctions() {
        let d = check("""
          steps:
            - id: a
              when: ${{ 1 + }}
              delay: 1
            - id: b
              transform: nope(1) + len("x")
            - id: c
              tool: filesystem.list
              with: {path: "/tmp/${{ unterminated"}
            - id: d
              if: " "
              then: [a]
        """)
        #expect(d.has("expression-syntax", step: "a") && d.with("expression-syntax").first?.path == "spec.steps[0].when")
        #expect(d.has("unknown-function", step: "b", containing: "'nope'") && d.with("unknown-function").count == 1)
        #expect(d.has("expression-syntax", step: "c", containing: "unterminated"))
        #expect(d.has("expression-syntax", step: "d", containing: "empty expression"))
    }

    @Test func parametersVariablesEnvironmentAndNames() {
        let d = check("""
          parameters:
            - {name: declared, type: string, default: x}
          variables: {known: 1}
          steps:
            - id: a
              set:
                later: ${{ params.declared + params.missing }}
            - id: b
              needs: [a]
              transform: ${{ vars.known + vars.later + vars.never }}
              into: fromTransform
            - id: c
              needs: [b]
              transform: ${{ vars.fromTransform }}
            - id: d
              transform: ${{ env.HOME + env.PATH + env["SHELL"] }}
            - id: e
              transform: ${{ item + stranger + map([1], x => x + other) }}
        """)
        #expect(d.with("missing-parameter").count == 1 && d.has("missing-parameter", step: "a", containing: "'missing'"))
        #expect(d.with("unset-variable").count == 1 && d.has("unset-variable", .warning, step: "b", containing: "vars.never"))
        #expect(d.with("env-not-allowed").map { $0.message.contains("env.PATH") || $0.message.contains("env.SHELL") } == [true, true])
        let names = d.with("unknown-name")
        #expect(names.count == 3 && names.allSatisfy { $0.stepID == "e" })
        #expect(!names.contains { $0.message.contains("'x'") }, "lambda parameters are bound")
    }

    @Test func stepReferencesMustBeUpstream() {
        let d = check("""
          steps:
            - id: first
              delay: 1
            - id: sibling
              transform: ${{ steps.first.status }}
            - id: ghostRef
              transform: ${{ steps.ghost.output }}
            - id: selfRef
              transform: ${{ steps.selfRef.output }}
            - id: box
              needs: [first]
              foreach: [1]
              steps:
                - id: inner
                  transform: ${{ steps.first.status }}
            - id: outside
              needs: [box]
              transform: ${{ steps.inner.output }}
            - id: v
              verify:
                - stepSucceeded: first
                - stepSucceeded: ghost
        """)
        let up = d.with("step-not-upstream")
        #expect(up.contains { $0.stepID == "sibling" && $0.message.contains("add it to 'needs'") })
        #expect(up.contains { $0.stepID == "selfRef" && $0.message.contains("its own result") })
        #expect(up.contains { $0.stepID == "outside" && $0.message.contains("container's output") })
        #expect(up.contains { $0.stepID == "v" && $0.path == "spec.steps[6].verify[0].stepSucceeded" })
        #expect(!up.contains { $0.stepID == "inner" }, "a nested step sees what its container sees")
        #expect(d.with("unknown-step-reference").map(\.stepID) == ["ghostRef", "v"])
    }

    @Test func allowedReferencesProduceNoDiagnostic() {
        let d = check("""
          variables: {n: 0}
          steps:
            - id: a
              delay: 1
            - id: b
              needs: [a]
              delay: 1
            - id: transitive
              needs: [b]
              transform: ${{ steps.a.status + steps.b.status }}
            - id: gate
              needs: [a]
              if: ${{ steps.a.status == "succeeded" }}
              then: [gated]
            - id: gated
              transform: ${{ steps.gate.output.result && steps.a.status == "succeeded" }}
            - id: each
              needs: [a]
              foreach: [1, 2]
              as: thing
              collect: use
              steps:
                - id: use
                  transform: ${{ thing + index + len(steps.a.status) }}
            - id: again
              while: ${{ loop.index < 3 && steps.bump.output != 2 && default(steps.peek.output, 0) < 5 }}
              maxIterations: 5
              steps:
                - id: bump
                  transform: ${{ loop.index + default(steps.peek.output, 0) }}
                - id: peek
                  transform: ${{ loop.index }}
            - id: risky
              delay: 1
              onError: recover
            - id: recover
              transform: ${{ error.message + steps.risky.status }}
          onError:
            - id: report
              transform: ${{ error.stepID + steps.a.status + steps.transitive.status }}
        """)
        #expect(d.isEmpty, "\(d.summary)")
    }

    @Test func loopVariablesAreScoped() {
        let d = check("""
          steps:
            - id: each
              foreach: [1]
              steps:
                - id: inside
                  transform: ${{ item }}
            - id: outside
              needs: [each]
              transform: ${{ item }}
            - id: noError
              transform: ${{ error.message }}
            - id: noLoop
              transform: ${{ loop.index }}
        """)
        #expect(d.with("unknown-name").map(\.stepID) == ["outside", "noError", "noLoop"])
    }
}

@Suite("Workflow validator: triggers, parameters, permissions, budget (unit)") struct ValidatorSpecTests {
    @Test(arguments: [
        ("0 9 * * MON", true), ("*/15 * * * *", true), ("0 9-17 * * MON-FRI", true), ("5,35 0 1 jan,jul *", true), ("0 0 * * 7", true),
        ("0 9 * *", false), ("60 * * * *", false), ("* 24 * * *", false), ("0 0 0 * *", false), ("0 0 * 13 *", false),
        ("0 0 * * FUNDAY", false), ("*/0 * * * *", false), ("10-5 * * * *", false), ("0 9 * * MON extra", false), ("a b c d e", false),
    ])
    func cronExpressions(cron: String, valid: Bool) {
        #expect((WorkflowValidator.cronProblem(cron) == nil) == valid, "\(cron): \(WorkflowValidator.cronProblem(cron) ?? "ok")")
    }

    @Test func invalidTriggers() {
        let d = check("""
          triggers:
            - {type: schedule, cron: "61 * * * *", timezone: America/Toronto}
            - {type: schedule, cron: "0 9 * * *", timezone: Mars/Olympus}
            - {type: once, at: tomorrow}
            - {type: once, at: "2026-12-01T09:00:00-05:00"}
            - {type: interval, seconds: 0}
            - {type: interval, seconds: 5}
            - {type: fileChange, path: relative/dir, debounceSeconds: -1}
            - {type: appLaunch, bundleID: Safari}
            - {type: fileChange, path: ~/ok}
          steps:
            - {id: a, delay: 1}
        """)
        #expect(d.with("invalid-cron").map(\.path) == ["spec.triggers[0].cron"])
        #expect(d.with("invalid-timezone").map(\.path) == ["spec.triggers[1].timezone"])
        let t = d.with("invalid-trigger")
        #expect(t.map(\.path) == ["spec.triggers[2].at", "spec.triggers[4].seconds", "spec.triggers[5].seconds", "spec.triggers[6].path",
                                  "spec.triggers[6].debounceSeconds", "spec.triggers[7].bundleID"], "\(t.summary)")
        #expect(t[2].severity == .warning && t[1].severity == .error)
    }

    @Test func parameterRules() {
        let d = check("""
          parameters:
            - {name: a, type: integer, default: 1}
            - {name: a, type: string}
            - {name: bad-name, type: string}
            - {name: n, type: number, default: nope}
            - {name: i, type: integer, default: 1.5}
            - {name: p, type: path, default: 3}
            - {name: ok, type: array, default: [1]}
            - {name: nul, type: object, default: null}
            - {name: req, type: boolean, default: true, required: true}
          steps:
            - {id: a, delay: 1}
        """)
        #expect(d.with("duplicate-parameter").map(\.path) == ["spec.parameters[1].name"])
        #expect(d.has("invalid-id", containing: "'bad-name'"))
        #expect(d.with("parameter-default-type").map(\.path) == ["spec.parameters[3].default", "spec.parameters[4].default", "spec.parameters[5].default"])
        #expect(d.has("parameter-required-default", .info))
    }

    @Test func permissionEntriesMustBeAbsolutePathsAndBareHosts() {
        let d = check("""
          parameters:
            - {name: folder, type: path, default: ~/Work}
            - {name: rel, type: path, default: work/here}
          permissions:
            filesystem:
              read: [relative/path, "~bob/Documents", "", "${{ params.folder }}/in", "${{ params.rel }}"]
              write: [/, "~", "${{ params.ghost }}", "${{ vars.x }}/y", "${{ steps.a.output }}", "${{ 1 + }}"]
            network: ["https://example.com", "example.com/path", "example.com:8080", "*.example.com", "*", ""]
            browser: [ok.example.com, "bad host"]
            scripts: [bash, ruby]
            processes: [git, ""]
          steps:
            - {id: a, delay: 1}
        """)
        let paths = d.with("invalid-permission-path")
        #expect(paths.map(\.path) == ["spec.permissions.filesystem.read[0]", "spec.permissions.filesystem.read[1]", "spec.permissions.filesystem.read[2]",
                                      "spec.permissions.filesystem.read[4]"], "\(paths.summary)")
        #expect(paths[0].message.contains("relative") && paths[1].message.contains("~user") && paths[2].message.contains("empty"))
        #expect(d.with("broad-permission").map(\.path) == ["spec.permissions.filesystem.write[0]", "spec.permissions.filesystem.write[1]", "spec.permissions.network[4]"])
        #expect(d.with("broad-permission").allSatisfy { $0.severity == .warning })
        #expect(d.with("missing-parameter").map(\.path) == ["spec.permissions.filesystem.write[2]"])
        #expect(d.with("invalid-permission-expression").map(\.path) == ["spec.permissions.filesystem.write[3]", "spec.permissions.filesystem.write[4]"])
        #expect(d.with("expression-syntax").map(\.path) == ["spec.permissions.filesystem.write[5]"])
        #expect(d.with("invalid-permission-host").map(\.path) == ["spec.permissions.network[0]", "spec.permissions.network[1]", "spec.permissions.network[2]",
                                                                 "spec.permissions.network[5]", "spec.permissions.browser[1]"])
        #expect(d.with("invalid-value").map(\.path).sorted() == ["spec.permissions.processes[1]", "spec.permissions.scripts[1]"])
    }

    @Test func permissionSufficiencyForPaths() {
        let d = check("""
          parameters:
            - {name: inbox, type: path, default: ~/Inbox}
            - {name: free, type: path, required: true}
          permissions:
            filesystem:
              read: ["${{ params.inbox }}", "${{ params.free }}", /data/in]
              write: [~/Out]
              delete: [~/Trashable]
          steps:
            - id: readOK
              tool: filesystem.read
              with: {path: "${{ params.inbox }}/sub/file.txt"}
            - id: readFree
              tool: filesystem.list
              with: {path: "${{ params.free }}/deep"}
            - id: readDotDot
              tool: filesystem.read
              with: {path: /data/in/../secret.txt}
            - id: readOutside
              tool: filesystem.read
              with: {path: ~/Elsewhere/file.txt}
            - id: readPrefixTrap
              tool: filesystem.read
              with: {path: ~/Inbox2/file.txt}
            - id: writeOutside
              tool: filesystem.write
              with: {path: ~/Inbox/new.txt, content: x}
            - id: copy
              tool: filesystem.copy
              with: {source: ~/Private/a, destination: ~/Out/a}
            - id: moveOut
              tool: filesystem.move
              with: {source: ~/Inbox/a, destination: ~/Out/a}
            - id: trashOK
              tool: filesystem.trash
              with: {paths: [~/Trashable/a, ~/Inbox/b]}
            - id: dynamic
              tool: filesystem.read
              with: {path: "${{ steps.readOK.output.next }}"}
              needs: [readOK]
            - id: relative
              tool: filesystem.read
              with: {path: notes.txt}
            - id: render
              tool: documents.renderPDF
              with: {source: ~/Inbox/r.md, destination: ~/Desktop/r.pdf}
            - id: shot
              tool: screen.capture
              with: {destination: ~/Out/s.png}
        """)
        let m = d.with("permission-missing")
        #expect(m.allSatisfy { $0.severity == .warning })
        func flagged(_ step: String, _ kind: String) -> Bool { m.contains { $0.stepID == step && $0.message.contains("filesystem.\(kind)") } }
        #expect(!m.contains { ["readOK", "readFree", "dynamic", "relative"].contains($0.stepID ?? "") }, "\(m.summary)")
        #expect(flagged("readDotDot", "read") && flagged("readOutside", "read") && flagged("readPrefixTrap", "read"))
        #expect(flagged("writeOutside", "write"))
        #expect(flagged("copy", "read") && !flagged("copy", "write"))
        #expect(flagged("moveOut", "delete") && !flagged("moveOut", "read") && !flagged("moveOut", "write"))
        #expect(m.filter { $0.stepID == "trashOK" }.map(\.path) == ["spec.steps[8].with.paths[1]"])
        #expect(flagged("render", "write") && !flagged("render", "read"))
        #expect(m.contains { $0.stepID == "shot" && $0.message.contains("permissions.screen") } && !flagged("shot", "write"))
    }

    @Test func permissionSufficiencyForHostsProcessesRuntimesAndTheRest() {
        let spec = """
          parameters:
            - {name: site, type: string, default: "https://api.example.com/v1"}
          PERMISSIONS
          steps:
            - id: http
              tool: http.request
              with: {url: "${{ params.site }}/items"}
            - id: httpOther
              tool: http.request
              with: {url: "https://other.test/x"}
            - id: browse
              tool: browser.open
              with: {url: "https://shop.example.org/cart"}
            - id: run
              tool: shell.run
              with: {args: [/usr/bin/make, build]}
            - id: bash
              tool: shell.script
              with: {script: "echo hi"}
            - id: py
              tool: python.run
              with: {script: "print(1)"}
            - id: osa
              tool: applescript.run
              with: {script: "return 1"}
            - id: git
              tool: git.status
              with: {path: /repo}
            - id: clipIn
              tool: clipboard.read
            - id: clipOut
              tool: clipboard.write
              with: {content: x}
            - id: post
              tool: notifications.post
              with: {title: T, body: B}
            - id: tell
              notify: Hello
            - id: shot
              tool: screen.capture
              with: {destination: /out/s.png}
            - id: launch
              tool: system.launchApp
              with: {bundleID: com.apple.Safari}
            - id: press
              tool: accessibility.press
              with: {bundleID: com.apple.Safari, selector: OK}
            - id: key
              tool: http.request
              with:
                url: https://api.example.com/login
                headers: {Authorization: "${{ secret('api-token') }}"}
        """
        let bare = check(spec.replacingOccurrences(of: "PERMISSIONS", with: "permissions: {filesystem: {read: [/repo], write: [/out]}}"))
        let m = bare.with("permission-missing")
        #expect(m.allSatisfy { $0.severity == .warning })
        for (step, text) in [("http", "api.example.com"), ("httpOther", "other.test"), ("browse", "permissions.browser"), ("run", "'make'"),
                             ("bash", "'bash'"), ("py", "'python'"), ("osa", "'applescript'"), ("git", "runs git"), ("clipIn", "clipboard.read"),
                             ("clipOut", "clipboard.write"), ("post", "permissions.notifications"), ("tell", "permissions.notifications"),
                             ("shot", "permissions.screen"), ("launch", "app control"), ("press", "accessibility control"), ("key", "api-token")] {
            #expect(m.contains { $0.stepID == step && $0.message.contains(text) }, "expected a permission warning for \(step) mentioning \(text)\n\(m.summary)")
        }
        let full = check(spec.replacingOccurrences(of: "PERMISSIONS", with: """
        permissions:
            filesystem: {read: [/repo], write: [/out]}
            processes: [make, git]
            scripts: [bash, python, applescript]
            apps: {accessibility: [com.apple.Safari], control: [com.apple.Safari]}
            network: ["*.example.com", other.test]
            browser: [shop.example.org]
            secrets: [api-token]
            clipboard: {read: true, write: true}
            notifications: true
            screen: [display]
        """))
        #expect(full.with("permission-missing").isEmpty, "\(full.summary)")
    }

    @Test func budgetRules() {
        let bad = check("""
          budget: {maxDurationSeconds: 0, maxProviderCostUSD: -1, maxToolCalls: 0, maxTokens: 0}
          steps:
            - {id: a, delay: 1}
        """)
        #expect(bad.with("invalid-budget").map(\.path) == ["spec.budget.maxDurationSeconds", "spec.budget.maxProviderCostUSD", "spec.budget.maxToolCalls", "spec.budget.maxTokens"])
        let warn = check("""
          budget: {maxDurationSeconds: 60, maxToolCalls: 1}
          permissions: {filesystem: {read: [/x]}, notifications: true}
          steps:
            - id: slow
              tool: filesystem.list
              with: {path: /x}
              timeoutSeconds: 120
            - id: again
              tool: filesystem.list
              with: {path: /x}
            - id: ag
              agent: {instructions: Think}
              objective: Think
        """)
        #expect(warn.has("budget-missing-cost-limit", .warning))
        #expect(warn.has("budget-timeout-exceeds-duration", .warning, step: "slow"))
        #expect(warn.has("budget-too-small", .warning))
        let unused = check("""
          budget: {maxProviderCostUSD: 2}
          steps:
            - {id: a, delay: 1}
        """)
        #expect(unused.has("budget-unused", .info) && unused.errors.isEmpty)
    }

    @Test func unsupportedVersionAndKindAreReportedOnHandBuiltDocuments() {
        var doc = WorkflowDocument(apiVersion: "orix.ai/v9", kind: "Job", metadata: WorkflowMetadata(id: "x", name: "X"))
        doc.spec.steps = [WorkflowStep(id: "a", kind: .delay(DelayStep(seconds: 1)))]
        let d = WorkflowValidator.validate(doc, tools: [], agents: [], workflows: [])
        #expect(d.has("unsupported-version") && d.has("unsupported-kind"))
    }
}

@Suite("Declared capabilities, proposed grants and source positions (unit)") struct ValidatorCapabilityTests {
    private func document() throws -> WorkflowDocument {
        try WorkflowCodec.parse("""
        apiVersion: orix.ai/v1
        kind: Automation
        metadata: {id: caps, name: Caps}
        spec:
          parameters:
            - {name: inbox, type: path, default: ~/Inbox}
            - {name: needed, type: path, required: true}
          permissions:
            filesystem:
              read: ["~/Docs/../Docs/In", "${{ params.inbox }}", "${{ params.needed }}", relative, "~bob/x", "~"]
              write: [/var/tmp/out]
              delete: [~/Docs/In]
            processes: [git]
            scripts: [python]
            apps: {automation: [com.apple.iCal], accessibility: [com.apple.Safari], control: [com.apple.Preview]}
            network: [API.Example.com]
            browser: ["*.example.org"]
            secrets: [smtp-password]
            clipboard: {read: true}
            notifications: true
            screen: ["window:com.apple.Safari"]
          steps:
            - {id: a, delay: 1}
        """)
    }

    @Test func declaredCapabilitiesExpandTildeAgainstTheGivenHome() throws {
        let caps = try document().declaredCapabilities(home: "/Users/tester")
        #expect(caps == [
            .fileRead(path: "/Users/tester/Docs/In"), .fileRead(path: "/Users/tester/Inbox"), .fileRead(path: "/Users/tester"),
            .fileWrite(path: PathResolver.resolveSymlinks("/var/tmp/out")), .fileDelete(path: "/Users/tester/Docs/In"),
            .processExec(executable: "git"), .scriptRuntime(name: "python"), .appAutomation(bundleID: "com.apple.iCal"),
            .accessibility(bundleID: "com.apple.Safari"), .appControl(bundleID: "com.apple.Preview"), .network(host: "api.example.com"),
            .browser(host: "*.example.org"), .secret(reference: "smtp-password"), .clipboardRead, .notify,
            .screenCapture(scope: "window:com.apple.Safari"),
        ])
        let supplied = try document().declaredCapabilities(home: "/Users/tester", parameters: ["needed": "~/Needed", "inbox": "/abs/inbox"])
        #expect(supplied.contains(.fileRead(path: "/Users/tester/Needed")) && supplied.contains(.fileRead(path: "/abs/inbox")))
        #expect(!supplied.contains(.fileRead(path: "/Users/tester/Inbox")))
    }

    @Test func proposedGrantsAreWorkflowScopedAndNeverAboveTierTwo() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let grants = try document().proposedGrants(workflowID: "wf-9", home: "/Users/tester", now: now)
        #expect(grants.count == 16)
        #expect(grants.allSatisfy { $0.scope == .workflow(workflowID: "wf-9") && $0.maxTier <= .consequential && $0.source == "workflow:wf-9" && $0.createdAt == now && $0.isActive(at: now) })
        func tier(_ c: Capability) -> ApprovalTier? { grants.first { $0.capability == c }?.maxTier }
        #expect(tier(.fileRead(path: "/Users/tester/Inbox")) == .readOnly)
        #expect(tier(.fileDelete(path: "/Users/tester/Docs/In")) == .reversibleWrite)
        #expect(tier(.clipboardRead) == .readOnly && tier(.notify) == .reversibleWrite)
        #expect(tier(.processExec(executable: "git")) == .consequential && tier(.network(host: "api.example.com")) == .consequential)
        #expect(Set(grants.map(\.id)).count == grants.count)
        #expect(WorkflowDocument.proposedTier(for: .secret(reference: "x")) == .consequential)
    }

    @Test func parameterDefaultsFeedPermissionResolution() throws {
        let doc = try document()
        #expect(doc.parameterDefaults == ["inbox": "~/Inbox"])
        #expect(doc.resolvePermissionEntry("${{ params.inbox }}/a", parameters: [:]) == "~/Inbox/a")
        #expect(doc.resolvePermissionEntry("${{ params.needed }}", parameters: [:]) == nil)
        #expect(doc.resolvePermissionEntry("${{ env.HOME }}", parameters: [:]) == nil)
        #expect(doc.resolvePermissionEntry("plain", parameters: [:]) == "plain")
    }

    @Test func diagnoseAttachesSourcePositionsToValidatorDiagnostics() {
        let source = """
        apiVersion: orix.ai/v1
        kind: Automation
        metadata: {id: pos, name: Pos}
        spec:
          steps:
            - id: a
              tool: filesystem.lst
              with:
                path: /x
            - id: b
              needs: [ghost]
              delay: 1
        """
        let result = WorkflowCodec.diagnose(source: source, tools: CanonicalTools.manifests())
        #expect(result.document != nil)
        let tool = result.diagnostics.first { $0.code == "unknown-tool" }
        #expect(tool?.line == 7 && tool?.column == 7)
        let need = result.diagnostics.first { $0.code == "unknown-need" }
        #expect(need?.line == 11 && need?.column == 15, "\(need?.line ?? 0):\(need?.column ?? 0)")
        let broken = WorkflowCodec.diagnose(source: "spec: [", tools: [])
        #expect(broken.document == nil && broken.diagnostics.first?.code == "syntax" && broken.diagnostics.first?.line == 1)
    }
}
