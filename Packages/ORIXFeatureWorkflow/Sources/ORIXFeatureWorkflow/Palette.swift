// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/Palette.swift
// Description      : What the add-node palette offers (step kinds, registered
//                    tools, agent profiles) and how each becomes a valid new
//                    step.
// Module           : ORIXFeatureWorkflow
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
import SwiftUI

/// Step kinds that can be added without choosing a tool or an agent.
enum StepTemplate: String, CaseIterable, Identifiable, Sendable {
    case condition, switchCase, foreach, parallel, loop, approval, delay, set, transform, verify, subworkflow, notify, fail, output
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .condition: return "Condition"
        case .switchCase: return "Switch"
        case .foreach: return "For each"
        case .parallel: return "Parallel"
        case .loop: return "Loop while"
        case .approval: return "Approval gate"
        case .delay: return "Delay"
        case .set: return "Set variables"
        case .transform: return "Transform"
        case .verify: return "Verify"
        case .subworkflow: return "Run another workflow"
        case .notify: return "Notify"
        case .fail: return "Fail"
        case .output: return "Output"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .condition: return "Runs some steps only when an expression is true, others when it is false."
        case .switchCase: return "Chooses which steps run from the value of an expression."
        case .foreach: return "Repeats its steps once for every item of a list."
        case .parallel: return "Runs several branches at the same time and waits for all of them."
        case .loop: return "Repeats its steps while an expression is true, up to a fixed number of times."
        case .approval: return "Pauses the run until a person approves."
        case .delay: return "Waits a number of seconds."
        case .set: return "Assigns workflow variables."
        case .transform: return "Computes a value from an expression."
        case .verify: return "Checks that files exist or that values are what they should be."
        case .subworkflow: return "Runs one of your other workflows as a step."
        case .notify: return "Posts a notification."
        case .fail: return "Stops with an error message."
        case .output: return "Declares the results and files the workflow produces."
        }
    }

    var searchText: String {
        switch self {
        case .condition: return "condition if then else"
        case .switchCase: return "switch case"
        case .foreach: return "for each foreach loop list"
        case .parallel: return "parallel branches fork join"
        case .loop: return "loop while repeat"
        case .approval: return "approval gate manual"
        case .delay: return "delay wait sleep"
        case .set: return "set variables"
        case .transform: return "transform expression compute"
        case .verify: return "verify assert check"
        case .subworkflow: return "subworkflow run another workflow"
        case .notify: return "notify notification"
        case .fail: return "fail stop error"
        case .output: return "output result artifact"
        }
    }

    var idBase: String {
        switch self {
        case .switchCase: return "switch"
        default: return rawValue
        }
    }

    var category: WorkflowGraph.Category {
        switch self {
        case .condition, .switchCase, .foreach, .loop, .transform, .subworkflow: return .logic
        case .parallel: return .parallelism
        case .set, .verify: return .data
        case .approval, .delay, .fail: return .control
        case .notify, .output: return .output
        }
    }
}

enum PaletteItem: Identifiable, Hashable, Sendable {
    case template(StepTemplate)
    case tool(ToolManifest)
    case agent(AgentProfile)

    var id: String {
        switch self {
        case .template(let t): return "kind:" + t.rawValue
        case .tool(let m): return "tool:" + m.identifier
        case .agent(let a): return "agent:" + a.name
        }
    }
}

enum Palette {
    /// A step id that is free in `doc`: `base`, then `base2`, `base3`…
    static func freshID(_ base: String, in doc: WorkflowDocument) -> String {
        var clean = ""
        for u in base.unicodeScalars {
            let ok = (u.value >= 48 && u.value <= 57) || (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122) || u == "_" || u == "-"
            if ok { clean.unicodeScalars.append(u) }
        }
        if clean.isEmpty || !WorkflowValidator.isValidIdentifier(clean) { clean = "step" + clean.filter { $0.isLetter || $0.isNumber } }
        let taken = Set(doc.allSteps.map(\.step.id))
        if !taken.contains(clean) { return clean }
        var n = 2
        while taken.contains("\(clean)\(n)") { n += 1 }
        return "\(clean)\(n)"
    }

    /// `filesystem.list` → `list`; `documents.csvRead` → `csvRead`.
    static func idBase(forTool identifier: String) -> String {
        identifier.split(separator: ".").last.map(String.init) ?? identifier
    }

    /// A new, structurally valid step for a palette entry. `otherWorkflows` are the ids a subworkflow step may call.
    static func makeStep(_ item: PaletteItem, in doc: WorkflowDocument, otherWorkflows: [String] = []) -> WorkflowStep {
        switch item {
        case .tool(let m):
            return WorkflowStep(id: freshID(idBase(forTool: m.identifier), in: doc), kind: .tool(ToolStep(tool: m.identifier, arguments: ArgumentForm.stub(for: m))))
        case .agent(let a):
            return WorkflowStep(id: freshID(MetadataSlug.camel(a.name), in: doc), kind: .agent(AgentStep(agent: .profile(a.name))))
        case .template(let t):
            let id = freshID(t.idBase, in: doc)
            let kind: WorkflowStepKind
            switch t {
            case .condition: kind = .condition(ConditionStep(condition: "${{ len(params) >= 0 }}"))
            case .switchCase: kind = .switch(SwitchStep(on: "${{ env.DATE }}"))
            case .foreach: kind = .foreach(ForeachStep(items: .array([])))
            case .parallel: kind = .parallel(ParallelStep())
            case .loop: kind = .loop(LoopStep(condition: "${{ loop.index < 1 }}", maxIterations: 1))
            case .approval: kind = .approval(ApprovalStep(message: "Continue?"))
            case .delay: kind = .delay(DelayStep(seconds: .int(1)))
            case .set: kind = .set(SetStep(values: [:]))
            case .transform: kind = .transform(TransformStep(expression: "${{ env.DATE }}"))
            case .verify: kind = .verify(VerifyStep(assertions: []))
            case .subworkflow: kind = .subworkflow(SubworkflowStep(workflow: otherWorkflows.first ?? ""))
            case .notify: kind = .notify(NotifyStep(message: "The workflow reached this step."))
            case .fail: kind = .fail(FailStep(message: "Stopped on purpose."))
            case .output: kind = .output(OutputStep())
            }
            return WorkflowStep(id: id, kind: kind)
        }
    }

    /// A minimal valid document: a manual trigger and one step.
    static func blankDocument(existingIDs: Set<String>) -> WorkflowDocument {
        var n = 1
        var id = "new-workflow"
        while existingIDs.contains(id) { n += 1; id = "new-workflow-\(n)" }
        let name = n == 1 ? "New workflow" : "New workflow \(n)"
        return WorkflowDocument(metadata: WorkflowMetadata(id: id, name: name),
                                spec: WorkflowSpec(triggers: [.manual], steps: [WorkflowStep(id: "start", kind: .set(SetStep(values: ["started": .string("${{ env.DATETIME }}")])))]))
    }

    /// Case-insensitive match of every word of the query.
    static func matches(_ query: String, _ haystack: String) -> Bool {
        let words = query.lowercased().split(separator: " ")
        let h = haystack.lowercased()
        return words.allSatisfy { h.contains($0) }
    }
}

enum MetadataSlug {
    /// `Research assistant` → `researchAssistant`.
    static func camel(_ text: String) -> String {
        let parts = text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        guard let first = parts.first else { return "agent" }
        return first.lowercased() + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
    }
}
