// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXServices/Sources/ORIXServices/ProvidersAndStores.swift
// Description      : Keychain-backed provider hub (BYOK), app settings,
//                    built-in agent profiles, and the adapters that put
//                    schedules, checkpoints, memory and agents on the SQLite
//                    store.
// Module           : ORIXServices
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
import ORIXAgentRuntime
import ORIXCore
import ORIXPersistence
import ORIXProviderAdapters
import ORIXScheduler
import ORIXSecurity

public enum KeySource: String, Sendable { case keychain, developmentEnvironment, none }

/// Builds provider clients from keys in the login Keychain. Keys never leave this actor except inside a client.
public actor ProviderHub: ProviderResolving {
    let keychain: KeychainStore
    let allowDevelopmentEnvironment: Bool
    private var clients: [ProviderID: any LLMProvider] = [:]
    private var injected: [ProviderID: any LLMProvider] = [:]
    private var catalogs: [ProviderID: [ModelInfo]] = [:]

    public init(keychain: KeychainStore, allowDevelopmentEnvironment: Bool = false) {
        self.keychain = keychain; self.allowDevelopmentEnvironment = allowDevelopmentEnvironment
    }

    /// Registers a ready-made provider (tests, or a scripted provider for offline demos of the plumbing).
    public func register(_ provider: any LLMProvider) { injected[provider.id] = provider }

    private func key(for id: ProviderID) -> (String, KeySource)? {
        if let k = try? keychain.get(account: KeychainStore.providerAccount(id)), !k.isEmpty { return (k, .keychain) }
        #if DEBUG
        if allowDevelopmentEnvironment, let k = DevEnvironmentCredentials().apiKey(for: id), !k.isEmpty { return (k, .developmentEnvironment) }
        #endif
        return nil
    }

    public func keySource(for id: ProviderID) -> KeySource {
        if injected[id] != nil { return .keychain }
        return key(for: id)?.1 ?? .none
    }

    public func configuredProviders() -> [ProviderID] { ProviderID.all.filter { keySource(for: $0) != .none } + injected.keys.filter { !ProviderID.all.contains($0) } }

    /// A masked form of the stored key (`sk-…a1b2`), or nil. The full key is never returned.
    public func maskedKey(for id: ProviderID) -> String? { key(for: id).map { KeychainStore.masked($0.0) } }

    public func setKey(_ value: String, for id: ProviderID) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { throw LLMError.invalidRequest("That does not look like an API key.") }
        try keychain.set(trimmed, account: KeychainStore.providerAccount(id))
        Redactor.shared.register(secret: trimmed)
        clients[id] = nil; catalogs[id] = nil
    }

    public func removeKey(for id: ProviderID) throws {
        try keychain.delete(account: KeychainStore.providerAccount(id))
        clients[id] = nil; catalogs[id] = nil
    }

    public func provider(for id: ProviderID) async throws -> any LLMProvider {
        if let p = injected[id] { return p }
        if let c = clients[id] { return c }
        guard let (k, _) = key(for: id) else { throw LLMError.missingCredential(id) }
        Redactor.shared.register(secret: k)
        let c = ProviderFactory.make(id, apiKey: k)
        clients[id] = c
        return c
    }

    /// Models for a provider: the live catalog when reachable, else the maintained registry (marked as such).
    public func models(for id: ProviderID, refresh: Bool = false) async -> (models: [ModelInfo], error: String?) {
        if !refresh, let c = catalogs[id] { return (c, nil) }
        do {
            let list = try await provider(for: id).listModels()
            catalogs[id] = list
            return (list, nil)
        } catch {
            let fallback = ModelRegistry.models(for: id)
            return (fallback, (error as? LLMError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func modelInfo(_ ref: ModelRef) async -> ModelInfo? {
        if let m = catalogs[ref.provider]?.first(where: { $0.id == ref.model }) { return m }
        if let m = ModelRegistry.info(provider: ref.provider, id: ref.model) { return m }
        if injected[ref.provider] != nil { return try? await injected[ref.provider]!.listModels().first { $0.id == ref.model } }
        return nil
    }

    /// One minimal request (at most 8 output tokens) to confirm the key and model work.
    public func test(_ ref: ModelRef) async -> ProviderTestResult {
        do {
            let r = await ProviderHealth.check(provider: try await provider(for: ref.provider), model: ref.model)
            return ProviderTestResult(model: ref, ok: r.ok, latencyMs: r.latencyMs, message: r.message ?? r.error?.errorDescription)
        } catch {
            return ProviderTestResult(model: ref, ok: false, latencyMs: 0, message: (error as? LLMError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

public struct ProviderTestResult: Sendable, Hashable {
    public var model: ModelRef
    public var ok: Bool
    public var latencyMs: Int
    public var message: String?
}

public struct AppSettings: Codable, Sendable, Hashable {
    public var onboardingCompleted = false
    public var defaultModel: ModelRef?
    public var plannerModel: ModelRef?
    public var verifierModel: ModelRef?
    public var defaultMode: ExecutionMode = .guided
    public var defaultBudget: Budget = .standard
    public var dailySpendLimitUSD: Double = 5
    public var defaultWorkspace: String?
    public var notificationsEnabled = true
    public var backgroundAgentEnabled = false
    public var retentionDays = 90
    /// Screen captures are sent to a model provider only when this is on. Off by default.
    public var allowScreenContentToProvider = false
    public var appearance = "system"
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
        defaultModel = try c.decodeIfPresent(ModelRef.self, forKey: .defaultModel)
        plannerModel = try c.decodeIfPresent(ModelRef.self, forKey: .plannerModel)
        verifierModel = try c.decodeIfPresent(ModelRef.self, forKey: .verifierModel)
        defaultMode = try c.decodeIfPresent(ExecutionMode.self, forKey: .defaultMode) ?? d.defaultMode
        defaultBudget = try c.decodeIfPresent(Budget.self, forKey: .defaultBudget) ?? d.defaultBudget
        dailySpendLimitUSD = try c.decodeIfPresent(Double.self, forKey: .dailySpendLimitUSD) ?? d.dailySpendLimitUSD
        defaultWorkspace = try c.decodeIfPresent(String.self, forKey: .defaultWorkspace)
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        backgroundAgentEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundAgentEnabled) ?? d.backgroundAgentEnabled
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        allowScreenContentToProvider = try c.decodeIfPresent(Bool.self, forKey: .allowScreenContentToProvider) ?? d.allowScreenContentToProvider
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
    }
}

public enum Collections {
    public static let settings = "settings"
    public static let agents = "agents"
    public static let sessions = "sessions"
    public static let sessionMessages = "session-messages"
    public static let memory = "memory"
    public static let schedules = "schedules"
    public static let queue = "schedule-queue"
    public static let agentCheckpoints = "agent-checkpoints"
    public static let workflowCheckpoints = "workflow-checkpoints"
    public static let recordings = "recordings"
}

public enum BuiltInAgents {
    /// An empty model id means "the default model from Settings", resolved when a run starts.
    static let unset = ModelRef(provider: .anthropic, model: "")

    public static let all: [AgentProfile] = [
        AgentProfile(id: "builtin.general", name: "general", role: "worker",
                     instructions: "You are a careful general-purpose automation agent. Prefer specific tools over scripts. Verify every change you make.",
                     model: unset, toolPatterns: ["*"], memoryScopes: ["session", "workflow", "user"], builtIn: true),
        AgentProfile(id: "builtin.file-organizer", name: "file-organizer", role: "specialist",
                     instructions: "You organise files. Never delete: move, rename or copy only. Report every move as old path → new path.",
                     model: unset, toolPatterns: ["filesystem.list", "filesystem.search", "filesystem.metadata", "filesystem.checksum", "filesystem.mkdir", "filesystem.move", "filesystem.copy", "filesystem.compare", "documents.imageInfo"],
                     builtIn: true),
        AgentProfile(id: "builtin.research-analyst", name: "research-analyst", role: "specialist",
                     instructions: "You read documents and pages and write accurate summaries with sources. Quote figures exactly. Say what you could not read.",
                     model: unset, toolPatterns: ["filesystem.list", "filesystem.search", "filesystem.read", "filesystem.metadata", "filesystem.write", "documents.*", "browser.open", "browser.read", "browser.waitFor", "browser.close", "http.request"],
                     builtIn: true),
        AgentProfile(id: "builtin.code-reviewer", name: "code-reviewer", role: "reviewer",
                     instructions: "You review source changes. Read the diff, run the project's tests when a test command is evident, and report defects with file and line. Do not push.",
                     model: unset, toolPatterns: ["git.status", "git.diff", "git.log", "git.branches", "git.createPatch", "filesystem.list", "filesystem.search", "filesystem.read", "shell.run", "filesystem.write"],
                     builtIn: true),
        AgentProfile(id: "builtin.verifier", name: "verifier", role: "verifier",
                     instructions: "You check claims against the actual state of the machine using read-only tools, and report PASS or FAIL per claim with evidence.",
                     model: unset, toolPatterns: ["filesystem.list", "filesystem.search", "filesystem.read", "filesystem.metadata", "filesystem.checksum", "filesystem.compare", "documents.pdfInfo", "documents.pdfText", "documents.csvRead", "documents.jsonQuery", "documents.imageInfo", "documents.textStats", "git.status", "git.diff", "git.log"],
                     builtIn: true),
    ]
}

/// Agent profiles: built-ins plus the user's, from the store.
public struct StoreAgentDirectory: AgentDirectory {
    let store: ORIXStore
    public init(store: ORIXStore) { self.store = store }

    public func all() async -> [AgentProfile] {
        let user = (try? await store.all(AgentProfile.self, collection: Collections.agents)) ?? []
        let userNames = Set(user.map(\.name))
        return BuiltInAgents.all.filter { !userNames.contains($0.name) } + user.sorted { $0.name < $1.name }
    }
    public func profile(named name: String) async -> AgentProfile? { await all().first { $0.name == name || $0.id == name } }
    public func profileNames() async -> [String] { await all().map(\.name) }
    public func save(_ profile: AgentProfile) async throws {
        var p = profile; p.builtIn = false
        try await store.put(p, collection: Collections.agents, id: p.id)
    }
    public func remove(id: String) async throws { _ = try await store.remove(collection: Collections.agents, id: id) }
}

public struct StoreCheckpoints: AgentCheckpointStoring {
    let store: ORIXStore
    public init(store: ORIXStore) { self.store = store }
    public func save(_ checkpoint: AgentCheckpoint) async { try? await store.put(checkpoint, collection: Collections.agentCheckpoints, id: checkpoint.runID) }
    public func load(runID: String) async -> AgentCheckpoint? { try? await store.get(AgentCheckpoint.self, collection: Collections.agentCheckpoints, id: runID) }
    public func clear(runID: String) async { _ = try? await store.remove(collection: Collections.agentCheckpoints, id: runID) }
}

public struct StoreMemory: MemoryStoring {
    let store: ORIXStore
    public init(store: ORIXStore) { self.store = store }
    public func all() async -> [MemoryRecord] { (try? await store.all(MemoryRecord.self, collection: Collections.memory)) ?? [] }
    public func memories(scopes: [MemoryRecord.Scope]) async -> [MemoryRecord] {
        let keys = Set(scopes.map(\.key))
        return await all().filter { keys.contains($0.scope.key) }
    }
    public func save(_ record: MemoryRecord) async { try? await store.put(record, collection: Collections.memory, id: record.id) }
    public func remove(id: String) async { _ = try? await store.remove(collection: Collections.memory, id: id) }
    public func approve(id: String) async {
        guard var r = try? await store.get(MemoryRecord.self, collection: Collections.memory, id: id) else { return }
        r.approved = true
        try? await store.put(r, collection: Collections.memory, id: id)
    }
}

/// Schedules and the run queue on the SQLite store. One actor serialises read-modify-write sequences; across
/// processes only the lease holder (see `acquireLease`) runs the engine that calls `enqueue`/`claimNext`.
public actor StoreScheduleStore: ScheduleStoring {
    let store: ORIXStore
    public init(store: ORIXStore) { self.store = store }

    public func schedules() async throws -> [Schedule] { try await store.all(Schedule.self, collection: Collections.schedules).sorted { $0.createdAt < $1.createdAt } }
    public func schedule(id: String) async throws -> Schedule? { try await store.get(Schedule.self, collection: Collections.schedules, id: id) }
    public func saveSchedule(_ schedule: Schedule) async throws { try await store.put(schedule, collection: Collections.schedules, id: schedule.id) }
    public func removeSchedule(id: String) async throws { _ = try await store.remove(collection: Collections.schedules, id: id) }

    public func queueItems() async throws -> [QueueItem] { try await store.all(QueueItem.self, collection: Collections.queue) }
    public func queueItem(id: String) async throws -> QueueItem? { try await store.get(QueueItem.self, collection: Collections.queue, id: id) }
    public func queueItem(dedupKey: String) async throws -> QueueItem? { try await queueItems().first { $0.dedupKey == dedupKey } }

    public func enqueue(_ item: QueueItem) async throws -> Bool {
        if try await queueItem(dedupKey: item.dedupKey) != nil { return false }
        try await store.put(item, collection: Collections.queue, id: item.id)
        return true
    }
    public func updateQueueItem(_ item: QueueItem) async throws { try await store.put(item, collection: Collections.queue, id: item.id) }
    public func removeQueueItem(id: String) async throws { _ = try await store.remove(collection: Collections.queue, id: id) }

    public func claimNext(now: Date, eligible: @Sendable (QueueItem) -> Bool) async throws -> QueueItem? {
        let due = try await queueItems().filter { $0.status == .pending && $0.dueAt <= now && eligible($0) }
            .sorted { ($0.dueAt, $0.enqueuedAt) < ($1.dueAt, $1.enqueuedAt) }
        guard var item = due.first else { return nil }
        item.status = .running
        try await store.put(item, collection: Collections.queue, id: item.id)
        return item
    }

    public func acquireLease(name: String, owner: String, ttlSeconds: Double) async throws -> Bool {
        try await store.acquireLease(name: name, owner: owner, ttlSeconds: ttlSeconds)
    }
    public func releaseLease(name: String, owner: String) async throws { _ = try await store.releaseLease(name: name, owner: owner) }

    /// Drops finished queue items older than `days` so the queue table stays small.
    public func prune(olderThanDays days: Int) async {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for item in (try? await queueItems()) ?? [] where item.status.isTerminal && item.enqueuedAt < cutoff {
            _ = try? await store.remove(collection: Collections.queue, id: item.id)
        }
    }
}
