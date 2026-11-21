// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/AgentsModel.swift
// Description      : Agent profiles: list, validation, save, duplicate, delete;
//                    the mapping between a tool tree with tri-state checkboxes
//                    and `toolPatterns`; and evaluation profiles run as real
//                    review-mode runs.
// Module           : ORIXFeatureManage
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
import Observation
import SwiftUI
import ORIXAppUI

// MARK: Tool grants as a tree

enum TriState: Sendable, Hashable { case off, mixed, on }

/// Pure mapping between checkboxes and `AgentProfile.toolPatterns`.
/// A family is the part of a tool identifier before the first dot, which is exactly what a `family.*` pattern matches.
enum ToolGrantTree {
    static func family(of toolID: String) -> String { String(toolID.split(separator: ".", maxSplits: 1).first ?? Substring(toolID)) }

    static func families(_ toolIDs: [String]) -> [(family: String, tools: [String])] {
        Dictionary(grouping: toolIDs, by: family(of:)).map { (family: $0.key, tools: $0.value.sorted()) }.sorted { $0.family < $1.family }
    }

    static func allows(_ toolID: String, _ patterns: [String]) -> Bool {
        patterns.contains { p in
            if p == "*" || p == toolID { return true }
            if p.hasSuffix(".*") { return toolID.hasPrefix(String(p.dropLast(1))) }
            return false
        }
    }

    static func state(family: String, tools: [String], patterns: [String]) -> TriState {
        let on = tools.filter { allows($0, patterns) }.count
        if on == 0 { return .off }
        return on == tools.count ? .on : .mixed
    }

    /// True when the patterns cover tools that do not exist yet (`*`).
    static func includesFutureTools(_ patterns: [String]) -> Bool { patterns.contains("*") }

    /// Replaces `*` by one `family.*` per known family so a single family or tool can then be changed.
    static func expanded(_ patterns: [String], all: [String]) -> [String] {
        guard patterns.contains("*") else { return patterns }
        return normalized(families(all).map { "\($0.family).*" } + patterns.filter { $0 != "*" })
    }

    /// Removes duplicates and patterns already covered by a `family.*` of the same list; sorted for stable storage.
    static func normalized(_ patterns: [String]) -> [String] {
        if patterns.contains("*") { return ["*"] }
        let wild = Set(patterns.filter { $0.hasSuffix(".*") })
        var out = Set<String>()
        for p in patterns where !p.isEmpty {
            if p.hasSuffix(".*") { out.insert(p) } else if !wild.contains(family(of: p) + ".*") { out.insert(p) }
        }
        return out.sorted()
    }

    /// Turns a whole family on (`family.*`, which also covers tools added to it later) or off.
    static func setFamily(_ family: String, on: Bool, patterns: [String], all: [String]) -> [String] {
        var p = expanded(patterns, all: all).filter { $0 != "\(family).*" && Self.family(of: $0) != family }
        if on { p.append("\(family).*") }
        return normalized(p)
    }

    /// Turns one tool on or off. Turning one off inside `family.*` replaces the pattern by the remaining tools.
    static func setTool(_ toolID: String, on: Bool, patterns: [String], all: [String]) -> [String] {
        let fam = family(of: toolID)
        var p = expanded(patterns, all: all)
        if on {
            if !allows(toolID, p) { p.append(toolID) }
        } else {
            if p.contains("\(fam).*") {
                p.removeAll { $0 == "\(fam).*" }
                p += all.filter { family(of: $0) == fam && $0 != toolID }
            }
            p.removeAll { $0 == toolID }
        }
        return normalized(p)
    }

    /// Everything, including tools and skills installed later.
    static func setEverything(_ on: Bool, patterns: [String], all: [String]) -> [String] {
        on ? ["*"] : normalized(families(all).map { "\($0.family).*" })
    }
}

// MARK: Evaluation profiles

/// One test objective with file checks. Stored per agent in the `agent-evals` collection.
struct AgentEvalCase: Codable, Sendable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var objective: String
    /// Folder the run works in. Empty uses the default workspace.
    var workspace: String = ""
    var expectations: [Expectation] = []
}

struct AgentEvalResult: Codable, Sendable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var caseID: String
    var objective: String
    var runID: String?
    var status: String
    var checksPassed: Int
    var checksTotal: Int
    var failedChecks: [String]
    var error: String?
    var costUSD: Double
    var ranAt: Date

    /// A case passes when the run succeeded and every declared check passed.
    var passed: Bool { status == RunStatus.succeeded.rawValue && checksPassed == checksTotal && error == nil }
}

struct AgentEvalProfile: Codable, Sendable, Hashable {
    static let collection = "agent-evals"
    var agentID: String
    var cases: [AgentEvalCase] = []
    var results: [AgentEvalResult] = []
}

enum AgentValidation {
    static let roles = ["worker", "specialist", "planner", "verifier", "reviewer"]
    static let memoryScopes = ["session", "workflow", "agent", "user"]
    static let expectationKinds = ["file_exists", "file_nonempty", "file_contains", "dir_nonempty"]

    /// Problems that prevent saving, as sentences. Empty means the profile can be saved.
    static func problems(_ p: AgentProfile, existing: [AgentProfile]) -> [String] {
        var out: [String] = []
        let name = p.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { out.append(String(localized: "Give the agent a name.")) }
        else if name.range(of: #"^[a-z][a-z0-9-]{1,39}$"#, options: .regularExpression) == nil {
            out.append(String(localized: "The name must be 2 to 40 lowercase letters, digits or dashes, starting with a letter (workflows refer to agents by this name)."))
        } else if existing.contains(where: { $0.name == name && $0.id != p.id }) {
            out.append(String(localized: "Another agent is already named “\(name)”."))
        }
        if p.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(String(localized: "Write instructions: they are what makes this agent different.")) }
        if !roles.contains(p.role) { out.append(String(localized: "Choose a role.")) }
        return out
    }

    static func roleTitle(_ role: String) -> String {
        switch role {
        case "worker": return String(localized: "Worker")
        case "specialist": return String(localized: "Specialist")
        case "planner": return String(localized: "Planner")
        case "verifier": return String(localized: "Verifier")
        case "reviewer": return String(localized: "Reviewer")
        default: return role
        }
    }

    static func memoryScopeTitle(_ scope: String) -> String {
        switch scope {
        case "session": return String(localized: "This conversation")
        case "workflow": return String(localized: "The workflow it runs in")
        case "agent": return String(localized: "Its own notes")
        case "user": return String(localized: "Your approved preferences")
        default: return scope
        }
    }

    static func expectationTitle(_ kind: String) -> String {
        switch kind {
        case "file_exists": return String(localized: "File exists")
        case "file_nonempty": return String(localized: "File is not empty")
        case "file_contains": return String(localized: "File contains text")
        case "dir_nonempty": return String(localized: "Folder is not empty")
        default: return kind
        }
    }
}

// MARK: View model

@MainActor
@Observable
final class AgentsModel {
    let services: ORIXServices
    private(set) var profiles: [AgentProfile] = []
    private(set) var manifests: [ToolManifest] = []
    private(set) var loaded = false
    /// The profile being edited. Changes stay here until `save()`.
    var draft: AgentProfile?
    private(set) var savedDraft: AgentProfile?
    var selectedID: String?
    var error: String?
    private(set) var saving = false
    private(set) var evaluation: AgentEvalProfile?
    private(set) var evaluating = false
    private(set) var evaluationProgress: String?

    init(services: ORIXServices) { self.services = services }

    var toolIDs: [String] { manifests.map(\.identifier) }
    var isDirty: Bool { draft != savedDraft }
    var problems: [String] { draft.map { AgentValidation.problems($0, existing: profiles) } ?? [] }

    func reload() async {
        profiles = await services.agents.all()
        manifests = await services.registry.manifests().sorted { $0.identifier < $1.identifier }
        loaded = true
        if let id = selectedID {
            // Keep unsaved edits (and a new, never saved profile); adopt the stored version only when nothing was changed here.
            if let fresh = profiles.first(where: { $0.id == id }), !isDirty { draft = fresh; savedDraft = fresh }
        } else if let first = profiles.first {
            await select(first.id)
        }
    }

    func select(_ id: String) async {
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        selectedID = id; draft = p; savedDraft = p; error = nil
        evaluation = (try? await services.store.get(AgentEvalProfile.self, collection: AgentEvalProfile.collection, id: id)) ?? AgentEvalProfile(agentID: id)
    }

    /// A unique name derived from `base`: `base`, `base-2`, `base-3`…
    func uniqueName(_ base: String) -> String {
        let names = Set(profiles.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Starts a new, unsaved user profile.
    func newProfile() {
        let p = AgentProfile(name: uniqueName("my-agent"), role: "worker", instructions: "", model: ModelRef(provider: .anthropic, model: ""),
                             toolPatterns: ["filesystem.list", "filesystem.read", "filesystem.search", "filesystem.metadata"], memoryScopes: ["session"])
        selectedID = p.id; draft = p; savedDraft = nil; error = nil
        evaluation = AgentEvalProfile(agentID: p.id)
    }

    /// Copies a profile (built-in or not) into a new editable one and saves it.
    @discardableResult
    func duplicate(_ id: String) async -> AgentProfile? {
        guard let source = profiles.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID().uuidString; copy.builtIn = false; copy.name = uniqueName(source.name + "-copy")
        do {
            try await services.agents.save(copy)
            await reload(); await select(copy.id)
            return copy
        } catch { self.error = ManageText.describe(error); return nil }
    }

    @discardableResult
    func save() async -> Bool {
        guard var p = draft, !p.builtIn else { return false }
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.budget = BudgetBounds.clamped(p.budget)
        p.maxConcurrency = BudgetBounds.clamp(p.maxConcurrency, BudgetBounds.concurrency)
        p.toolPatterns = ToolGrantTree.normalized(p.toolPatterns)
        let problems = AgentValidation.problems(p, existing: profiles)
        guard problems.isEmpty else { error = problems.joined(separator: " "); return false }
        saving = true; defer { saving = false }
        do {
            try await services.agents.save(p)
            draft = p; savedDraft = p; error = nil
            profiles = await services.agents.all()
            return true
        } catch { self.error = ManageText.describe(error); return false }
    }

    func revert() { draft = savedDraft; error = nil; if savedDraft == nil { selectedID = nil } }

    func delete(_ id: String) async {
        do {
            try await services.agents.remove(id: id)
            _ = try? await services.store.remove(collection: AgentEvalProfile.collection, id: id)
            if selectedID == id { selectedID = nil; draft = nil; savedDraft = nil; evaluation = nil }
            await reload()
        } catch { self.error = ManageText.describe(error) }
    }

    // MARK: Evaluation

    func saveEvaluation(_ profile: AgentEvalProfile) async {
        evaluation = profile
        do { try await services.store.put(profile, collection: AgentEvalProfile.collection, id: profile.agentID) }
        catch { self.error = ManageText.describe(error) }
    }

    func addCase(_ c: AgentEvalCase) async {
        guard var e = evaluation else { return }
        e.cases.append(c)
        await saveEvaluation(e)
    }

    func removeCase(_ id: String) async {
        guard var e = evaluation else { return }
        e.cases.removeAll { $0.id == id }
        e.results.removeAll { $0.caseID == id }
        await saveEvaluation(e)
    }

    /// Runs every case as a real agent run in review mode (read-only), one after another, and stores the results.
    /// The checks are evaluated by the runtime, not by the model.
    func runEvaluation(defaultWorkspace: String) async {
        guard var e = evaluation, let agent = savedDraft, !isDirty, !e.cases.isEmpty, !evaluating else { return }
        evaluating = true; error = nil
        defer { evaluating = false; evaluationProgress = nil }
        var results: [AgentEvalResult] = []
        for (i, c) in e.cases.enumerated() {
            evaluationProgress = String(localized: "Case \(String(i + 1)) of \(String(e.cases.count))")
            var req = AgentRunRequest(objective: c.objective, workingDirectory: c.workspace.isEmpty ? defaultWorkspace : c.workspace)
            req.agent = agent.name; req.mode = .review; req.workspaceAccess = .read; req.expectations = c.expectations
            req.title = "Evaluation · \(agent.name) · \(String(c.objective.prefix(50)))"; req.trigger = "evaluation"
            var result = AgentEvalResult(caseID: c.id, objective: c.objective, runID: nil, status: RunStatus.failed.rawValue, checksPassed: 0,
                                         checksTotal: c.expectations.count, failedChecks: [], error: nil, costUSD: 0, ranAt: Date())
            do {
                let runID = try await services.runs.startAgentRun(req)
                result.runID = runID
                let record = await services.runs.wait(runID: runID)
                let receipt = try? await services.store.receipt(runID: runID)
                let checks = receipt?.verifications ?? []
                result.status = (record?.status ?? .failed).rawValue
                result.checksTotal = max(checks.count, c.expectations.count)
                result.checksPassed = checks.filter(\.passed).count
                result.failedChecks = checks.filter { !$0.passed }.map { "\($0.assertion) — \($0.evidence)" }
                result.costUSD = record?.usage.costUSD ?? 0
                if let s = record?.errorSummary, record?.status != .succeeded { result.error = s }
            } catch {
                result.error = ManageText.describe(error)
            }
            results.append(result)
        }
        e.results = results
        await saveEvaluation(e)
    }
}
