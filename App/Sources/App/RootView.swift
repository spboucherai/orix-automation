// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : App/Sources/App/RootView.swift
// Description      : Main window: sidebar with live badges, the section detail,
//                    banners, the global attention panel for pending approvals,
//                    onboarding and the command palette.
// Module           : App
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
import ORIXFeatureChat
import ORIXFeatureCode
import ORIXFeatureManage
import ORIXFeatureRuns
import ORIXFeatureWorkflow
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let backgroundAgent: BackgroundAgentRegistration
    @SceneStorage("orix.sidebar") private var sidebarVisibility = "all"
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    Banner(kind: banner.kind, text: banner.text, actionTitle: "Dismiss") { model.banner = nil }
                        .padding(.horizontal, Theme.Space.l).padding(.top, Theme.Space.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("app.banner")
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.canvas)
            .animation(Theme.spring(reduceMotion), value: model.banner?.text)
            .overlay(alignment: .bottomTrailing) { attentionPanel }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if !model.activeRuns.isEmpty {
                    Button { model.section = .runs } label: {
                        HStack(spacing: 5) { PulseDot(color: Theme.blue, active: true); Text("\(model.activeRuns.count) running").font(Theme.Font.caption) }
                    }
                    .help(Text("Show running automations"))
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showCommandPalette = true } label: { Label("Command Palette", systemImage: "command") }
                    .help(Text("Command palette (⌘K)")).accessibilityIdentifier("app.palette")
                Button(role: .destructive) { model.emergencyStop() } label: {
                    Label("Emergency Stop", systemImage: "stop.circle.fill").foregroundStyle(model.activeRuns.isEmpty ? Theme.textTertiary : Theme.danger)
                }
                .help(Text("Stop every run, tool and child process now (⌃⌥⌘.)")).disabled(model.isStopping)
                .accessibilityIdentifier("app.emergencyStop")
            }
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView { model.showOnboarding = false }
                .environment(model).frame(minWidth: 640, minHeight: 520)
        }
        .sheet(isPresented: $model.showCommandPalette) {
            CommandPalette().environment(model)
        }
        .onChange(of: columns) { _, v in sidebarVisibility = v == .detailOnly ? "detail" : "all" }
        .onAppear { columns = sidebarVisibility == "detail" ? .detailOnly : .all }
        .environment(\.backgroundAgentControl, backgroundAgent.control)
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .dashboard: DashboardView()
        case .chat: AgentChatView()
        case .workflows: WorkflowStudioView()
        case .code: CodeStudioView()
        case .runs: RunsView()
        case .scheduler: SchedulerView()
        case .agents: AgentsView()
        case .skills: SkillsView()
        case .learn: WatchAndLearnView()
        case .permissions: PermissionsView()
        case .settings: SettingsView()
        }
    }

    /// Pending approvals follow the user to every section except the ones that already show them in place.
    @ViewBuilder private var attentionPanel: some View {
        let count = model.pendingApprovals.count + model.pendingInteractions.count
        if count > 0, ![.chat, .dashboard, .workflows].contains(model.section) {
            ScrollView { AttentionStack().padding(Theme.Space.m) }
                .frame(width: 440).frame(maxHeight: 460).fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                .padding(Theme.Space.l)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .accessibilityIdentifier("app.attention")
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    private let groups: [(LocalizedStringKey, [AppSection])] = [
        ("Work", [.dashboard, .chat, .workflows, .code]),
        ("Activity", [.runs, .scheduler]),
        ("Build", [.agents, .skills, .learn]),
        ("Control", [.permissions, .settings]),
    ]

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Section(group.0) {
                    ForEach(group.1) { section in
                        Label { Text(section.title) } icon: { Image(systemName: section.symbol) }
                            .badge(badge(section))
                            .tag(section)
                            .accessibilityIdentifier("sidebar.\(section.rawValue)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                ForEach(ProviderID.all, id: \.self) { p in
                    ProviderGlyph(provider: p, size: 18).opacity(model.configuredProviders.contains(p) ? 1 : 0.28)
                        .help(Text(model.configuredProviders.contains(p) ? "\(p.displayName): key stored" : "\(p.displayName): no key"))
                }
                Spacer()
                if model.configuredProviders.isEmpty {
                    Button("Add a key") { model.section = .settings }.buttonStyle(.link).font(Theme.Font.caption)
                }
            }
            .padding(Theme.Space.m)
        }
    }

    private func badge(_ s: AppSection) -> Int {
        switch s {
        case .runs: return model.activeRuns.count
        case .dashboard: return model.pendingApprovals.count + model.pendingInteractions.count
        default: return 0
        }
    }
}

/// ⌘K: jump to a section, open a workflow or a recent run, or run an app-wide action. Fully keyboard driven.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @State private var entries: [Entry] = []
    @FocusState private var focused: Bool

    struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let action: @MainActor (AppModel) -> Void
    }

    private var filtered: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { ($0.title + " " + $0.subtitle).lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField(String(localized: "Search sections, workflows, runs and actions"), text: $query)
                    .textFieldStyle(.plain).font(Theme.Font.heading).focused($focused)
                    .onSubmit { run(selection) }
                    .accessibilityIdentifier("palette.search")
            }
            .padding(Theme.Space.l)
            Divider()
            ScrollViewReader { proxy in
                List(Array(filtered.enumerated()), id: \.element.id) { i, e in
                    HStack(spacing: Theme.Space.m) {
                        Image(systemName: e.symbol).frame(width: 20).foregroundStyle(i == selection ? Theme.violet : Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(Theme.Font.body)
                            if !e.subtitle.isEmpty { Text(e.subtitle).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(i == selection ? Theme.accentSoft : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { run(i) }
                    .id(i)
                }
                .listStyle(.plain)
                .onChange(of: selection) { _, v in proxy.scrollTo(v) }
            }
            .overlay { if filtered.isEmpty { Text("Nothing matches").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) } }
        }
        .frame(width: 620, height: 420)
        .background(Theme.surface)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) { selection = min(selection + 1, max(filtered.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .task { await load() }
    }

    private func run(_ index: Int) {
        guard filtered.indices.contains(index) else { return }
        let e = filtered[index]
        dismiss()
        e.action(model)
    }

    private func load() async {
        var out: [Entry] = AppSection.allCases.map { s in
            Entry(id: "section-\(s.rawValue)", title: String(localized: "Go to \(sectionName(s))"), subtitle: "", symbol: s.symbol) { $0.section = s }
        }
        out.append(Entry(id: "action-stop", title: String(localized: "Emergency stop"), subtitle: String(localized: "Stop every run, tool and child process now"), symbol: "stop.circle.fill") { $0.emergencyStop() })
        out.append(Entry(id: "action-onboarding", title: String(localized: "Show the welcome guide"), subtitle: "", symbol: "sparkles") { $0.showOnboarding = true })
        for w in await model.services.workflows.list() {
            out.append(Entry(id: "wf-\(w.id)", title: w.name, subtitle: String(localized: "Workflow · version \(w.currentVersion)"), symbol: "point.3.connected.trianglepath.dotted") { $0.open(.workflow(w.id)) })
            out.append(Entry(id: "wfc-\(w.id)", title: String(localized: "Edit \(w.name) as code"), subtitle: "", symbol: "chevron.left.forwardslash.chevron.right") { $0.open(.workflowCode(w.id)) })
        }
        for r in (try? await model.services.store.runs(limit: 15)) ?? [] {
            out.append(Entry(id: "run-\(r.id)", title: r.title, subtitle: String(localized: "Run · \(r.status.rawValue) · \(Format.relative(r.startedAt))"), symbol: "list.bullet.rectangle") { $0.open(.run(r.id)) })
        }
        entries = out
    }

    private func sectionName(_ s: AppSection) -> String {
        switch s {
        case .dashboard: return String(localized: "Dashboard")
        case .chat: return String(localized: "Agent")
        case .workflows: return String(localized: "Workflow Studio")
        case .code: return String(localized: "Code Studio")
        case .runs: return String(localized: "Runs")
        case .scheduler: return String(localized: "Scheduler")
        case .agents: return String(localized: "Agents")
        case .skills: return String(localized: "Skills")
        case .learn: return String(localized: "Watch & Learn")
        case .permissions: return String(localized: "Permissions")
        case .settings: return String(localized: "Settings")
        }
    }
}
