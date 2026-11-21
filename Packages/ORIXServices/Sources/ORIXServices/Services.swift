// ORIX OS Automation
// File: Packages/ORIXServices/Sources/ORIXServices/Services.swift
// Description: The composition root. Builds every service once, registers the tool families, and keeps installed skills in sync with the tool registry.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAgentRuntime
import ORIXAppleAutomation
import ORIXBrowserAutomation
import ORIXCore
import ORIXPersistence
import ORIXProviderAdapters
import ORIXSecurity
import ORIXSkills
import ORIXToolRegistry

public struct ServiceOptions: Sendable {
    /// True in the app (a person can answer approvals); false in the background agent and unattended CLI runs.
    public var interactive = true
    /// Debug builds only: fall back to `ORIX_DEV_*_API_KEY` environment variables when no key is in the Keychain.
    public var allowDevelopmentCredentials = false
    public var keychainService = KeychainStore.defaultService
    public init() {}
}

public final class ORIXServices: Sendable {
    public let paths: ORIXPaths
    public let options: ServiceOptions
    public let processStart = Date()
    public let store: ORIXStore
    public let audit: AuditLog
    public let policy: PolicyEngine
    public let keychain: KeychainStore
    public let providers: ProviderHub
    public let registry: ToolRegistry
    public let executor: ToolExecutor
    public let runner: ProcessRunner
    public let approvals: ApprovalCenter
    public let interaction: InteractionCenter
    public let browser: BrowserSessionManager
    public let skills: SkillStore
    public let runs: RunManager
    public let agents: StoreAgentDirectory
    public let memory: StoreMemory
    public let workflows: WorkflowService

    public static func bootstrap(paths: ORIXPaths = .default, options: ServiceOptions = ServiceOptions()) async throws -> ORIXServices {
        try paths.prepare()
        let s = try ORIXServices(paths: paths, options: options)
        try await s.registerTools()
        return s
    }

    private init(paths: ORIXPaths, options: ServiceOptions) throws {
        self.paths = paths; self.options = options
        store = try ORIXStore(url: paths.database)
        audit = try AuditLog(url: paths.auditLog)
        policy = PolicyEngine(store: store, audit: audit)
        keychain = KeychainStore(service: options.keychainService)
        providers = ProviderHub(keychain: keychain, allowDevelopmentEnvironment: options.allowDevelopmentCredentials)
        registry = ToolRegistry()
        runner = ProcessRunner()
        approvals = ApprovalCenter(interactive: options.interactive)
        interaction = InteractionCenter(interactive: options.interactive)
        executor = ToolExecutor(registry: registry, policy: policy, approvals: approvals, audit: audit, events: store,
                                secrets: KeychainSecretResolver(store: keychain))
        browser = BrowserSessionManager()
        skills = try SkillStore(root: paths.skills, runner: runner)
        runs = RunManager(store: store, policy: policy, executor: executor, providers: providers, approvals: approvals, interaction: interaction,
                          browser: browser, runner: runner, audit: audit, paths: paths)
        agents = StoreAgentDirectory(store: store)
        memory = StoreMemory(store: store)
        workflows = WorkflowService(store: store, policy: policy, executor: executor, runs: runs, providers: providers, approvals: approvals,
                                    interaction: interaction, paths: paths)
    }

    private func registerTools() async throws {
        try await registry.registerAll(ORIXToolRegistryTools.all(pythonEnvRoot: paths.pythonEnv, runner: runner))
        try await registry.registerAll(ORIXAppleAutomationTools.all())
        try await registry.registerAll(ORIXBrowserAutomationTools.all(manager: browser))
        try await registry.registerAll(ORIXSkillsTools.all(store: skills))
        await refreshSkillTools()
        await skills.onChange { [weak self] in Task { await self?.refreshSkillTools() } }
    }

    /// Replaces the registered `skill.*` tools with the enabled, verified skills currently installed.
    public func refreshSkillTools() async {
        for m in await registry.manifests() where m.identifier.hasPrefix("skill.") { await registry.unregister(id: m.identifier) }
        for tool in await skills.tools() { try? await registry.register(tool) }
    }

    /// Store recovery note (a corrupt database was set aside), if any, for the UI to show once.
    public var recoveryNote: String? { store.recoveryNote }

    /// macOS privacy permission status, without prompting.
    public func permissionSnapshot() -> [MacPermission: PermissionStatus] { MacPermissions.snapshot() }

    public func shutdown() async {
        await runs.emergencyStop()
        await workflows.stopScheduler()
    }
}
