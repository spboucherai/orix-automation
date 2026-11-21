// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/SkillsView.swift
// Description: Skills section: installed skills with versions and tests, drafts with source, findings and an install confirmation, the read-only tool catalog, folder import and manual authoring.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

public enum SkillsTab: String, CaseIterable, Identifiable, Sendable {
    case installed, drafts, catalog, author
    public var id: String { rawValue }
}

public struct SkillsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: SkillsTab
    @State private var skills: SkillsModel?
    @State private var installCandidate: SkillDraft?
    @State private var uninstallCandidate: InstalledSkill?
    @State private var discardCandidate: SkillDraft?
    @State private var search = ""
    @State private var selectedTool: String?
    @State private var form = SkillForm()
    private let initialTool: String?

    public init() { _tab = State(initialValue: .installed); initialTool = nil }

    /// Opens on a tab; `selectTool` preselects a tool in the catalog. Used by the preview harness and deep links.
    public init(tab: SkillsTab, selectTool: String? = nil) { _tab = State(initialValue: tab); initialTool = selectTool }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            PageHeader("Skills", subtitle: "Tools ORIX can use: the built-in catalog, and packages you reviewed and installed.") {
                HStack(spacing: Theme.Space.s) {
                    Button { importFolder() } label: { BusyLabel(title: "Import a skill folder…", busy: skills?.busy == "import", symbol: "square.and.arrow.down") }
                        .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("skills.import")
                    Button { tab = .author } label: { Label("New skill", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("skills.new")
                }
            }
            ManageTabBar(items: [
                TabItem(value: SkillsTab.installed, title: "Installed", symbol: "puzzlepiece.extension", count: skills?.installed.count),
                TabItem(value: .drafts, title: "Drafts to review", symbol: "doc.text.magnifyingglass", count: skills?.drafts.count),
                TabItem(value: .catalog, title: "Built-in tools", symbol: "wrench.and.screwdriver", count: skills?.manifests.count),
                TabItem(value: .author, title: "New skill", symbol: "plus.square"),
            ], selection: $tab, identifierPrefix: "skills")
            if let m = skills?.message { Banner(kind: m.kind, text: m.text) }
            if let skills, skills.loaded {
                switch tab {
                case .installed: scroll { installedSection(skills) }
                case .drafts: scroll { draftsSection(skills) }
                case .catalog: catalogSection(skills)
                case .author: scroll { SkillAuthoringForm(form: $form, busy: skills.busy == "propose") { Task { if await skills.propose(form) != nil { tab = .drafts } } } }
                }
            } else {
                Card { VStack(alignment: .leading, spacing: Theme.Space.s) { SkeletonLine(width: 220); SkeletonLine(width: 300) } }
            }
        }
        .padding([.horizontal, .top], Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas)
        .task {
            if skills == nil { skills = SkillsModel(services: model.services); selectedTool = initialTool; form = .wordCountTemplate }
        }
        .task(id: model.revision) { await skills?.reload() }
        .sheet(item: $installCandidate) { draft in
            InstallConfirmation(draft: draft, onCancel: { installCandidate = nil }) {
                installCandidate = nil
                Task { if await skills?.install(draftID: draft.id) != nil { tab = .installed } }
            }
            .frame(width: 560)
        }
        .confirmationDialog("Uninstall \(uninstallCandidate?.package.manifest.name ?? "")?", isPresented: Binding(get: { uninstallCandidate != nil }, set: { if !$0 { uninstallCandidate = nil } }), titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { if let s = uninstallCandidate { Task { await skills?.uninstall(s.id) } }; uninstallCandidate = nil }
            Button("Cancel", role: .cancel) { uninstallCandidate = nil }
        } message: { Text("Every installed version of this skill is removed from this Mac. Workflows and agents that call it will fail until it is installed again.") }
        .confirmationDialog("Discard this draft?", isPresented: Binding(get: { discardCandidate != nil }, set: { if !$0 { discardCandidate = nil } }), titleVisibility: .visible) {
            Button("Discard draft", role: .destructive) { if let d = discardCandidate { Task { await skills?.discard(draftID: d.id) } }; discardCandidate = nil }
            Button("Cancel", role: .cancel) { discardCandidate = nil }
        } message: { Text("The draft package, its source and its test results are deleted. Installed skills are not affected.") }
    }

    private func scroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: Theme.Space.m) { content() }.padding(.bottom, Theme.Space.xl) }
    }

    private func importFolder() {
        guard let url = FilePanels.chooseFolder(message: String(localized: "Choose a skill folder (it contains skill.json). It is imported as a draft, never installed directly.")) else { return }
        Task { if await skills?.importFolder(url) != nil { tab = .drafts } }
    }

    // MARK: Installed

    @ViewBuilder
    private func installedSection(_ skills: SkillsModel) -> some View {
        if skills.installed.isEmpty {
            Card {
                EmptyState(symbol: "puzzlepiece.extension", title: "No skill installed",
                           message: "A skill is a small script with a manifest, tests and declared permissions. Write one, import a folder, or let an agent propose one; each is reviewed as a draft first.",
                           actionTitle: "New skill") { tab = .author }
                    .frame(minHeight: 300)
            }
        } else {
            ForEach(skills.installed) { s in
                InstalledSkillCard(skill: s, results: skills.testResults[s.id], testing: skills.testing.contains(s.id), skills: skills) { uninstallCandidate = s }
            }
        }
    }

    // MARK: Drafts

    @ViewBuilder
    private func draftsSection(_ skills: SkillsModel) -> some View {
        Banner(kind: .info, text: String(localized: "A draft is not installed and cannot be called. Imported and agent-written skills are untrusted until you have read the source. Findings are advice; the real limit is the sandbox the skill runs in. Drafts are kept until you quit ORIX."))
        if skills.drafts.isEmpty {
            Card {
                EmptyState(symbol: "doc.text.magnifyingglass", title: "Nothing to review", message: "Drafts appear here when you write a skill, import a folder, or an agent proposes one during a run.")
                    .frame(minHeight: 260)
            }
        } else {
            ForEach(skills.drafts) { d in
                DraftCard(draft: d, busy: skills.busy == d.id, onInstall: { installCandidate = d }, onDiscard: { discardCandidate = d })
            }
        }
    }

    // MARK: Catalog

    private func catalogSection(_ skills: SkillsModel) -> some View {
        let groups = skills.catalog(search: search)
        let selected = skills.manifests.first { $0.identifier == selectedTool } ?? groups.first?.tools.first
        return HStack(alignment: .top, spacing: Theme.Space.l) {
            VStack(spacing: Theme.Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                    TextField(String(localized: "Search tools"), text: $search).textFieldStyle(.plain).accessibilityIdentifier("skills.catalog.search")
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.stroke))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.family) { g in
                            Section {
                                ForEach(g.tools, id: \.identifier) { m in
                                    let isSelected = selected?.identifier == m.identifier
                                    Button { selectedTool = m.identifier } label: {
                                        HStack(spacing: 6) {
                                            Text(m.identifier).font(Theme.Font.monoSmall).foregroundStyle(isSelected ? Theme.violet : Theme.text).lineLimit(1)
                                            Spacer(minLength: 0)
                                            Text(verbatim: "T\(m.defaultTier.rawValue)").font(Theme.Font.captionStrong).foregroundStyle(StatusStyle.tier(m.defaultTier).0)
                                                .accessibilityLabel(Text(m.defaultTier.label))
                                        }
                                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 5)
                                        .background(isSelected ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).accessibilityIdentifier("skills.catalog.tool.\(m.identifier)")
                                }
                            } header: {
                                HStack {
                                    Text(g.family).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    Text(verbatim: String(g.tools.count)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                                }
                                .padding(.horizontal, Theme.Space.s).padding(.vertical, 4).background(Theme.canvas)
                            }
                        }
                    }
                    .padding(.bottom, Theme.Space.xl)
                }
            }
            .frame(width: 272)
            if let selected {
                ScrollView { ToolManifestDetail(manifest: selected).padding(.bottom, Theme.Space.xl) }
            } else {
                Card { EmptyState(symbol: "wrench.and.screwdriver", title: "No tool matches", message: "Change the search to see the catalog.") }
            }
        }
    }
}

// MARK: Installed skill

struct InstalledSkillCard: View {
    let skill: InstalledSkill
    let results: [SkillTestResult]?
    let testing: Bool
    let skills: SkillsModel
    let onUninstall: () -> Void

    var body: some View {
        let m = skill.package.manifest
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Theme.violet).frame(width: 30, height: 30)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(m.name).font(Theme.Font.heading)
                            Pill(text: m.version, symbol: "number")
                            Pill(text: m.runtime, symbol: "scroll")
                            TierBadge(tier: m.tier)
                        }
                        Text(m.id).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Toggle(skill.enabled ? LocalizedStringKey("Enabled") : LocalizedStringKey("Disabled"), isOn: Binding(get: { skill.enabled }, set: { on in Task { await skills.setEnabled(on, id: skill.id) } }))
                        .toggleStyle(.switch).accessibilityIdentifier("skills.installed.\(m.id).enabled")
                }
                Text(m.summary).font(Theme.Font.body).foregroundStyle(Theme.text)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.xl) { permissions(m).frame(maxWidth: .infinity, alignment: .leading); provenance.frame(maxWidth: .infinity, alignment: .leading) }
                    VStack(alignment: .leading, spacing: Theme.Space.m) { permissions(m); provenance }
                }
                versions
                if let results { SkillTestList(results: results) }
                HStack(spacing: Theme.Space.s) {
                    Button { Task { await skills.test(skill) } } label: { BusyLabel(title: "Test", busy: testing, symbol: "checkmark.seal") }
                        .buttonStyle(SecondaryButtonStyle()).disabled(testing).accessibilityIdentifier("skills.installed.\(m.id).test")
                    Button { FilePanels.reveal(skill.package.directory) } label: { Label("Reveal package", systemImage: "folder") }
                        .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("skills.installed.\(m.id).reveal")
                    Spacer()
                    Button(role: .destructive, action: onUninstall) { Label("Uninstall", systemImage: "trash") }
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).accessibilityIdentifier("skills.installed.\(m.id).uninstall")
                }
            }
        }
    }

    private func permissions(_ m: SkillManifest) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(title: "Permissions it declares")
            SkillPermissionList(manifest: m)
        }
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldLabel(title: "Provenance")
            if let p = skill.provenance {
                KeyValueRow(key: "Source", value: p.source, mono: true)
                KeyValueRow(key: "Installed", value: Format.dateTime(p.installedAt))
                KeyValueRow(key: "Digest", value: String(p.digest.prefix(16)) + "…", mono: true)
                KeyValueRow(key: "Tests at install", value: String(localized: "\(String(p.testsPassed)) of \(String(p.testsTotal)) passed, \(String(p.warnings)) warning(s)"))
            } else {
                Text("No provenance was recorded for this version.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var versions: some View {
        let current = skill.package.manifest.version
        let canRollBack = (skill.versions.firstIndex(of: current) ?? 0) > 0
        return VStack(alignment: .leading, spacing: 5) {
            FieldLabel(title: "Versions")
            HStack(spacing: Theme.Space.s) {
                ForEach(skill.versions, id: \.self) { v in
                    if v == current {
                        StatePill(text: String(localized: "\(v) in use"), symbol: "checkmark.circle.fill", color: Theme.success)
                    } else {
                        Button { Task { await skills.activate(skill.id, version: v) } } label: { Text("Use \(v)") }
                            .buttonStyle(.link).accessibilityIdentifier("skills.installed.\(skill.id).activate.\(v)")
                    }
                }
                if canRollBack {
                    Button { Task { await skills.rollback(skill.id) } } label: { Label("Roll back", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.link).accessibilityIdentifier("skills.installed.\(skill.id).rollback")
                }
            }
        }
    }
}

struct SkillPermissionList: View {
    let manifest: SkillManifest
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(SkillsModel.permissionLines(manifest).enumerated()), id: \.offset) { _, line in
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: line.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.violet).frame(width: 18)
                    Text(line.text).font(Theme.Font.body).foregroundStyle(Theme.text)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct SkillTestList: View {
    let results: [SkillTestResult]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if results.isEmpty {
                Label("This skill has no test. A skill without a passing test cannot be installed.", systemImage: "exclamationmark.triangle").font(Theme.Font.caption).foregroundStyle(Theme.warning)
            }
            ForEach(results, id: \.self) { r in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(r.passed ? Theme.success : Theme.danger)
                    Text(r.passed ? LocalizedStringKey("Passed") : LocalizedStringKey("Failed")).font(Theme.Font.captionStrong).foregroundStyle(r.passed ? Theme.success : Theme.danger)
                    Text(r.name).font(Theme.Font.body)
                    Text(r.detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
                    Spacer(minLength: 0)
                    Text(Format.duration(Double(r.durationMs) / 1000)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: Draft

struct FindingList: View {
    let findings: [SkillFinding]
    var body: some View {
        if findings.isEmpty {
            Label("The source review found nothing to report.", systemImage: "checkmark.circle").font(Theme.Font.caption).foregroundStyle(Theme.success)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach([SkillFinding.Severity.blocker, .warning, .info], id: \.self) { severity in
                    ForEach(findings.filter { $0.severity == severity }, id: \.self) { f in
                        let (label, symbol, color): (String, String, Color) = {
                            switch severity {
                            case .blocker: return (String(localized: "Blocker"), "xmark.octagon.fill", Theme.danger)
                            case .warning: return (String(localized: "Warning"), "exclamationmark.triangle.fill", Theme.warning)
                            case .info: return (String(localized: "Note"), "info.circle.fill", Theme.info)
                            }
                        }()
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Label(label, systemImage: symbol).font(Theme.Font.captionStrong).foregroundStyle(color).frame(width: 84, alignment: .leading)
                            Text(verbatim: "\(f.file):\(f.line)").font(Theme.Font.monoSmall).foregroundStyle(Theme.textSecondary)
                            Text(f.message).font(Theme.Font.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

struct DraftCard: View {
    let draft: SkillDraft
    var busy = false
    let onInstall: () -> Void
    let onDiscard: () -> Void
    @State private var showSource = true

    var body: some View {
        let m = draft.package.manifest
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(m.name).font(Theme.Font.heading)
                            Pill(text: m.version, symbol: "number")
                            Pill(text: m.runtime, symbol: "scroll")
                            TierBadge(tier: m.tier)
                        }
                        Text(verbatim: "\(m.id) · \(draft.source) · \(Format.dateTime(draft.createdAt))").font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if draft.installable { StatePill(text: String(localized: "Ready to install"), symbol: "checkmark.seal.fill", color: Theme.success) }
                    else { StatePill(text: String(localized: "Cannot be installed"), symbol: "xmark.seal.fill", color: Theme.danger) }
                }
                Text(m.summary).font(Theme.Font.body)
                if !draft.installable { Text(Self.blockedReason(draft)).font(Theme.Font.caption).foregroundStyle(Theme.danger) }
                group("Requested permissions") { SkillPermissionList(manifest: m) }
                group("Source review") { FindingList(findings: draft.findings) }
                group("Tests (run confined, without network)") { SkillTestList(results: draft.tests) }
                DisclosureGroup(isExpanded: $showSource) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(draft.sources.keys.sorted(), id: \.self) { file in
                            Text(file).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                            CodeBlock(text: draft.sources[file] ?? "", maxHeight: 240)
                        }
                    }
                    .padding(.top, Theme.Space.s)
                } label: { Text("Source code").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary) }
                HStack {
                    Button(role: .destructive, action: onDiscard) { Label("Discard", systemImage: "trash") }
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).accessibilityIdentifier("skills.draft.\(draft.id).discard")
                    Spacer()
                    if draft.installable {
                        Button(action: onInstall) { BusyLabel(title: "Install…", busy: busy, symbol: "square.and.arrow.down") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("skills.draft.\(draft.id).install")
                    }
                }
            }
        }
    }

    private func group<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { FieldLabel(title: title); content() }
    }

    static func blockedReason(_ d: SkillDraft) -> String {
        if SkillAnalyzer.hasBlocker(d.findings) { return String(localized: "The source review found a blocker. Fix the source and propose it again.") }
        if d.tests.isEmpty { return String(localized: "It has no test. Add at least one test case.") }
        return String(localized: "At least one test failed.")
    }
}

/// The sheet shown before installing: what the skill will be allowed to do and what the review found.
struct InstallConfirmation: View {
    let draft: SkillDraft
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        let m = draft.package.manifest
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(Theme.violet)
                Text("Install \(m.name) \(m.version)?").font(Theme.Font.title)
                Spacer()
                TierBadge(tier: m.tier)
            }
            Text("Once installed, agents and workflows can call \(m.id). Every call is still checked against your grants; the script runs in a sandbox limited to the permissions below.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            FieldLabel(title: "It will be allowed to")
            SkillPermissionList(manifest: m)
            FieldLabel(title: "Source review")
            FindingList(findings: draft.findings)
            FieldLabel(title: "Tests")
            Text("\(String(draft.tests.filter(\.passed).count)) of \(String(draft.tests.count)) passed").font(Theme.Font.body)
            Text(verbatim: "sha256 \(draft.package.digest.prefix(24))…").font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: onInstall) { Label("Install", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!draft.installable).accessibilityIdentifier("skills.install.confirm")
            }
        }
        .padding(Theme.Space.xl)
        .background(Theme.surface)
    }
}

// MARK: Tool manifest

struct ToolManifestDetail: View {
    let manifest: ToolManifest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manifest.name).font(Theme.Font.title)
                            Text(verbatim: "\(manifest.identifier) · \(manifest.version)").font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                        }
                        Spacer()
                        TierBadge(tier: manifest.defaultTier)
                    }
                    Text(manifest.summary).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 6) {
                        fact("Side effect", ManageText.sideEffectLabel(manifest.sideEffect), "bolt")
                        fact("Dry run", manifest.supportsDryRun ? String(localized: "Supported: can show what would change") : String(localized: "Not supported"), "eye")
                        fact("Repeat safely", manifest.idempotent ? String(localized: "Yes, may be retried") : String(localized: "No, never retried automatically"), "arrow.clockwise")
                        fact("Time limit", Format.duration(manifest.defaultTimeoutSeconds), "timer")
                        fact("Output", manifest.outputIsUntrusted ? String(localized: "Treated as untrusted data") : String(localized: "Produced by ORIX itself"), "shield.lefthalf.filled")
                        fact("macOS permissions", manifest.macPermissions.isEmpty ? String(localized: "None") : manifest.macPermissions.map(ManageText.permissionTitle).joined(separator: ", "), "lock")
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader("Input schema")
                    CodeBlock(text: manifest.inputSchema.raw.serialized(pretty: true), maxHeight: 280)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader("Output schema")
                    CodeBlock(text: manifest.outputSchema.raw.serialized(pretty: true), maxHeight: 220)
                }
            }
        }
    }

    private func fact(_ key: LocalizedStringKey, _ value: String, _ symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.violet).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(key).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Text(value).font(Theme.Font.body).foregroundStyle(Theme.text)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Authoring

struct SkillAuthoringForm: View {
    @Binding var form: SkillForm
    let busy: Bool
    let onPropose: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Describe the skill", subtitle: "It becomes a draft: analysed, tested in a sandbox, then shown to you before anything is installed.") {
                    Menu {
                        Button("Word count example (Python)") { form = .wordCountTemplate }
                        Button("Empty form") { form = SkillForm() }
                    } label: { Text("Start from") }.menuStyle(.borderlessButton).fixedSize()
                }
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    labeled("Name") { TextField(String(localized: "Word count"), text: $form.name).textFieldStyle(.roundedBorder).frame(maxWidth: 260).accessibilityIdentifier("skills.author.name") }
                    labeled("Version") { TextField("1.0.0", text: $form.version).textFieldStyle(.roundedBorder).font(Theme.Font.mono).frame(width: 90) }
                    labeled("Runtime") {
                        Picker("Runtime", selection: $form.runtime) { Text(verbatim: "python").tag("python"); Text(verbatim: "bash").tag("bash") }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 160).accessibilityIdentifier("skills.author.runtime")
                    }
                    labeled("Time limit") { DoubleField(value: $form.timeoutSeconds, range: 1...600, step: 5, unit: String(localized: "seconds"), fraction: 0) }
                }
                Text(verbatim: form.identifier).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary)
                labeled("What it does, in one sentence") { TextField(String(localized: "Counts the words and lines of a text file."), text: $form.summary).textFieldStyle(.roundedBorder).accessibilityIdentifier("skills.author.summary") }
            }
        }
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader("Source", subtitle: "Reads one JSON object on standard input, prints one JSON object on standard output.")
                Text(verbatim: form.entry).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                CodeEditor(text: $form.source, minHeight: 190).accessibilityIdentifier("skills.author.source")
            }
        }
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Contract")
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Theme.Space.l) { schema("Input schema (JSON)", $form.inputSchemaJSON); schema("Output schema (JSON)", $form.outputSchemaJSON) }
                    VStack(alignment: .leading, spacing: Theme.Space.m) { schema("Input schema (JSON)", $form.inputSchemaJSON); schema("Output schema (JSON)", $form.outputSchemaJSON) }
                }
            }
        }
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Permissions", subtitle: "One entry per line. Anything not listed is denied by the sandbox when the skill runs.")
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    labeled("May read") { CodeEditor(text: $form.fileRead, minHeight: 54).accessibilityIdentifier("skills.author.read") }
                    labeled("May write") { CodeEditor(text: $form.fileWrite, minHeight: 54).accessibilityIdentifier("skills.author.write") }
                    labeled("May contact (hosts)") { CodeEditor(text: $form.network, minHeight: 54).accessibilityIdentifier("skills.author.network") }
                }
                Explanation(String(localized: "Paths are absolute, start with ~/, or are $input.<field> for a path the caller passes in that field. Leave hosts empty for no network at all."))
            }
        }
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Tests", subtitle: "At least one must pass. Each runs in a fresh folder holding its fixture files; $fixture is that folder.") {
                    Button { form.tests.append(SkillForm.TestForm(name: "test \(form.tests.count + 1)")) } label: { Label("Add a test", systemImage: "plus") }
                        .buttonStyle(.link).accessibilityIdentifier("skills.author.addTest")
                }
                if form.tests.isEmpty { Explanation(String(localized: "No test yet. A skill without a passing test cannot be installed.")) }
                ForEach($form.tests) { $t in testEditor($t) }
            }
        }
        HStack {
            Spacer()
            Button(action: onPropose) { BusyLabel(title: "Analyse and test", busy: busy, symbol: "doc.text.magnifyingglass") }
                .buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("skills.author.propose")
        }
    }

    private func labeled<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { FieldLabel(title: title); control() }
    }

    private func schema(_ title: LocalizedStringKey, _ text: Binding<String>) -> some View {
        labeled(title) { CodeEditor(text: text, minHeight: 130) }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func testEditor(_ t: Binding<SkillForm.TestForm>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                TextField(String(localized: "Test name"), text: t.name).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Expect a failure", isOn: t.expectFailure).toggleStyle(.checkbox)
                Spacer()
                Button { form.tests.removeAll { $0.id == t.wrappedValue.id } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel(Text("Remove this test"))
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                labeled("Input (JSON)") { CodeEditor(text: t.inputJSON, minHeight: 60) }
                labeled("Expected output fields (JSON)") { CodeEditor(text: t.expectOutputJSON, minHeight: 60) }
            }
            ForEach(t.fixtures) { $f in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    TextField(String(localized: "File name"), text: $f.path).textFieldStyle(.roundedBorder).font(Theme.Font.mono).frame(width: 180)
                    CodeEditor(text: $f.content, minHeight: 44)
                    Button { t.wrappedValue.fixtures.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove this fixture file"))
                }
            }
            HStack(spacing: Theme.Space.m) {
                Button { t.wrappedValue.fixtures.append(.init()) } label: { Label("Add a fixture file", systemImage: "doc.badge.plus") }.buttonStyle(.link)
                TextField(String(localized: "Files that must exist afterwards (comma-separated)"), text: t.expectFiles).textFieldStyle(.roundedBorder).font(Theme.Font.monoSmall)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }
}

/// The install confirmation as a standalone view, so the preview harness can render the sheet's content.
public struct InstallConfirmationPreview: View {
    let draft: SkillDraft
    public init(draft: SkillDraft) { self.draft = draft }
    public var body: some View { InstallConfirmation(draft: draft, onCancel: {}, onInstall: {}) }
}
