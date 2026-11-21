// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Diff.swift
// Description      : Semantic diff between two workflow documents for version
//                    history, flagging permission changes as security-relevant.
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

public enum WorkflowChange: Sendable, Hashable {
    case metadataChanged(fields: [String])
    case triggersChanged
    case parametersChanged(added: [String], removed: [String], modified: [String])
    /// Entries read like `filesystem.write: ~/Reports`, `network: example.com`, `notifications`.
    case permissionsChanged(added: [String], removed: [String])
    case budgetChanged
    case variablesChanged
    case stepRemoved(id: String)
    case stepAdded(id: String)
    /// `fields` uses the YAML key names: `name`, `needs`, `when`, `retry`, `timeoutSeconds`, `continueOnError`, `onError`, `kind`, `tool`, `with`, …
    case stepModified(id: String, fields: [String])
    /// The step changed position in its list or moved to another container/branch.
    case stepMoved(id: String)
    case onErrorChanged
    case layoutChanged

    /// True for changes of declared authority. Only `permissionsChanged` is flagged.
    public var isSecurityRelevant: Bool {
        if case .permissionsChanged = self { return true }
        return false
    }

    public var summary: String {
        func list(_ a: [String]) -> String { a.joined(separator: ", ") }
        switch self {
        case .metadataChanged(let f): return "Metadata changed: \(list(f))"
        case .triggersChanged: return "Triggers changed"
        case .parametersChanged(let a, let r, let m):
            var parts: [String] = []
            if !a.isEmpty { parts.append("added \(list(a))") }
            if !r.isEmpty { parts.append("removed \(list(r))") }
            if !m.isEmpty { parts.append("modified \(list(m))") }
            return "Parameters changed: " + parts.joined(separator: "; ")
        case .permissionsChanged(let a, let r):
            var parts: [String] = []
            if !a.isEmpty { parts.append("added \(list(a))") }
            if !r.isEmpty { parts.append("removed \(list(r))") }
            return "Permissions changed (security-relevant): " + parts.joined(separator: "; ")
        case .budgetChanged: return "Budget changed"
        case .variablesChanged: return "Variables changed"
        case .stepRemoved(let id): return "Step '\(id)' removed"
        case .stepAdded(let id): return "Step '\(id)' added"
        case .stepModified(let id, let f): return "Step '\(id)' modified: \(list(f))"
        case .stepMoved(let id): return "Step '\(id)' moved"
        case .onErrorChanged: return "Workflow-level error handler changed"
        case .layoutChanged: return "Layout changed"
        }
    }
}

public enum WorkflowDiff {
    /// Changes from `old` to `new`, in a deterministic order. Empty when the documents are equal.
    /// Steps are matched by id; steps of the workflow-level `onError` list are reported together as `onErrorChanged`.
    public static func diff(_ old: WorkflowDocument, _ new: WorkflowDocument) -> [WorkflowChange] {
        var out: [WorkflowChange] = []
        var meta: [String] = []
        if old.apiVersion != new.apiVersion { meta.append("apiVersion") }
        if old.kind != new.kind { meta.append("kind") }
        if old.metadata.id != new.metadata.id { meta.append("id") }
        if old.metadata.name != new.metadata.name { meta.append("name") }
        if old.metadata.description != new.metadata.description { meta.append("description") }
        if old.metadata.tags != new.metadata.tags { meta.append("tags") }
        if !meta.isEmpty { out.append(.metadataChanged(fields: meta)) }
        if old.spec.triggers != new.spec.triggers { out.append(.triggersChanged) }
        if old.spec.parameters != new.spec.parameters {
            let o = Dictionary(old.spec.parameters.map { ($0.name, $0) }, uniquingKeysWith: { f, _ in f })
            let n = Dictionary(new.spec.parameters.map { ($0.name, $0) }, uniquingKeysWith: { f, _ in f })
            out.append(.parametersChanged(added: new.spec.parameters.map(\.name).filter { o[$0] == nil },
                                          removed: old.spec.parameters.map(\.name).filter { n[$0] == nil },
                                          modified: new.spec.parameters.map(\.name).filter { o[$0] != nil && o[$0] != n[$0] }))
        }
        if old.spec.permissions != new.spec.permissions {
            let o = permissionEntries(old.spec.permissions), n = permissionEntries(new.spec.permissions)
            out.append(.permissionsChanged(added: n.filter { !o.contains($0) }, removed: o.filter { !n.contains($0) }))
        }
        if old.spec.budget != new.spec.budget { out.append(.budgetChanged) }
        if old.spec.variables != new.spec.variables { out.append(.variablesChanged) }

        let oldSteps = old.allSteps.filter { !inOnError($0, old) }
        let newSteps = new.allSteps.filter { !inOnError($0, new) }
        let oldByID = Dictionary(oldSteps.map { ($0.step.id, $0) }, uniquingKeysWith: { f, _ in f })
        let newByID = Dictionary(newSteps.map { ($0.step.id, $0) }, uniquingKeysWith: { f, _ in f })
        for l in oldSteps where newByID[l.step.id] == nil { out.append(.stepRemoved(id: l.step.id)) }
        for l in newSteps where oldByID[l.step.id] == nil { out.append(.stepAdded(id: l.step.id)) }

        // Moves: another scope, or out of order among the steps both versions keep in that scope.
        var moved: Set<String> = []
        var newOrder: [String: [String]] = [:]
        for l in newSteps {
            guard let o = oldByID[l.step.id] else { continue }
            if o.scopeID != l.scopeID { moved.insert(l.step.id) } else { newOrder[l.scopeID, default: []].append(l.step.id) }
        }
        var oldOrder: [String: [String]] = [:]
        for l in oldSteps { if let n = newByID[l.step.id], n.scopeID == l.scopeID { oldOrder[l.scopeID, default: []].append(l.step.id) } }
        for (scope, a) in oldOrder {
            let b = newOrder[scope] ?? []
            if a != b { moved.formUnion(Set(b).subtracting(longestCommonSubsequence(a, b))) }
        }
        for l in newSteps {
            guard let o = oldByID[l.step.id] else { continue }
            let fields = changedFields(o.step, l.step)
            if !fields.isEmpty { out.append(.stepModified(id: l.step.id, fields: fields)) }
            if moved.contains(l.step.id) { out.append(.stepMoved(id: l.step.id)) }
        }
        if old.spec.onError != new.spec.onError { out.append(.onErrorChanged) }
        if old.spec.layout != new.spec.layout { out.append(.layoutChanged) }
        return out
    }

    private static func inOnError(_ l: WorkflowStepLocation, _ doc: WorkflowDocument) -> Bool { l.path.hasPrefix("spec.onError") }

    /// Declared permissions as flat, human-readable entries.
    public static func permissionEntries(_ p: WorkflowPermissions) -> [String] {
        var out: [String] = []
        func add(_ kind: String, _ list: [String]) { for x in list { out.append("\(kind): \(x)") } }
        add("filesystem.read", p.filesystem.read); add("filesystem.write", p.filesystem.write); add("filesystem.delete", p.filesystem.delete)
        add("processes", p.processes); add("scripts", p.scripts)
        add("apps.automation", p.apps.automation); add("apps.accessibility", p.apps.accessibility); add("apps.control", p.apps.control)
        add("network", p.network); add("browser", p.browser); add("secrets", p.secrets)
        if p.clipboard.read { out.append("clipboard.read") }
        if p.clipboard.write { out.append("clipboard.write") }
        if p.notifications { out.append("notifications") }
        add("screen", p.screen)
        return out
    }

    /// Names of the fields that differ between two versions of a step. Nested steps are compared on their own.
    static func changedFields(_ a: WorkflowStep, _ b: WorkflowStep) -> [String] {
        var f: [String] = []
        if a.name != b.name { f.append("name") }
        if a.needs != b.needs { f.append("needs") }
        if a.when != b.when { f.append("when") }
        switch (a.kind, b.kind) {
        case (.tool(let x), .tool(let y)):
            if x.tool != y.tool { f.append("tool") }
            if x.arguments != y.arguments { f.append("with") }
        case (.agent(let x), .agent(let y)):
            if x.agent != y.agent { f.append("agent") }
            if x.objective != y.objective { f.append("objective") }
            if x.inputs != y.inputs { f.append("inputs") }
            if x.expect != y.expect { f.append("expect") }
        case (.condition(let x), .condition(let y)):
            if x.condition != y.condition { f.append("if") }
            if x.then != y.then { f.append("then") }
            if x.otherwise != y.otherwise { f.append("else") }
        case (.switch(let x), .switch(let y)):
            if x.on != y.on { f.append("switch") }
            if x.cases != y.cases { f.append("cases") }
            if x.defaultSteps != y.defaultSteps { f.append("default") }
        case (.foreach(let x), .foreach(let y)):
            if x.items != y.items { f.append("foreach") }
            if x.itemName != y.itemName { f.append("as") }
            if x.concurrency != y.concurrency { f.append("concurrency") }
            if x.collect != y.collect { f.append("collect") }
        case (.parallel(let x), .parallel(let y)):
            if x.branches.map(\.name) != y.branches.map(\.name) { f.append("branches") }
        case (.loop(let x), .loop(let y)):
            if x.condition != y.condition { f.append("while") }
            if x.maxIterations != y.maxIterations { f.append("maxIterations") }
        case (.approval(let x), .approval(let y)): if x != y { f.append("approval") }
        case (.delay(let x), .delay(let y)): if x != y { f.append("delay") }
        case (.set(let x), .set(let y)): if x != y { f.append("set") }
        case (.transform(let x), .transform(let y)):
            if x.expression != y.expression { f.append("transform") }
            if x.into != y.into { f.append("into") }
        case (.verify(let x), .verify(let y)): if x != y { f.append("verify") }
        case (.subworkflow(let x), .subworkflow(let y)):
            if x.workflow != y.workflow { f.append("subworkflow") }
            if x.inputs != y.inputs { f.append("inputs") }
        case (.notify(let x), .notify(let y)):
            if x.message != y.message { f.append("notify") }
            if x.title != y.title { f.append("title") }
        case (.fail(let x), .fail(let y)): if x != y { f.append("fail") }
        case (.output(let x), .output(let y)):
            if x.values != y.values { f.append("output") }
            if x.artifacts != y.artifacts { f.append("artifacts") }
        default: f.append("kind")
        }
        if a.retry != b.retry { f.append("retry") }
        if a.timeoutSeconds != b.timeoutSeconds { f.append("timeoutSeconds") }
        if a.continueOnError != b.continueOnError { f.append("continueOnError") }
        if a.onError != b.onError { f.append("onError") }
        return f
    }

    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Set<String> {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var t = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count { for j in 1...b.count { t[i][j] = a[i - 1] == b[j - 1] ? t[i - 1][j - 1] + 1 : max(t[i - 1][j], t[i][j - 1]) } }
        var out: Set<String> = []
        var i = a.count, j = b.count
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1] { out.insert(a[i - 1]); i -= 1; j -= 1 }
            else if t[i - 1][j] >= t[i][j - 1] { i -= 1 } else { j -= 1 }
        }
        return out
    }
}
