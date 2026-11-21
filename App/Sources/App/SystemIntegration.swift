// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : App/Sources/App/SystemIntegration.swift
// Description      : Menu-bar item, background-agent registration through
//                    SMAppService, and local notifications for approvals that
//                    wait and runs that end.
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

import AppKit
import ORIXAppUI
import ORIXFeatureManage
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: Menu bar

struct MenuBarLabel: View {
    let boot: AppBoot
    var body: some View {
        if case .ready(let m) = boot.state {
            let waiting = m.pendingApprovals.count + m.pendingInteractions.count
            Image(systemName: waiting > 0 ? "hand.raised.circle.fill" : (m.activeRuns.isEmpty ? "circle.hexagongrid" : "circle.hexagongrid.fill"))
                .accessibilityLabel(Text(waiting > 0 ? "ORIX: approval waiting" : (m.activeRuns.isEmpty ? "ORIX: idle" : "ORIX: running")))
        } else {
            Image(systemName: "circle.hexagongrid").accessibilityLabel(Text("ORIX"))
        }
    }
}

struct MenuBarContent: View {
    let boot: AppBoot
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if case .ready(let model) = boot.state {
                HStack {
                    Text("ORIX OS Automation").font(Theme.Font.heading)
                    Spacer()
                    Button { show(model, .dashboard) } label: { Text("Open") }.buttonStyle(.link)
                }
                if model.activeRuns.isEmpty && model.pendingApprovals.isEmpty {
                    Text("Nothing is running.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                ForEach(model.activeRuns.prefix(5)) { run in
                    HStack(spacing: Theme.Space.s) {
                        StatusBadge(run.status, compact: true)
                        Text(run.title).font(Theme.Font.body).lineLimit(1)
                        Spacer()
                        Button { model.cancel(runID: run.id) } label: { Image(systemName: "stop.fill") }.buttonStyle(.borderless)
                            .accessibilityLabel(Text("Stop \(run.title)"))
                    }
                }
                if !model.pendingApprovals.isEmpty {
                    Button { show(model, .dashboard) } label: {
                        Label("\(model.pendingApprovals.count) approval(s) waiting", systemImage: "hand.raised.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.violet))
                }
                Divider()
                HStack {
                    Button { show(model, .chat) } label: { Label("Ask the agent", systemImage: "bubble.left") }.buttonStyle(.borderless)
                    Spacer()
                    Button(role: .destructive) { model.emergencyStop() } label: { Label("Emergency stop", systemImage: "stop.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(Theme.danger).disabled(model.activeRuns.isEmpty)
                }
                Button("Quit ORIX OS Automation") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(Theme.Font.caption)
            } else {
                Text("Starting…").font(Theme.Font.caption)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 330)
    }

    private func show(_ model: AppModel, _ section: AppSection) {
        model.section = section
        if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) { openWindow(id: "main") }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: Background agent

/// Registers the bundled LaunchAgent with macOS (System Settings › General › Login Items shows it; the user can turn it
/// off there at any time). Registration is opt-in from Settings.
@MainActor
final class BackgroundAgentRegistration {
    static let plistName = "ai.spboucher.orix.automation.agent.plist"
    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    var statusText: String {
        switch service.status {
        case .enabled: return String(localized: "Registered: schedules run when the app is closed.")
        case .requiresApproval: return String(localized: "Waiting for approval in System Settings › General › Login Items.")
        case .notRegistered: return String(localized: "Not registered: schedules run only while the app is open.")
        case .notFound: return String(localized: "Unavailable in this build (the launch agent is not bundled).")
        @unknown default: return String(localized: "Unknown")
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    var control: BackgroundAgentControl {
        BackgroundAgentControl(status: { [weak self] in self?.statusText ?? "" }, setEnabled: { [weak self] on in try self?.setEnabled(on) })
    }
}

// MARK: Notifications

/// Posts a local notification when something waits for the user or a run ends while the app is not frontmost.
/// Authorization is requested through the standard system prompt the first time one is needed, and only when the
/// user left notifications enabled in Settings.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()
    private var tasks: [Task<Void, Never>] = []
    private var announced = Set<String>()
    private var services: ORIXServices?

    func start(services: ORIXServices) {
        guard Bundle.main.bundleIdentifier != nil, tasks.isEmpty else { return }
        self.services = services
        UNUserNotificationCenter.current().delegate = self
        tasks.append(Task { [weak self] in
            for await pending in services.approvals.updates() {
                for p in pending { await self?.post(id: "approval-\(p.id)", title: String(localized: "Approval needed"), body: p.access.summary) }
            }
        })
        tasks.append(Task { [weak self] in
            for await change in services.store.changes {
                guard case .run(let id) = change, let run = try? await services.store.run(id: id), run.status.isTerminal else { continue }
                let title: String
                switch run.status {
                case .succeeded: title = String(localized: "Finished")
                case .waitingApproval, .blockedPermission: title = String(localized: "Waiting for you")
                default: title = String(localized: "Did not complete")
                }
                await self?.post(id: "run-\(id)-\(run.status.rawValue)", title: title, body: "\(run.title) — \(run.status.rawValue)")
            }
        })
    }

    private func post(id: String, title: String, body: String) async {
        guard !announced.contains(id), let services else { return }
        announced.insert(id)
        guard await services.runs.settings().notificationsEnabled else { return }
        if NSApp.isActive && NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = Redactor.shared.redact(body)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // Clicking a notification only brings the app forward. Approving always happens in the app, where the details are.
        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
    }
}
