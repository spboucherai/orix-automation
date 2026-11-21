// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/PermissionsView.swift
// Description: The permission centre: macOS permissions with live status, grants by scope with revoke and manual add, the approval tiers explained, emergency stop, and the audit trail.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

public enum PermissionsTab: String, CaseIterable, Identifiable, Sendable {
    case macOS, grants, approval, audit
    public var id: String { rawValue }
}

public struct PermissionsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: PermissionsTab
    @State private var permissions: PermissionsModel?
    @State private var showAdd: Bool
    @State private var confirmRevokeAll = false
    @State private var revokeCandidate: PermissionGrant?
    @State private var confirmStop = false

    public init() { _tab = State(initialValue: .macOS); _showAdd = State(initialValue: false) }

    /// Opens on a given tab, optionally with the "add a grant" form open. Used by the preview harness and deep links.
    public init(tab: PermissionsTab, showAddForm: Bool = false) { _tab = State(initialValue: tab); _showAdd = State(initialValue: showAddForm) }

    public var body: some View {
        ManagePage {
            PageHeader("Permissions", subtitle: "What ORIX may do on this Mac, who allowed it, and how to take it back.") {
                Button(role: .destructive) { confirmStop = true } label: {
                    BusyLabel(title: "Emergency stop", busy: model.isStopping, symbol: "stop.circle.fill")
                }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).disabled(model.isStopping)
                .accessibilityIdentifier("permissions.emergencyStop")
            }
            ManageTabBar(items: [
                TabItem(value: PermissionsTab.macOS, title: "macOS permissions", symbol: "apple.logo"),
                TabItem(value: .grants, title: "Grants", symbol: "checkmark.shield", count: permissions?.activeCount),
                TabItem(value: .approval, title: "How approval works", symbol: "hand.raised"),
                TabItem(value: .audit, title: "Audit trail", symbol: "list.bullet.rectangle.portrait"),
            ], selection: $tab, identifierPrefix: "permissions")
            if let permissions, permissions.loaded {
                switch tab {
                case .macOS: macOSSection(permissions)
                case .grants: grantsSection(permissions)
                case .approval: approvalSection
                case .audit: auditSection(permissions)
                }
            } else {
                Card { VStack(alignment: .leading, spacing: Theme.Space.s) { SkeletonLine(width: 240); SkeletonLine(width: 360); SkeletonLine(width: 200) } }
            }
        }
        .task { if permissions == nil { permissions = PermissionsModel(services: model.services) } }
        .task(id: model.revision) { await permissions?.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions?.refreshStatus() }
        }
        .confirmationDialog("Stop everything now?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop all runs", role: .destructive) { model.emergencyStop() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(Self.stopExplanation) }
        .confirmationDialog("Revoke every grant?", isPresented: $confirmRevokeAll, titleVisibility: .visible) {
            Button("Revoke all", role: .destructive) { Task { await permissions?.revokeAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every grant stops matching at once, including those accepted for workflows. Running steps that depend on them will ask again or stop, and scheduled workflows wait for approval until you accept their permissions again. History is kept.")
        }
        .confirmationDialog("Revoke this grant?", isPresented: Binding(get: { revokeCandidate != nil }, set: { if !$0 { revokeCandidate = nil } }), titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { if let g = revokeCandidate { Task { await permissions?.revoke(g.id) } }; revokeCandidate = nil }
            Button("Cancel", role: .cancel) { revokeCandidate = nil }
        } message: {
            Text("ORIX will ask again the next time something needs: \(revokeCandidate?.capability.humanDescription ?? "")")
        }
    }

    static var stopExplanation: String {
        String(localized: "Every run is canceled, every tool call and child process is terminated, pending approvals are refused and browser sessions are closed. Work already done stays done; nothing is rolled back. Your grants are not touched.")
    }

    // MARK: macOS

    private func macOSSection(_ p: PermissionsModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Banner(kind: .info, text: String(localized: "These switches belong to macOS. ORIX cannot turn them on for you and never clicks through a system prompt: it can only ask macOS to show its own dialog, or open the right page of System Settings."))
            ForEach(MacPermission.allCases, id: \.self) { permission in
                MacPermissionRow(permission: permission, status: p.snapshot[permission] ?? .unknown, tools: p.toolsByPermission[permission] ?? [],
                                 requesting: p.requesting == permission) { Task { await p.request(permission) } }
            }
            HStack {
                Button { Task { await p.refreshStatus() } } label: { Label("Check again", systemImage: "arrow.clockwise") }.buttonStyle(.link)
                    .accessibilityIdentifier("permissions.macos.refresh")
                Text("Status is also refreshed whenever you come back to ORIX.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Grants

    private func grantsSection(_ p: PermissionsModel) -> some View {
        @Bindable var p = p
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                    TextField(String(localized: "Search grants"), text: $p.search).textFieldStyle(.plain).accessibilityIdentifier("permissions.grants.search")
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6).frame(maxWidth: 280)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.stroke))
                Toggle("Active only", isOn: $p.activeOnly).toggleStyle(.checkbox).accessibilityIdentifier("permissions.grants.activeOnly")
                Spacer()
                Button { showAdd.toggle() } label: { Label("Add a grant", systemImage: "plus") }.buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("permissions.grants.add")
                Button(role: .destructive) { confirmRevokeAll = true } label: { Label("Revoke all", systemImage: "xmark.shield") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).disabled(p.activeCount == 0)
                    .accessibilityIdentifier("permissions.grants.revokeAll")
            }
            if showAdd { AddGrantForm(permissions: p) { showAdd = false } }
            if p.visible.isEmpty {
                Card {
                    EmptyState(symbol: "checkmark.shield", title: p.grants.isEmpty ? "No grant yet" : "No grant matches",
                               message: p.grants.isEmpty ? "ORIX asks before each action. A grant appears here when you allow something for a run, a workflow, or until revoked."
                                                         : "Change the search, or turn off “Active only” to see revoked and expired grants.")
                        .frame(minHeight: 240)
                }
            } else {
                ForEach(GrantGroup.allCases) { group in
                    let items = p.visible(in: group)
                    if !items.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: Theme.Space.s) {
                                SectionHeader(group.title, subtitle: LocalizedStringKey(group.explanation)) {
                                    Text(verbatim: String(items.count)).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).monospacedDigit()
                                }
                                LazyVStack(spacing: 0) {
                                    ForEach(items) { g in
                                        GrantRow(grant: g, scopeDetail: p.scopeDetail(g)) {
                                            if g.scope == .persistent { revokeCandidate = g } else { Task { await p.revoke(g.id) } }
                                        }
                                        if g.id != items.last?.id { Divider().opacity(0.6) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Approval tiers and emergency

    private var approvalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionHeader("The four tiers", subtitle: "Each tool declares its tier in code. The model cannot change it.")
                    tier(.readOnly, String(localized: "Looking without touching: listing a folder, reading a file, inspecting an app. Still needs a grant for the folder, host or app."))
                    tier(.reversibleWrite, String(localized: "Changes you can undo: creating or editing files in a granted folder, moving to the Trash, writing the clipboard, posting a notification."))
                    tier(.consequential, String(localized: "Actions with effects beyond a file: sending over the network, running a script or program, controlling an app, pushing to a repository. Approved each time unless a grant covers that tier."))
                    tier(.highRisk, String(localized: "Cannot be undone: permanent deletion, force push. Always approved by you at that moment, for that one call, by typing APPROVE. No grant can pre-approve it."))
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader("Your default mode")
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Pill(text: ManageText.modeTitle(model.settings.defaultMode), symbol: "dial.medium", color: Theme.violet)
                        Explanation(ManageText.modeExplanation(model.settings.defaultMode))
                    }
                    Button("Change in Settings") { model.open(.section(.settings)) }.buttonStyle(.link).accessibilityIdentifier("permissions.openSettings")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader("Never allowed")
                    Explanation(String(localized: "Keychains, SSH and cloud credentials, the macOS privacy database, system folders, sudo and privileged helpers are refused before grants are even consulted. ORIX never reads secure text fields and never scripts a macOS consent prompt."))
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionHeader("Emergency stop")
                    Explanation(Self.stopExplanation)
                    HStack(spacing: Theme.Space.m) {
                        Button(role: .destructive) { confirmStop = true } label: { BusyLabel(title: "Emergency stop", busy: model.isStopping, symbol: "stop.circle.fill") }
                            .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).disabled(model.isStopping)
                            .accessibilityIdentifier("permissions.emergencyStop.card")
                        Text("\(String(model.activeRuns.count)) run(s) in progress").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func tier(_ t: ApprovalTier, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            TierBadge(tier: t).frame(width: 178, alignment: .leading)
            Text(text).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Audit

    private func auditSection(_ p: PermissionsModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Recent consequential entries", subtitle: "Approvals, refusals, grant changes, consequential actions and stops. The full log, its integrity check and its export are in Settings › Storage & backup.") {
                    Button("Open Storage") { model.open(.section(.settings)) }.buttonStyle(.link).accessibilityIdentifier("permissions.audit.openStorage")
                }
                AuditList(entries: p.audit, maxHeight: 520)
            }
        }
    }
}

// MARK: Rows

struct MacPermissionRow: View {
    let permission: MacPermission
    let status: PermissionStatus
    let tools: [String]
    var requesting = false
    let onRequest: () -> Void

    var body: some View {
        let s = ManageText.permissionStatus(status)
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: ManageText.permissionSymbol(permission)).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.violet)
                        .frame(width: 30, height: 30).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(ManageText.permissionTitle(permission)).font(Theme.Font.heading)
                    Spacer()
                    StatePill(text: s.label, symbol: s.symbol, color: s.color)
                }
                Explanation(ManageText.permissionPurpose(permission))
                if status != .granted {
                    Text(note).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                if !tools.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text("Needed by").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            ForEach(tools, id: \.self) { Pill(text: $0) }
                        }
                    }
                }
                HStack(spacing: Theme.Space.s) {
                    if PermissionsModel.canRequest(permission) && status != .granted {
                        Button(action: onRequest) { BusyLabel(title: "Request", busy: requesting, symbol: "hand.point.up.left") }
                            .buttonStyle(PrimaryButtonStyle()).disabled(requesting)
                            .accessibilityIdentifier("permissions.macos.\(permission.rawValue).request")
                    }
                    Button { NSWorkspace.shared.open(MacPermissions.settingsURL(for: permission)) } label: { Label("Open System Settings", systemImage: "gearshape") }
                        .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("permissions.macos.\(permission.rawValue).settings")
                }
            }
        }
    }

    private var note: String {
        switch (permission, status) {
        case (.appleEvents, _): return String(localized: "Consent is per application, so there is no single status. macOS asks the first time ORIX sends a command to each app; review them in System Settings › Privacy & Security › Automation.")
        case (.notifications, .unknown): return String(localized: "Notifications need the installed app; this process is not running from an app bundle.")
        case (.accessibility, _), (.screenRecording, _), (.fullDiskAccess, .denied):
            return String(localized: "macOS does not say whether this was refused or never asked.") + " " + MacPermissions.howToEnable(permission)
        default: return MacPermissions.howToEnable(permission)
        }
    }
}

struct GrantRow: View {
    let grant: PermissionGrant
    let scopeDetail: String?
    let onRevoke: () -> Void

    var body: some View {
        let state = PermissionsModel.state(grant)
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 5) {
                CapabilityRow(grant.capability)
                HStack(spacing: 6) {
                    TierBadge(tier: grant.maxTier)
                    if let scopeDetail { Pill(text: scopeDetail, symbol: "scope") }
                    Pill(text: String(localized: "by \(grant.source)"), symbol: "person")
                    switch state {
                    case .active: StatePill(text: String(localized: "Active"), symbol: "checkmark.circle.fill", color: Theme.success)
                    case .revoked: StatePill(text: String(localized: "Revoked"), symbol: "xmark.circle.fill", color: Theme.neutral)
                    case .expired: StatePill(text: String(localized: "Expired"), symbol: "clock.badge.xmark", color: Theme.neutral)
                    }
                }
                HStack(spacing: Theme.Space.m) {
                    Text("Added \(Format.dateTime(grant.createdAt))").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    if let e = grant.expiresAt { Text("Expires \(Format.dateTime(e))").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                    if let r = grant.revokedAt { Text("Revoked \(Format.dateTime(r))").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                    if !grant.note.isEmpty { Text(grant.note).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                }
            }
            Spacer(minLength: Theme.Space.s)
            if state == .active {
                Button("Revoke", role: .destructive, action: onRevoke).buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
                    .accessibilityIdentifier("permissions.grants.revoke.\(grant.id)")
            }
        }
        .padding(.vertical, Theme.Space.s)
        .opacity(state == .active ? 1 : 0.7)
        .accessibilityElement(children: .contain)
    }
}

/// The small form that adds a persistent grant by hand.
struct AddGrantForm: View {
    let permissions: PermissionsModel
    let onDone: () -> Void
    @State private var kind: ManualGrantKind = .fileRead
    @State private var value = ""
    @State private var tier: ApprovalTier = .readOnly
    @State private var note = ""
    @State private var error: String?
    @State private var saving = false
    @State private var apps: [RunningAppInfo] = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Add a grant that lasts until revoked", subtitle: "Prefer granting per run or per workflow. Add a lasting grant only for something you would approve every time.")
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(title: "Allow ORIX to")
                        Picker("Allow ORIX to", selection: $kind) {
                            ForEach(ManualGrantKind.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 280).accessibilityIdentifier("permissions.add.kind")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        FieldLabel(title: "Without asking, up to")
                        Picker("Without asking, up to", selection: $tier) {
                            ForEach([ApprovalTier.readOnly, .reversibleWrite, .consequential], id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 220).accessibilityIdentifier("permissions.add.tier")
                    }
                }
                valueField
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(title: "Note (optional)")
                    TextField(String(localized: "Why you added it"), text: $note).textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                        .accessibilityIdentifier("permissions.add.note")
                }
                if let error { Banner(kind: .error, text: error) }
                HStack {
                    Button("Cancel", role: .cancel, action: onDone).buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button(action: add) { BusyLabel(title: "Add grant", busy: saving, symbol: "plus") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(value.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .accessibilityIdentifier("permissions.add.save")
                }
            }
        }
        .onChange(of: kind) { _, new in
            value = new.input == .runtime ? "bash" : ""
            tier = new.defaultTier; error = nil
        }
        .onAppear { apps = RunningAppInfo.current() }
    }

    @ViewBuilder
    private var valueField: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch kind.input {
            case .folder:
                FieldLabel(title: "Folder")
                HStack(spacing: Theme.Space.s) {
                    TextField("~/Documents/Project", text: $value).textFieldStyle(.roundedBorder).font(Theme.Font.mono).accessibilityIdentifier("permissions.add.value")
                    Button("Choose…") {
                        if let url = FilePanels.chooseFolder(message: String(localized: "Choose the folder this grant covers")) { value = url.path }
                    }.buttonStyle(SecondaryButtonStyle())
                }
                Explanation(String(localized: "The grant covers this folder and everything inside it. Credential and system locations are refused."))
            case .host:
                FieldLabel(title: "Host")
                TextField("api.example.com", text: $value).textFieldStyle(.roundedBorder).font(Theme.Font.mono).frame(maxWidth: 420).accessibilityIdentifier("permissions.add.value")
                Explanation(String(localized: "One host name. Use *.example.com to include its subdomains."))
            case .app:
                FieldLabel(title: "Application")
                HStack(spacing: Theme.Space.s) {
                    TextField("com.apple.finder", text: $value).textFieldStyle(.roundedBorder).font(Theme.Font.mono).accessibilityIdentifier("permissions.add.value")
                    Menu {
                        ForEach(apps) { app in Button(app.name) { value = app.bundleID } }
                        Divider()
                        Button("Choose an application…") {
                            if let url = FilePanels.chooseApplication(), let id = Bundle(url: url)?.bundleIdentifier { value = id }
                        }
                    } label: { Text("Running apps") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            case .program:
                FieldLabel(title: "Program")
                TextField("git", text: $value).textFieldStyle(.roundedBorder).font(Theme.Font.mono).frame(maxWidth: 420).accessibilityIdentifier("permissions.add.value")
                Explanation(String(localized: "A program name or its full path, without arguments."))
            case .runtime:
                FieldLabel(title: "Language")
                Picker("Language", selection: $value) { ForEach(ManualGrantKind.runtimes, id: \.self) { Text(verbatim: $0).tag($0) } }
                    .labelsHidden().frame(width: 200).accessibilityIdentifier("permissions.add.value")
            }
        }
    }

    private func add() {
        saving = true; error = nil
        Task {
            do {
                _ = try await permissions.addPersistentGrant(kind: kind, value: value, tier: tier, note: note)
                onDone()
            } catch { self.error = ManageText.describe(error) }
            saving = false
        }
    }
}
