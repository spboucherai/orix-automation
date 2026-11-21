// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/AgentsView.swift
// Description      : Agents section: the profile list, the editor (identity,
//                    model, budget, tool grants as a tree, memory scopes),
//                    evaluation profiles and the memory panel.
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

import ORIXAppUI
import SwiftUI

public enum AgentsTab: String, CaseIterable, Identifiable, Sendable {
    case profiles, memory
    public var id: String { rawValue }
}

public struct AgentsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AgentsTab
    @State private var agents: AgentsModel?
    @State private var catalogs: [ProviderID: [ModelInfo]] = [:]
    @State private var deleteCandidate: AgentProfile?
    private let initialSelection: String?
    private let initialExpanded: Set<String>

    public init() { _tab = State(initialValue: .profiles); initialSelection = nil; initialExpanded = [] }

    /// Opens on a tab, optionally selecting a profile by name and expanding tool families. Used by the preview harness.
    public init(tab: AgentsTab, selectAgentNamed: String? = nil, expandedFamilies: Set<String> = []) {
        _tab = State(initialValue: tab); initialSelection = selectAgentNamed; initialExpanded = expandedFamilies
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PageHeader("Agents", subtitle: "Reusable agents: what they are told, which model they use, and exactly which tools they are handed.") {
                Button { agents?.newProfile(); tab = .profiles } label: { Label("New agent", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("agents.new")
            }
            ManageTabBar(items: [
                TabItem(value: AgentsTab.profiles, title: "Profiles", symbol: "person.2", count: agents?.profiles.count),
                TabItem(value: .memory, title: "Memory", symbol: "tray.full"),
            ], selection: $tab, identifierPrefix: "agents")
            switch tab {
            case .profiles: profilesBody
            case .memory: ScrollView { MemoryPanel().padding(.bottom, Theme.Space.xl) }
            }
        }
        .padding([.horizontal, .top], Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .task {
            if agents == nil {
                let a = AgentsModel(services: model.services)
                agents = a
                await a.reload()
                if let name = initialSelection, let p = a.profiles.first(where: { $0.name == name }) { await a.select(p.id) }
            }
        }
        .task(id: model.revision) {
            await agents?.reload()
            for id in model.configuredProviders where catalogs[id] == nil { catalogs[id] = await model.services.providers.models(for: id).models }
        }
        .confirmationDialog("Delete the agent “\(deleteCandidate?.name ?? "")”?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }), titleVisibility: .visible) {
            Button("Delete agent", role: .destructive) { if let p = deleteCandidate { Task { await agents?.delete(p.id) } }; deleteCandidate = nil }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("Its instructions, tool grants and evaluation cases are removed. Workflows that name this agent will fail validation until you change them. Past runs are kept.")
        }
    }

    @ViewBuilder
    private var profilesBody: some View {
        if let agents, agents.loaded {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                list(agents).frame(width: 264)
                if let draft = agents.draft {
                    AgentEditor(agents: agents, draft: draft, catalogs: catalogs, initialExpanded: initialExpanded) { deleteCandidate = draft }
                        .id(draft.id)
                } else {
                    Card { EmptyState(symbol: "person.2.badge.gearshape", title: "Choose an agent", message: "Select a profile on the left, or create a new one.", actionTitle: "New agent") { agents.newProfile() } }
                }
            }
        } else {
            Card { VStack(alignment: .leading, spacing: Theme.Space.s) { SkeletonLine(width: 220); SkeletonLine(width: 300) } }
        }
    }

    private func list(_ agents: AgentsModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if let d = agents.draft, !agents.profiles.contains(where: { $0.id == d.id }) {
                    profileRow(d, agents, unsaved: true)
                }
                ForEach(agents.profiles) { p in profileRow(p, agents, unsaved: false) }
            }
            .padding(.bottom, Theme.Space.xl)
        }
    }

    private func profileRow(_ p: AgentProfile, _ agents: AgentsModel, unsaved: Bool) -> some View {
        let selected = agents.selectedID == p.id
        return Button { if !unsaved { Task { await agents.select(p.id) } } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(p.name.isEmpty ? String(localized: "Untitled") : p.name).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if p.builtIn { Pill(text: String(localized: "built-in"), symbol: "lock") }
                    if unsaved { Pill(text: String(localized: "not saved"), symbol: "pencil", color: Theme.warning) }
                }
                Text(AgentValidation.roleTitle(p.role)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Text(p.model.model.isEmpty ? String(localized: "Default model") : p.model.model).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(selected ? Theme.violet.opacity(0.5) : Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("agents.row.\(p.name)")
    }
}

// MARK: Editor

struct AgentEditor: View {
    @Environment(AppModel.self) private var model
    let agents: AgentsModel
    let draft: AgentProfile
    let catalogs: [ProviderID: [ModelInfo]]
    let initialExpanded: Set<String>
    let onDelete: () -> Void
    @State private var expanded: Set<String> = []

    private func field<T>(_ kp: WritableKeyPath<AgentProfile, T>) -> Binding<T> {
        Binding(get: { agents.draft?[keyPath: kp] ?? draft[keyPath: kp] }, set: { agents.draft?[keyPath: kp] = $0 })
    }

    private var readOnly: Bool { draft.builtIn }
    private var isNew: Bool { !agents.profiles.contains { $0.id == draft.id } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if readOnly {
                        Banner(kind: .info, text: String(localized: "Built-in agents cannot be changed. Duplicate this one to make your own version."), actionTitle: "Duplicate") {
                            Task { await agents.duplicate(draft.id) }
                        }
                    }
                    if let e = agents.error { Banner(kind: .error, text: e) }
                    identity.disabled(readOnly)
                    modelCard.disabled(readOnly)
                    toolsCard
                    limitsCard.disabled(readOnly)
                    if !isNew { AgentEvaluationCard(agents: agents) }
                }
                .padding(.bottom, Theme.Space.l)
            }
            Divider()
            footer.padding(.vertical, Theme.Space.m)
        }
        .onAppear { expanded = initialExpanded }
    }

    private var identity: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Identity")
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(title: "Name")
                        TextField("research-helper", text: field(\.name)).textFieldStyle(.roundedBorder).font(Theme.Font.mono).frame(maxWidth: 280)
                            .accessibilityIdentifier("agents.editor.name")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(title: "Role")
                        Picker("Role", selection: field(\.role)) {
                            ForEach(AgentValidation.roles, id: \.self) { Text(AgentValidation.roleTitle($0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 180).accessibilityIdentifier("agents.editor.role")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(title: "Instructions")
                    TextEditor(text: field(\.instructions)).font(Theme.Font.body).scrollContentBackground(.hidden).padding(6)
                        .frame(minHeight: 110, maxHeight: 220)
                        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.stroke))
                        .accessibilityIdentifier("agents.editor.instructions")
                    Explanation(String(localized: "Instructions shape behaviour. They never grant anything: what the agent may do is decided by its tools below and by your grants."))
                }
                if !readOnly, !agents.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(agents.problems, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(Theme.Font.caption).foregroundStyle(Theme.warning) }
                    }
                }
            }
        }
    }

    private var modelCard: some View {
        let current = agents.draft?.model ?? draft.model
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Model")
                HStack(spacing: Theme.Space.m) {
                    if current.model.isEmpty {
                        Label("Use the default model", systemImage: "star").font(Theme.Font.bodyStrong)
                        Text(model.settings.defaultModel.map { String(localized: "currently \($0.displayString)") } ?? String(localized: "none chosen in Settings yet"))
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    } else {
                        ProviderGlyph(provider: current.provider, size: 20)
                        Text(current.model).font(Theme.Font.mono).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Menu {
                        Button("Use the default model") { agents.draft?.model = ModelRef(provider: .anthropic, model: "") }
                        Divider()
                        ForEach(model.configuredProviders, id: \.self) { provider in
                            Menu(provider.displayName) {
                                ForEach(catalogs[provider] ?? []) { m in
                                    Button(m.displayName) { agents.draft?.model = ModelRef(provider: provider, model: m.id) }
                                }
                            }
                        }
                    } label: { Text("Change") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("agents.editor.model")
                }
                if model.configuredProviders.isEmpty {
                    Explanation(String(localized: "No provider has a key yet, so only the default-model option is available. Add a key in Settings › Providers."))
                }
            }
        }
    }

    private var toolsCard: some View {
        let patterns = agents.draft?.toolPatterns ?? draft.toolPatterns
        let all = agents.toolIDs
        let families = ToolGrantTree.families(all)
        let allowed = all.filter { ToolGrantTree.allows($0, patterns) }.count
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Tools this agent is handed", subtitle: "\(String(allowed)) of \(String(all.count)) tools. Each call is still checked against your grants and approved by tier.")
                Toggle(isOn: Binding(get: { ToolGrantTree.includesFutureTools(patterns) },
                                     set: { agents.draft?.toolPatterns = ToolGrantTree.setEverything($0, patterns: patterns, all: all) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Every tool, including tools and skills added later").font(Theme.Font.bodyStrong)
                        Text("Stored as the pattern *. Turn it off to choose family by family.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                .toggleStyle(.checkbox).disabled(readOnly).accessibilityIdentifier("agents.editor.tools.everything")
                VStack(spacing: 0) {
                    ForEach(families, id: \.family) { f in
                        familyRow(f.family, tools: f.tools, patterns: patterns, all: all)
                        if expanded.contains(f.family) {
                            ForEach(f.tools, id: \.self) { id in toolRow(id, patterns: patterns, all: all) }
                        }
                        Divider().opacity(0.5)
                    }
                }
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                Text(verbatim: ToolGrantTree.normalized(patterns).joined(separator: "  ")).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(3)
                    .accessibilityLabel(Text("Stored patterns"))
            }
        }
    }

    private func familyRow(_ family: String, tools: [String], patterns: [String], all: [String]) -> some View {
        let state = ToolGrantTree.state(family: family, tools: tools, patterns: patterns)
        let on = tools.filter { ToolGrantTree.allows($0, patterns) }.count
        return HStack(spacing: Theme.Space.s) {
            TriStateBox(state: state) { agents.draft?.toolPatterns = ToolGrantTree.setFamily(family, on: state != .on, patterns: patterns, all: all) }
                .disabled(readOnly).accessibilityLabel(Text("All \(family) tools")).accessibilityIdentifier("agents.editor.tools.family.\(family)")
            Button {
                if expanded.contains(family) { expanded.remove(family) } else { expanded.insert(family) }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: expanded.contains(family) ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary).frame(width: 12)
                    Text(family).font(Theme.Font.mono).foregroundStyle(Theme.text)
                    if patterns.contains("\(family).*") || patterns.contains("*") { Pill(text: String(localized: "whole family"), color: Theme.violet) }
                    Spacer()
                    Text(verbatim: "\(on) / \(tools.count)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("agents.editor.tools.expand.\(family)")
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 7)
    }

    private func toolRow(_ id: String, patterns: [String], all: [String]) -> some View {
        let m = agents.manifests.first { $0.identifier == id }
        let on = ToolGrantTree.allows(id, patterns)
        return HStack(alignment: .top, spacing: Theme.Space.s) {
            TriStateBox(state: on ? .on : .off) { agents.draft?.toolPatterns = ToolGrantTree.setTool(id, on: !on, patterns: patterns, all: all) }
                .disabled(readOnly).accessibilityLabel(Text(id)).accessibilityIdentifier("agents.editor.tools.tool.\(id)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(id).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                    if let m {
                        Pill(text: ManageText.sideEffectLabel(m.sideEffect), symbol: "bolt", color: ManageText.sideEffectColor(m.sideEffect))
                        TierBadge(tier: m.defaultTier)
                    }
                }
                if let m { Text(m.summary).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 44).padding(.trailing, Theme.Space.m).padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private var limitsCard: some View {
        let scopes = agents.draft?.memoryScopes ?? draft.memoryScopes
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Budget of one run", subtitle: "The run stops when it reaches any limit. Today's spending limit in Settings still applies on top.")
                BudgetEditor(budget: field(\.budget), identifierPrefix: "agents.editor.budget")
                Divider()
                SettingRow(title: "Runs of this agent at the same time", detail: String(localized: "Further runs of this agent wait.")) {
                    IntField(value: field(\.maxConcurrency), range: BudgetBounds.concurrency, identifier: "agents.editor.concurrency")
                }
                Divider()
                Text("Memory it may read").font(Theme.Font.bodyStrong)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(AgentValidation.memoryScopes, id: \.self) { scope in
                        Toggle(AgentValidation.memoryScopeTitle(scope), isOn: Binding(get: { scopes.contains(scope) }, set: { on in
                            var s = scopes.filter { $0 != scope }
                            if on { s.append(scope) }
                            agents.draft?.memoryScopes = AgentValidation.memoryScopes.filter(s.contains)
                        }))
                        .toggleStyle(.checkbox).accessibilityIdentifier("agents.editor.memory.\(scope)")
                    }
                }
                Explanation(String(localized: "Memory is advisory. It is given to the model as context and never changes what the agent is allowed to do."))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            if !readOnly && !isNew {
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).accessibilityIdentifier("agents.editor.delete")
            }
            if !isNew {
                Button { Task { await agents.duplicate(draft.id) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("agents.editor.duplicate")
                Button { model.open(.section(.chat)) } label: { Label("Try this agent", systemImage: "bubble.left.and.text.bubble.right") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(agents.isDirty)
                    .help(Text("Opens the Agent section. Choose “\(draft.name)” there to talk to it."))
                    .accessibilityIdentifier("agents.editor.try")
            }
            Spacer()
            if !readOnly {
                if agents.isDirty { Text("Unsaved changes").font(Theme.Font.caption).foregroundStyle(Theme.warning) }
                Button(isNew ? LocalizedStringKey("Discard") : LocalizedStringKey("Revert")) { agents.revert() }.buttonStyle(SecondaryButtonStyle()).disabled(!agents.isDirty)
                    .accessibilityIdentifier("agents.editor.revert")
                Button { Task { await agents.save() } } label: { BusyLabel(title: "Save", busy: agents.saving) }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!agents.isDirty || !agents.problems.isEmpty || agents.saving)
                    .keyboardShortcut("s", modifiers: .command).accessibilityIdentifier("agents.editor.save")
            }
        }
    }
}

/// A checkbox with three states. The mixed state is a dash, not a colour.
struct TriStateBox: View {
    let state: TriState
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : (state == .mixed ? "minus.square.fill" : "square"))
                .font(.system(size: 15)).foregroundStyle(state == .off ? Theme.textTertiary : Theme.violet)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(state == .on ? LocalizedStringKey("on") : (state == .mixed ? LocalizedStringKey("partly on") : LocalizedStringKey("off"))))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: Evaluation

struct AgentEvaluationCard: View {
    @Environment(AppModel.self) private var model
    let agents: AgentsModel
    @State private var objective = ""
    @State private var workspace = ""
    @State private var checks: [Expectation] = []
    @State private var adding = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Evaluation", subtitle: "Test objectives with file checks, run for real in review mode (read-only).") {
                    Button { adding.toggle() } label: { Label("Add a case", systemImage: "plus") }.buttonStyle(.link).accessibilityIdentifier("agents.eval.add")
                }
                if let e = agents.evaluation {
                    if e.cases.isEmpty && !adding {
                        Explanation(String(localized: "No test case yet. A case is an objective plus the files that must exist afterwards; the runtime checks them, not the model."))
                    }
                    ForEach(e.cases) { c in caseRow(c, result: e.results.last { $0.caseID == c.id }) }
                    if adding { addForm }
                    if !e.cases.isEmpty {
                        Divider()
                        HStack(spacing: Theme.Space.m) {
                            Button { Task { await agents.runEvaluation(defaultWorkspace: model.defaultWorkspace) } } label: {
                                BusyLabel(title: "Run evaluation", busy: agents.evaluating, symbol: "play.fill")
                            }
                            .buttonStyle(PrimaryButtonStyle()).disabled(agents.evaluating || agents.isDirty)
                            .accessibilityIdentifier("agents.eval.run")
                            if let p = agents.evaluationProgress { Text(p).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                            else {
                                Text(agents.isDirty ? LocalizedStringKey("Save the agent first.") : LocalizedStringKey("Each case is one real run billed to your key, limited by the agent's budget."))
                                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        if !e.results.isEmpty {
                            let passed = e.results.filter(\.passed).count
                            Text("Last result: \(String(passed)) of \(String(e.results.count)) case(s) passed").font(Theme.Font.bodyStrong)
                        }
                    }
                }
            }
        }
    }

    private func caseRow(_ c: AgentEvalCase, result: AgentEvalResult?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                if let result {
                    StatePill(text: result.passed ? String(localized: "Passed") : String(localized: "Failed"), symbol: result.passed ? "checkmark.circle.fill" : "xmark.octagon.fill",
                              color: result.passed ? Theme.success : Theme.danger)
                } else {
                    StatePill(text: String(localized: "Not run"), symbol: "circle.dashed", color: Theme.neutral)
                }
                Text(c.objective).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(role: .destructive) { Task { await agents.removeCase(c.id) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).accessibilityLabel(Text("Remove this case"))
                    .accessibilityIdentifier("agents.eval.remove.\(c.id)")
            }
            if !c.workspace.isEmpty { Text(PathResolver.display(c.workspace)).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary) }
            ForEach(Array(c.expectations.enumerated()), id: \.offset) { _, x in
                Label("\(AgentValidation.expectationTitle(x.kind)): \(x.path)" + (x.text.map { " — “\($0)”" } ?? ""), systemImage: "checkmark.seal")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            if let result {
                HStack(spacing: Theme.Space.s) {
                    Text("\(result.status) · \(String(result.checksPassed))/\(String(result.checksTotal)) checks · \(Format.cost(result.costUSD)) · \(Format.dateTime(result.ranAt))")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    if let id = result.runID { Button("Open run") { model.open(.run(id)) }.buttonStyle(.link).font(Theme.Font.caption) }
                }
                ForEach(result.failedChecks, id: \.self) { Text($0).font(Theme.Font.caption).foregroundStyle(Theme.danger) }
                if let err = result.error { Text(err).font(Theme.Font.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }

    /// A binding into one check that stays valid while rows are being removed.
    private func check<T>(_ i: Int, _ kp: WritableKeyPath<Expectation, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { checks.indices.contains(i) ? checks[i][keyPath: kp] : fallback }, set: { if checks.indices.contains(i) { checks[i][keyPath: kp] = $0 } })
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            FieldLabel(title: "Objective")
            TextField(String(localized: "What the agent is asked to do"), text: $objective, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                .accessibilityIdentifier("agents.eval.objective")
            FieldLabel(title: "Workspace folder (empty: the default workspace)")
            HStack {
                TextField("~/Documents/Test", text: $workspace).textFieldStyle(.roundedBorder).font(Theme.Font.mono)
                Button("Choose…") { if let u = FilePanels.chooseFolder(message: String(localized: "Choose the folder this case runs in")) { workspace = u.path } }
                    .buttonStyle(SecondaryButtonStyle())
            }
            FieldLabel(title: "Checks")
            ForEach(checks.indices, id: \.self) { i in
                HStack(spacing: Theme.Space.s) {
                    Picker("Check", selection: check(i, \.kind, "file_exists")) {
                        ForEach(AgentValidation.expectationKinds, id: \.self) { Text(AgentValidation.expectationTitle($0)).tag($0) }
                    }.labelsHidden().frame(width: 180)
                    TextField(String(localized: "Path"), text: check(i, \.path, "")).textFieldStyle(.roundedBorder).font(Theme.Font.mono)
                    if checks.indices.contains(i), checks[i].kind == "file_contains" {
                        TextField(String(localized: "Text"), text: Binding(get: { checks.indices.contains(i) ? (checks[i].text ?? "") : "" }, set: { if checks.indices.contains(i) { checks[i].text = $0 } })).textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    Button { if checks.indices.contains(i) { checks.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel(Text("Remove this check"))
                }
            }
            HStack {
                Button { checks.append(Expectation(kind: "file_exists", path: "")) } label: { Label("Add a check", systemImage: "plus") }.buttonStyle(.link)
                Spacer()
                Button("Cancel") { adding = false }.buttonStyle(SecondaryButtonStyle())
                Button("Add case") {
                    let c = AgentEvalCase(objective: objective.trimmingCharacters(in: .whitespacesAndNewlines), workspace: workspace.trimmingCharacters(in: .whitespaces),
                                          expectations: checks.filter { !$0.path.trimmingCharacters(in: .whitespaces).isEmpty })
                    Task { await agents.addCase(c) }
                    objective = ""; workspace = ""; checks = []; adding = false
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("agents.eval.saveCase")
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }
}
