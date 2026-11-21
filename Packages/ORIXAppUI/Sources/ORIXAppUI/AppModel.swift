// ORIX OS Automation
// File: Packages/ORIXAppUI/Sources/ORIXAppUI/AppModel.swift
// Description: The observable app model shared by every feature: services, navigation, settings, pending approvals and questions, active runs, and a revision counter that ticks on every store change.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Observation
import ORIXCore
import ORIXPersistence
import ORIXServices
import SwiftUI

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case dashboard, chat, workflows, code, runs, scheduler, agents, skills, permissions, settings
    public var id: String { rawValue }

    public var title: LocalizedStringKey {
        switch self {
        case .dashboard: return "Dashboard"
        case .chat: return "Agent"
        case .workflows: return "Workflow Studio"
        case .code: return "Code Studio"
        case .runs: return "Runs"
        case .scheduler: return "Scheduler"
        case .agents: return "Agents"
        case .skills: return "Skills"
        case .permissions: return "Permissions"
        case .settings: return "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .workflows: return "point.3.connected.trianglepath.dotted"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .runs: return "list.bullet.rectangle"
        case .scheduler: return "calendar.badge.clock"
        case .agents: return "person.2.badge.gearshape"
        case .skills: return "puzzlepiece.extension"
        case .permissions: return "lock.shield"
        case .settings: return "gearshape"
        }
    }
}

/// A request from one feature to show something in another (for example "open this run").
public enum NavigationTarget: Hashable, Sendable {
    case run(String)
    case workflow(String)
    case workflowCode(String)
    case section(AppSection)
}

@MainActor
@Observable
public final class AppModel {
    public let services: ORIXServices

    // Navigation
    public var section: AppSection = .dashboard
    public var selectedRunID: String?
    public var selectedWorkflowID: String?
    public var showCommandPalette = false
    public var showOnboarding = false

    // Shared state
    public var settings = AppSettings()
    /// Increases whenever the store changes (in this process or another). Views reload with `.task(id: model.revision)`.
    public private(set) var revision = 0
    public private(set) var pendingApprovals: [ApprovalRequest] = []
    public private(set) var pendingInteractions: [InteractionCenter.Item] = []
    public private(set) var activeRuns: [RunRecord] = []
    public private(set) var configuredProviders: [ProviderID] = []
    public var banner: (kind: Banner.Kind, text: String)?
    public private(set) var isStopping = false

    private var observers: [Task<Void, Never>] = []

    public init(services: ORIXServices) { self.services = services }

    /// Starts observing the store and the approval/interaction centres. Call once after creating the model.
    public func start() async {
        settings = await services.runs.settings()
        showOnboarding = !settings.onboardingCompleted
        await refreshShared()
        if let note = services.recoveryNote { banner = (.warning, note) }
        let services = self.services
        observers.append(Task { [weak self] in
            for await _ in services.store.changes { await self?.storeChanged() }
        })
        observers.append(Task { [weak self] in
            for await _ in ORIXStore.darwinChanges() { await self?.storeChanged() }
        })
        observers.append(Task { [weak self] in
            for await p in services.approvals.updates() { self?.pendingApprovals = p }
        })
        observers.append(Task { [weak self] in
            for await i in services.interaction.updates() { self?.pendingInteractions = i }
        })
    }

    private var refreshScheduled = false
    private func storeChanged() async {
        // Coalesce bursts of writes (event streams) into at most ~8 refreshes per second.
        guard !refreshScheduled else { return }
        refreshScheduled = true
        try? await Task.sleep(nanoseconds: 120_000_000)
        refreshScheduled = false
        await refreshShared()
    }

    public func refreshShared() async {
        activeRuns = (try? await services.store.activeRuns()) ?? []
        configuredProviders = await services.providers.configuredProviders()
        revision &+= 1
    }

    // MARK: Navigation

    public func open(_ target: NavigationTarget) {
        switch target {
        case .run(let id): selectedRunID = id; section = .runs
        case .workflow(let id): selectedWorkflowID = id; section = .workflows
        case .workflowCode(let id): selectedWorkflowID = id; section = .code
        case .section(let s): section = s
        }
    }

    // MARK: Settings

    public func saveSettings() {
        let s = settings
        Task {
            do { try await services.runs.save(s) } catch { report(error) }
        }
    }

    // MARK: Approvals and questions

    public func resolve(_ request: ApprovalRequest, _ response: ApprovalResponse) {
        Task { await services.approvals.resolve(id: request.id, response: response) }
    }

    public func answer(_ question: PendingQuestion, _ text: String?) {
        Task { await services.interaction.answer(questionID: question.id, text) }
    }

    public func review(_ plan: PendingPlan, _ decision: PlanReview) {
        Task { await services.interaction.review(planID: plan.id, decision) }
    }

    // MARK: Runs

    /// Starts an agent run and returns its id, or shows the error and returns nil.
    @discardableResult
    public func startAgentRun(_ request: AgentRunRequest) async -> String? {
        do { return try await services.runs.startAgentRun(request) }
        catch { report(error); return nil }
    }

    @discardableResult
    public func startWorkflowRun(_ request: WorkflowRunRequest) async -> String? {
        do { return try await services.workflows.startRun(request) }
        catch { report(error); return nil }
    }

    public func cancel(runID: String) { Task { await services.runs.cancel(runID: runID) } }

    /// Emergency stop: every run, tool call, child process and pending approval, now.
    public func emergencyStop() {
        guard !isStopping else { return }
        isStopping = true
        Task {
            await services.runs.emergencyStop()
            isStopping = false
            banner = (.warning, String(localized: "Emergency stop: all runs and their processes were stopped.", bundle: .main))
        }
    }

    // MARK: Errors

    public func report(_ error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        banner = (.error, Redactor.shared.redact(text))
    }

    public func notice(_ text: String, kind: Banner.Kind = .info) { banner = (kind, text) }

    /// The default workspace folder for new runs: the one from Settings, else the app's own scratch folder.
    public var defaultWorkspace: String {
        if let w = settings.defaultWorkspace, !w.isEmpty { return w }
        return services.paths.scratch.path
    }
}

