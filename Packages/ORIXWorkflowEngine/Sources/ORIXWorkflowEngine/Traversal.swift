// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Traversal.swift
// Description      : Walking and rewriting the step tree: nested scopes,
//                    step-id references and every expression-bearing text,
//                    shared by validator, engine, graph and edits.
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

/// How a text field is interpreted.
public enum WorkflowTextRole: Sendable, Hashable {
    /// The whole text is an expression (or a `${{ … }}` template when it contains one).
    case expression
    /// Literal text with optional `${{ … }}` interpolations.
    case template
}

/// A list of steps that share one `needs` namespace.
public struct WorkflowScope: Sendable, Hashable {
    public enum Kind: String, Sendable { case root, onError, foreach, parallel, loop }
    public var kind: Kind
    /// Id of the container step; nil for the two document-level scopes.
    public var containerID: String?
    /// Branch name for `parallel`.
    public var branch: String?
    /// Document path of the step list, for example `spec.steps[3].steps`.
    public var path: String
    public var steps: [WorkflowStep]
    /// Container ids from the outside in.
    public var ancestors: [String]

    /// Stable identifier of the scope.
    public var id: String {
        switch kind {
        case .root: return ""
        case .onError: return "!onError"
        default: return (containerID ?? "") + (branch.map { "/\($0)" } ?? "")
        }
    }
}

public struct WorkflowStepLocation: Sendable, Hashable {
    public var step: WorkflowStep
    /// Document path, for example `spec.steps[2].steps[0]`.
    public var path: String
    public var scopeID: String
    public var scopeKind: WorkflowScope.Kind
    public var containerID: String?
    public var branch: String?
    public var ancestors: [String]
    public var index: Int
}

extension WorkflowStep {
    /// Nested step lists of a container step, with the path suffix of each list.
    public var childScopes: [(branch: String?, suffix: String, steps: [WorkflowStep])] {
        switch kind {
        case .foreach(let f): return [(nil, "steps", f.steps)]
        case .loop(let l): return [(nil, "steps", l.steps)]
        case .parallel(let p): return p.branches.enumerated().map { ($0.element.name, "parallel[\($0.offset)].steps", $0.element.steps) }
        default: return []
        }
    }

    public var isContainer: Bool {
        switch kind {
        case .foreach, .loop, .parallel: return true
        default: return false
        }
    }

    /// Rewrites every nested step list.
    mutating func mapChildLists(_ f: ([WorkflowStep]) throws -> [WorkflowStep]) rethrows {
        switch kind {
        case .foreach(var x): x.steps = try f(x.steps); kind = .foreach(x)
        case .loop(var x): x.steps = try f(x.steps); kind = .loop(x)
        case .parallel(var x):
            for i in x.branches.indices { x.branches[i].steps = try f(x.branches[i].steps) }
            kind = .parallel(x)
        default: break
        }
    }

    /// Step ids this step names in its own fields (not in expressions): `needs`, branch lists, `onError`, `collect`, `stepSucceeded`.
    public var referencedStepIDs: [String] {
        var out: [String] = []
        var copy = self
        copy.transformStepReferences { out.append($0); return $0 }
        return out
    }

    /// Steps gated by this condition/switch step.
    public var gatedStepIDs: [String] {
        switch kind {
        case .condition(let c): return c.then + c.otherwise
        case .switch(let s): return s.cases.flatMap(\.steps) + s.defaultSteps
        default: return []
        }
    }

    /// Rewrites structural step-id references of this step only. Returning nil removes the reference.
    mutating func transformStepReferences(_ f: (String) -> String?) {
        needs = needs.compactMap(f)
        if let h = onError { onError = f(h) }
        switch kind {
        case .condition(var c):
            c.then = c.then.compactMap(f); c.otherwise = c.otherwise.compactMap(f); kind = .condition(c)
        case .switch(var s):
            for i in s.cases.indices { s.cases[i].steps = s.cases[i].steps.compactMap(f) }
            s.defaultSteps = s.defaultSteps.compactMap(f); kind = .switch(s)
        case .foreach(var x):
            if let c = x.collect { x.collect = f(c) }
            kind = .foreach(x)
        case .verify(var v):
            v.assertions = v.assertions.compactMap { a in
                if case .stepSucceeded(let id) = a { return f(id).map { .stepSucceeded($0) } }
                return a
            }
            kind = .verify(v)
        default: break
        }
    }

    /// Rewrites every expression-bearing text of this step (not of nested steps). `f` receives the text, its role and its
    /// path relative to the step (`when`, `with.path`, `verify[0].fileExists`, …).
    mutating func transformTexts(_ f: (String, WorkflowTextRole, String) -> String) {
        if let w = when { when = f(w, .expression, "when") }
        func deep(_ v: JSONValue, _ path: String) -> JSONValue {
            switch v {
            case .string(let s): return .string(f(s, .template, path))
            case .array(let a): return .array(a.enumerated().map { deep($0.element, "\(path)[\($0.offset)]") })
            case .object(let o):
                var out: [String: JSONValue] = [:]
                for (k, x) in o { out[k] = deep(x, "\(path).\(k)") }
                return .object(out)
            default: return v
            }
        }
        func object(_ o: [String: JSONValue], _ path: String) -> [String: JSONValue] {
            var out: [String: JSONValue] = [:]
            for (k, x) in o { out[k] = deep(x, "\(path).\(k)") }
            return out
        }
        func assertions(_ list: [WorkflowAssertion], _ path: String) -> [WorkflowAssertion] {
            list.enumerated().map { i, a in
                let p = "\(path)[\(i)]"
                switch a {
                case .fileExists(let x): return .fileExists(path: f(x, .template, p + ".fileExists"))
                case .fileNonEmpty(let x): return .fileNonEmpty(path: f(x, .template, p + ".fileNonEmpty"))
                case .dirNonEmpty(let x): return .dirNonEmpty(path: f(x, .template, p + ".dirNonEmpty"))
                case .fileContains(let x, let t): return .fileContains(path: f(x, .template, p + ".fileContains"), text: f(t, .template, p + ".text"))
                case .equals(let l, let r): return .equals(deep(l, p + ".equals[0]"), deep(r, p + ".equals[1]"))
                case .truthy(let v):
                    if case .string(let s) = v { return .truthy(.string(f(s, .expression, p + ".truthy"))) }
                    return .truthy(deep(v, p + ".truthy"))
                case .stepSucceeded: return a
                }
            }
        }
        switch kind {
        case .tool(var t): t.arguments = object(t.arguments, "with"); kind = .tool(t)
        case .agent(var a):
            if case .inline(var i) = a.agent { i.instructions = f(i.instructions, .template, "agent.instructions"); a.agent = .inline(i) }
            a.objective = f(a.objective, .template, "objective")
            a.inputs = object(a.inputs, "inputs")
            a.expect = assertions(a.expect, "expect")
            kind = .agent(a)
        case .condition(var c): c.condition = f(c.condition, .expression, "if"); kind = .condition(c)
        case .switch(var s):
            s.on = f(s.on, .expression, "switch")
            for i in s.cases.indices { s.cases[i].value = deep(s.cases[i].value, "cases[\(i)].value") }
            kind = .switch(s)
        case .foreach(var x):
            if case .string(let s) = x.items { x.items = .string(f(s, .expression, "foreach")) } else { x.items = deep(x.items, "foreach") }
            kind = .foreach(x)
        case .parallel: break
        case .loop(var l): l.condition = f(l.condition, .expression, "while"); kind = .loop(l)
        case .approval(var a): a.message = f(a.message, .template, "approval"); kind = .approval(a)
        case .delay(var d):
            if case .string(let s) = d.seconds { d.seconds = .string(f(s, .expression, "delay")) }
            kind = .delay(d)
        case .set(var s): s.values = object(s.values, "set"); kind = .set(s)
        case .transform(var t): t.expression = f(t.expression, .expression, "transform"); kind = .transform(t)
        case .verify(var v): v.assertions = assertions(v.assertions, "verify"); kind = .verify(v)
        case .subworkflow(var s): s.inputs = object(s.inputs, "inputs"); kind = .subworkflow(s)
        case .notify(var n):
            n.message = f(n.message, .template, "notify")
            if let t = n.title { n.title = f(t, .template, "title") }
            kind = .notify(n)
        case .fail(var x): x.message = f(x.message, .template, "fail"); kind = .fail(x)
        case .output(var o):
            o.values = object(o.values, "output")
            o.artifacts = o.artifacts.enumerated().map { f($0.element, .template, "artifacts[\($0.offset)]") }
            kind = .output(o)
        }
    }

    /// Every expression-bearing text of this step with its role and relative path.
    public var texts: [(text: String, role: WorkflowTextRole, path: String)] {
        var out: [(String, WorkflowTextRole, String)] = []
        var copy = self
        copy.transformTexts { text, role, path in out.append((text, role, path)); return text }
        return out
    }
}

extension WorkflowDocument {
    /// Every scope of the document: root, workflow-level `onError`, and each container body.
    public var scopes: [WorkflowScope] {
        var out: [WorkflowScope] = []
        func visit(_ scope: WorkflowScope) {
            out.append(scope)
            for (i, s) in scope.steps.enumerated() {
                for child in s.childScopes {
                    let kind: WorkflowScope.Kind
                    switch s.kind {
                    case .foreach: kind = .foreach
                    case .loop: kind = .loop
                    default: kind = .parallel
                    }
                    visit(WorkflowScope(kind: kind, containerID: s.id, branch: child.branch, path: "\(scope.path)[\(i)].\(child.suffix)",
                                        steps: child.steps, ancestors: scope.ancestors + [s.id]))
                }
            }
        }
        visit(WorkflowScope(kind: .root, containerID: nil, branch: nil, path: "spec.steps", steps: spec.steps, ancestors: []))
        if !spec.onError.isEmpty {
            visit(WorkflowScope(kind: .onError, containerID: nil, branch: nil, path: "spec.onError", steps: spec.onError, ancestors: []))
        }
        return out
    }

    /// Every step, nested ones included, in document order.
    public var allSteps: [WorkflowStepLocation] {
        var out: [WorkflowStepLocation] = []
        for scope in scopes {
            for (i, s) in scope.steps.enumerated() {
                out.append(WorkflowStepLocation(step: s, path: "\(scope.path)[\(i)]", scopeID: scope.id, scopeKind: scope.kind,
                                                containerID: scope.containerID, branch: scope.branch, ancestors: scope.ancestors, index: i))
            }
        }
        return out
    }

    public func step(id: String) -> WorkflowStep? { allSteps.first { $0.step.id == id }?.step }

    public func location(of id: String) -> WorkflowStepLocation? { allSteps.first { $0.step.id == id } }

    /// Applies `f` to every step of the document (nested and `onError` steps included), children first.
    mutating func transformEveryStep(_ f: (inout WorkflowStep) -> Void) {
        func walk(_ list: [WorkflowStep]) -> [WorkflowStep] {
            list.map { s in
                var s = s
                s.mapChildLists(walk)
                f(&s)
                return s
            }
        }
        spec.steps = walk(spec.steps)
        spec.onError = walk(spec.onError)
    }

    /// Rewrites the step list that directly contains `id`. Returns false when the step does not exist.
    @discardableResult
    mutating func transformList(containing id: String, _ f: (inout [WorkflowStep]) throws -> Void) rethrows -> Bool {
        var found = false
        func walk(_ list: [WorkflowStep]) throws -> [WorkflowStep] {
            var list = list
            if !found, list.contains(where: { $0.id == id }) {
                found = true
                try f(&list)
                return list
            }
            for i in list.indices where !found { try list[i].mapChildLists(walk) }
            return list
        }
        spec.steps = try walk(spec.steps)
        if !found { spec.onError = try walk(spec.onError) }
        return found
    }

    /// Rewrites one step in place. Returns false when the step does not exist.
    @discardableResult
    mutating func transformStep(_ id: String, _ f: (inout WorkflowStep) throws -> Void) rethrows -> Bool {
        try transformList(containing: id) { list in
            if let i = list.firstIndex(where: { $0.id == id }) { try f(&list[i]) }
        }
    }
}
