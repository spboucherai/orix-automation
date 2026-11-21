// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Permissions.swift
// Description      : From declared workflow permissions to Core capabilities
//                    and proposed grants, with explicit `~` expansion and
//                    parameter substitution.
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

extension WorkflowDocument {
    /// Parameter values used when nothing is supplied: the declared defaults.
    public var parameterDefaults: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for p in spec.parameters { if let d = p.defaultValue { out[p.name] = d } }
        return out
    }

    /// Resolves a permission entry. Only `${{ params.<name> }}` may appear in it; anything unresolved yields nil.
    func resolvePermissionEntry(_ text: String, parameters: [String: JSONValue]) -> String? {
        guard text.contains("${{") else { return text }
        var values = parameterDefaults
        for (k, v) in parameters { values[k] = v }
        guard let refs = try? WorkflowExpression.references(in: text, isExpressionField: false),
              refs.steps.isEmpty, refs.variables.isEmpty, refs.environment.isEmpty, refs.freeNames.isEmpty, refs.secrets.isEmpty,
              refs.parameters.allSatisfy({ values[$0] != nil }),
              let v = try? WorkflowExpression.interpolate(text, context: ExpressionContext(params: values, environment: [:])),
              case .string(let s) = v else { return nil }
        return s
    }

    /// The capabilities this workflow declares, with `~` expanded against `home` and paths made canonical.
    /// Entries that cannot be resolved (relative paths, `~user`, missing parameters) are left out; the validator reports them.
    public func declaredCapabilities(home: String, parameters: [String: JSONValue] = [:]) -> [Capability] {
        let p = spec.permissions
        var out: [Capability] = []
        func add(_ c: Capability) { if !out.contains(c) { out.append(c) } }
        func path(_ raw: String) -> String? {
            guard let text = resolvePermissionEntry(raw, parameters: parameters) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let expanded: String
            if trimmed == "~" { expanded = home }
            else if trimmed.hasPrefix("~/") { expanded = home + String(trimmed.dropFirst(1)) }
            else if trimmed.hasPrefix("/") { expanded = trimmed }
            else { return nil }
            return try? PathResolver.canonical(expanded, relativeTo: URL(fileURLWithPath: home))
        }
        func entries(_ list: [String]) -> [String] { list.compactMap { resolvePermissionEntry($0, parameters: parameters) }.filter { !$0.isEmpty } }
        for raw in p.filesystem.read { if let x = path(raw) { add(.fileRead(path: x)) } }
        for raw in p.filesystem.write { if let x = path(raw) { add(.fileWrite(path: x)) } }
        for raw in p.filesystem.delete { if let x = path(raw) { add(.fileDelete(path: x)) } }
        for x in entries(p.processes) { add(.processExec(executable: x)) }
        for x in entries(p.scripts) { add(.scriptRuntime(name: x)) }
        for x in entries(p.apps.automation) { add(.appAutomation(bundleID: x)) }
        for x in entries(p.apps.accessibility) { add(.accessibility(bundleID: x)) }
        for x in entries(p.apps.control) { add(.appControl(bundleID: x)) }
        for x in entries(p.network) { add(.network(host: x.lowercased())) }
        for x in entries(p.browser) { add(.browser(host: x.lowercased())) }
        for x in entries(p.secrets) { add(.secret(reference: x)) }
        if p.clipboard.read { add(.clipboardRead) }
        if p.clipboard.write { add(.clipboardWrite) }
        if p.notifications { add(.notify) }
        for x in entries(p.screen) { add(.screenCapture(scope: x)) }
        return out
    }

    /// Highest tier of a tool call a workflow-scoped grant of this capability may take part in without a new approval.
    /// Never above tier 2: high-risk operations (permanent deletion, privileged changes) always need a contemporaneous approval.
    ///
    /// The policy engine compares a grant's ceiling with the tier of the whole call, and a call names every capability it
    /// touches. A read permission is therefore an *input* of write and consequential calls (copy, move, archive, convert,
    /// running a script in a folder): its ceiling is tier 2, otherwise an accepted workflow could read a folder but never
    /// copy from it. This widens nothing: the write, process, runtime or network side of such a call is a separate
    /// capability that needs its own declared grant. Screen capture and clipboard read are only used by tier 1 tools
    /// (`screen.capture` writes the picture to a file; `clipboard.read` is tier 1 by its manifest).
    public static func proposedTier(for capability: Capability) -> ApprovalTier {
        switch capability {
        case .fileRead: return .consequential
        case .fileWrite, .fileDelete, .clipboardRead, .clipboardWrite, .notify, .screenCapture: return .reversibleWrite
        default: return .consequential
        }
    }

    /// Grants to show in the "review permissions" sheet: one per declared capability, scoped to this workflow.
    public func proposedGrants(workflowID: String, home: String = NSHomeDirectory(), parameters: [String: JSONValue] = [:],
                               now: Date = Date()) -> [PermissionGrant] {
        declaredCapabilities(home: home, parameters: parameters).map { cap in
            PermissionGrant(capability: cap, scope: .workflow(workflowID: workflowID), maxTier: Self.proposedTier(for: cap),
                            createdAt: now, source: "workflow:\(workflowID)", note: "Declared by \(metadata.name)")
        }
    }
}
