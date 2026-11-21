// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Validator.swift
// Description      : Static validation of a workflow document: identifiers,
//                    dependency graph, tools and arguments, expressions,
//                    triggers, permissions and budgets.
// Module           : ORIXWorkflowEngine
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
import ORIXCore

public enum WorkflowValidator {
    /// Validates `doc` against the given tool catalogue, agent profile names and loadable workflow ids/names.
    /// Diagnostics carry a document path; use `WorkflowCodec.locate` to attach source positions.
    public static func validate(_ doc: WorkflowDocument, tools: [ToolManifest], agents: [String], workflows: [String]) -> [WorkflowDiagnostic] {
        var v = Validation(doc: doc, tools: Dictionary(tools.map { ($0.identifier, $0) }, uniquingKeysWith: { f, _ in f }),
                           agents: Set(agents), workflows: Set(workflows))
        v.run()
        return v.out
    }

    /// Errors that make a document unusable as a graph: invalid or duplicate ids, unknown `needs`, cycles. Used by the graph edits.
    public static func structuralErrors(_ doc: WorkflowDocument) -> [WorkflowDiagnostic] {
        var v = Validation(doc: doc, tools: [:], agents: [], workflows: [])
        v.checkIdentifiers()
        v.checkGraph()
        return v.out.filter { $0.severity == .error }
    }

    public static func isValidIdentifier(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    static func isValidName(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// Basic five-field cron check: minute hour day-of-month month day-of-week, with `*`, lists, ranges, steps and month/day names.
    public static func cronProblem(_ cron: String) -> String? {
        let fields = cron.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else { return "expected 5 fields (minute hour day-of-month month day-of-week), found \(fields.count)" }
        let specs: [(String, Int, Int, [String])] = [
            ("minute", 0, 59, []), ("hour", 0, 23, []), ("day-of-month", 1, 31, []),
            ("month", 1, 12, ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]),
            ("day-of-week", 0, 7, ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]),
        ]
        for (field, spec) in zip(fields, specs) {
            let (name, lo, hi, names) = spec
            func value(_ s: String) -> Int? {
                if let i = names.firstIndex(of: s.uppercased()) { return i + (name == "month" ? 1 : 0) }
                guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(s), v >= lo, v <= hi else { return nil }
                return v
            }
            for part in field.split(separator: ",", omittingEmptySubsequences: false) {
                let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard pieces.count <= 2, let range = pieces.first, !range.isEmpty else { return "invalid \(name) field '\(field)'" }
                if pieces.count == 2 {
                    guard let step = Int(pieces[1]), step > 0 else { return "invalid step in \(name) field '\(field)'" }
                }
                if range == "*" { continue }
                let bounds = range.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                guard bounds.count <= 2, let a = value(bounds[0]) else { return "invalid \(name) value '\(range)' (allowed \(lo)-\(hi))" }
                if bounds.count == 2 {
                    guard let b = value(bounds[1]) else { return "invalid \(name) value '\(range)' (allowed \(lo)-\(hi))" }
                    if b < a { return "descending range '\(range)' in the \(name) field" }
                }
            }
        }
        return nil
    }
}

struct Validation {
    let doc: WorkflowDocument
    let tools: [String: ToolManifest]
    let agents: Set<String>
    let workflows: Set<String>
    var out: [WorkflowDiagnostic] = []

    private var scopes: [WorkflowScope] = []
    private var locations: [String: WorkflowStepLocation] = [:]
    /// Per scope id: transitive upstream (needs + gates) of each step.
    private var upstream: [String: [String: Set<String>]] = [:]
    /// Handler step id → steps that route their errors to it.
    private var handlerSources: [String: [String]] = [:]
    private var assignedVariables: Set<String> = []

    init(doc: WorkflowDocument, tools: [String: ToolManifest], agents: Set<String>, workflows: Set<String>) {
        self.doc = doc; self.tools = tools; self.agents = agents; self.workflows = workflows
        scopes = doc.scopes
        for l in doc.allSteps where locations[l.step.id] == nil { locations[l.step.id] = l }
        for l in doc.allSteps { if let h = l.step.onError { handlerSources[h, default: []].append(l.step.id) } }
        assignedVariables = Set(doc.spec.variables.keys)
        for l in doc.allSteps {
            if case .set(let s) = l.step.kind { assignedVariables.formUnion(s.values.keys) }
            if case .transform(let t) = l.step.kind, let into = t.into { assignedVariables.insert(into) }
        }
    }

    mutating func add(_ severity: WorkflowDiagnostic.Severity, _ code: String, _ message: String, step: String? = nil, path: String) {
        out.append(WorkflowDiagnostic(severity: severity, code: code, message: message, stepID: step, path: path))
    }

    mutating func run() {
        checkDocument()
        checkIdentifiers()
        checkGraph()
        checkTriggers()
        checkParameters()
        checkPermissionEntries()
        checkBudget()
        for l in doc.allSteps { checkStep(l) }
        checkReachability()
        checkLayout()
    }

    // MARK: Document

    private mutating func checkDocument() {
        if doc.apiVersion != WorkflowDocument.currentAPIVersion {
            add(.error, "unsupported-version", "unsupported apiVersion '\(doc.apiVersion)'; expected '\(WorkflowDocument.currentAPIVersion)'", path: "apiVersion")
        }
        if doc.kind != WorkflowDocument.automationKind { add(.error, "unsupported-kind", "unsupported kind '\(doc.kind)'; expected 'Automation'", path: "kind") }
        if !WorkflowValidator.isValidIdentifier(doc.metadata.id) {
            add(.error, "invalid-id", "metadata.id '\(doc.metadata.id)' must match [A-Za-z_][A-Za-z0-9_-]*", path: "metadata.id")
        }
        if doc.metadata.name.trimmingCharacters(in: .whitespaces).isEmpty { add(.error, "missing-field", "metadata.name is empty", path: "metadata.name") }
        if doc.spec.steps.isEmpty { add(.warning, "empty-workflow", "the workflow has no steps", path: "spec.steps") }
    }

    mutating func checkIdentifiers() {
        var seen: [String: String] = [:]
        for l in doc.allSteps {
            let id = l.step.id
            if !WorkflowValidator.isValidIdentifier(id) {
                add(.error, "invalid-id", "step id '\(id)' must match [A-Za-z_][A-Za-z0-9_-]*", step: id, path: l.path + ".id")
            }
            if let first = seen[id] {
                add(.error, "duplicate-id", "step id '\(id)' is already used at \(first); ids are unique in the whole document, nested steps included", step: id, path: l.path + ".id")
            } else { seen[id] = l.path }
        }
    }

    // MARK: Graph

    mutating func checkGraph() {
        for scope in scopes {
            let ids = Set(scope.steps.map(\.id))
            var edges: [String: [String]] = [:]
            for (i, s) in scope.steps.enumerated() {
                let path = "\(scope.path)[\(i)]"
                for (n, need) in s.needs.enumerated() {
                    if need == s.id {
                        add(.error, "self-need", "step '\(s.id)' needs itself", step: s.id, path: "\(path).needs[\(n)]")
                    } else if !ids.contains(need) {
                        let hint = locations[need] != nil ? " ('\(need)' exists but in another scope; a step can only need steps of its own list)" : ""
                        add(.error, "unknown-need", "step '\(s.id)' needs unknown step '\(need)'\(hint)", step: s.id, path: "\(path).needs[\(n)]")
                    } else { edges[s.id, default: []].append(need) }
                }
                for target in s.gatedStepIDs {
                    if target == s.id || !ids.contains(target) {
                        add(.error, "unknown-branch-step", "step '\(s.id)' lists '\(target)' in a branch, which is not another step of the same list", step: s.id, path: path)
                    } else { edges[target, default: []].append(s.id) }
                }
            }
            // Cycle detection (depth-first), reporting one path per cycle found.
            var state: [String: Int] = [:]
            var stack: [String] = []
            var reported: Set<String> = []
            func visit(_ id: String) {
                state[id] = 1
                stack.append(id)
                for dep in edges[id] ?? [] {
                    if state[dep] == 1 {
                        let start = stack.firstIndex(of: dep) ?? 0
                        let cycle = Array(stack[start...])
                        let key = cycle.sorted().joined(separator: ",")
                        if reported.insert(key).inserted {
                            let text = (cycle.reversed() + [cycle.last!]).joined(separator: " → ")
                            let idx = scope.steps.firstIndex { $0.id == dep } ?? 0
                            out.append(WorkflowDiagnostic(code: "dependency-cycle", message: "dependency cycle: \(text); 'needs' must form a DAG (use 'while' or 'foreach' for repetition)",
                                                          stepID: dep, path: "\(scope.path)[\(idx)].needs"))
                        }
                    } else if state[dep] == nil { visit(dep) }
                }
                stack.removeLast()
                state[id] = 2
            }
            for s in scope.steps where state[s.id] == nil { visit(s.id) }
            // Transitive upstream sets (bounded by the scope size, cycle-safe).
            var closure: [String: Set<String>] = [:]
            func up(_ id: String, _ trail: Set<String>) -> Set<String> {
                if let c = closure[id] { return c }
                var acc: Set<String> = []
                for dep in edges[id] ?? [] where !trail.contains(dep) {
                    acc.insert(dep)
                    acc.formUnion(up(dep, trail.union([id])))
                }
                closure[id] = acc
                return acc
            }
            for s in scope.steps { _ = up(s.id, []) }
            upstream[scope.id] = closure
        }
    }

    /// Step ids whose results an expression of `id` may read.
    private func visibleSteps(for l: WorkflowStepLocation) -> Set<String> {
        var visible = upstream[l.scopeID]?[l.step.id] ?? []
        // A handler sees the step that failed and what that step could see.
        for source in handlerSources[l.step.id] ?? [] {
            visible.insert(source)
            visible.formUnion(upstream[l.scopeID]?[source] ?? [])
        }
        switch l.scopeKind {
        case .onError: visible.formUnion(doc.spec.steps.map(\.id))
        case .loop:
            // A loop body also sees the previous iteration of its siblings.
            if let scope = scopes.first(where: { $0.id == l.scopeID }) { visible.formUnion(scope.steps.map(\.id).filter { $0 != l.step.id }) }
        default: break
        }
        if let container = l.containerID, let cl = locations[container] { visible.formUnion(visibleSteps(for: cl)) }
        return visible
    }

    private func localNames(for l: WorkflowStepLocation) -> Set<String> {
        var names: Set<String> = []
        if handlerSources[l.step.id] != nil || l.scopeKind == .onError { names.insert("error") }
        var current: WorkflowStepLocation? = l
        while let c = current {
            if c.scopeKind == .onError { names.insert("error") }
            guard let container = c.containerID, let cl = locations[container] else { break }
            switch cl.step.kind {
            case .foreach(let f): names.insert(f.itemName); names.insert("index")
            case .loop: names.insert("loop")
            default: break
            }
            if handlerSources[cl.step.id] != nil { names.insert("error") }
            current = cl
        }
        return names
    }

    // MARK: Triggers, parameters, permissions, budget

    private mutating func checkTriggers() {
        for (i, t) in doc.spec.triggers.enumerated() {
            let path = "spec.triggers[\(i)]"
            switch t {
            case .schedule(let cron, let tz):
                if let problem = WorkflowValidator.cronProblem(cron) { add(.error, "invalid-cron", "invalid cron expression '\(cron)': \(problem)", path: path + ".cron") }
                if let tz, TimeZone(identifier: tz) == nil || tz.isEmpty {
                    add(.error, "invalid-timezone", "unknown time zone '\(tz)'; use an IANA identifier such as America/Toronto", path: path + ".timezone")
                }
            case .once(let at):
                if ExpressionEvaluator.parseDate(at, timeZone: .current) == nil {
                    add(.error, "invalid-trigger", "'once' needs an ISO 8601 date-time in 'at' (got '\(at)')", path: path + ".at")
                }
            case .interval(let s):
                if !(s > 0) { add(.error, "invalid-trigger", "'interval' needs a positive number of seconds", path: path + ".seconds") }
                else if s < 10 { add(.warning, "invalid-trigger", "an interval under 10 seconds will run the workflow almost continuously", path: path + ".seconds") }
            case .fileChange(let p, _, let debounce):
                if let problem = pathProblem(p) { add(.error, "invalid-trigger", "fileChange path '\(p)' \(problem)", path: path + ".path") }
                if let d = debounce, d < 0 { add(.error, "invalid-trigger", "debounceSeconds cannot be negative", path: path + ".debounceSeconds") }
            case .appLaunch(let b):
                if b.isEmpty || b.contains(" ") || !b.contains(".") { add(.error, "invalid-trigger", "'appLaunch' needs a bundle identifier such as com.apple.Safari", path: path + ".bundleID") }
            case .manual, .login: break
            }
        }
    }

    private mutating func checkParameters() {
        var seen: Set<String> = []
        for (i, p) in doc.spec.parameters.enumerated() {
            let path = "spec.parameters[\(i)]"
            if !WorkflowValidator.isValidName(p.name) { add(.error, "invalid-id", "parameter name '\(p.name)' must match [A-Za-z_][A-Za-z0-9_]*", path: path + ".name") }
            if !seen.insert(p.name).inserted { add(.error, "duplicate-parameter", "parameter '\(p.name)' is declared twice", path: path + ".name") }
            if let d = p.defaultValue, !d.isNull, !Self.value(d, matches: p.type) {
                add(.error, "parameter-default-type", "the default of parameter '\(p.name)' is not of type \(p.type.rawValue)", path: path + ".default")
            }
            if p.required, p.defaultValue != nil {
                add(.info, "parameter-required-default", "parameter '\(p.name)' is required and has a default; the default is only used by previews", path: path)
            }
        }
    }

    static func value(_ v: JSONValue, matches type: WorkflowParameterType) -> Bool {
        switch (type, v) {
        case (.string, .string), (.path, .string), (.boolean, .bool), (.array, .array), (.object, .object), (.integer, .int), (.number, .int), (.number, .number): return true
        case (.integer, .number(let d)): return d.rounded() == d
        default: return false
        }
    }

    /// Nil when `p` is an absolute or `~/` path (possibly through parameters).
    private func pathProblem(_ raw: String) -> String? {
        var p = raw
        if raw.contains("${{") {
            guard let resolved = doc.resolvePermissionEntry(raw, parameters: [:]) else { return nil }
            p = resolved
        }
        let t = p.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "is empty" }
        if t == "~" || t.hasPrefix("~/") || t.hasPrefix("/") { return nil }
        if t.hasPrefix("~") { return "uses '~user', which is not supported; write the absolute path" }
        return "is relative; use an absolute path or one starting with '~/'"
    }

    private mutating func checkPermissionEntries() {
        let p = doc.spec.permissions
        let base = "spec.permissions"
        func checkExpression(_ raw: String, _ path: String) {
            guard raw.contains("${{") else { return }
            if let e = WorkflowExpression.syntaxErrors(in: raw, isExpressionField: false).first {
                add(.error, "expression-syntax", "invalid expression in permission entry: \(e.message)", path: path)
                return
            }
            guard let refs = try? WorkflowExpression.references(in: raw, isExpressionField: false) else { return }
            if !refs.steps.isEmpty || !refs.variables.isEmpty || !refs.environment.isEmpty || !refs.freeNames.isEmpty || !refs.secrets.isEmpty {
                add(.error, "invalid-permission-expression", "permission entries may only use ${{ params.<name> }}; permissions cannot depend on run-time values", path: path)
            }
            for name in refs.parameters.sorted() where !doc.spec.parameters.contains(where: { $0.name == name }) {
                add(.error, "missing-parameter", "permission entry uses undeclared parameter '\(name)'", path: path)
            }
        }
        for (kind, list) in [("read", p.filesystem.read), ("write", p.filesystem.write), ("delete", p.filesystem.delete)] {
            for (i, raw) in list.enumerated() {
                let path = "\(base).filesystem.\(kind)[\(i)]"
                checkExpression(raw, path)
                if let problem = pathProblem(raw) { add(.error, "invalid-permission-path", "filesystem.\(kind) path '\(raw)' \(problem)", path: path) }
                else if !raw.contains("${{"), let canon = Self.lexical(raw), canon == "/" || canon == "~" {
                    add(.warning, "broad-permission", "filesystem.\(kind) covers '\(raw)' entirely; declare the folders the workflow really needs", path: path)
                }
            }
        }
        for (kind, list) in [("network", p.network), ("browser", p.browser)] {
            for (i, raw) in list.enumerated() {
                let path = "\(base).\(kind)[\(i)]"
                checkExpression(raw, path)
                guard !raw.contains("${{") else { continue }
                if raw.isEmpty || raw.contains("/") || raw.contains(" ") || raw.contains(":") {
                    add(.error, "invalid-permission-host", "\(kind) entry '\(raw)' must be a host name such as example.com or *.example.com (no scheme, port or path)", path: path)
                } else if raw == "*" {
                    add(.warning, "broad-permission", "\(kind) allows every host; list the hosts the workflow really needs", path: path)
                }
            }
        }
        for (kind, list) in [("processes", p.processes), ("scripts", p.scripts), ("secrets", p.secrets), ("screen", p.screen),
                             ("apps.automation", p.apps.automation), ("apps.accessibility", p.apps.accessibility), ("apps.control", p.apps.control)] {
            for (i, raw) in list.enumerated() {
                checkExpression(raw, "\(base).\(kind)[\(i)]")
                if raw.isEmpty { add(.error, "invalid-value", "empty entry in permissions.\(kind)", path: "\(base).\(kind)[\(i)]") }
            }
        }
        let runtimes: Set<String> = ["bash", "python", "swift", "javascript", "applescript", "jxa"]
        for (i, r) in p.scripts.enumerated() where !r.contains("${{") && !runtimes.contains(r) {
            add(.error, "invalid-value", "unknown script runtime '\(r)'; expected one of \(runtimes.sorted().joined(separator: ", "))", path: "\(base).scripts[\(i)]")
        }
    }

    private mutating func checkBudget() {
        let b = doc.spec.budget
        if let v = b.maxDurationSeconds, !(v > 0) { add(.error, "invalid-budget", "budget.maxDurationSeconds must be positive", path: "spec.budget.maxDurationSeconds") }
        if let v = b.maxProviderCostUSD, v < 0 { add(.error, "invalid-budget", "budget.maxProviderCostUSD cannot be negative", path: "spec.budget.maxProviderCostUSD") }
        if let v = b.maxToolCalls, v < 1 { add(.error, "invalid-budget", "budget.maxToolCalls must be at least 1", path: "spec.budget.maxToolCalls") }
        if let v = b.maxTokens, v < 1 { add(.error, "invalid-budget", "budget.maxTokens must be at least 1", path: "spec.budget.maxTokens") }
        let all = doc.allSteps
        let hasAgent = all.contains { if case .agent = $0.step.kind { return true }; return false }
        if hasAgent && b.maxProviderCostUSD == nil {
            add(.warning, "budget-missing-cost-limit", "the workflow runs agents but declares no budget.maxProviderCostUSD", path: "spec.budget")
        }
        if !hasAgent, let c = b.maxProviderCostUSD, c > 0 {
            add(.info, "budget-unused", "budget.maxProviderCostUSD is set but no step uses a model", path: "spec.budget.maxProviderCostUSD")
        }
        if let d = b.maxDurationSeconds {
            for l in all { if let t = l.step.timeoutSeconds, t > d {
                add(.warning, "budget-timeout-exceeds-duration", "step timeout (\(Int(t)) s) is longer than budget.maxDurationSeconds (\(Int(d)) s)", step: l.step.id, path: l.path + ".timeoutSeconds")
            } }
        }
        if let max = b.maxToolCalls {
            let top = doc.spec.steps.filter { if case .tool = $0.kind { return true }; if case .notify = $0.kind { return true }; return false }.count
            if top > max { add(.warning, "budget-too-small", "the workflow has \(top) top-level tool steps but budget.maxToolCalls is \(max)", path: "spec.budget.maxToolCalls") }
        }
    }

    // MARK: Steps

    private mutating func checkStep(_ l: WorkflowStepLocation) {
        let s = l.step
        let id = s.id
        if let t = s.timeoutSeconds, !(t > 0) { add(.error, "invalid-value", "timeoutSeconds must be positive", step: id, path: l.path + ".timeoutSeconds") }
        if let r = s.retry {
            if r.maxAttempts < 1 { add(.error, "invalid-value", "retry.maxAttempts must be at least 1", step: id, path: l.path + ".retry.maxAttempts") }
            if r.backoffSeconds < 0 || r.backoffMultiplier < 1 {
                add(.error, "invalid-value", "retry.backoffSeconds must be ≥ 0 and retry.backoffMultiplier ≥ 1", step: id, path: l.path + ".retry")
            }
            if r.maxAttempts > 1, !r.force {
                var reason: String?
                switch s.kind {
                case .tool(let t): if let m = tools[t.tool], !m.idempotent { reason = "tool '\(t.tool)' is not idempotent" }
                case .agent: reason = "agent steps are not idempotent"
                case .notify: if let m = tools["notifications.post"], !m.idempotent { reason = "notifications are not idempotent" }
                case .subworkflow, .foreach, .parallel, .loop: reason = "container steps are not retried as a whole"
                default: break
                }
                if let reason { add(.warning, "retry-not-idempotent", "retry will not happen: \(reason); set retry.force: true to accept repeated side effects", step: id, path: l.path + ".retry") }
            }
        }
        if let h = s.onError {
            let scope = scopes.first { $0.id == l.scopeID }
            if h == id { add(.error, "invalid-handler", "a step cannot be its own onError handler", step: id, path: l.path + ".onError") }
            else if let target = scope?.steps.first(where: { $0.id == h }) {
                if !target.needs.isEmpty { add(.error, "invalid-handler", "handler step '\(h)' must not declare 'needs': it only runs when a step routes an error to it", step: id, path: l.path + ".onError") }
                if scope?.steps.contains(where: { $0.gatedStepIDs.contains(h) }) == true {
                    add(.error, "invalid-handler", "handler step '\(h)' is also listed in a condition/switch branch", step: id, path: l.path + ".onError")
                }
                if target.onError != nil { add(.warning, "invalid-handler", "handler step '\(h)' has its own onError; handlers are not chained", step: id, path: l.path + ".onError") }
            } else {
                add(.error, "invalid-handler", "onError names '\(h)', which is not a step of the same list", step: id, path: l.path + ".onError")
            }
        }

        switch s.kind {
        case .tool(let t): checkTool(t, l)
        case .agent(let a):
            switch a.agent {
            case .profile(let name):
                if !agents.contains(name) { add(.error, "unknown-agent", "unknown agent profile '\(name)'", step: id, path: l.path + ".agent") }
            case .inline(let i):
                if i.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.error, "missing-field", "inline agent instructions are empty", step: id, path: l.path + ".agent.instructions") }
                if let m = i.model, m.split(separator: "/", maxSplits: 1).count != 2 || m.hasPrefix("/") || m.hasSuffix("/") {
                    add(.error, "invalid-model", "model '\(m)' must be written provider/model, for example anthropic/claude-sonnet-4-5", step: id, path: l.path + ".agent.model")
                }
                for (i, pattern) in i.tools.enumerated() where !tools.isEmpty {
                    let known = pattern == "*" || tools[pattern] != nil || (pattern.hasSuffix(".*") && tools.keys.contains { $0.hasPrefix(String(pattern.dropLast(1))) })
                    if !known { add(.warning, "unknown-tool", "agent tool pattern '\(pattern)' matches no known tool", step: id, path: "\(l.path).agent.tools[\(i)]") }
                }
            }
            if a.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.warning, "missing-objective", "agent step has no objective", step: id, path: l.path) }
            for (i, e) in a.expect.enumerated() {
                switch e {
                case .fileExists, .fileNonEmpty, .fileContains, .dirNonEmpty: break
                default: add(.error, "invalid-assertion", "agent 'expect' only supports fileExists, fileNonEmpty, fileContains and dirNonEmpty", step: id, path: "\(l.path).expect[\(i)]")
                }
            }
        case .condition(let c):
            if c.then.isEmpty && c.otherwise.isEmpty { add(.warning, "empty-branches", "condition gates no step (both 'then' and 'else' are empty)", step: id, path: l.path) }
            let both = Set(c.then).intersection(c.otherwise)
            if !both.isEmpty { add(.warning, "ambiguous-branch", "step(s) \(both.sorted().joined(separator: ", ")) are in both 'then' and 'else' and will always run", step: id, path: l.path) }
        case .switch(let sw):
            if sw.cases.isEmpty { add(.warning, "empty-branches", "switch has no cases", step: id, path: l.path + ".cases") }
            var seen: [JSONValue] = []
            for (i, c) in sw.cases.enumerated() {
                if seen.contains(c.value) { add(.warning, "duplicate-case", "case value \(c.value.serialized()) appears twice; only the first one can match", step: id, path: "\(l.path).cases[\(i)]") }
                seen.append(c.value)
            }
        case .foreach(let f):
            if f.concurrency < 1 { add(.error, "invalid-value", "foreach concurrency must be at least 1", step: id, path: l.path + ".concurrency") }
            if !WorkflowValidator.isValidName(f.itemName) || ["params", "vars", "steps", "env", "index", "loop", "error", "true", "false", "null"].contains(f.itemName) {
                add(.error, "invalid-value", "'as: \(f.itemName)' is not a usable variable name", step: id, path: l.path + ".as")
            }
            if let c = f.collect, !f.steps.contains(where: { $0.id == c }) {
                add(.error, "unknown-step-reference", "'collect' names '\(c)', which is not a step of this foreach body", step: id, path: l.path + ".collect")
            }
            if f.steps.isEmpty { add(.warning, "empty-body", "foreach has no body steps", step: id, path: l.path + ".steps") }
        case .parallel(let p):
            var names: Set<String> = []
            for (i, b) in p.branches.enumerated() {
                if !names.insert(b.name).inserted { add(.error, "duplicate-branch", "parallel branch name '\(b.name)' is used twice", step: id, path: "\(l.path).parallel[\(i)].name") }
                if b.steps.isEmpty { add(.warning, "empty-body", "parallel branch '\(b.name)' has no steps", step: id, path: "\(l.path).parallel[\(i)].steps") }
            }
            if p.branches.isEmpty { add(.warning, "empty-body", "parallel has no branches", step: id, path: l.path + ".parallel") }
        case .loop(let lo):
            if lo.maxIterations < 1 { add(.error, "unbounded-loop", "'while' needs maxIterations ≥ 1 (got \(lo.maxIterations)); loops are always bounded", step: id, path: l.path + ".maxIterations") }
            else if lo.maxIterations > 10_000 { add(.warning, "unbounded-loop", "maxIterations of \(lo.maxIterations) is effectively unbounded", step: id, path: l.path + ".maxIterations") }
            if lo.steps.isEmpty { add(.warning, "empty-body", "loop has no body steps", step: id, path: l.path + ".steps") }
            if ["true", "${{ true }}", "${{true}}", "1"].contains(lo.condition.trimmingCharacters(in: .whitespaces)) {
                add(.warning, "unbounded-loop", "the loop condition is constant; the loop will always run maxIterations times and then fail", step: id, path: l.path + ".while")
            }
        case .delay(let d):
            if let n = d.seconds.doubleValue, n < 0 { add(.error, "invalid-value", "delay cannot be negative", step: id, path: l.path + ".delay") }
        case .set(let st):
            for k in st.values.keys.sorted() where !WorkflowValidator.isValidName(k) {
                add(.error, "invalid-id", "variable name '\(k)' must match [A-Za-z_][A-Za-z0-9_]*", step: id, path: "\(l.path).set.\(k)")
            }
            if st.values.isEmpty { add(.warning, "empty-body", "set assigns nothing", step: id, path: l.path + ".set") }
        case .transform(let t):
            if let into = t.into, !WorkflowValidator.isValidName(into) { add(.error, "invalid-id", "variable name '\(into)' must match [A-Za-z_][A-Za-z0-9_]*", step: id, path: l.path + ".into") }
        case .verify(let v):
            if v.assertions.isEmpty { add(.warning, "empty-verify", "verify has no assertion and proves nothing", step: id, path: l.path + ".verify") }
        case .subworkflow(let sw):
            if sw.workflow == doc.metadata.id || sw.workflow == doc.metadata.name {
                add(.error, "recursive-subworkflow", "the workflow calls itself; direct recursion is not allowed", step: id, path: l.path + ".subworkflow")
            } else if !workflows.contains(sw.workflow) {
                add(.error, "unknown-workflow", "unknown workflow '\(sw.workflow)'", step: id, path: l.path + ".subworkflow")
            }
        case .notify:
            if !doc.spec.permissions.notifications { add(.warning, "permission-missing", "the step posts a notification but permissions.notifications is not declared", step: id, path: l.path + ".notify") }
        case .approval, .fail, .output: break
        }
        checkTexts(l)
    }

    private mutating func checkTool(_ t: ToolStep, _ l: WorkflowStepLocation) {
        let id = l.step.id
        guard let manifest = tools[t.tool] else {
            let family = t.tool.split(separator: ".").first.map(String.init) ?? ""
            let siblings = tools.keys.filter { $0.hasPrefix(family + ".") }.sorted()
            let hint = siblings.isEmpty ? "" : "; tools of '\(family)': \(siblings.prefix(12).joined(separator: ", "))"
            add(.error, "unknown-tool", "unknown tool '\(t.tool)'\(hint)", step: id, path: l.path + ".tool")
            return
        }
        // Arguments are checked against the input schema where they are literals; values containing ${{ }} are only known at run time.
        let schema = manifest.inputSchema.raw
        let props = schema["properties"]?.objectValue ?? [:]
        for req in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where t.arguments[req] == nil {
            add(.error, "invalid-argument", "tool '\(t.tool)' requires argument '\(req)'", step: id, path: l.path + ".with")
        }
        for key in t.arguments.keys.sorted() {
            let value = t.arguments[key]!
            guard let ps = props[key] else {
                if schema["additionalProperties"] == .bool(false) {
                    let known = props.keys.sorted().joined(separator: ", ")
                    add(.error, "invalid-argument", "tool '\(t.tool)' has no argument '\(key)'" + (known.isEmpty ? "" : " (known: \(known))"), step: id, path: "\(l.path).with.\(key)")
                }
                continue
            }
            guard Self.isLiteral(value) else { continue }
            for violation in JSONSchema(raw: ps).validate(value) {
                let sub = violation.path.isEmpty ? "" : ".\(violation.path)"
                add(.error, "invalid-argument", "argument '\(key)\(sub)' of '\(t.tool)': \(violation.message)", step: id, path: "\(l.path).with.\(key)")
            }
        }
        checkSufficiency(t, l)
    }

    static func isLiteral(_ v: JSONValue) -> Bool {
        switch v {
        case .string(let s): return !s.contains("${{")
        case .array(let a): return a.allSatisfy(isLiteral)
        case .object(let o): return o.values.allSatisfy(isLiteral)
        default: return true
        }
    }

    // MARK: Expressions

    private mutating func checkTexts(_ l: WorkflowStepLocation) {
        let s = l.step
        let visible = visibleSteps(for: l)
        var locals = localNames(for: l)
        var bodyVisible: Set<String> = []
        if case .loop(let lo) = s.kind { bodyVisible = Set(lo.steps.map(\.id)) }
        for (text, role, sub) in s.texts {
            let path = "\(l.path).\(sub)"
            if role == .template && !text.contains("${{") { continue }
            if role == .expression && text.trimmingCharacters(in: .whitespaces).isEmpty {
                add(.error, "expression-syntax", "empty expression", step: s.id, path: path)
                continue
            }
            let refs: ExpressionReferences
            do { refs = try WorkflowExpression.references(in: text, isExpressionField: role == .expression) }
            catch let e as WorkflowExpressionError {
                add(.error, "expression-syntax", "invalid expression: \(e.message) (at character \(e.offset + 1) of \"\(text.prefix(60))\")", step: s.id, path: path)
                continue
            } catch { continue }
            // The `while` condition of a loop is evaluated around its own body.
            let isLoopCondition = sub == "while"
            if isLoopCondition { locals.insert("loop") }
            for fn in refs.functions.sorted() where !WorkflowExpression.functionNames.contains(fn) {
                add(.error, "unknown-function", "unknown function '\(fn)'", step: s.id, path: path)
            }
            for name in refs.parameters.sorted() where !doc.spec.parameters.contains(where: { $0.name == name }) {
                add(.error, "missing-parameter", "'params.\(name)' is used but the workflow declares no parameter '\(name)'", step: s.id, path: path)
            }
            for name in refs.variables.sorted() where !assignedVariables.contains(name) {
                add(.warning, "unset-variable", "'vars.\(name)' is never declared in spec.variables nor assigned by a set/transform step; it will be null", step: s.id, path: path)
            }
            for name in refs.environment.sorted() where !WorkflowExpression.environmentAllowlist.contains(name) {
                add(.error, "env-not-allowed", "'env.\(name)' is not available; allowed names: \(WorkflowExpression.environmentAllowlist.sorted().joined(separator: ", "))", step: s.id, path: path)
            }
            for name in refs.freeNames.sorted() where !locals.contains(name) {
                add(.error, "unknown-name", "unknown name '\(name)' (available here: params, vars, steps, env\(locals.isEmpty ? "" : ", " + locals.sorted().joined(separator: ", ")))", step: s.id, path: path)
            }
            for ref in refs.steps.sorted() {
                if ref == s.id && !isLoopCondition {
                    add(.error, "step-not-upstream", "step '\(s.id)' reads its own result", step: s.id, path: path)
                } else if locations[ref] == nil {
                    add(.error, "unknown-step-reference", "expression refers to unknown step '\(ref)'", step: s.id, path: path)
                } else if !visible.contains(ref) && !(isLoopCondition && bodyVisible.contains(ref)) {
                    let nested = locations[ref].map { $0.scopeID != l.scopeID && !l.ancestors.contains($0.containerID ?? "") } ?? false
                    let why = nested ? "it lives in another scope; read the container's output instead" : "add it to 'needs' (directly or through another step)"
                    add(.error, "step-not-upstream", "'steps.\(ref)' is not upstream of '\(s.id)': \(why)", step: s.id, path: path)
                }
            }
            for secret in refs.secrets.sorted() where !doc.spec.permissions.secrets.contains(secret) {
                add(.warning, "permission-missing", "secret(\"\(secret)\") is used but permissions.secrets does not list '\(secret)'", step: s.id, path: path)
            }
        }
        if case .verify(let v) = s.kind {
            for (i, a) in v.assertions.enumerated() {
                guard case .stepSucceeded(let ref) = a else { continue }
                if locations[ref] == nil { add(.error, "unknown-step-reference", "stepSucceeded names unknown step '\(ref)'", step: s.id, path: "\(l.path).verify[\(i)].stepSucceeded") }
                else if !visible.contains(ref) { add(.error, "step-not-upstream", "stepSucceeded: '\(ref)' is not upstream of '\(s.id)'; add it to 'needs'", step: s.id, path: "\(l.path).verify[\(i)].stepSucceeded") }
            }
        }
    }

    // MARK: Permission sufficiency

    /// Lexical normalisation for comparison: keeps `~` and parameter placeholders symbolic, removes `.` and `..`.
    static func lexical(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let root: String, rest: Substring
        if t == "~" || t.hasPrefix("~/") { root = "~"; rest = t.dropFirst(1) }
        else if t.hasPrefix("/") { root = ""; rest = Substring(t) }
        else if t.hasPrefix("«") { root = ""; rest = Substring("/" + t) }
        else { return nil }
        var parts: [Substring] = []
        for c in rest.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        let joined = parts.joined(separator: "/")
        if root == "~" { return joined.isEmpty ? "~" : "~/" + joined }
        return "/" + joined
    }

    /// Replaces `${{ params.x }}` by the literal default, or by a symbolic placeholder when there is none. Nil when other expressions remain.
    private func symbolic(_ text: String) -> String? {
        guard text.contains("${{") else { return text }
        guard let segments = try? ExpressionTemplate.segments(text) else { return nil }
        var out = ""
        for seg in segments {
            switch seg {
            case .text(let t): out += t
            case .expression(let src, _):
                guard let e = try? ExpressionParser.parse(src), case .member(.name("params", _), let name, _) = e else { return nil }
                if let p = doc.spec.parameters.first(where: { $0.name == name }), case .string(let d)? = p.defaultValue, !d.contains("${{") { out += d }
                else { out += "«\(name)»" }
            }
        }
        return out
    }

    private func covered(_ path: String, by declared: [String]) -> Bool {
        guard let p = symbolic(path).flatMap(Self.lexical) else { return true }  // unknown at validation time
        for d in declared {
            guard let root = symbolic(d).flatMap(Self.lexical) else { continue }
            if root == "/" || p == root || p.hasPrefix(root + "/") { return true }
        }
        return false
    }

    private func hostCovered(_ url: String, by declared: [String]) -> (host: String, ok: Bool)? {
        guard let text = symbolic(url), !text.contains("«"), let host = URLComponents(string: text)?.host?.lowercased(), !host.isEmpty else { return nil }
        for d in declared {
            guard let pattern = symbolic(d)?.lowercased() else { continue }
            if pattern == "*" || pattern == host { return (host, true) }
            if pattern.hasPrefix("*."), host.hasSuffix(String(pattern.dropFirst(1))) { return (host, true) }
        }
        return (host, false)
    }

    private mutating func checkSufficiency(_ t: ToolStep, _ l: WorkflowStepLocation) {
        let p = doc.spec.permissions
        let id = l.step.id
        func strings(_ key: String) -> [(String, String)] {
            switch t.arguments[key] {
            case .string(let s)?: return [(s, "with.\(key)")]
            case .array(let a)?: return a.enumerated().compactMap { i, v in v.stringValue.map { ($0, "with.\(key)[\(i)]") } }
            default: return []
            }
        }
        func need(_ kind: String, _ declared: [String], _ keys: [String]) {
            for key in keys {
                for (value, sub) in strings(key) where !covered(value, by: declared) {
                    add(.warning, "permission-missing", "'\(t.tool)' uses \(key) '\(value)', which permissions.filesystem.\(kind) does not cover", step: id, path: "\(l.path).\(sub)")
                }
            }
        }
        func needEntry(_ list: [String], _ value: String, _ what: String, _ sub: String = "tool") {
            let resolved = list.compactMap { symbolic($0) }
            if !resolved.contains(value) {
                add(.warning, "permission-missing", "'\(t.tool)' needs \(what) '\(value)', which the workflow does not declare", step: id, path: "\(l.path).\(sub)")
            }
        }
        let fs = p.filesystem
        switch t.tool {
        case "filesystem.list", "filesystem.search", "filesystem.read", "filesystem.metadata", "filesystem.checksum", "filesystem.waitForChange":
            need("read", fs.read, ["path", "paths"])
        case "filesystem.compare": need("read", fs.read, ["path", "paths", "source", "destination"])
        case "filesystem.write", "filesystem.mkdir": need("write", fs.write, ["path"])
        case "filesystem.copy", "filesystem.archive", "filesystem.unarchive":
            need("read", fs.read, ["source", "paths", "path"]); need("write", fs.write, ["destination"])
        case "filesystem.move":
            // filesystem.move asks for read and write on the source (the source folder changes) and write on the destination.
            need("read", fs.read, ["source", "paths"]); need("write", fs.write, ["source", "paths", "destination"])
        case "filesystem.trash", "filesystem.delete": need("delete", fs.delete, ["path", "paths"])
        default:
            if t.tool.hasPrefix("documents.") || t.tool == "screen.ocr" || t.tool == "screen.compare" {
                let writes = ["documents.csvWrite", "documents.renderPDF", "documents.imageConvert"].contains(t.tool)
                need("read", fs.read, writes ? ["source"] : ["path", "source", "paths"])
                need("write", fs.write, writes ? ["destination", "path"] : ["destination"])
            } else if t.tool == "screen.capture" || t.tool == "browser.screenshot" || t.tool == "browser.download" {
                need("write", fs.write, ["destination", "path"])
            } else if t.tool.hasPrefix("git.") {
                need("read", fs.read, ["path", "cwd"])
            }
        }
        if t.tool == "http.request" || t.tool == "browser.open" {
            let (list, kind) = t.tool == "http.request" ? (p.network, "network") : (p.browser, "browser")
            for (url, sub) in strings("url") {
                if let r = hostCovered(url, by: list), !r.ok {
                    add(.warning, "permission-missing", "'\(t.tool)' contacts '\(r.host)', which permissions.\(kind) does not list", step: id, path: "\(l.path).\(sub)")
                }
            }
        }
        switch t.tool {
        case "shell.run":
            // The program is the `executable` argument; `args` are its arguments, never the program.
            if case .string(let exe)? = t.arguments["executable"], let resolved = symbolic(exe), !resolved.contains("«") {
                let name = (resolved as NSString).lastPathComponent
                let declared = p.processes.compactMap { symbolic($0) }
                if !declared.contains(resolved) && !declared.contains(name) {
                    add(.warning, "permission-missing", "'shell.run' executes '\(name)', which permissions.processes does not list", step: id, path: l.path + ".with.executable")
                }
            }
        case "shell.script": needEntry(p.scripts, "bash", "the script runtime")
        case "python.run": needEntry(p.scripts, "python", "the script runtime")
        case "script.swift": needEntry(p.scripts, "swift", "the script runtime")
        case "script.javascript": needEntry(p.scripts, "javascript", "the script runtime")
        case "applescript.run": needEntry(p.scripts, "applescript", "the script runtime")
        case "jxa.run": needEntry(p.scripts, "jxa", "the script runtime")
        case "clipboard.read": if !p.clipboard.read { add(.warning, "permission-missing", "'clipboard.read' needs permissions.clipboard.read", step: id, path: l.path + ".tool") }
        case "clipboard.write": if !p.clipboard.write { add(.warning, "permission-missing", "'clipboard.write' needs permissions.clipboard.write", step: id, path: l.path + ".tool") }
        case "notifications.post": if !p.notifications { add(.warning, "permission-missing", "'notifications.post' needs permissions.notifications", step: id, path: l.path + ".tool") }
        case "screen.capture": if p.screen.isEmpty { add(.warning, "permission-missing", "'screen.capture' needs a permissions.screen scope (display, window:<bundleID> or region)", step: id, path: l.path + ".tool") }
        case "system.launchApp", "system.quitApp":
            for (b, sub) in strings("bundleID") where !b.contains("${{") { needEntry(p.apps.control, b, "app control of", sub) }
        default:
            if t.tool.hasPrefix("git."), !p.processes.contains("git") {
                add(.warning, "permission-missing", "'\(t.tool)' runs git, which permissions.processes does not list", step: id, path: l.path + ".tool")
            }
            if t.tool.hasPrefix("accessibility."), t.tool != "accessibility.status" {
                for (b, sub) in strings("bundleID") where !b.contains("${{") { needEntry(p.apps.accessibility, b, "accessibility control of", sub) }
            }
        }
    }

    // MARK: Reachability, layout

    private mutating func checkReachability() {
        for scope in scopes {
            let handlers = Set(scope.steps.compactMap(\.onError))
            var dead: [String: String] = [:]
            for s in scope.steps {
                if case .fail = s.kind, s.when == nil, !s.continueOnError, s.onError == nil, !handlers.contains(s.id) { dead[s.id] = "the unconditional fail step '\(s.id)'" }
                if case .condition(let c) = s.kind {
                    let text = c.condition.trimmingCharacters(in: .whitespaces)
                    let constant: Bool? = ["true", "${{ true }}"].contains(text) ? true : (["false", "${{ false }}"].contains(text) ? false : nil)
                    if let constant {
                        for target in (constant ? c.otherwise : c.then) where !(constant ? c.then : c.otherwise).contains(target) {
                            dead[target, default: "the constant condition of '\(s.id)'"] = "the constant condition of '\(s.id)'"
                            if let i = scope.steps.firstIndex(where: { $0.id == target }) {
                                add(.warning, "unreachable-step", "step '\(target)' can never run: the condition of '\(s.id)' is always \(constant)", step: target, path: "\(scope.path)[\(i)]")
                            }
                        }
                    }
                }
            }
            for (i, s) in scope.steps.enumerated() where !handlers.contains(s.id) {
                let path = "\(scope.path)[\(i)]"
                if let need = s.needs.first(where: { handlers.contains($0) }) {
                    add(.error, "unreachable-step", "step '\(s.id)' can never run: it needs '\(need)', which only runs as an onError handler", step: s.id, path: path + ".needs")
                    continue
                }
                let ups = (upstream[scope.id]?[s.id] ?? []).sorted()
                if let cause = ups.first(where: { dead[$0] != nil }), let why = dead[cause] {
                    add(.warning, "unreachable-step", "step '\(s.id)' can never run: it comes after \(why)", step: s.id, path: path + ".needs")
                }
            }
        }
    }

    private mutating func checkLayout() {
        for key in doc.spec.layout.keys.sorted() where locations[key] == nil && !key.hasPrefix("trigger:") {
            add(.warning, "stale-layout", "layout has a position for '\(key)', which is not a step", path: "spec.layout.\(key)")
        }
    }
}
