// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/SettingsView.swift
// Description: Settings root with its sidebar, and the General, Privacy, Diagnostics and Updates panes.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case providers, general, privacy, storage, diagnostics, updates
    public var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .providers: return "Providers"
        case .general: return "General"
        case .privacy: return "Privacy"
        case .storage: return "Storage & backup"
        case .diagnostics: return "Diagnostics"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .providers: return "key.horizontal"
        case .general: return "slider.horizontal.3"
        case .privacy: return "hand.raised"
        case .storage: return "externaldrive"
        case .diagnostics: return "stethoscope"
        case .updates: return "arrow.down.circle"
        }
    }
}

public struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: SettingsTab

    private var expandCatalogFor: ProviderID?

    public init() { _tab = State(initialValue: .providers) }

    /// Opens on a given pane. Used by the preview harness and by deep links from other sections.
    public init(tab: SettingsTab, expandCatalogFor provider: ProviderID? = nil) { _tab = State(initialValue: tab); expandCatalogFor = provider }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch tab {
                case .providers: ProvidersPane(expandCatalogFor: expandCatalogFor)
                case .general: GeneralPane()
                case .privacy: PrivacyPane()
                case .storage: StoragePane()
                case .diagnostics: DiagnosticsPane()
                case .updates: UpdatesPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings").font(Theme.Font.title).foregroundStyle(Theme.text).padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.m)
                .accessibilityAddTraits(.isHeader)
            ForEach(SettingsTab.allCases) { t in
                Button { tab = t } label: {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: t.symbol).font(.system(size: 12, weight: .medium)).frame(width: 18)
                        Text(t.title).font(Theme.Font.bodyStrong)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tab == t ? Theme.violet : Theme.textSecondary)
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 7)
                    .background(tab == t ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == t ? [.isSelected] : [])
                .accessibilityIdentifier("settings.tab.\(t.rawValue)")
            }
            Spacer()
        }
        .padding(Theme.Space.l)
        .frame(width: 196)
        .background(Theme.surface)
    }
}

// MARK: Settings binding

extension AppModel {
    /// A binding that writes one setting and saves.
    func setting<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { self.settings[keyPath: keyPath] = $0; self.saveSettings() })
    }
}

// MARK: General

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.backgroundAgentControl) private var agentControl
    @State private var agentBusy = false
    @State private var agentError: String?

    static let modes: [ExecutionMode] = [.quick, .guided, .autonomous, .review]

    var body: some View {
        ManagePage {
            PageHeader("General", subtitle: "How ORIX behaves by default. Every run can still choose differently.")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionHeader("Default mode", subtitle: "Used when you start a run without choosing one.")
                    ForEach(Self.modes, id: \.self) { mode in
                        let selected = model.settings.defaultMode == mode
                        Button {
                            model.settings.defaultMode = mode; model.saveSettings()
                        } label: {
                            HStack(alignment: .top, spacing: Theme.Space.m) {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Theme.violet : Theme.textTertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ManageText.modeTitle(mode)).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                                    Text(ManageText.modeExplanation(mode)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                        .accessibilityIdentifier("settings.mode.\(mode.rawValue)")
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionHeader("Workspace")
                    SettingRow(title: "Default workspace folder",
                               detail: String(localized: "New runs start here. A run can only touch this folder with the access you give it when you start it.")) {
                        HStack(spacing: Theme.Space.s) {
                            Text(PathResolver.display(model.defaultWorkspace)).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 260, alignment: .trailing)
                            Button("Choose…") {
                                if let url = FilePanels.chooseFolder(message: String(localized: "Choose the default workspace folder"), startingAt: model.defaultWorkspace) {
                                    let path = url.path
                                    if PathResolver.isProtected(PathResolver.resolveSymlinks(path)) {
                                        model.notice(String(localized: "That folder is a protected location and cannot be a workspace."), kind: .error)
                                    } else { model.settings.defaultWorkspace = path; model.saveSettings() }
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("settings.workspace.choose")
                            if model.settings.defaultWorkspace != nil {
                                Button("Reset") { model.settings.defaultWorkspace = nil; model.saveSettings() }.buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionHeader("Appearance and notifications")
                    SettingRow(title: "Appearance", detail: String(localized: "Applies to every window.")) {
                        Picker("Appearance", selection: model.setting(\.appearance)) {
                            Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240).accessibilityIdentifier("settings.appearance")
                    }
                    Divider()
                    SettingRow(title: "Notifications",
                               detail: String(localized: "Tell me when a run finishes or waits for approval. macOS must also allow notifications for ORIX (see Permissions).")) {
                        Toggle("Notifications", isOn: model.setting(\.notificationsEnabled)).labelsHidden().toggleStyle(.switch)
                            .accessibilityIdentifier("settings.notifications")
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionHeader("Background agent")
                    SettingRow(title: "Run scheduled workflows when the window is closed",
                               detail: String(localized: "A small helper started at login runs your schedules and file watchers. It never approves anything: a step that needs approval waits until you open ORIX. It cannot run while the Mac is off or asleep, and it cannot operate app interfaces while the screen is locked.")) {
                        HStack(spacing: Theme.Space.s) {
                            if agentBusy { ProgressView().controlSize(.small) }
                            Toggle("Background agent", isOn: Binding(get: { model.settings.backgroundAgentEnabled }, set: { setAgent($0) }))
                                .labelsHidden().toggleStyle(.switch).disabled(agentControl == nil || agentBusy)
                                .accessibilityIdentifier("settings.backgroundAgent")
                        }
                    }
                    if let agentControl {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle").foregroundStyle(Theme.textTertiary)
                            Text(agentControl.status()).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        Banner(kind: .info, text: String(localized: "This build of the interface has no connection to the login-item registration, so the switch is disabled. The app registers the helper with macOS; nothing is installed from here."))
                    }
                    if let agentError { Banner(kind: .error, text: agentError) }
                }
            }
        }
    }

    private func setAgent(_ enabled: Bool) {
        guard let agentControl else { return }
        agentBusy = true; agentError = nil
        Task {
            do {
                try await agentControl.setEnabled(enabled)
                model.settings.backgroundAgentEnabled = enabled
                model.saveSettings()
            } catch { agentError = ManageText.describe(error) }
            agentBusy = false
        }
    }
}

// MARK: Privacy

struct PrivacyPane: View {
    @Environment(AppModel.self) private var model
    @State private var storage: StorageModel?
    @State private var confirmPrune = false

    var body: some View {
        ManagePage {
            PageHeader("Privacy", subtitle: "What leaves this Mac, what stays, and for how long.")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SettingRow(title: "Send screen content to the model provider",
                               detail: String(localized: "Off: screen captures and text read from them stay on this Mac, and a step that would send them to a model is refused. On: a run you started may include a capture in what it sends to the provider you chose. Secure fields are never captured either way.")) {
                        Toggle("Send screen content to the model provider", isOn: model.setting(\.allowScreenContentToProvider)).labelsHidden().toggleStyle(.switch)
                            .accessibilityIdentifier("settings.privacy.screenContent")
                    }
                    Divider()
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(Theme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No telemetry").font(Theme.Font.bodyStrong)
                            Explanation(String(localized: "ORIX sends no usage data, crash report or analytics anywhere. The only network traffic is to the model provider you configured and to the hosts you granted."))
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionHeader("Stored on this Mac", subtitle: "Everything is in one folder, readable only by your user account.")
                    KeyValueRow(key: "Data folder", value: PathResolver.display(model.services.paths.root.path), mono: true)
                    KeyValueRow(key: "Database", value: String(localized: "Runs, events, receipts, workflows, agents, grants, memory, settings — \(model.services.paths.database.lastPathComponent)"))
                    KeyValueRow(key: "Audit log", value: String(localized: "Decisions and consequential actions, hash-chained — \(model.services.paths.auditLog.lastPathComponent)"))
                    KeyValueRow(key: "Artifacts", value: String(localized: "Files produced by runs — \(model.services.paths.artifacts.lastPathComponent)/"))
                    KeyValueRow(key: "Skills", value: String(localized: "Installed skill packages — \(model.services.paths.skills.lastPathComponent)/"))
                    KeyValueRow(key: "API keys", value: String(localized: "Not in that folder: only in your login Keychain."))
                    Button { FilePanels.reveal(model.services.paths.root) } label: { Label("Reveal data folder", systemImage: "folder") }
                        .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("settings.privacy.reveal")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionHeader("Run history")
                    SettingRow(title: "Keep finished runs for", detail: String(localized: "Older runs, with their events and receipts, are removed. Runs still in progress are never removed.")) {
                        HStack(spacing: Theme.Space.s) {
                            IntField(value: model.setting(\.retentionDays), range: BudgetBounds.retentionDays, step: 10, unit: String(localized: "days"), identifier: "settings.privacy.retention")
                        }
                    }
                    HStack {
                        Button(role: .destructive) { confirmPrune = true } label: {
                            BusyLabel(title: "Delete history now", busy: storage?.working == "prune", symbol: "trash")
                        }
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).disabled(storage?.working != nil)
                        .accessibilityIdentifier("settings.privacy.deleteHistory")
                        Spacer()
                    }
                    if let m = storage?.message { Banner(kind: m.kind, text: m.text) }
                }
            }
            .confirmationDialog("Delete run history?", isPresented: $confirmPrune, titleVisibility: .visible) {
                Button("Delete runs older than \(String(model.settings.retentionDays)) days", role: .destructive) { Task { _ = await storage?.pruneRuns(olderThanDays: model.settings.retentionDays) } }
                Button("Delete every finished run", role: .destructive) { Task { _ = await storage?.pruneRuns(olderThanDays: 0) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The runs, their events and their receipts are removed from the database. Files they produced stay where they are. This cannot be undone.")
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SectionHeader("Memory", subtitle: "What agents were allowed to remember.")
                    MemoryPanel(compact: true)
                }
            }
        }
        .task { if storage == nil { storage = StorageModel(services: model.services) } }
    }
}

// MARK: Diagnostics

struct DiagnosticsPane: View {
    @Environment(AppModel.self) private var model
    @State private var report: DiagnosticsReport?
    @State private var copied = false

    var body: some View {
        ManagePage {
            PageHeader("Diagnostics", subtitle: "What this installation is made of. Nothing here is a secret.") {
                Button {
                    if let report { FilePanels.copy(report.text); copied = true }
                } label: { Label(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy diagnostics"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(report == nil).accessibilityIdentifier("settings.diagnostics.copy")
            }
            if let report {
                if let note = report.recoveryNote { Banner(kind: .warning, text: note) }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader("Application")
                        KeyValueRow(key: "Version", value: "\(report.appVersion) (\(report.build))")
                        KeyValueRow(key: "macOS", value: "\(report.macOS) · \(report.architecture)")
                        KeyValueRow(key: "Data folder", value: report.dataFolder, mono: true)
                        KeyValueRow(key: "Providers", value: report.configuredProviders.isEmpty ? String(localized: "No provider has a key") : report.configuredProviders.joined(separator: ", "))
                        KeyValueRow(key: "Database", value: report.databaseBytes.map(Format.bytes) ?? "—")
                        KeyValueRow(key: "Audit entries", value: String(report.auditEntries))
                        KeyValueRow(key: "Scheduler", value: report.schedulerActive ? String(localized: "Running in this process") : String(localized: "Not running in this process"))
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        SectionHeader("Tools", subtitle: "\(String(report.toolTotal)) registered, \(String(report.installedSkills)) installed skill(s)")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.s)], alignment: .leading, spacing: Theme.Space.s) {
                            ForEach(report.toolsByFamily, id: \.family) { f in
                                HStack {
                                    Text(f.family).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(verbatim: String(f.count)).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).monospacedDigit()
                                }
                                .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
                                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        SectionHeader("macOS permissions", subtitle: "As macOS reports them right now.")
                        ForEach(report.permissions, id: \.permission) { p in
                            let s = ManageText.permissionStatus(p.status)
                            HStack {
                                Image(systemName: ManageText.permissionSymbol(p.permission)).foregroundStyle(Theme.violet).frame(width: 20)
                                Text(ManageText.permissionTitle(p.permission)).font(Theme.Font.body)
                                Spacer()
                                StatePill(text: s.label, symbol: s.symbol, color: s.color)
                            }
                        }
                    }
                }
            } else {
                Card { VStack(alignment: .leading, spacing: Theme.Space.s) { SkeletonLine(width: 220); SkeletonLine(width: 320); SkeletonLine(width: 180) } }
            }
        }
        .task(id: model.revision) { report = await DiagnosticsReport.make(model) }
    }
}

// MARK: Updates

struct UpdatesPane: View {
    var body: some View {
        let url = ManageConfiguration.releasesURL
        ManagePage {
            PageHeader("Updates", subtitle: "How new versions reach this Mac.")
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Image(systemName: "arrow.down.circle").foregroundStyle(Theme.violet)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This build does not update itself").font(Theme.Font.bodyStrong)
                            Explanation(String(localized: "There is no automatic updater in this version: ORIX never downloads or installs code on its own. To update, download the new signed and notarized version and replace the app in Applications. Your data folder and Keychain items are kept."))
                        }
                    }
                    Divider()
                    if let link = URL(string: url), !url.isEmpty {
                        KeyValueRow(key: "Releases", value: url, mono: true)
                        Button { NSWorkspace.shared.open(link) } label: { Label("Open the releases page", systemImage: "safari") }
                            .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("settings.updates.open")
                    } else {
                        Explanation(String(localized: "No release address is configured in this build: updates are installed manually from the copy you were given."))
                    }
                    KeyValueRow(key: "Installed", value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? String(localized: "not in an app bundle"))
                }
            }
        }
    }
}

// MARK: Numeric fields

struct IntField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit: String?
    var identifier: String?

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(get: { value }, set: { value = BudgetBounds.clamp($0, range) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 84).monospacedDigit()
                .accessibilityIdentifier(identifier ?? "")
            Stepper("", value: Binding(get: { value }, set: { value = BudgetBounds.clamp($0, range) }), in: range, step: step).labelsHidden()
            if let unit { Text(unit).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
        }
    }
}

struct DoubleField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var unit: String?
    var fraction = 2
    var identifier: String?

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(get: { value }, set: { value = BudgetBounds.clamp($0, range) }), format: .number.precision(.fractionLength(0...fraction)).grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 84).monospacedDigit()
                .accessibilityIdentifier(identifier ?? "")
            Stepper("", value: Binding(get: { value }, set: { value = BudgetBounds.clamp($0, range) }), in: range, step: step).labelsHidden()
            if let unit { Text(unit).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
        }
    }
}

/// The seven limits of a run budget, in an adaptive grid.
struct BudgetEditor: View {
    @Binding var budget: Budget
    var identifierPrefix = "budget"

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: Theme.Space.l, alignment: .leading)], alignment: .leading, spacing: Theme.Space.m) {
            field("Model turns") { IntField(value: $budget.maxTurns, range: BudgetBounds.turns, identifier: "\(identifierPrefix).turns") }
            field("Wall clock") { DoubleField(value: $budget.maxWallSeconds, range: BudgetBounds.wallSeconds, step: 60, unit: String(localized: "seconds"), fraction: 0, identifier: "\(identifierPrefix).wall") }
            field("Tokens") { IntField(value: $budget.maxTotalTokens, range: BudgetBounds.tokens, step: 50_000, identifier: "\(identifierPrefix).tokens") }
            field("Cost") { DoubleField(value: $budget.maxCostUSD, range: BudgetBounds.costUSD, step: 0.25, unit: "USD", identifier: "\(identifierPrefix).cost") }
            field("Tool calls") { IntField(value: $budget.maxToolCalls, range: BudgetBounds.toolCalls, step: 10, identifier: "\(identifierPrefix).toolCalls") }
            field("Subprocess time") { DoubleField(value: $budget.maxSubprocessSeconds, range: BudgetBounds.subprocessSeconds, step: 30, unit: String(localized: "seconds"), fraction: 0, identifier: "\(identifierPrefix).subprocess") }
            field("Concurrent tasks") { IntField(value: $budget.maxConcurrentTasks, range: BudgetBounds.concurrency, identifier: "\(identifierPrefix).concurrency") }
        }
    }

    private func field<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: title)
            control()
        }
    }
}
