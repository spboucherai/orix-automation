// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/SettingsProvidersStorage.swift
// Description: Settings panes for providers (keys, connection test, model catalog, model roles, spending) and for storage (sizes, backup, export/import, audit log).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: Providers

struct ProvidersPane: View {
    @Environment(AppModel.self) private var model
    @State private var providers: ProvidersModel?
    @State private var confirmReset = false

    var body: some View {
        ManagePage {
            PageHeader("Providers", subtitle: "Your own keys, your own account with each provider.")
            Banner(kind: .info, text: String(localized: "Bring your own key. Keys are stored only in the login Keychain of this Mac. Requests go directly from this Mac to the provider you choose; ORIX has no server and no account."))
            rolesCard
            if let providers {
                ForEach(ProviderID.all, id: \.self) { id in
                    ProviderCard(provider: id, providers: providers)
                }
            }
            spendingCard
        }
        .task {
            if providers == nil { providers = ProvidersModel(services: model.services) }
        }
        .task(id: model.revision) { await providers?.reload() }
    }

    private var rolesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Models in use", subtitle: "Choose them from a provider's model list below (the “Use as” menu).")
                roleRow("Default model", detail: String(localized: "Used by agents that do not name a model."), ref: model.settings.defaultModel, clear: nil, id: "default")
                Divider()
                roleRow("Planner", detail: String(localized: "Optional. Writes plans and drafts workflows; the default model does it otherwise."), ref: model.settings.plannerModel,
                        clear: { model.settings.plannerModel = nil; model.saveSettings() }, id: "planner")
                Divider()
                roleRow("Verifier", detail: String(localized: "Optional. A second model that checks the result against the objective."), ref: model.settings.verifierModel,
                        clear: { model.settings.verifierModel = nil; model.saveSettings() }, id: "verifier")
            }
        }
    }

    private func roleRow(_ title: LocalizedStringKey, detail: String, ref: ModelRef?, clear: (() -> Void)?, id: String) -> some View {
        SettingRow(title: title, detail: detail) {
            HStack(spacing: Theme.Space.s) {
                if let ref, !ref.model.isEmpty {
                    ProviderGlyph(provider: ref.provider, size: 18)
                    Text(ref.model).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                    if let clear { Button("Clear", action: clear).buttonStyle(.link).accessibilityIdentifier("settings.providers.clear.\(id)") }
                } else {
                    Text(clear == nil ? LocalizedStringKey("Not chosen yet") : LocalizedStringKey("Same as the default")).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var spendingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Spending limits", subtitle: "Enforced by the runtime, not by the model.") {
                    Button("Reset to defaults") { confirmReset = true }.buttonStyle(.link).accessibilityIdentifier("settings.providers.resetBudget")
                }
                SettingRow(title: "Daily spending limit", detail: String(localized: "When today's known cost reaches this amount, new runs that use a model are refused until tomorrow.")) {
                    DoubleField(value: model.setting(\.dailySpendLimitUSD), range: BudgetBounds.dailySpendUSD, step: 1, unit: "USD", identifier: "settings.providers.dailyLimit")
                }
                Divider()
                Text("Default budget of one run").font(Theme.Font.bodyStrong)
                Explanation(String(localized: "A run stops with “Budget exceeded” when it reaches any of these. Costs are known only for models with a published price."))
                BudgetEditor(budget: model.setting(\.defaultBudget), identifierPrefix: "settings.providers.budget")
            }
        }
        .confirmationDialog("Reset spending limits?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to defaults") {
                model.settings.defaultBudget = .standard
                model.settings.dailySpendLimitUSD = AppSettings().dailySpendLimitUSD
                model.saveSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The daily limit and the default run budget return to their original values.") }
    }
}

/// One provider: key state, key entry, connection test, model catalog.
struct ProviderCard: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderID
    let providers: ProvidersModel
    var startExpanded = false
    @State private var keyInput = ""
    @State private var confirmDelete = false
    @State private var showCatalog = false
    @State private var search = ""

    var body: some View {
        let state = providers.state(provider)
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    ProviderGlyph(provider: provider, size: 28)
                    Text(provider.displayName).font(Theme.Font.heading)
                    Spacer()
                    switch state.source {
                    case .keychain:
                        if let masked = state.masked { Text(masked).font(Theme.Font.monoSmall).foregroundStyle(Theme.textSecondary).accessibilityLabel(Text("Stored key, masked")) }
                        StatePill(text: String(localized: "Key stored"), symbol: "checkmark.seal.fill", color: Theme.success)
                    case .developmentEnvironment:
                        StatePill(text: String(localized: "Development key from the environment"), symbol: "hammer.fill", color: Theme.warning)
                    case .none:
                        StatePill(text: String(localized: "No key"), symbol: "key.slash", color: Theme.neutral)
                    }
                }
                keyRow(state)
                if let e = state.keyError { Banner(kind: .error, text: e) }
                testRow(state)
                Divider()
                catalog(state)
            }
        }
        .task(id: state.masked ?? "") { await providers.loadCatalog(for: provider) }
        .onAppear { if startExpanded { showCatalog = true } }
        .confirmationDialog("Delete the \(provider.displayName) key?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete key", role: .destructive) { Task { await providers.removeKey(for: provider); await model.refreshShared() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The key is removed from the Keychain of this Mac. Agents and workflows that use this provider stop working until you add a key again. The key itself is not revoked at the provider.")
        }
    }

    private func keyRow(_ state: ProvidersModel.State) -> some View {
        HStack(spacing: Theme.Space.s) {
            SecureField(state.source == .keychain ? String(localized: "Paste a new key to replace the stored one") : String(localized: "Paste your API key"), text: $keyInput)
                .textFieldStyle(.roundedBorder).onSubmit(save)
                .accessibilityIdentifier("settings.providers.\(provider.rawValue).keyField")
            Button(action: save) {
                BusyLabel(title: state.source == .keychain ? LocalizedStringKey("Replace key") : LocalizedStringKey("Save key"), busy: state.saving)
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.saving)
            .accessibilityIdentifier("settings.providers.\(provider.rawValue).saveKey")
            if state.source == .keychain {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).accessibilityLabel(Text("Delete key"))
                    .accessibilityIdentifier("settings.providers.\(provider.rawValue).deleteKey")
            }
        }
    }

    /// The field value goes straight to the Keychain and is cleared whatever the outcome.
    private func save() {
        let value = keyInput
        keyInput = ""
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await providers.saveKey(value, for: provider); await model.refreshShared() }
    }

    private func testRow(_ state: ProvidersModel.State) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Button { Task { await providers.test(provider, settings: model.settings) } } label: {
                    BusyLabel(title: "Test connection", busy: state.testing, symbol: "bolt.horizontal")
                }
                .buttonStyle(SecondaryButtonStyle()).disabled(state.source == .none || state.testing)
                .accessibilityIdentifier("settings.providers.\(provider.rawValue).test")
                Text("Sends one minimal request (at most 8 output tokens), billed to your key: a fraction of a cent.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            if let t = state.test {
                if t.ok {
                    Banner(kind: .success, text: String(localized: "\(t.model.model) answered in \(String(t.latencyMs)) ms."))
                } else {
                    Banner(kind: .error, text: t.message ?? String(localized: "The provider did not answer."))
                }
            }
        }
    }

    private func catalog(_ state: ProvidersModel.State) -> some View {
        DisclosureGroup(isExpanded: $showCatalog) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                    TextField(String(localized: "Search models"), text: $search).textFieldStyle(.plain)
                        .accessibilityIdentifier("settings.providers.\(provider.rawValue).search")
                    Button { Task { await providers.loadCatalog(for: provider, refresh: true) } } label: {
                        BusyLabel(title: "Refresh", busy: state.loadingCatalog, symbol: "arrow.clockwise")
                    }
                    .buttonStyle(.link).disabled(state.loadingCatalog)
                    .accessibilityIdentifier("settings.providers.\(provider.rawValue).refresh")
                }
                .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                sourceLine(state)
                let models = providers.filtered(provider, search: search)
                if models.isEmpty {
                    Text(state.models.isEmpty ? LocalizedStringKey("No model is known for this provider yet. Add a key and refresh.") : LocalizedStringKey("No model matches the search."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(.vertical, Theme.Space.s)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(models) { m in
                                ModelRow(info: m)
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            }
            .padding(.top, Theme.Space.s)
        } label: {
            HStack {
                Text("Models").font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                Text(verbatim: String(state.models.count)).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).monospacedDigit()
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { showCatalog.toggle() }
        }
        .accessibilityIdentifier("settings.providers.\(provider.rawValue).catalog")
    }

    @ViewBuilder
    private func sourceLine(_ state: ProvidersModel.State) -> some View {
        if !state.catalogLoaded {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading the model list…").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
        } else if let e = state.catalogError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "books.vertical").foregroundStyle(Theme.warning)
                Text("Source: maintained registry built into ORIX (verified \(ModelRegistry.lastVerified)). The live list was not available: \(e)")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.success)
                Text("Source: live list from the provider, completed with known prices.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// A catalog row: name, identifier, context window, tool support, price, and the role menu.
struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let info: ModelInfo

    private var ref: ModelRef { ModelRef(provider: info.provider, model: info.id) }

    var body: some View {
        let s = model.settings
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(info.displayName).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                    if s.defaultModel == ref { Pill(text: String(localized: "default"), symbol: "star.fill", color: Theme.violet) }
                    if s.plannerModel == ref { Pill(text: String(localized: "planner"), symbol: "list.bullet.clipboard", color: Theme.blue) }
                    if s.verifierModel == ref { Pill(text: String(localized: "verifier"), symbol: "checkmark.seal", color: Theme.success) }
                }
                Text(info.id).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ManageText.price(info)).font(Theme.Font.caption).foregroundStyle(info.inputPricePerMTok == nil ? Theme.textTertiary : Theme.textSecondary).monospacedDigit()
                HStack(spacing: 6) {
                    Text("context \(ManageText.context(info))").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    Label(info.supportsTools ? LocalizedStringKey("tools") : LocalizedStringKey("no tools"), systemImage: info.supportsTools ? "wrench.and.screwdriver" : "wrench.and.screwdriver.fill")
                        .labelStyle(.titleAndIcon).font(Theme.Font.caption).foregroundStyle(info.supportsTools ? Theme.success : Theme.warning)
                }
            }
            Menu {
                Button("Default model") { model.settings.defaultModel = ref; model.saveSettings() }
                Button("Planner") { model.settings.plannerModel = ref; model.saveSettings() }
                Button("Verifier") { model.settings.verifierModel = ref; model.saveSettings() }
            } label: { Text("Use as") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityIdentifier("settings.providers.model.\(info.id).useAs")
        }
        .padding(.vertical, 6).padding(.horizontal, Theme.Space.xs)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Storage

struct StoragePane: View {
    @Environment(AppModel.self) private var model
    @State private var storage: StorageModel?

    var body: some View {
        ManagePage {
            PageHeader("Storage & backup", subtitle: "Your data is a folder on this Mac. Back it up, move it, inspect it.")
            if let storage {
                if let m = storage.message { Banner(kind: m.kind, text: m.text) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                    MetricTile(title: "Database", value: storage.databaseBytes.map(Format.bytes) ?? "—", detail: model.services.paths.database.lastPathComponent, symbol: "cylinder.split.1x2")
                    MetricTile(title: "Artifacts", value: storage.artifactsBytes.map(Format.bytes) ?? "…", detail: String(localized: "files produced by runs"), symbol: "shippingbox", tint: Theme.blue)
                    MetricTile(title: "Audit entries", value: storage.auditCount.map(String.init) ?? "—", detail: model.services.paths.auditLog.lastPathComponent, symbol: "list.bullet.rectangle.portrait", tint: Theme.success)
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        SectionHeader("Data folder") {
                            Button { FilePanels.reveal(model.services.paths.root) } label: { Label("Reveal data folder", systemImage: "folder") }
                                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("settings.storage.reveal")
                        }
                        Text(PathResolver.display(model.services.paths.root.path)).font(Theme.Font.monoSmall).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        SectionHeader("Backup and transfer")
                        SettingRow(title: "Back up the database", detail: String(localized: "A complete, consistent copy for this Mac, including grants and history. Keep it private. API keys are not in it.")) {
                            Button { backup(storage) } label: { BusyLabel(title: "Back up database…", busy: storage.working == "backup", symbol: "externaldrive.badge.plus") }
                                .buttonStyle(SecondaryButtonStyle()).disabled(storage.working != nil).accessibilityIdentifier("settings.storage.backup")
                        }
                        Divider()
                        SettingRow(title: "Export workflows and settings", detail: String(localized: "A portable file for another Mac. Grants, keys and run history are left out; secret-shaped values are replaced.")) {
                            HStack(spacing: Theme.Space.s) {
                                Button { exportBundle(storage) } label: { BusyLabel(title: "Export…", busy: storage.working == "export", symbol: "square.and.arrow.up") }
                                    .buttonStyle(SecondaryButtonStyle()).disabled(storage.working != nil).accessibilityIdentifier("settings.storage.export")
                                Button { importBundle(storage) } label: { BusyLabel(title: "Import…", busy: storage.working == "import", symbol: "square.and.arrow.down") }
                                    .buttonStyle(SecondaryButtonStyle()).disabled(storage.working != nil).accessibilityIdentifier("settings.storage.import")
                            }
                        }
                        if let s = storage.lastSummary {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.title).font(Theme.Font.bodyStrong)
                                ForEach(StorageModel.summaryLines(s.summary), id: \.self) { line in
                                    Label(line, systemImage: "smallcircle.filled.circle").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        SectionHeader("Audit log", subtitle: "Every decision and consequential action, each line chained to the one before.") {
                            HStack(spacing: Theme.Space.s) {
                                Button { Task { await storage.verifyAudit() } } label: { BusyLabel(title: "Verify integrity", busy: storage.verifying, symbol: "checkmark.shield") }
                                    .buttonStyle(SecondaryButtonStyle()).disabled(storage.verifying).accessibilityIdentifier("settings.storage.verify")
                                Button { exportAudit(storage) } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                                    .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("settings.storage.exportAudit")
                            }
                        }
                        if let v = storage.verification {
                            if v.isValid {
                                Banner(kind: .success, text: String(localized: "The chain is intact: \(String(v.verifiedEntries)) entries verified. Removal of the newest lines cannot be detected from the file alone."))
                            } else {
                                Banner(kind: .error, text: String(localized: "The chain is broken at line \(String(v.firstBrokenLine ?? 0)): \(v.reason ?? "")"))
                            }
                        }
                        Text("Last \(String(storage.auditEntries.count)) entries, newest first").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        AuditList(entries: storage.auditEntries, maxHeight: 320)
                    }
                }
            }
        }
        .task {
            if storage == nil { storage = StorageModel(services: model.services) }
        }
        .task(id: model.revision) { await storage?.reload() }
    }

    private func backup(_ storage: StorageModel) {
        let stamp = Date().formatted(.iso8601.year().month().day())
        guard let url = FilePanels.saveFile(name: "orix-backup-\(stamp).sqlite", message: String(localized: "Choose where to write the database backup"), types: [.data]) else { return }
        Task {
            // The save panel already asked about replacing; the store itself refuses to overwrite.
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            _ = await storage.backup(to: url)
        }
    }

    private func exportBundle(_ storage: StorageModel) {
        guard let url = FilePanels.saveFile(name: "orix-workflows-and-settings.json", message: String(localized: "Choose where to write the export"), types: [.json]) else { return }
        Task { _ = await storage.exportBundle(to: url) }
    }

    private func importBundle(_ storage: StorageModel) {
        guard let url = FilePanels.chooseFile(message: String(localized: "Choose an ORIX export file"), types: [.json]) else { return }
        Task { _ = await storage.importBundle(from: url); await model.refreshShared() }
    }

    private func exportAudit(_ storage: StorageModel) {
        guard let url = FilePanels.saveFile(name: "orix-audit.jsonl", message: String(localized: "Choose where to copy the audit log"), types: [.data]) else { return }
        Task { _ = await storage.exportAudit(to: url) }
    }
}

/// Audit entries as rows: time, kind (symbol and words), tool, tier, detail. Virtualised.
struct AuditList: View {
    let entries: [AuditEntry]
    var maxHeight: CGFloat = 360

    var body: some View {
        if entries.isEmpty {
            Text("Nothing has been recorded yet.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(.vertical, Theme.Space.m)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { e in
                        let k = ManageText.auditKind(e.kind)
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text(Format.dateTime(e.timestamp)).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).frame(width: 128, alignment: .leading)
                            Label(k.label, systemImage: k.symbol).font(Theme.Font.captionStrong).foregroundStyle(k.color).frame(width: 132, alignment: .leading).lineLimit(1)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.detail).font(Theme.Font.caption).foregroundStyle(Theme.text).lineLimit(2).textSelection(.enabled)
                                if let tool = e.toolID {
                                    Text(tool + (e.tier.map { " · " + $0.label } ?? "")).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                        .accessibilityElement(children: .combine)
                        Divider().opacity(0.5)
                    }
                }
                .padding(.horizontal, Theme.Space.s)
            }
            .frame(maxHeight: maxHeight)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        }
    }
}
