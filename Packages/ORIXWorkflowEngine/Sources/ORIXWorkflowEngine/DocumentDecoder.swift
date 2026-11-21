// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/DocumentDecoder.swift
// Description: Turns positioned YAML/JSON nodes into the workflow IR, reporting every structural problem with line, column and document path.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

struct DocumentDecoder {
    private(set) var diagnostics: [WorkflowDiagnostic] = []
    /// Shorthand forms that were normalised (reported by `roundTripLoss`).
    private(set) var notes: [String] = []
    private var currentStep: String?

    static let stepKindKeys = ["tool", "agent", "verifier", "if", "switch", "foreach", "parallel", "while", "approval", "delay",
                               "set", "transform", "verify", "subworkflow", "notify", "fail", "output"]

    // MARK: Helpers

    private struct Fields {
        let node: YNode
        let path: String
        var byKey: [String: YEntry]
        var order: [YEntry]
        var used: Set<String> = []
        mutating func take(_ key: String) -> YNode? { used.insert(key); return byKey[key]?.value }
        func has(_ key: String) -> Bool { byKey[key] != nil }
        func sub(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
    }

    private mutating func report(_ code: String, _ message: String, at node: YNode, path: String, severity: WorkflowDiagnostic.Severity = .error) {
        diagnostics.append(WorkflowDiagnostic(severity: severity, code: code, message: message, line: node.line, column: node.column,
                                              stepID: currentStep, path: path))
    }

    private mutating func fields(_ node: YNode, _ path: String) -> Fields? {
        guard case .map(let entries) = node.value else {
            report("type-mismatch", "expected a mapping, found \(node.typeName)", at: node, path: path)
            return nil
        }
        return Fields(node: node, path: path, byKey: Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { f, _ in f }), order: entries)
    }

    private mutating func finish(_ f: Fields, allowed hint: String = "") {
        for e in f.order where !f.used.contains(e.key) {
            diagnostics.append(WorkflowDiagnostic(code: "unknown-field", message: "unknown field '\(e.key)'" + (hint.isEmpty ? "" : " (\(hint))"),
                                                  line: e.line, column: e.column, stepID: currentStep, path: f.sub(e.key)))
        }
    }

    private mutating func string(_ node: YNode?, _ path: String) -> String? {
        guard let node else { return nil }
        if case .string(let s) = node.value { return s }
        report("type-mismatch", "expected a string, found \(node.typeName) (quote the value)", at: node, path: path)
        return nil
    }

    /// Expression-bearing fields accept bare booleans and numbers (`when: true`) and keep their text.
    private mutating func expressionString(_ node: YNode?, _ path: String) -> String? {
        guard let node else { return nil }
        switch node.value {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        default:
            report("type-mismatch", "expected an expression string, found \(node.typeName)", at: node, path: path)
            return nil
        }
    }

    private mutating func bool(_ node: YNode?, _ path: String) -> Bool? {
        guard let node else { return nil }
        if case .bool(let b) = node.value { return b }
        report("type-mismatch", "expected true or false, found \(node.typeName)", at: node, path: path)
        return nil
    }

    private mutating func int(_ node: YNode?, _ path: String) -> Int? {
        guard let node else { return nil }
        if case .int(let i) = node.value { return i }
        if case .double(let d) = node.value, d.rounded() == d, abs(d) < 9e15 { return Int(d) }
        report("type-mismatch", "expected an integer, found \(node.typeName)", at: node, path: path)
        return nil
    }

    private mutating func double(_ node: YNode?, _ path: String) -> Double? {
        guard let node else { return nil }
        if case .int(let i) = node.value { return Double(i) }
        if case .double(let d) = node.value { return d }
        report("type-mismatch", "expected a number, found \(node.typeName)", at: node, path: path)
        return nil
    }

    private mutating func stringList(_ node: YNode?, _ path: String) -> [String] {
        guard let node else { return [] }
        switch node.value {
        case .null: return []
        case .string(let s): return [s]
        case .seq(let items):
            var out: [String] = []
            for (i, item) in items.enumerated() { if let s = string(item, "\(path)[\(i)]") { out.append(s) } }
            return out
        default:
            report("type-mismatch", "expected a list of strings, found \(node.typeName)", at: node, path: path)
            return []
        }
    }

    private mutating func object(_ node: YNode?, _ path: String) -> [String: JSONValue] {
        guard let node else { return [:] }
        if case .null = node.value { return [:] }
        guard case .object(let o) = node.json else {
            report("type-mismatch", "expected a mapping, found \(node.typeName)", at: node, path: path)
            return [:]
        }
        return o
    }

    private mutating func sequence(_ node: YNode?, _ path: String) -> [YNode] {
        guard let node else { return [] }
        switch node.value {
        case .null: return []
        case .seq(let items): return items
        default:
            report("type-mismatch", "expected a list, found \(node.typeName)", at: node, path: path)
            return []
        }
    }

    // MARK: Document

    mutating func decode(_ root: YNode) -> WorkflowDocument? {
        guard var f = fields(root, "") else { return nil }
        var apiVersion = WorkflowDocument.currentAPIVersion
        if let n = f.take("apiVersion"), let s = string(n, "apiVersion") {
            apiVersion = s
            if s != WorkflowDocument.currentAPIVersion {
                report("unsupported-version", "unsupported apiVersion '\(s)'; this build reads '\(WorkflowDocument.currentAPIVersion)'", at: n, path: "apiVersion")
            }
        }
        var kind = WorkflowDocument.automationKind
        if let n = f.take("kind"), let s = string(n, "kind") {
            kind = s
            if s != WorkflowDocument.automationKind { report("unsupported-kind", "unsupported kind '\(s)'; expected 'Automation'", at: n, path: "kind") }
        }
        var metadata = WorkflowMetadata(id: "", name: "")
        if let n = f.take("metadata"), var m = fields(n, "metadata") {
            let id = string(m.take("id"), "metadata.id")
            let name = string(m.take("name"), "metadata.name")
            if id == nil && name == nil { report("missing-field", "metadata needs a 'name' (and optionally an 'id')", at: n, path: "metadata") }
            if id == nil, name != nil { notes.append("metadata.id is derived from metadata.name and will be written explicitly") }
            metadata = WorkflowMetadata(id: id ?? WorkflowMetadata.slug(name ?? ""), name: name ?? id ?? "",
                                        description: string(m.take("description"), "metadata.description") ?? "",
                                        tags: stringList(m.take("tags"), "metadata.tags"))
            finish(m)
        } else if !f.has("metadata") {
            report("missing-field", "missing 'metadata'", at: root, path: "metadata")
        }
        var spec = WorkflowSpec()
        if let n = f.take("spec") {
            if let s = decodeSpec(n) { spec = s }
        } else {
            report("missing-field", "missing 'spec'", at: root, path: "spec")
        }
        finish(f)
        if diagnostics.contains(where: { $0.severity == .error }) { return nil }
        return WorkflowDocument(apiVersion: apiVersion, kind: kind, metadata: metadata, spec: spec)
    }

    private mutating func decodeSpec(_ node: YNode) -> WorkflowSpec? {
        guard var f = fields(node, "spec") else { return nil }
        var spec = WorkflowSpec()
        if f.has("trigger") && f.has("triggers") {
            report("conflicting-fields", "use either 'trigger' or 'triggers', not both", at: f.byKey["trigger"]!.value, path: "spec.trigger")
        }
        if let n = f.take("trigger") {
            notes.append("'spec.trigger' is written as the list 'spec.triggers'")
            if case .seq(let items) = n.value {
                for (i, t) in items.enumerated() { if let tr = decodeTrigger(t, "spec.trigger[\(i)]") { spec.triggers.append(tr) } }
            } else if let tr = decodeTrigger(n, "spec.trigger") { spec.triggers.append(tr) }
        }
        if let n = f.take("triggers") {
            for (i, t) in sequence(n, "spec.triggers").enumerated() {
                if let tr = decodeTrigger(t, "spec.triggers[\(i)]") { spec.triggers.append(tr) }
            }
        }
        for (i, p) in sequence(f.take("parameters"), "spec.parameters").enumerated() {
            let path = "spec.parameters[\(i)]"
            guard var pf = fields(p, path) else { continue }
            guard let name = string(pf.take("name"), path + ".name") else {
                if !pf.has("name") { report("missing-field", "parameter needs a 'name'", at: p, path: path) }
                continue
            }
            var type = WorkflowParameterType.string
            if let tn = pf.take("type"), let ts = string(tn, path + ".type") {
                if let t = WorkflowParameterType(rawValue: ts) { type = t }
                else { report("invalid-value", "unknown parameter type '\(ts)'; expected one of \(WorkflowParameterType.allCases.map(\.rawValue).joined(separator: ", "))", at: tn, path: path + ".type") }
            }
            let def = pf.take("default")?.json
            let desc = string(pf.take("description"), path + ".description") ?? ""
            let req = bool(pf.take("required"), path + ".required") ?? false
            finish(pf)
            spec.parameters.append(WorkflowParameter(name: name, type: type, defaultValue: def, description: desc, required: req))
        }
        if let n = f.take("permissions") { spec.permissions = decodePermissions(n) }
        if let n = f.take("budget"), var b = fields(n, "spec.budget") {
            spec.budget = WorkflowBudget(maxDurationSeconds: double(b.take("maxDurationSeconds"), "spec.budget.maxDurationSeconds"),
                                         maxProviderCostUSD: double(b.take("maxProviderCostUSD"), "spec.budget.maxProviderCostUSD"),
                                         maxToolCalls: int(b.take("maxToolCalls"), "spec.budget.maxToolCalls"),
                                         maxTokens: int(b.take("maxTokens"), "spec.budget.maxTokens"))
            finish(b)
        }
        spec.variables = object(f.take("variables"), "spec.variables")
        spec.steps = decodeSteps(f.take("steps"), "spec.steps")
        spec.onError = decodeSteps(f.take("onError"), "spec.onError")
        if let n = f.take("layout"), let lf = fields(n, "spec.layout") {
            for e in lf.order {
                let path = "spec.layout.\(e.key)"
                guard var pf = fields(e.value, path) else { continue }
                let x = double(pf.take("x"), path + ".x"), y = double(pf.take("y"), path + ".y")
                finish(pf)
                if let x, let y { spec.layout[e.key] = WorkflowNodePosition(x: x, y: y) }
                else { report("missing-field", "a layout entry needs numeric 'x' and 'y'", at: e.value, path: path) }
            }
        }
        finish(f)
        return spec
    }

    private mutating func decodeTrigger(_ node: YNode, _ path: String) -> WorkflowTrigger? {
        if case .string(let s) = node.value {
            switch s {
            case "manual": return .manual
            case "login": return .login
            default:
                report("invalid-value", "trigger '\(s)' needs a mapping with its settings", at: node, path: path)
                return nil
            }
        }
        guard var f = fields(node, path) else { return nil }
        guard let tn = f.take("type"), let type = string(tn, path + ".type") else {
            if !f.has("type") { report("missing-field", "trigger needs a 'type'", at: node, path: path) }
            return nil
        }
        var out: WorkflowTrigger?
        func missing(_ key: String) -> String { "a '\(type)' trigger needs '\(key)'" }
        switch type {
        case "manual": out = .manual
        case "login": out = .login
        case "schedule":
            let tz = string(f.take("timezone"), path + ".timezone")
            if let cron = string(f.take("cron"), path + ".cron") { out = .schedule(cron: cron, timezone: tz) }
            else if !f.has("cron") { report("missing-field", missing("cron"), at: node, path: path) }
        case "once":
            if let at = string(f.take("at"), path + ".at") { out = .once(at: at) }
            else if !f.has("at") { report("missing-field", missing("at"), at: node, path: path) }
        case "interval":
            if let s = double(f.take("seconds"), path + ".seconds") { out = .interval(seconds: s) }
            else if !f.has("seconds") { report("missing-field", missing("seconds"), at: node, path: path) }
        case "fileChange":
            let glob = string(f.take("glob"), path + ".glob")
            let debounce = double(f.take("debounceSeconds"), path + ".debounceSeconds")
            if let p = string(f.take("path"), path + ".path") { out = .fileChange(path: p, glob: glob, debounceSeconds: debounce) }
            else if !f.has("path") { report("missing-field", missing("path"), at: node, path: path) }
        case "appLaunch":
            if let b = string(f.take("bundleID"), path + ".bundleID") { out = .appLaunch(bundleID: b) }
            else if !f.has("bundleID") { report("missing-field", missing("bundleID"), at: node, path: path) }
        default:
            report("invalid-value", "unknown trigger type '\(type)'; expected manual, schedule, once, interval, fileChange, login or appLaunch", at: tn, path: path + ".type")
            return nil
        }
        finish(f)
        return out
    }

    private mutating func decodePermissions(_ node: YNode) -> WorkflowPermissions {
        var p = WorkflowPermissions()
        let base = "spec.permissions"
        guard var f = fields(node, base) else { return p }
        if let n = f.take("filesystem"), var fs = fields(n, base + ".filesystem") {
            p.filesystem = .init(read: stringList(fs.take("read"), base + ".filesystem.read"),
                                 write: stringList(fs.take("write"), base + ".filesystem.write"),
                                 delete: stringList(fs.take("delete"), base + ".filesystem.delete"))
            finish(fs)
        }
        p.processes = stringList(f.take("processes"), base + ".processes")
        if f.has("runtimes") && !f.has("scripts") {
            notes.append("'permissions.runtimes' is written as 'permissions.scripts'")
            p.scripts = stringList(f.take("runtimes"), base + ".runtimes")
        } else {
            p.scripts = stringList(f.take("scripts"), base + ".scripts")
        }
        if let n = f.take("apps"), var a = fields(n, base + ".apps") {
            p.apps = .init(automation: stringList(a.take("automation"), base + ".apps.automation"),
                           accessibility: stringList(a.take("accessibility"), base + ".apps.accessibility"),
                           control: stringList(a.take("control"), base + ".apps.control"))
            finish(a)
        }
        for key in ["network", "browser"] {
            guard let n = f.take(key) else { continue }
            var hosts: [String]
            if case .map = n.value, var h = fields(n, "\(base).\(key)") {
                notes.append("'permissions.\(key).hosts' is written as the list 'permissions.\(key)'")
                hosts = stringList(h.take("hosts"), "\(base).\(key).hosts")
                finish(h)
            } else { hosts = stringList(n, "\(base).\(key)") }
            if key == "network" { p.network = hosts } else { p.browser = hosts }
        }
        p.secrets = stringList(f.take("secrets"), base + ".secrets")
        if let n = f.take("clipboard") {
            if case .bool(let b) = n.value {
                notes.append("'permissions.clipboard: \(b)' is written as explicit read/write flags")
                p.clipboard = .init(read: b, write: b)
            } else if var c = fields(n, base + ".clipboard") {
                p.clipboard = .init(read: bool(c.take("read"), base + ".clipboard.read") ?? false,
                                    write: bool(c.take("write"), base + ".clipboard.write") ?? false)
                finish(c)
            }
        }
        p.notifications = bool(f.take("notifications"), base + ".notifications") ?? false
        if let n = f.take("screen") {
            if case .bool(let b) = n.value {
                notes.append("'permissions.screen: \(b)' is written as a list of capture scopes")
                p.screen = b ? ["display"] : []
            } else { p.screen = stringList(n, base + ".screen") }
        }
        finish(f)
        return p
    }

    // MARK: Steps

    private mutating func decodeSteps(_ node: YNode?, _ path: String) -> [WorkflowStep] {
        var out: [WorkflowStep] = []
        for (i, s) in sequence(node, path).enumerated() {
            if let step = decodeStep(s, "\(path)[\(i)]") { out.append(step) }
        }
        return out
    }

    private mutating func decodeStep(_ node: YNode, _ path: String) -> WorkflowStep? {
        let outer = currentStep
        defer { currentStep = outer }
        guard var f = fields(node, path) else { return nil }
        if case .string(let s)? = f.byKey["id"]?.value.value { currentStep = s }
        guard let id = string(f.take("id"), path + ".id") else {
            if !f.has("id") { report("missing-field", "step needs an 'id'", at: node, path: path) }
            return nil
        }
        let name = string(f.take("name"), path + ".name")
        let needs = stringList(f.take("needs"), path + ".needs")
        let when = expressionString(f.take("when"), path + ".when")
        var retry: WorkflowRetryPolicy?
        if let n = f.take("retry") {
            if case .int(let i) = n.value { retry = WorkflowRetryPolicy(maxAttempts: i) }
            else if var r = fields(n, path + ".retry") {
                retry = WorkflowRetryPolicy(maxAttempts: int(r.take("maxAttempts"), path + ".retry.maxAttempts") ?? 1,
                                            backoffSeconds: double(r.take("backoffSeconds"), path + ".retry.backoffSeconds") ?? 0,
                                            backoffMultiplier: double(r.take("backoffMultiplier"), path + ".retry.backoffMultiplier") ?? 1,
                                            force: bool(r.take("force"), path + ".retry.force") ?? false)
                if !r.has("maxAttempts") { report("missing-field", "retry needs 'maxAttempts'", at: n, path: path + ".retry") }
                finish(r)
            }
        }
        let timeout = double(f.take("timeoutSeconds"), path + ".timeoutSeconds")
        let continueOnError = bool(f.take("continueOnError"), path + ".continueOnError") ?? false
        let onError = string(f.take("onError"), path + ".onError")

        let present = Self.stepKindKeys.filter { f.has($0) }
        guard present.count == 1, let key = present.first else {
            let msg = present.isEmpty
                ? "step has no kind; add exactly one of: \(Self.stepKindKeys.filter { $0 != "verifier" }.joined(separator: ", "))"
                : "step declares several kinds (\(present.joined(separator: ", "))); keep exactly one"
            report("invalid-step-kind", msg, at: node, path: path)
            return nil
        }
        let kn = f.take(key)!
        let kp = "\(path).\(key)"
        var kind: WorkflowStepKind?
        switch key {
        case "tool":
            if let t = string(kn, kp) { kind = .tool(ToolStep(tool: t, arguments: object(f.take("with"), path + ".with"))) }
        case "agent":
            var ref: AgentReference?
            if case .string(let s) = kn.value { ref = .profile(s) }
            else if var a = fields(kn, kp) {
                let instr = string(a.take("instructions"), kp + ".instructions")
                if instr == nil && !a.has("instructions") { report("missing-field", "an inline agent needs 'instructions'", at: kn, path: kp) }
                ref = .inline(InlineAgent(instructions: instr ?? "", model: string(a.take("model"), kp + ".model"),
                                          tools: stringList(a.take("tools"), kp + ".tools")))
                finish(a)
            }
            let objective = string(f.take("objective"), path + ".objective") ?? ""
            let inputs = object(f.take("inputs"), path + ".inputs")
            let expect = decodeAssertions(f.take("expect"), path + ".expect")
            if let ref { kind = .agent(AgentStep(agent: ref, objective: objective, inputs: inputs, expect: expect)) }
        case "verifier":
            if let v = string(kn, kp) {
                notes.append("step '\(id)': the 'verifier: \(v)' shorthand is written as a 'verify' step asserting that each needed step succeeded")
                kind = .verify(VerifyStep(assertions: needs.map { .stepSucceeded($0) }))
            }
        case "if":
            if let c = expressionString(kn, kp) {
                kind = .condition(ConditionStep(condition: c, then: stringList(f.take("then"), path + ".then"),
                                                otherwise: stringList(f.take("else"), path + ".else")))
            }
        case "switch":
            var cases: [SwitchCase] = []
            for (i, c) in sequence(f.take("cases"), path + ".cases").enumerated() {
                let cp = "\(path).cases[\(i)]"
                guard var cf = fields(c, cp) else { continue }
                guard let v = cf.take("value") else { report("missing-field", "a switch case needs a 'value'", at: c, path: cp); continue }
                cases.append(SwitchCase(value: v.json, steps: stringList(cf.take("steps"), cp + ".steps")))
                finish(cf)
            }
            let def = stringList(f.take("default"), path + ".default")
            if let on = expressionString(kn, kp) { kind = .switch(SwitchStep(on: on, cases: cases, defaultSteps: def)) }
        case "foreach":
            let itemName = string(f.take("as"), path + ".as") ?? "item"
            let concurrency = int(f.take("concurrency"), path + ".concurrency") ?? 1
            let collect = string(f.take("collect"), path + ".collect")
            let body = decodeSteps(f.take("steps"), path + ".steps")
            switch kn.value {
            case .string, .seq:
                kind = .foreach(ForeachStep(items: kn.json, itemName: itemName, concurrency: concurrency, steps: body, collect: collect))
            default:
                report("type-mismatch", "'foreach' expects an expression string or a list, found \(kn.typeName)", at: kn, path: kp)
            }
        case "parallel":
            var branches: [ParallelBranch] = []
            for (i, b) in sequence(kn, kp).enumerated() {
                let bp = "\(kp)[\(i)]"
                guard var bf = fields(b, bp) else { continue }
                let bname = string(bf.take("name"), bp + ".name") ?? "branch\(i + 1)"
                branches.append(ParallelBranch(name: bname, steps: decodeSteps(bf.take("steps"), bp + ".steps")))
                finish(bf)
            }
            kind = .parallel(ParallelStep(branches: branches))
        case "while":
            let max = int(f.take("maxIterations"), path + ".maxIterations")
            if max == nil && !f.has("maxIterations") {
                report("unbounded-loop", "a 'while' loop needs 'maxIterations'", at: node, path: path)
            }
            let body = decodeSteps(f.take("steps"), path + ".steps")
            if let c = expressionString(kn, kp), let max { kind = .loop(LoopStep(condition: c, maxIterations: max, steps: body)) }
        case "approval":
            if let m = string(kn, kp) { kind = .approval(ApprovalStep(message: m)) }
        case "delay":
            switch kn.value {
            case .int, .double, .string: kind = .delay(DelayStep(seconds: kn.json))
            default: report("type-mismatch", "'delay' expects a number of seconds or an expression string, found \(kn.typeName)", at: kn, path: kp)
            }
        case "set":
            kind = .set(SetStep(values: object(kn, kp)))
        case "transform":
            if let e = expressionString(kn, kp) { kind = .transform(TransformStep(expression: e, into: string(f.take("into"), path + ".into"))) }
        case "verify":
            kind = .verify(VerifyStep(assertions: decodeAssertions(kn, kp)))
        case "subworkflow":
            if let w = string(kn, kp) { kind = .subworkflow(SubworkflowStep(workflow: w, inputs: object(f.take("inputs"), path + ".inputs"))) }
        case "notify":
            if let m = string(kn, kp) { kind = .notify(NotifyStep(message: m, title: string(f.take("title"), path + ".title"))) }
        case "fail":
            if let m = string(kn, kp) { kind = .fail(FailStep(message: m)) }
        case "output":
            kind = .output(OutputStep(values: object(kn, kp), artifacts: stringList(f.take("artifacts"), path + ".artifacts")))
        default: break
        }
        finish(f, allowed: "not valid on a '\(key)' step")
        guard let kind else { return nil }
        return WorkflowStep(id: id, name: name, needs: needs, when: when, retry: retry, timeoutSeconds: timeout,
                            continueOnError: continueOnError, onError: onError, kind: kind)
    }

    private mutating func decodeAssertions(_ node: YNode?, _ path: String) -> [WorkflowAssertion] {
        var out: [WorkflowAssertion] = []
        for (i, a) in sequence(node, path).enumerated() {
            let ap = "\(path)[\(i)]"
            guard var f = fields(a, ap) else { continue }
            let present = WorkflowAssertion.kindNames.filter { f.has($0) }
            guard present.count == 1, let key = present.first else {
                report("invalid-assertion", "an assertion needs exactly one of: \(WorkflowAssertion.kindNames.joined(separator: ", "))", at: a, path: ap)
                continue
            }
            let n = f.take(key)!
            let np = "\(ap).\(key)"
            switch key {
            case "fileExists": if let p = string(n, np) { out.append(.fileExists(path: p)) }
            case "fileNonEmpty": if let p = string(n, np) { out.append(.fileNonEmpty(path: p)) }
            case "dirNonEmpty": if let p = string(n, np) { out.append(.dirNonEmpty(path: p)) }
            case "fileContains":
                let text = string(f.take("text"), ap + ".text")
                if text == nil && !f.has("text") { report("missing-field", "'fileContains' needs 'text'", at: a, path: ap) }
                if let p = string(n, np), let text { out.append(.fileContains(path: p, text: text)) }
            case "equals":
                if case .seq(let pair) = n.value, pair.count == 2 { out.append(.equals(pair[0].json, pair[1].json)) }
                else { report("invalid-assertion", "'equals' expects a list of exactly two values", at: n, path: np) }
            case "truthy": out.append(.truthy(n.json))
            case "stepSucceeded": if let s = string(n, np) { out.append(.stepSucceeded(s)) }
            default: break
            }
            finish(f)
        }
        return out
    }
}
