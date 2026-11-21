// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/Generators.swift
// Description: Seeded random generators of workflow documents and JSON values for the property tests (deterministic: no system randomness).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore
@testable import ORIXWorkflowEngine

/// SplitMix64: small, deterministic, good enough for test data.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct DocumentGenerator {
    var rng: SeededRNG
    private var counter = 0
    init(seed: UInt64) { rng = SeededRNG(seed: seed) }

    static let trickyStrings: [String] = [
        "", " ", "plain", "two words", "true", "false", "null", "~", "Null", "123", "-7", "1.5", "1e3", "007", ".inf", "0x1F",
        "- dash", "-", "a: b", "a:b", "key:", "#hash", "a #b", "a#b", "[x]", "{y}", "a,b", "\"quoted\"", "it's", "'single'",
        "back\\slash", "tab\there", "line1\nline2", "line1\nline2\n", "trailing\n\n", "\nleading", "  indented\nnext", "a\n\nb",
        "multi\n  keep indent\nend", "sp \nline", "emoji 🚀 ok", "accentué çà", "~/ORIX Samples/x", "/abs/path with space/f.txt",
        "${{ params.folder }}/out.pdf", "${{ steps.a.output.items }}", "0 9 * * MON", "*.pdf", "&anchor", "*alias", "!tag", "@at", "`tick`",
        "%percent", "|pipe", ">gt", "?q", "x: ", " lead", "trail ", "a\rb", "ctrl\u{01}x", "nbsp\u{A0}x", "ls\u{2028}x", "---", "...",
        "on", "yes", "no", "https://example.com/a?b=c#d", "{\"json\": [1, 2]}", "end:",
    ]

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
    mutating func bool(_ p: Double = 0.5) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }

    mutating func string() -> String {
        if bool(0.7) { return pick(Self.trickyStrings) }
        let alphabet = Array("abc XYZ019_-.:/#'\"\\{}[],\n$~é🙂")
        return String((0..<int(0...12)).map { _ in pick(alphabet) })
    }

    mutating func ident() -> String {
        counter += 1
        return pick(["step", "s", "fetch", "render", "check_it", "a-b"]) + "\(counter)"
    }

    mutating func double() -> Double {
        pick([0, 1, -1, 0.5, 2.25, 1e-7, 123456.789, 1e20, -3.0e-12, 30, 0.1 + 0.2, Double(int(-1000...1000)) / 7])
    }

    mutating func json(depth: Int = 0) -> JSONValue {
        let top = depth >= 3 ? 4 : 6
        switch int(0...top) {
        case 0: return .null
        case 1: return .bool(bool())
        case 2: return .int(pick([0, 1, -1, 42, Int.max, Int.min, int(-100000...100000)]))
        case 3: return .number(double())
        case 4: return .string(string())
        case 5: return .array((0..<int(0...4)).map { _ in json(depth: depth + 1) })
        default: return .object(object(depth: depth + 1))
        }
    }

    mutating func object(depth: Int = 0) -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        for _ in 0..<int(0...4) { o[bool(0.8) ? pick(["path", "source", "destination", "url", "args", "recursive", "pattern"]) : string()] = json(depth: depth + 1) }
        return o
    }

    mutating func strings(_ max: Int = 3) -> [String] { (0..<int(0...max)).map { _ in string() } }

    mutating func assertion() -> WorkflowAssertion {
        switch int(0...6) {
        case 0: return .fileExists(path: string())
        case 1: return .fileNonEmpty(path: string())
        case 2: return .fileContains(path: string(), text: string())
        case 3: return .dirNonEmpty(path: string())
        case 4: return .equals(json(), json())
        case 5: return .truthy(json())
        default: return .stepSucceeded(string())
        }
    }

    mutating func step(depth: Int = 0) -> WorkflowStep {
        let kind: WorkflowStepKind
        let maxKind = depth >= 2 ? 12 : 15
        switch int(0...maxKind) {
        case 0: kind = .tool(ToolStep(tool: pick(["filesystem.list", "shell.run", "http.request", string()]), arguments: object()))
        case 1:
            let ref: AgentReference = bool() ? .profile(string()) : .inline(InlineAgent(instructions: string(), model: bool() ? string() : nil, tools: strings()))
            kind = .agent(AgentStep(agent: ref, objective: string(), inputs: object(), expect: (0..<int(0...2)).map { _ in assertion() }))
        case 2: kind = .condition(ConditionStep(condition: string(), then: strings(), otherwise: strings()))
        case 3: kind = .switch(SwitchStep(on: string(), cases: (0..<int(0...3)).map { _ in SwitchCase(value: json(), steps: strings()) }, defaultSteps: strings()))
        case 4: kind = .approval(ApprovalStep(message: string()))
        case 5: kind = .delay(DelayStep(seconds: pick([.int(int(0...60)), .number(double()), .string(string())])))
        case 6: kind = .set(SetStep(values: object()))
        case 7: kind = .transform(TransformStep(expression: string(), into: bool() ? string() : nil))
        case 8: kind = .verify(VerifyStep(assertions: (0..<int(0...3)).map { _ in assertion() }))
        case 9: kind = .subworkflow(SubworkflowStep(workflow: string(), inputs: object()))
        case 10: kind = .notify(NotifyStep(message: string(), title: bool() ? string() : nil))
        case 11: kind = .fail(FailStep(message: string()))
        case 12: kind = .output(OutputStep(values: object(), artifacts: strings()))
        case 13:
            let items: JSONValue = bool() ? .string(string()) : .array((0..<int(0...3)).map { _ in json(depth: 2) })
            kind = .foreach(ForeachStep(items: items, itemName: bool(0.7) ? "item" : string(), concurrency: int(1...4),
                                        steps: steps(depth: depth + 1, max: 3), collect: bool(0.3) ? string() : nil))
        case 14:
            kind = .parallel(ParallelStep(branches: (0..<int(0...3)).map { _ in ParallelBranch(name: string(), steps: steps(depth: depth + 1, max: 2)) }))
        default: kind = .loop(LoopStep(condition: string(), maxIterations: int(1...50), steps: steps(depth: depth + 1, max: 2)))
        }
        return WorkflowStep(
            id: bool(0.9) ? ident() : string(), name: bool(0.4) ? string() : nil, needs: bool(0.5) ? strings() : [],
            when: bool(0.3) ? string() : nil,
            retry: bool(0.3) ? WorkflowRetryPolicy(maxAttempts: int(1...5), backoffSeconds: pick([0, 1, 0.5]), backoffMultiplier: pick([1, 2, 1.5]), force: bool()) : nil,
            timeoutSeconds: bool(0.3) ? double() : nil, continueOnError: bool(0.2), onError: bool(0.2) ? string() : nil, kind: kind)
    }

    mutating func steps(depth: Int, max: Int) -> [WorkflowStep] { (0..<int(0...max)).map { _ in step(depth: depth) } }

    mutating func trigger() -> WorkflowTrigger {
        switch int(0...6) {
        case 0: return .manual
        case 1: return .schedule(cron: string(), timezone: bool() ? string() : nil)
        case 2: return .once(at: string())
        case 3: return .interval(seconds: double())
        case 4: return .fileChange(path: string(), glob: bool() ? string() : nil, debounceSeconds: bool() ? double() : nil)
        case 5: return .login
        default: return .appLaunch(bundleID: string())
        }
    }

    mutating func document() -> WorkflowDocument {
        var spec = WorkflowSpec()
        spec.triggers = (0..<int(0...3)).map { _ in trigger() }
        spec.parameters = (0..<int(0...3)).map { _ in
            WorkflowParameter(name: string(), type: pick(WorkflowParameterType.allCases), defaultValue: bool() ? json() : nil, description: string(), required: bool())
        }
        if bool(0.7) {
            spec.permissions = WorkflowPermissions(
                filesystem: .init(read: strings(), write: strings(), delete: strings()), processes: strings(), scripts: strings(),
                apps: .init(automation: strings(), accessibility: strings(), control: strings()), network: strings(), browser: strings(),
                secrets: strings(), clipboard: .init(read: bool(), write: bool()), notifications: bool(), screen: strings())
        }
        if bool(0.6) {
            spec.budget = WorkflowBudget(maxDurationSeconds: bool() ? double() : nil, maxProviderCostUSD: bool() ? double() : nil,
                                         maxToolCalls: bool() ? int(0...500) : nil, maxTokens: bool() ? int(0...1_000_000) : nil)
        }
        spec.variables = object()
        spec.steps = steps(depth: 0, max: 6)
        spec.onError = bool(0.3) ? steps(depth: 1, max: 2) : []
        for _ in 0..<int(0...3) { spec.layout[string()] = WorkflowNodePosition(x: double(), y: double()) }
        return WorkflowDocument(metadata: WorkflowMetadata(id: string(), name: string(), description: string(), tags: strings()), spec: spec)
    }
}
