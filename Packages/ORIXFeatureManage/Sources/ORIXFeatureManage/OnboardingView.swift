// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/OnboardingView.swift
// Description      : First-run setup in five short, skippable steps: how
//                    control works, provider key and model, workspace and mode,
//                    macOS permissions, and where to start.
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

import AppKit
import ORIXAppUI
import SwiftUI

public struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onFinish: () -> Void
    @State private var step: Int
    @State private var providers: ProvidersModel?
    @State private var provider: ProviderID = .anthropic
    @State private var keyInput = ""
    @State private var snapshot: [MacPermission: PermissionStatus] = [:]
    @State private var requesting: MacPermission?

    static let stepCount = 5

    public init(onFinish: @escaping () -> Void) { self.onFinish = onFinish; _step = State(initialValue: 0) }

    /// Opens on a given step (0…4). Used by the preview harness.
    public init(step: Int, onFinish: @escaping () -> Void) { self.onFinish = onFinish; _step = State(initialValue: min(max(step, 0), Self.stepCount - 1)) }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    switch step {
                    case 0: welcome
                    case 1: providerStep
                    case 2: workspaceStep
                    case 3: permissionsStep
                    default: doneStep
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .background(Theme.canvas)
        .task {
            if providers == nil { providers = ProvidersModel(services: model.services) }
            await providers?.reload()
            if let first = model.configuredProviders.first { provider = first }
            snapshot = await Task.detached { MacPermissions.snapshot() }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { snapshot = await Task.detached { MacPermissions.snapshot() }.value }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "sparkles").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accentGradient)
            Text("Set up ORIX").font(Theme.Font.title)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.stepCount, id: \.self) { i in
                    Capsule().fill(i == step ? Theme.violet : (i < step ? Theme.violet.opacity(0.45) : Theme.stroke)).frame(width: i == step ? 22 : 8, height: 8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Step \(String(step + 1)) of \(String(Self.stepCount))"))
            Text("Step \(String(step + 1)) of \(String(Self.stepCount))").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.l)
        .background(Theme.surface)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Skip setup") { finish() }.buttonStyle(.link).accessibilityIdentifier("onboarding.skip")
            Text("Everything here can be done later in Settings and Permissions.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            Spacer()
            if step > 0 {
                Button("Back") { withAnimation(Theme.spring(reduceMotion)) { step -= 1 } }.buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("onboarding.back")
            }
            if step < Self.stepCount - 1 {
                Button("Continue") { withAnimation(Theme.spring(reduceMotion)) { step += 1 } }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.continue")
            } else {
                Button("Finish") { finish() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).accessibilityIdentifier("onboarding.finish")
            }
        }
        .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.m)
        .background(Theme.surface)
    }

    private func finish(open section: AppSection? = nil) {
        model.settings.onboardingCompleted = true
        model.saveSettings()
        model.showOnboarding = false
        if let section { model.open(.section(section)) }
        onFinish()
    }

    // MARK: Step 1

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("You state the goal. ORIX does the authorized work and shows what happened.").font(Theme.Font.display).fixedSize(horizontal: false, vertical: true)
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    line("target", String(localized: "Objective"), String(localized: "You say what you want, in plain words, and choose the folder it may work in."))
                    line("list.bullet.clipboard", String(localized: "Plan"), String(localized: "ORIX looks first, then shows the steps it intends to take."))
                    line("hand.raised", String(localized: "Approval"), String(localized: "Nothing consequential happens without a grant you gave or an approval you click."))
                    line("checkmark.seal", String(localized: "Verified result"), String(localized: "ORIX checks the outcome itself and gives you a receipt: what ran, what changed, what failed."))
                }
            }
            Explanation(String(localized: "ORIX runs on this Mac. It has no account and no server of its own."))
        }
    }

    private func line(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.violet).frame(width: 30, height: 30)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.bodyStrong)
                Text(text).font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 2

    @ViewBuilder
    private var providerStep: some View {
        Text("Connect a model provider").font(Theme.Font.display)
        Explanation(String(localized: "ORIX uses your own account with a provider. The key is stored only in the login Keychain of this Mac, and requests go directly from this Mac to that provider."))
        if let providers {
            let state = providers.state(provider)
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Picker("Provider", selection: $provider) {
                        ForEach(ProviderID.all, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("onboarding.provider")
                    HStack(spacing: Theme.Space.s) {
                        ProviderGlyph(provider: provider, size: 24)
                        if state.source == .none {
                            StatePill(text: String(localized: "No key"), symbol: "key.slash", color: Theme.neutral)
                        } else {
                            StatePill(text: String(localized: "Key stored"), symbol: "checkmark.seal.fill", color: Theme.success)
                            if let masked = state.masked { Text(masked).font(Theme.Font.monoSmall).foregroundStyle(Theme.textSecondary) }
                        }
                    }
                    HStack(spacing: Theme.Space.s) {
                        SecureField(String(localized: "Paste your API key"), text: $keyInput).textFieldStyle(.roundedBorder).onSubmit(saveKey)
                            .accessibilityIdentifier("onboarding.keyField")
                        Button(action: saveKey) { BusyLabel(title: state.source == .none ? LocalizedStringKey("Save key") : LocalizedStringKey("Replace key"), busy: state.saving) }
                            .buttonStyle(PrimaryButtonStyle()).disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.saving)
                            .accessibilityIdentifier("onboarding.saveKey")
                    }
                    if let e = state.keyError { Banner(kind: .error, text: e) }
                    HStack(spacing: Theme.Space.s) {
                        Button { Task { await providers.test(provider, settings: model.settings) } } label: { BusyLabel(title: "Test connection", busy: state.testing, symbol: "bolt.horizontal") }
                            .buttonStyle(SecondaryButtonStyle()).disabled(state.source == .none || state.testing).accessibilityIdentifier("onboarding.test")
                        Text("Sends one minimal request (at most 8 output tokens), billed to your key: a fraction of a cent.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if let t = state.test {
                        Banner(kind: t.ok ? .success : .error, text: t.ok ? String(localized: "\(t.model.model) answered in \(String(t.latencyMs)) ms.") : (t.message ?? String(localized: "The provider did not answer.")))
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader("Default model", subtitle: "Used by agents that do not name one. You can change it any time.")
                    if state.source == .none {
                        Explanation(String(localized: "Add a key first; the list of models comes from the provider."))
                    } else if !state.catalogLoaded {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading the model list…").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                    } else {
                        Picker("Default model", selection: Binding(get: { model.settings.defaultModel?.provider == provider ? (model.settings.defaultModel?.model ?? "") : "" },
                                                                   set: { id in if !id.isEmpty { model.settings.defaultModel = ModelRef(provider: provider, model: id); model.saveSettings() } })) {
                            Text("Choose a model").tag("")
                            ForEach(state.models) { m in Text(verbatim: "\(m.displayName) — \(ManageText.price(m))").tag(m.id) }
                        }
                        .labelsHidden().frame(maxWidth: 460).accessibilityIdentifier("onboarding.model")
                        if let e = state.catalogError {
                            Text("This list is the registry built into ORIX; the live list was not available: \(e)").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let d = model.settings.defaultModel, !d.model.isEmpty {
                        Label(d.displayString, systemImage: "star.fill").font(Theme.Font.caption).foregroundStyle(Theme.violet)
                    }
                }
            }
            .task(id: "\(provider.rawValue)|\(state.masked ?? "")") { if state.source != .none { await providers.loadCatalog(for: provider) } }
        }
    }

    private func saveKey() {
        let value = keyInput
        keyInput = ""
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let providers else { return }
        Task { await providers.saveKey(value, for: provider); await model.refreshShared() }
    }

    // MARK: Step 3

    @ViewBuilder
    private var workspaceStep: some View {
        Text("Where and how ORIX works").font(Theme.Font.display)
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SettingRow(title: "Workspace folder", detail: String(localized: "New runs start in this folder. Each run only gets the access to it that you choose when you start it.")) {
                    HStack(spacing: Theme.Space.s) {
                        Text(PathResolver.display(model.defaultWorkspace)).font(Theme.Font.monoSmall).lineLimit(1).truncationMode(.middle).frame(maxWidth: 240, alignment: .trailing)
                        Button("Choose…") {
                            if let url = FilePanels.chooseFolder(message: String(localized: "Choose the default workspace folder")) {
                                if PathResolver.isProtected(PathResolver.resolveSymlinks(url.path)) {
                                    model.notice(String(localized: "That folder is a protected location and cannot be a workspace."), kind: .error)
                                } else { model.settings.defaultWorkspace = url.path; model.saveSettings() }
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("onboarding.workspace")
                    }
                }
                if model.settings.defaultWorkspace == nil {
                    Explanation(String(localized: "Until you choose one, ORIX uses its own scratch folder inside its data folder."))
                }
            }
        }
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Default mode")
                ForEach(GeneralPane.modes, id: \.self) { mode in
                    let selected = model.settings.defaultMode == mode
                    Button { model.settings.defaultMode = mode; model.saveSettings() } label: {
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Theme.violet : Theme.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ManageText.modeTitle(mode)).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                                Text(ManageText.modeExplanation(mode)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : []).accessibilityIdentifier("onboarding.mode.\(mode.rawValue)")
                }
            }
        }
    }

    // MARK: Step 4

    @ViewBuilder
    private var permissionsStep: some View {
        Text("macOS permissions").font(Theme.Font.display)
        Explanation(String(localized: "Nothing is requested automatically. Working with files in folders you grant needs none of these; they matter only when you ask ORIX to operate other apps, capture the screen or notify you. You can do this later in Permissions."))
        Card {
            VStack(spacing: 0) {
                ForEach(MacPermission.allCases, id: \.self) { p in
                    let status = snapshot[p] ?? .unknown
                    let s = ManageText.permissionStatus(status)
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: ManageText.permissionSymbol(p)).foregroundStyle(Theme.violet).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Theme.Space.s) {
                                Text(ManageText.permissionTitle(p)).font(Theme.Font.bodyStrong)
                                StatePill(text: s.label, symbol: s.symbol, color: s.color)
                            }
                            Text(ManageText.permissionPurpose(p)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Theme.Space.s)
                        if PermissionsModel.canRequest(p) && status != .granted {
                            Button {
                                requesting = p
                                Task { _ = await MacPermissions.request(p); snapshot = await Task.detached { MacPermissions.snapshot() }.value; requesting = nil }
                            } label: { BusyLabel(title: "Request", busy: requesting == p) }
                                .buttonStyle(SecondaryButtonStyle()).disabled(requesting != nil).accessibilityIdentifier("onboarding.permission.\(p.rawValue).request")
                        }
                        Button("Open Settings") { NSWorkspace.shared.open(MacPermissions.settingsURL(for: p)) }.buttonStyle(.link)
                            .accessibilityIdentifier("onboarding.permission.\(p.rawValue).settings")
                    }
                    .padding(.vertical, Theme.Space.s)
                    if p != MacPermission.allCases.last { Divider().opacity(0.6) }
                }
            }
        }
    }

    // MARK: Step 5

    @ViewBuilder
    private var doneStep: some View {
        Text("You are set").font(Theme.Font.display)
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                check(model.settings.defaultModel?.model.isEmpty == false, String(localized: "Default model"), model.settings.defaultModel?.displayString ?? String(localized: "Not chosen. Agents cannot run until you choose one in Settings › Providers."))
                check(true, String(localized: "Workspace"), PathResolver.display(model.defaultWorkspace))
                check(true, String(localized: "Default mode"), ManageText.modeTitle(model.settings.defaultMode))
            }
        }
        Text("Try one of these").font(Theme.Font.heading)
        HStack(alignment: .top, spacing: Theme.Space.m) {
            starter("bubble.left.and.text.bubble.right", String(localized: "Ask the agent"), String(localized: "Describe a task in your own words and watch each step."), "onboarding.starter.agent") { finish(open: .chat) }
            starter("point.3.connected.trianglepath.dotted", String(localized: "Open the templates"), String(localized: "Start from a tested workflow such as the system health report."), "onboarding.starter.templates") { finish(open: .workflows) }
        }
    }

    private func check(_ ok: Bool, _ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(ok ? Theme.success : Theme.warning)
            Text(title).font(Theme.Font.bodyStrong).frame(width: 120, alignment: .leading)
            Text(value).font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func starter(_ symbol: String, _ title: String, _ text: String, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.accentGradient)
                Text(title).font(Theme.Font.heading).foregroundStyle(Theme.text)
                Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.l).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}
