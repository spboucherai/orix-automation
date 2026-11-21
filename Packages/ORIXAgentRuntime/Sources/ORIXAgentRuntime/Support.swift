// ORIX OS Automation
// File: Packages/ORIXAgentRuntime/Sources/ORIXAgentRuntime/Support.swift
// Description: Runtime collaborators: run control (pause, cancel, steer), observers, user interaction, memory, checkpoints, agent directory, options and results.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

/// Controls one run from outside: emergency stop, pause before the next side effect, queued steering messages.
public actor RunControl {
    public enum StopReason: Sendable { case user, timeout }
    private var task: Task<AgentRunResult, Never>?
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var steering: [String] = []
    public private(set) var stopReason: StopReason?

    public init() {}

    func attach(_ task: Task<AgentRunResult, Never>) {
        self.task = task
        if stopReason != nil { task.cancel() }
    }

    /// Stops the run: cancels the model stream and the in-flight tool call.
    public func cancel() { stop(.user) }

    func stop(_ reason: StopReason) {
        if stopReason == nil { stopReason = reason }
        task?.cancel()
        resume()
    }

    /// The agent finishes what is in flight and stops before its next side-effecting action.
    public func pause() { paused = true }

    public func resume() {
        paused = false
        let w = waiters; waiters = []
        for c in w { c.resume() }
    }

    public var isPaused: Bool { paused }

    func waitWhilePaused() async {
        guard paused, stopReason == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Queues an instruction from the user; it is delivered at the next turn boundary.
    public func steer(_ message: String) { steering.append(message) }

    func drainSteering() -> [String] { let s = steering; steering = []; return s }
}

/// Live, non-persisted callbacks for the UI. Persisted history goes through `RunEventSink`.
public struct AgentObserver: Sendable {
    public var onTextDelta: @Sendable (String) -> Void = { _ in }
    public var onReasoningDelta: @Sendable (String) -> Void = { _ in }
    public var onToolStarted: @Sendable (ToolCall) -> Void = { _ in }
    public var onToolFinished: @Sendable (ToolCall, ToolResult) -> Void = { _, _ in }
    /// Streaming output of a running tool (stdout/stderr of a subprocess), keyed by call id.
    public var onToolProgress: @Sendable (String, ToolProgress) -> Void = { _, _ in }
    public var onPlan: @Sendable (AgentPlan) -> Void = { _ in }
    public var onStatus: @Sendable (RunStatus) -> Void = { _ in }
    public var onUsage: @Sendable (RunUsage) -> Void = { _ in }
    public init() {}
}

public enum PlanReview: Sendable, Hashable {
    case approved
    case revise(feedback: String)
    case rejected
}

/// How the runtime reaches a person. Headless runs pass nil: questions go unanswered, plans are not auto-approved in guided mode.
public protocol UserInteracting: Sendable {
    func ask(question: String, runID: String) async -> String?
    func review(plan: AgentPlan, runID: String) async -> PlanReview
}

public protocol MemoryStoring: Sendable {
    func memories(scopes: [MemoryRecord.Scope]) async -> [MemoryRecord]
    func save(_ record: MemoryRecord) async
}

public struct AgentCheckpoint: Codable, Sendable, Hashable {
    public var runID: String
    public var task: AgentTask
    public var profile: AgentProfile
    public var messages: [LLMMessage]
    public var usage: RunUsage
    public var plan: AgentPlan?
    public var toolCalls: [ToolCallRecord]
    public var turn: Int
    /// A side-effecting call that had started but not returned when the checkpoint was written. Resuming must not blindly repeat it.
    public var inFlightCall: ToolCall?
    public var savedAt: Date
    public var modelVersion: Int
}

public protocol AgentCheckpointStoring: Sendable {
    func save(_ checkpoint: AgentCheckpoint) async
    func load(runID: String) async -> AgentCheckpoint?
    func clear(runID: String) async
}

/// Named agent profiles available for delegation.
public protocol AgentDirectory: Sendable {
    func profile(named name: String) async -> AgentProfile?
    func profileNames() async -> [String]
}

public struct AgentRunOptions: Sendable {
    /// Transient provider failures: attempts per turn, including the first.
    public var maxProviderAttempts = 3
    public var retryBaseDelaySeconds = 1.0
    /// Estimated context size (tokens) above which older turns are compacted. Nil derives it from the model's context window.
    public var compactionThresholdTokens: Int?
    /// Bytes of one tool result returned to the model.
    public var maxToolResultBytes = 24_000
    /// Identical consecutive calls tolerated before the run is stopped as a loop.
    public var maxIdenticalCalls = 4
    /// Optional independent verifier model. Its verdict can lower the status, never raise it.
    public var verifier: ModelRef?
    public var maxDelegationDepth = 2
    public var maxOutputTokensPerTurn = 4096
    public init() {}
}

public struct AgentRunResult: Sendable {
    public var outcome: AgentOutcome
    public var receipt: RunReceipt
    public var messages: [LLMMessage]
    public var plan: AgentPlan?
}

public struct AgentDependencies: Sendable {
    public var providers: any ProviderResolving
    public var tools: any ToolInvoking
    public var events: any RunEventSink
    public var memory: (any MemoryStoring)?
    public var checkpoints: (any AgentCheckpointStoring)?
    public var interaction: (any UserInteracting)?
    public var agents: (any AgentDirectory)?
    /// Run artifacts are stored under `<artifactsRoot>/<runID>/`.
    public var artifactsRoot: URL
    public var sleep: @Sendable (Double) async -> Void

    public init(providers: any ProviderResolving, tools: any ToolInvoking, events: any RunEventSink, memory: (any MemoryStoring)? = nil,
                checkpoints: (any AgentCheckpointStoring)? = nil, interaction: (any UserInteracting)? = nil,
                agents: (any AgentDirectory)? = nil, artifactsRoot: URL,
                sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }) {
        self.providers = providers; self.tools = tools; self.events = events; self.memory = memory; self.checkpoints = checkpoints
        self.interaction = interaction; self.agents = agents; self.artifactsRoot = artifactsRoot; self.sleep = sleep
    }
}

public actor InMemoryCheckpointStore: AgentCheckpointStoring {
    private var items: [String: AgentCheckpoint] = [:]
    public init() {}
    public func save(_ checkpoint: AgentCheckpoint) async { items[checkpoint.runID] = checkpoint }
    public func load(runID: String) async -> AgentCheckpoint? { items[runID] }
    public func clear(runID: String) async { items[runID] = nil }
}

public actor InMemoryMemoryStore: MemoryStoring {
    public private(set) var records: [MemoryRecord] = []
    public init(_ records: [MemoryRecord] = []) { self.records = records }
    public func memories(scopes: [MemoryRecord.Scope]) async -> [MemoryRecord] {
        let keys = Set(scopes.map(\.key))
        return records.filter { keys.contains($0.scope.key) }
    }
    public func save(_ record: MemoryRecord) async { records.append(record) }
}
