// ORIX OS Automation
// File: Packages/ORIXServices/Sources/ORIXServices/RunManager.swift
// Description: Starts, tracks and stops runs: run records, run-scoped workspace grants, live updates for the UI, receipts, session transcripts, crash recovery and emergency stop.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAgentRuntime
import ORIXBrowserAutomation
import ORIXCore
import ORIXPersistence
import ORIXSecurity
import ORIXToolRegistry

/// What the user lets a run do in its workspace folder without being asked each time. Chosen in the UI; it is the grant.
public enum WorkspaceAccess: String, Sendable, Codable, CaseIterable { case none, read, readWrite }

public struct AgentRunRequest: Sendable {
    public var objective: String
    public var agent: String = "general"
    public var model: ModelRef?
    public var mode: ExecutionMode = .guided
    public var workingDirectory: String
    public var workspaceAccess: WorkspaceAccess = .read
    public var budget: Budget?
    public var sessionID: String?
    public var expectations: [ORIXCore.Expectation] = []
    public var title: String?
    public var trigger = "manual"
    public init(objective: String, workingDirectory: String) { self.objective = objective; self.workingDirectory = workingDirectory }
}

public enum LiveUpdate: Sendable {
    case text(String)
    case reasoning(String)
    case toolStarted(ToolCall)
    case toolProgress(callID: String, ToolProgress)
    case toolFinished(ToolCall, ToolResult)
    case plan(AgentPlan)
    case status(RunStatus)
    case usage(RunUsage)
    case stepStatus(stepID: String, status: String)
    case finished(RunStatus)
}

/// Fan-out of live, non-persisted updates to UI subscribers. Lock-based so synchronous observer callbacks can publish.
public final class LiveHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subs: [String: [UUID: AsyncStream<LiveUpdate>.Continuation]] = [:]
    public init() {}

    public func subscribe(runID: String) -> AsyncStream<LiveUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2000)) { c in
            let id = UUID()
            lock.lock(); subs[runID, default: [:]][id] = c; lock.unlock()
            c.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.subs[runID]?[id] = nil; self.lock.unlock()
            }
        }
    }

    public func publish(_ runID: String, _ update: LiveUpdate) {
        lock.lock(); let cs = subs[runID].map { Array($0.values) } ?? []; lock.unlock()
        for c in cs { c.yield(update) }
    }

    public func finish(_ runID: String) {
        lock.lock(); let cs = subs.removeValue(forKey: runID).map { Array($0.values) } ?? []; lock.unlock()
        for c in cs { c.finish() }
    }
}

public struct SessionTranscript: Codable, Sendable { public var messages: [LLMMessage] }

public enum RunError: Error, LocalizedError, Sendable {
    case noModel
    case unknownAgent(String)
    case dailyLimit(Double)
    case notFound(String)
    case invalid(String)
    public var errorDescription: String? {
        switch self {
        case .noModel: return "No model is selected. Add a provider key and choose a default model in Settings › Providers."
        case .unknownAgent(let a): return "There is no agent named “\(a)”."
        case .dailyLimit(let l): return String(format: "Today's spending limit of $%.2f is reached. Raise it in Settings › Providers or wait until tomorrow.", l)
        case .notFound(let w): return "\(w) was not found."
        case .invalid(let m): return m
        }
    }
}

public actor RunManager {
    let store: ORIXStore
    let policy: PolicyEngine
    let executor: ToolExecutor
    let providers: ProviderHub
    let approvals: ApprovalCenter
    let interaction: InteractionCenter
    let agents: StoreAgentDirectory
    let memory: StoreMemory
    let checkpoints: StoreCheckpoints
    let browser: BrowserSessionManager
    let runner: ProcessRunner
    let audit: AuditLog
    let paths: ORIXPaths
    public nonisolated let live = LiveHub()

    private var controls: [String: RunControl] = [:]
    private var tasks: [String: Task<RunRecord, Never>] = [:]
    /// Cancel hooks for runs that are not agent runs (workflows).
    private var cancelers: [String: @Sendable () async -> Void] = [:]

    init(store: ORIXStore, policy: PolicyEngine, executor: ToolExecutor, providers: ProviderHub, approvals: ApprovalCenter,
         interaction: InteractionCenter, browser: BrowserSessionManager, runner: ProcessRunner, audit: AuditLog, paths: ORIXPaths) {
        self.store = store; self.policy = policy; self.executor = executor; self.providers = providers; self.approvals = approvals
        self.interaction = interaction; self.browser = browser; self.runner = runner; self.audit = audit; self.paths = paths
        agents = StoreAgentDirectory(store: store); memory = StoreMemory(store: store); checkpoints = StoreCheckpoints(store: store)
    }

    // MARK: Settings and budgets

    public func settings() async -> AppSettings { (try? await store.get(AppSettings.self, collection: Collections.settings, id: "app")) ?? AppSettings() }
    public func save(_ settings: AppSettings) async throws { try await store.put(settings, collection: Collections.settings, id: "app") }

    func spentToday() async -> Double { (try? await store.usageByDay(days: 1).last?.costUSD) ?? 0 }

    /// Caps a budget by what is left of today's spending limit; throws when nothing is left.
    func capped(_ budget: Budget, settings: AppSettings) async throws -> Budget {
        let left = settings.dailySpendLimitUSD - (await spentToday())
        guard left > 0 else { throw RunError.dailyLimit(settings.dailySpendLimitUSD) }
        var b = budget; b.maxCostUSD = min(b.maxCostUSD, left)
        return b
    }

    func resolveModel(_ requested: ModelRef?, profile: AgentProfile, settings: AppSettings) throws -> ModelRef {
        if let m = requested, !m.model.isEmpty { return m }
        if !profile.model.model.isEmpty { return profile.model }
        if let m = settings.defaultModel, !m.model.isEmpty { return m }
        throw RunError.noModel
    }

    /// Run-scoped grants for the folder the user picked for this run.
    func grantWorkspace(_ access: WorkspaceAccess, directory: String, runID: String) async throws -> String {
        let path = try PathResolver.canonical(directory, relativeTo: URL(fileURLWithPath: NSHomeDirectory()))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { throw RunError.invalid("The workspace folder \(PathResolver.display(path)) does not exist.") }
        guard !PathResolver.isProtected(path) else { throw RunError.invalid("\(PathResolver.display(path)) is a protected location and cannot be a workspace.") }
        if access != .none {
            // Reading is allowed up to tier 1 so that a copy or move whose source is in the workspace is not blocked on its read
            // side; the write side of such a call still needs its own grant or an approval.
            await policy.add(PermissionGrant(capability: .fileRead(path: path), scope: .run(runID: runID), maxTier: .reversibleWrite, source: "user", note: "Workspace of this run"))
        }
        if access == .readWrite {
            await policy.add(PermissionGrant(capability: .fileWrite(path: path), scope: .run(runID: runID), maxTier: .reversibleWrite, source: "user", note: "Workspace of this run"))
        }
        return path
    }

    // MARK: Agent runs

    @discardableResult
    public func startAgentRun(_ req: AgentRunRequest) async throws -> String {
        let settings = await settings()
        guard var profile = await agents.profile(named: req.agent) else { throw RunError.unknownAgent(req.agent) }
        profile.model = try resolveModel(req.model, profile: profile, settings: settings)
        let budget = try await capped(req.budget ?? (req.mode == .quick ? .quick : settings.defaultBudget), settings: settings)
        let runID = UUID().uuidString
        let workDir = try await grantWorkspace(req.mode == .review && req.workspaceAccess == .readWrite ? .read : req.workspaceAccess,
                                               directory: req.workingDirectory, runID: runID)
        let record = RunRecord(id: runID, kind: "agent", title: req.title ?? String(req.objective.prefix(80)), sessionID: req.sessionID,
                               trigger: req.trigger, mode: req.mode, status: .running, model: profile.model, startedAt: Date())
        try await store.saveRun(record)

        var history: [LLMMessage] = []
        if let sid = req.sessionID, let t = try? await store.get(SessionTranscript.self, collection: Collections.sessionMessages, id: sid) { history = t.messages }

        let task = AgentTask(objective: req.objective, mode: req.mode, workingDirectory: workDir, budget: budget, expectations: req.expectations)
        var options = AgentRunOptions()
        options.verifier = settings.verifierModel
        let runtime = AgentRuntime(deps: AgentDependencies(providers: providers, tools: executor, events: store, memory: memory, checkpoints: checkpoints,
                                                           interaction: interaction, agents: agents, artifactsRoot: paths.artifacts), options: options)
        let control = RunControl()
        controls[runID] = control
        let observer = makeObserver(runID)
        let frozenProfile = profile
        let sessionID = req.sessionID
        let snapshot = record
        tasks[runID] = Task { [self] in
            let result = await runtime.execute(task: task, profile: frozenProfile, runID: runID, history: history, control: control, observer: observer)
            if let sessionID { try? await store.put(SessionTranscript(messages: Self.trimmed(result.messages)), collection: Collections.sessionMessages, id: sessionID) }
            return await finalize(snapshot, status: result.outcome.status, usage: result.outcome.usage, error: result.outcome.errorSummary, receipt: result.receipt)
        }
        return runID
    }

    /// Keeps a session transcript bounded: old tool output is the first thing to go.
    static func trimmed(_ messages: [LLMMessage]) -> [LLMMessage] {
        guard messages.count > 80 else { return messages }
        var start = messages.count - 60
        while start < messages.count && !(messages[start].role == .user && messages[start].toolUses.isEmpty && !messages[start].text.isEmpty) { start += 1 }
        return start < messages.count ? Array(messages[start...]) : Array(messages.suffix(2))
    }

    nonisolated func makeObserver(_ runID: String) -> AgentObserver {
        var o = AgentObserver()
        let hub = live
        o.onTextDelta = { hub.publish(runID, .text($0)) }
        o.onReasoningDelta = { hub.publish(runID, .reasoning($0)) }
        o.onToolStarted = { hub.publish(runID, .toolStarted($0)) }
        o.onToolProgress = { hub.publish(runID, .toolProgress(callID: $0, $1)) }
        o.onToolFinished = { hub.publish(runID, .toolFinished($0, $1)) }
        o.onPlan = { hub.publish(runID, .plan($0)) }
        o.onUsage = { hub.publish(runID, .usage($0)) }
        o.onStatus = { [weak self] s in
            hub.publish(runID, .status(s))
            Task { await self?.noteStatus(runID, s) }
        }
        return o
    }

    func noteStatus(_ runID: String, _ status: RunStatus) async {
        guard tasks[runID] != nil, !status.isTerminal, var r = try? await store.run(id: runID), !r.status.isTerminal else { return }
        r.status = status
        try? await store.saveRun(r)
    }

    /// Writes the final record and receipt, releases run-scoped authority and resources.
    func finalize(_ record: RunRecord, status: RunStatus, usage: RunUsage, error: String?, receipt: RunReceipt?) async -> RunRecord {
        var r = record
        r.status = status; r.endedAt = Date(); r.usage = usage; r.errorSummary = error.map { Redactor.shared.redact($0) }
        if var receipt {
            let events = (try? await store.events(runID: r.id, afterSeq: 0, limit: 5000)) ?? []
            receipt.approvals = events.filter { $0.kind == .approvalResolved }.map { e in
                let approved = e.data["approved"]?.boolValue ?? false
                return "\(approved ? "Approved" : "Not approved") (\(e.text)) at \(ISO8601DateFormatter().string(from: e.timestamp))"
            }
            try? await store.saveReceipt(receipt)
        }
        try? await store.saveRun(r)
        await policy.revokeRun(runID: r.id)
        await executor.forgetRun(r.id)
        _ = await browser.close(runID: r.id)
        controls[r.id] = nil; tasks[r.id] = nil; cancelers[r.id] = nil
        live.publish(r.id, .finished(status))
        live.finish(r.id)
        return r
    }

    /// Continues an agent run left `RECOVERY_REQUIRED` by a crash, from its checkpoint.
    public func resumeAgentRun(runID: String, resolution: InFlightResolution) async throws {
        guard let cp = await checkpoints.load(runID: runID), var record = try await store.run(id: runID) else { throw RunError.notFound("A checkpoint for this run") }
        let settings = await settings()
        var task = cp.task
        task.budget = try await capped(task.budget, settings: settings)
        _ = try await grantWorkspace(.read, directory: task.workingDirectory, runID: runID)
        record.status = .recovering; record.endedAt = nil
        try await store.saveRun(record)
        let runtime = AgentRuntime(deps: AgentDependencies(providers: providers, tools: executor, events: store, memory: memory, checkpoints: checkpoints,
                                                           interaction: interaction, agents: agents, artifactsRoot: paths.artifacts))
        let control = RunControl(); controls[runID] = control
        let observer = makeObserver(runID)
        let frozen = task
        let snapshot = record
        tasks[runID] = Task { [self] in
            let result = await runtime.execute(task: frozen, profile: cp.profile, runID: runID, control: control, observer: observer, resumeFrom: cp, inFlight: resolution)
            return await finalize(snapshot, status: result.outcome.status, usage: result.outcome.usage, error: result.outcome.errorSummary, receipt: result.receipt)
        }
    }

    // MARK: Generic run registration (workflows)

    func register(runID: String, task: Task<RunRecord, Never>, cancel: @escaping @Sendable () async -> Void) {
        tasks[runID] = task; cancelers[runID] = cancel
    }

    // MARK: Control

    public func activeRunIDs() -> [String] { Array(tasks.keys) }
    public func isActive(_ runID: String) -> Bool { tasks[runID] != nil }

    public func cancel(runID: String) async {
        await controls[runID]?.cancel()
        await cancelers[runID]?()
        await executor.cancel(runID: runID)
        await approvals.denyAll(runID: runID, reason: "The run was canceled.")
    }
    public func pause(runID: String) async { await controls[runID]?.pause() }
    public func resume(runID: String) async { await controls[runID]?.resume() }
    public func steer(runID: String, _ text: String) async { await controls[runID]?.steer(text) }

    /// Waits for a run to end and returns its final record.
    public func wait(runID: String) async -> RunRecord? {
        if let t = tasks[runID] { return await t.value }
        return try? await store.run(id: runID)
    }

    /// Stops everything now: model streams, tool calls, every child process group, pending approvals, browser sessions.
    /// Persistent grants are not touched; `revokeAllGrants` does that.
    public func emergencyStop() async {
        let ids = Array(tasks.keys)
        await audit.record(AuditEntry(kind: .emergencyStop, detail: "Emergency stop: \(ids.count) run(s) stopped", data: ["runs": .array(ids.map(JSONValue.string))]))
        for id in ids { await controls[id]?.cancel(); await cancelers[id]?() }
        await executor.cancelAll()
        runner.killAll()
        await approvals.denyAll(reason: "Emergency stop")
        await interaction.cancelAll()
        await browser.closeAll()
    }

    public func revokeAllGrants() async { await policy.revokeAll() }

    /// Marks runs left in flight by a process that died as `RECOVERY_REQUIRED`. Call once at start-up with the process start time.
    public func recoverInterrupted(startedAt: Date) async -> [RunRecord] {
        (try? await store.markInterruptedRuns(olderThan: startedAt)) ?? []
    }
}
