// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/SettingsModels.swift
// Description      : View models behind Settings and Onboarding: provider keys
//                    and catalogs, budget bounds, storage, backup,
//                    export/import, audit log and the diagnostics report.
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
import Foundation
import Observation
import SwiftUI
import ORIXAppUI

// MARK: Providers

/// Provider keys, connection tests and model catalogs. A key passes through `saveKey` to the Keychain and is not kept here.
@MainActor
@Observable
final class ProvidersModel {
    /// Outcome of one connection test, already redacted for display.
    struct ConnectionTest: Sendable, Hashable {
        var model: ModelRef
        var ok: Bool
        var latencyMs: Int
        var message: String?
    }

    struct State {
        var masked: String?
        var source: KeySource = .none
        var models: [ModelInfo] = []
        var catalogError: String?
        var catalogLoaded = false
        var loadingCatalog = false
        var test: ConnectionTest?
        var testing = false
        var keyError: String?
        var saving = false
    }

    let services: ORIXServices
    private(set) var states: [ProviderID: State] = Dictionary(uniqueKeysWithValues: ProviderID.all.map { ($0, State()) })

    init(services: ORIXServices) { self.services = services }

    func state(_ id: ProviderID) -> State { states[id] ?? State() }

    /// Reads which providers have a key and their masked form. Never reads a full key into this object.
    func reload() async {
        for id in ProviderID.all {
            let source = await services.providers.keySource(for: id)
            let masked = await services.providers.maskedKey(for: id)
            states[id, default: State()].source = source
            states[id, default: State()].masked = source == .none ? nil : masked
        }
    }

    /// Stores a key in the Keychain. Returns true on success. The error text never contains the key.
    @discardableResult
    func saveKey(_ key: String, for id: ProviderID) async -> Bool {
        states[id, default: State()].saving = true
        defer { states[id, default: State()].saving = false }
        do {
            try await services.providers.setKey(key, for: id)
            states[id, default: State()].keyError = nil
            states[id, default: State()].test = nil
            states[id, default: State()].catalogLoaded = false
            await reload()
            return true
        } catch {
            states[id, default: State()].keyError = Redactor.shared.redact(ManageText.describe(error)).replacingOccurrences(of: key, with: Redactor.placeholder)
            return false
        }
    }

    func removeKey(for id: ProviderID) async {
        do {
            try await services.providers.removeKey(for: id)
            states[id, default: State()].keyError = nil
        } catch {
            states[id, default: State()].keyError = ManageText.describe(error)
        }
        states[id, default: State()].test = nil
        states[id, default: State()].catalogLoaded = false
        states[id, default: State()].models = []
        await reload()
    }

    /// Loads the model list: live when the provider answers, otherwise the maintained registry with the reason.
    func loadCatalog(for id: ProviderID, refresh: Bool = false) async {
        states[id, default: State()].loadingCatalog = true
        let result = await services.providers.models(for: id, refresh: refresh)
        states[id, default: State()].models = result.models.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        states[id, default: State()].catalogError = result.error
        states[id, default: State()].catalogLoaded = true
        states[id, default: State()].loadingCatalog = false
    }

    /// The model a connection test uses: the default model when it belongs to this provider, else the cheapest known one.
    func testModel(for id: ProviderID, settings: AppSettings) -> String? {
        if let d = settings.defaultModel, d.provider == id, !d.model.isEmpty { return d.model }
        let models = state(id).models
        let priced = models.filter { $0.inputPricePerMTok != nil }.min { ($0.inputPricePerMTok ?? 0) < ($1.inputPricePerMTok ?? 0) }
        return (priced ?? models.first)?.id
    }

    /// Sends one minimal request (at most 8 output tokens).
    func test(_ id: ProviderID, settings: AppSettings) async {
        if !state(id).catalogLoaded { await loadCatalog(for: id) }
        guard let model = testModel(for: id, settings: settings) else {
            states[id, default: State()].test = ConnectionTest(model: ModelRef(provider: id, model: ""), ok: false, latencyMs: 0, message: String(localized: "No model is known for this provider yet."))
            return
        }
        states[id, default: State()].testing = true
        let r = await services.providers.test(ModelRef(provider: id, model: model))
        states[id, default: State()].test = ConnectionTest(model: r.model, ok: r.ok, latencyMs: r.latencyMs, message: r.message.map { Redactor.shared.redact($0) })
        states[id, default: State()].testing = false
    }

    func filtered(_ id: ProviderID, search: String) -> [ModelInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state(id).models }
        return state(id).models.filter { $0.id.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
    }

    /// True when the list shown came from the provider itself rather than the built-in registry.
    func catalogIsLive(_ id: ProviderID) -> Bool { state(id).catalogLoaded && state(id).catalogError == nil }
}

// MARK: Budget bounds

/// Limits that keep a budget meaningful: never zero, never absurd.
enum BudgetBounds {
    static let turns = 1...200
    static let wallSeconds = 30.0...14_400.0
    static let tokens = 10_000...5_000_000
    static let costUSD = 0.01...100.0
    static let toolCalls = 1...1000
    static let subprocessSeconds = 5.0...3600.0
    static let concurrency = 1...16
    static let dailySpendUSD = 0.10...500.0
    static let retentionDays = 1...3650

    static func clamp<T: Comparable>(_ v: T, _ r: ClosedRange<T>) -> T { min(max(v, r.lowerBound), r.upperBound) }

    static func clamped(_ b: Budget) -> Budget {
        Budget(maxTurns: clamp(b.maxTurns, turns), maxWallSeconds: clamp(b.maxWallSeconds, wallSeconds), maxTotalTokens: clamp(b.maxTotalTokens, tokens),
               maxCostUSD: clamp(b.maxCostUSD, costUSD), maxToolCalls: clamp(b.maxToolCalls, toolCalls),
               maxSubprocessSeconds: clamp(b.maxSubprocessSeconds, subprocessSeconds), maxConcurrentTasks: clamp(b.maxConcurrentTasks, concurrency))
    }
}

// MARK: Storage, backup, audit

@MainActor
@Observable
final class StorageModel {
    let services: ORIXServices
    private(set) var databaseBytes: Int?
    private(set) var artifactsBytes: Int?
    private(set) var measuring = false
    private(set) var auditCount: Int?
    private(set) var auditEntries: [AuditEntry] = []
    private(set) var verification: AuditVerification?
    private(set) var verifying = false
    private(set) var lastSummary: (title: String, summary: BundleSummary)?
    private(set) var working: String?
    var message: (kind: Banner.Kind, text: String)?

    init(services: ORIXServices) { self.services = services }

    /// Total size of the regular files under a folder. Runs off the main actor.
    nonisolated static func folderSize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            total += v.fileSize ?? 0
        }
        return total
    }

    func reload() async {
        measuring = true
        databaseBytes = try? await services.store.databaseSizeBytes()
        let artifacts = services.paths.artifacts
        artifactsBytes = await Task.detached(priority: .utility) { StorageModel.folderSize(artifacts) }.value
        measuring = false
        await reloadAudit()
    }

    func reloadAudit() async {
        auditCount = await services.audit.entryCount()
        auditEntries = Array(await services.audit.entries(limit: 200).reversed())
    }

    func verifyAudit() async {
        verifying = true
        verification = await services.audit.verify()
        verifying = false
    }

    /// Writes a consistent copy of the database. Refuses to overwrite an existing file.
    func backup(to url: URL) async -> Bool {
        working = "backup"; defer { working = nil }
        do {
            try await services.store.backup(to: url)
            message = (.success, String(localized: "Backup written to \(PathResolver.display(url.path))."))
            return true
        } catch {
            message = (.error, ManageText.describe(error)); return false
        }
    }

    func exportBundle(to url: URL) async -> BundleSummary? {
        working = "export"; defer { working = nil }
        do {
            let s = try await services.workflows.exportBundle(to: url)
            lastSummary = (String(localized: "Exported to \(PathResolver.display(url.path))"), s)
            message = nil
            return s
        } catch { message = (.error, ManageText.describe(error)); return nil }
    }

    func importBundle(from url: URL) async -> BundleSummary? {
        working = "import"; defer { working = nil }
        do {
            let s = try await services.workflows.importBundle(from: url)
            lastSummary = (String(localized: "Imported from \(PathResolver.display(url.path))"), s)
            message = nil
            return s
        } catch { message = (.error, ManageText.describe(error)); return nil }
    }

    /// Copies the audit log file as it is (already redacted when written).
    func exportAudit(to url: URL) async -> Bool {
        let source = services.paths.auditLog
        do {
            try await Task.detached {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.copyItem(at: source, to: url)
            }.value
            message = (.success, String(localized: "Audit log exported to \(PathResolver.display(url.path))."))
            return true
        } catch { message = (.error, ManageText.describe(error)); return false }
    }

    /// Deletes finished runs older than `days` days (0 deletes every finished run). Returns how many were deleted.
    func pruneRuns(olderThanDays days: Int) async -> Int? {
        working = "prune"; defer { working = nil }
        do {
            let n = try await services.store.pruneRuns(olderThanDays: days)
            message = (.success, String(localized: "\(String(n)) run(s) deleted from the history."))
            await reload()
            return n
        } catch { message = (.error, ManageText.describe(error)); return nil }
    }

    static func summaryLines(_ s: BundleSummary) -> [String] {
        var out = [String(localized: "\(String(s.workflows)) workflow(s), \(String(s.workflowVersions)) version(s), \(String(s.documents)) other record(s).")]
        if s.excludedCollections.isEmpty { out.append(String(localized: "No collection was left out.")) }
        else { out.append(String(localized: "Left out because they can hold sensitive material: \(s.excludedCollections.sorted().joined(separator: ", ")).")) }
        out.append(s.redactedValues == 0 ? String(localized: "No value needed redaction.") : String(localized: "\(String(s.redactedValues)) value(s) looked like a secret and were replaced by a placeholder."))
        out.append(String(localized: "Grants, API keys and run history are never part of an export."))
        return out
    }
}

// MARK: Diagnostics

struct DiagnosticsReport: Sendable, Hashable {
    var appVersion: String
    var build: String
    var macOS: String
    var architecture: String
    var dataFolder: String
    var toolsByFamily: [(family: String, count: Int)]
    var toolTotal: Int
    var permissions: [(permission: MacPermission, status: PermissionStatus)]
    var recoveryNote: String?
    var configuredProviders: [String]
    var installedSkills: Int
    var databaseBytes: Int?
    var auditEntries: Int
    var schedulerActive: Bool

    static func == (a: DiagnosticsReport, b: DiagnosticsReport) -> Bool { a.text == b.text }
    func hash(into hasher: inout Hasher) { hasher.combine(text) }

    /// Groups tool identifiers by the part before the first dot.
    static func families(_ manifests: [ToolManifest]) -> [(family: String, count: Int)] {
        Dictionary(grouping: manifests, by: { String($0.identifier.split(separator: ".").first ?? "") })
            .map { (family: $0.key, count: $0.value.count) }.sorted { $0.family < $1.family }
    }

    @MainActor
    static func make(_ model: AppModel) async -> DiagnosticsReport {
        let s = model.services
        let info = Bundle.main.infoDictionary ?? [:]
        let manifests = await s.registry.manifests()
        let snapshot = await Task.detached { MacPermissions.snapshot() }.value
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return DiagnosticsReport(
            appVersion: info["CFBundleShortVersionString"] as? String ?? String(localized: "not in an app bundle"),
            build: info["CFBundleVersion"] as? String ?? "—",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString, architecture: arch,
            dataFolder: PathResolver.display(s.paths.root.path),
            toolsByFamily: families(manifests), toolTotal: manifests.count,
            permissions: MacPermission.allCases.map { ($0, snapshot[$0] ?? .unknown) },
            recoveryNote: s.recoveryNote.map { Redactor.shared.redact($0) },
            configuredProviders: model.configuredProviders.map(\.displayName),
            installedSkills: await s.skills.installed().count,
            databaseBytes: try? await s.store.databaseSizeBytes(),
            auditEntries: await s.audit.entryCount(),
            schedulerActive: await s.workflows.schedulerIsActive())
    }

    /// Plain text for the clipboard. No key, no secret, home-relative paths only.
    var text: String {
        var lines = ["ORIX OS Automation — diagnostics",
                     "Version: \(appVersion) (\(build))", "macOS: \(macOS) · \(architecture)", "Data folder: \(dataFolder)",
                     "Providers with a key: \(configuredProviders.isEmpty ? "none" : configuredProviders.joined(separator: ", "))",
                     "Tools: \(toolTotal) — " + toolsByFamily.map { "\($0.family) \($0.count)" }.joined(separator: ", "),
                     "Installed skills: \(installedSkills)",
                     "Database: \(databaseBytes.map(Format.bytes) ?? "unknown") · Audit entries: \(auditEntries)",
                     "Scheduler active in this process: \(schedulerActive ? "yes" : "no")",
                     "macOS permissions: " + permissions.map { "\($0.permission.rawValue)=\($0.status.rawValue)" }.joined(separator: ", ")]
        if let recoveryNote { lines.append("Store recovery: \(recoveryNote)") }
        return Redactor.shared.redact(lines.joined(separator: "\n"))
    }
}
