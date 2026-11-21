// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Engine.swift
// Description      : Workflow engine entry point and its contracts: injected
//                    dependencies, run options, step results, outcome,
//                    checkpoints and clocks.
// Module           : ORIXWorkflowEngine
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
import ORIXCore

// MARK: - Results

public enum StepStatus: String, Codable, Sendable, CaseIterable {
    case pending, running, succeeded
    /// Dry run: nothing was changed. The step's note says exactly what was simulated.
    case simulated
    case skipped, failed, timedOut, canceled
    /// A tool reported `notApproved`, or an approval gate was left unanswered.
    case notApproved
    /// A macOS privacy permission is missing.
    case blockedPermission
    case budgetExceeded
    /// The step was mid-flight when the previous process stopped and is not idempotent.
    case recoveryRequired

    public var isSuccess: Bool { self == .succeeded || self == .simulated }
    public var isTerminal: Bool { self != .pending && self != .running }
}

public struct StepResult: Codable, Sendable, Hashable, Identifiable {
    /// Instance key: the step id prefixed by its container path (`each[2]/copy`, `par(left)/a`, `poll#3/check`, `sub>/inner`).
    public var key: String
    public var stepID: String
    public var kind: String
    public var status: StepStatus
    public var output: JSONValue
    public var attempts: Int
    public var startedAt: Date?
    public var endedAt: Date?
    public var error: String?
    public var errorCode: String?
    /// Id of the `onError` step that handled the failure.
    public var handledBy: String?
    /// True when the failure did not stop the scope (`continueOnError` or a successful handler).
    public var continued: Bool
    /// Why the step was skipped, or what a dry run simulated.
    public var note: String?

    public var id: String { key }
    public var durationSeconds: Double? {
        guard let s = startedAt, let e = endedAt else { return nil }
        return e.timeIntervalSince(s)
    }

    public init(key: String, stepID: String, kind: String, status: StepStatus, output: JSONValue = .null, attempts: Int = 0,
                startedAt: Date? = nil, endedAt: Date? = nil, error: String? = nil, errorCode: String? = nil, handledBy: String? = nil,
                continued: Bool = false, note: String? = nil) {
        self.key = key; self.stepID = stepID; self.kind = kind; self.status = status; self.output = output; self.attempts = attempts
        self.startedAt = startedAt; self.endedAt = endedAt; self.error = error; self.errorCode = errorCode
        self.handledBy = handledBy; self.continued = continued; self.note = note
    }
}

public struct WorkflowOutcome: Codable, Sendable, Hashable {
    public var runID: String
    public var workflowID: String
    public var status: RunStatus
    public var dryRun: Bool
    /// Step results in completion order (nested instances included).
    public var steps: [StepResult]
    public var outputs: [String: JSONValue]
    public var artifacts: [Artifact]
    public var verifications: [VerificationResult]
    public var usage: RunUsage
    /// Dry run only: one line per step saying exactly what was simulated and what was not executed.
    public var simulations: [String]
    public var errors: [String]
    /// Expression evaluation errors and similar run-time diagnostics, each with its step id.
    public var diagnostics: [WorkflowDiagnostic]
    public var startedAt: Date
    public var endedAt: Date
    /// Last checkpoint, usable with `WorkflowEngine.resume(from:)` when the status allows it.
    public var checkpoint: WorkflowCheckpoint?

    /// Latest result of a step by id (for steps run several times in a loop, the last instance).
    public func step(_ id: String) -> StepResult? { steps.last { $0.stepID == id } }
    public func results(for id: String) -> [StepResult] { steps.filter { $0.stepID == id } }
}

// MARK: - Checkpoints

public struct InFlightStep: Codable, Sendable, Hashable {
    public var key: String
    public var stepID: String
    public var kind: String
    /// True when running the step again cannot cause additional effects.
    public var idempotent: Bool
    /// Containers are re-entered on resume; only their unfinished children run.
    public var isContainer: Bool
}

public struct WorkflowCheckpoint: Codable, Sendable, Hashable {
    public var runID: String
    public var workflowID: String
    /// Increases with every save. Saves can reach a store out of order: keep the highest sequence.
    public var sequence: Int
    public var savedAt: Date
    public var document: WorkflowDocument
    public var parameters: [String: JSONValue]
    public var dryRun: Bool
    public var mode: ExecutionMode
    /// Variables per frame (`""` is the workflow itself, `<key>>` a subworkflow).
    public var variables: [String: [String: JSONValue]]
    public var results: [String: StepResult]
    /// Progress of containers: evaluated `foreach` items, current `while` iteration.
    public var containerState: [String: JSONValue]
    public var inFlight: [InFlightStep]
    public var usage: RunUsage
    public var artifacts: [Artifact]
    public var verifications: [VerificationResult]
    public var outputs: [String: [String: JSONValue]]
    public var startedAt: Date
}

public protocol WorkflowCheckpointStoring: Sendable {
    func save(_ checkpoint: WorkflowCheckpoint) async
    func latest(runID: String) async -> WorkflowCheckpoint?
    func remove(runID: String) async
}

/// Keeps checkpoints in memory. `history` keeps every save (tests use it to simulate a crash at any point).
public actor InMemoryCheckpointStore: WorkflowCheckpointStoring {
    private var latestByRun: [String: WorkflowCheckpoint] = [:]
    public private(set) var history: [WorkflowCheckpoint] = []
    private let keepHistory: Bool

    public init(keepHistory: Bool = false) { self.keepHistory = keepHistory }

    public func save(_ checkpoint: WorkflowCheckpoint) {
        if keepHistory { history.append(checkpoint) }
        if let current = latestByRun[checkpoint.runID], current.sequence > checkpoint.sequence { return }
        latestByRun[checkpoint.runID] = checkpoint
    }

    public func latest(runID: String) -> WorkflowCheckpoint? { latestByRun[runID] }
    public func remove(runID: String) { latestByRun[runID] = nil }
}

// MARK: - Dependencies

public protocol SubworkflowLoading: Sendable {
    /// Returns the workflow named by a `subworkflow:` step (id or name). Throws when it cannot be found.
    func loadWorkflow(_ reference: String) async throws -> WorkflowDocument
}

public struct DictionarySubworkflowLoader: SubworkflowLoading {
    public struct NotFound: Error, LocalizedError {
        public let reference: String
        public var errorDescription: String? { "no workflow named '\(reference)'" }
    }
    private let documents: [String: WorkflowDocument]
    public init(_ documents: [WorkflowDocument]) {
        var d: [String: WorkflowDocument] = [:]
        for doc in documents { d[doc.metadata.name] = doc; d[doc.metadata.id] = doc }
        self.documents = d
    }
    public func loadWorkflow(_ reference: String) async throws -> WorkflowDocument {
        guard let d = documents[reference] else { throw NotFound(reference: reference) }
        return d
    }
}

/// Time source for delays, retry backoff, timestamps and the duration budget. Step timeouts always use real time.
public protocol WorkflowClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

public struct SystemWorkflowClock: WorkflowClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400 * 365) * 1_000_000_000))
    }
}

/// A clock for tests and previews: `sleep` returns at once, advances the virtual time and records the request.
public final class VirtualWorkflowClock: WorkflowClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var recorded: [Double] = []

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    public func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
    public var sleeps: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
    public func advance(by seconds: Double) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }

    public func sleep(seconds: Double) async throws {
        try Task.checkCancellation()
        lock.withLock {
            recorded.append(seconds)
            current = current.addingTimeInterval(max(0, seconds))
        }
    }
}

public struct WorkflowApprovalPrompt: Sendable, Hashable, Identifiable {
    public var id: String
    public var runID: String
    public var workflowID: String
    public var stepID: String
    public var message: String
}

/// Asks a person to let an `approval` step pass. Headless runs answer `.unanswered`.
public typealias WorkflowApprovalHandler = @Sendable (WorkflowApprovalPrompt) async -> ApprovalResponse

/// Resolves a named agent profile for `agent: <name>` steps.
public typealias AgentProfileResolver = @Sendable (String) async -> AgentProfile?

public enum InFlightResolution: Sendable, Hashable {
    /// The operator checked that running the step again is safe.
    case rerun
    /// The operator checked that the step's effect happened; continue with this output.
    case markSucceeded(output: JSONValue)
}

public struct WorkflowRunOptions: Sendable {
    public var runID: String
    public var parameters: [String: JSONValue]
    public var mode: ExecutionMode
    /// Tools that support it are invoked with `dryRun: true`; everything else is reported as not executed.
    public var dryRun: Bool
    public var workingDirectory: URL
    public var artifactsDirectory: URL
    public var breakpoints: Set<String>
    /// Start paused before the first step (step debugger).
    public var startPaused: Bool
    /// Decisions for non-idempotent steps that were mid-flight in the checkpoint being resumed, by instance key.
    public var inFlightResolutions: [String: InFlightResolution]

    public init(runID: String = UUID().uuidString, parameters: [String: JSONValue] = [:], mode: ExecutionMode = .guided, dryRun: Bool = false,
                workingDirectory: URL, artifactsDirectory: URL, breakpoints: Set<String> = [], startPaused: Bool = false,
                inFlightResolutions: [String: InFlightResolution] = [:]) {
        self.runID = runID; self.parameters = parameters; self.mode = mode; self.dryRun = dryRun
        self.workingDirectory = workingDirectory; self.artifactsDirectory = artifactsDirectory
        self.breakpoints = breakpoints; self.startPaused = startPaused; self.inFlightResolutions = inFlightResolutions
    }
}

public struct WorkflowEngineConfiguration: Sendable {
    /// Leaf steps (tool calls, agents) running at the same time, across all nesting levels.
    public var maxConcurrentSteps: Int
    public var maxSubworkflowDepth: Int
    /// Upper bound handed to the tool invoker for every call.
    public var maxToolSeconds: Double
    /// Model of inline agents that do not name one. Nil makes such a step fail with a clear message.
    public var defaultModel: ModelRef?
    public var maxForeachItems: Int

    public init(maxConcurrentSteps: Int = 4, maxSubworkflowDepth: Int = 8, maxToolSeconds: Double = 600, defaultModel: ModelRef? = nil,
                maxForeachItems: Int = 10_000) {
        self.maxConcurrentSteps = max(1, maxConcurrentSteps); self.maxSubworkflowDepth = maxSubworkflowDepth
        self.maxToolSeconds = maxToolSeconds; self.defaultModel = defaultModel; self.maxForeachItems = maxForeachItems
    }
}

struct EngineDependencies: Sendable {
    var tools: any ToolInvoking
    var agents: (any AgentRunning)?
    var events: (any RunEventSink)?
    var checkpoints: any WorkflowCheckpointStoring
    var loader: (any SubworkflowLoading)?
    var approval: WorkflowApprovalHandler?
    var agentProfiles: AgentProfileResolver?
    var clock: any WorkflowClock
    var configuration: WorkflowEngineConfiguration
}

/// What the debugger and the live graph bind to.
public struct WorkflowRunState: Sendable, Hashable {
    public var runID: String
    public var status: RunStatus
    public var pauseRequested: Bool
    /// Step ids waiting at the debugger gate, in arrival order. `stepOver()` releases the first one.
    public var pausedAt: [String]
    /// Instance keys of steps currently executing.
    public var running: [String]
    /// Status of every step instance that has started or finished, by instance key.
    public var steps: [String: StepStatus]
    public var breakpoints: Set<String>
    public var sequence: Int
}

// MARK: - Engine

/// Executes workflow documents. One engine serves many runs; every run is controlled through its `WorkflowRun` handle.
public actor WorkflowEngine {
    private let dependencies: EngineDependencies
    private var active: [String: WorkflowRun] = [:]

    public init(tools: any ToolInvoking, agents: (any AgentRunning)? = nil, events: (any RunEventSink)? = nil,
                checkpoints: any WorkflowCheckpointStoring = InMemoryCheckpointStore(), loader: (any SubworkflowLoading)? = nil,
                approval: WorkflowApprovalHandler? = nil, agentProfiles: AgentProfileResolver? = nil,
                clock: any WorkflowClock = SystemWorkflowClock(), configuration: WorkflowEngineConfiguration = .init()) {
        dependencies = EngineDependencies(tools: tools, agents: agents, events: events, checkpoints: checkpoints, loader: loader,
                                          approval: approval, agentProfiles: agentProfiles, clock: clock, configuration: configuration)
    }

    /// Starts a run and returns its control handle immediately.
    public func start(_ document: WorkflowDocument, options: WorkflowRunOptions) async -> WorkflowRun {
        let run = WorkflowRun(document: document, options: options, dependencies: dependencies, restored: nil) { [weak self] id in
            await self?.forget(id)
        }
        active[options.runID] = run
        await run.start()
        return run
    }

    /// Runs to the end and returns the outcome.
    public func run(_ document: WorkflowDocument, options: WorkflowRunOptions) async -> WorkflowOutcome {
        await start(document, options: options).outcome()
    }

    /// Continues a run from a checkpoint: completed steps are not run again. `options` defaults to the checkpoint's own
    /// run id, parameters and mode. A non-idempotent step that was mid-flight ends the run at once with
    /// `RECOVERY_REQUIRED` unless `options.inFlightResolutions` says what to do with it.
    public func resume(from checkpoint: WorkflowCheckpoint, options: WorkflowRunOptions) async -> WorkflowRun {
        var opts = options
        opts.runID = checkpoint.runID
        opts.parameters = checkpoint.parameters
        opts.dryRun = checkpoint.dryRun
        let run = WorkflowRun(document: checkpoint.document, options: opts, dependencies: dependencies, restored: checkpoint) { [weak self] id in
            await self?.forget(id)
        }
        active[opts.runID] = run
        await run.start()
        return run
    }

    public func run(id: String) -> WorkflowRun? { active[id] }
    public var activeRunIDs: [String] { active.keys.sorted() }

    /// Emergency stop for every run of this engine.
    public func cancelAll() async {
        for run in active.values { await run.cancel() }
    }

    private func forget(_ id: String) { active[id] = nil }

    /// Final run status caused by one step that failed without `continueOnError` or a successful handler (CLAUDE.md §16).
    public static func runStatus(forUnhandled status: StepStatus) -> RunStatus {
        switch status {
        case .notApproved: return .waitingApproval
        case .blockedPermission: return .blockedPermission
        case .timedOut: return .timedOut
        case .budgetExceeded: return .budgetExceeded
        case .recoveryRequired: return .recoveryRequired
        case .canceled: return .canceled
        case .failed, .pending, .running, .skipped, .succeeded, .simulated: return .failed
        }
    }

    /// Step status for a tool result status.
    public static func stepStatus(for status: ToolStatus) -> StepStatus {
        switch status {
        case .succeeded: return .succeeded
        case .simulated: return .simulated
        case .notApproved: return .notApproved
        case .blockedPermission: return .blockedPermission
        case .timedOut: return .timedOut
        case .canceled: return .canceled
        case .failed, .denied, .invalidInput, .unsupported: return .failed
        }
    }

    /// Checks supplied parameter values against the declared parameters and fills defaults.
    public static func resolveParameters(_ document: WorkflowDocument, provided: [String: JSONValue]) -> Result<[String: JSONValue], WorkflowExpressionError> {
        var out: [String: JSONValue] = [:]
        let declared = Set(document.spec.parameters.map(\.name))
        if let unknown = provided.keys.sorted().first(where: { !declared.contains($0) }) {
            return .failure(WorkflowExpressionError(message: "unknown parameter '\(unknown)'"))
        }
        for p in document.spec.parameters {
            if let v = provided[p.name], !v.isNull {
                guard Validation.value(v, matches: p.type) else {
                    return .failure(WorkflowExpressionError(message: "parameter '\(p.name)' must be of type \(p.type.rawValue)"))
                }
                out[p.name] = v
            } else if let d = p.defaultValue {
                do { out[p.name] = try WorkflowExpression.resolve(d, context: ExpressionContext(params: out)) }
                catch let e as WorkflowExpressionError { return .failure(WorkflowExpressionError(message: "default of parameter '\(p.name)': \(e.message)")) }
                catch { return .failure(WorkflowExpressionError(message: "default of parameter '\(p.name)': \(error)")) }
            } else if p.required {
                return .failure(WorkflowExpressionError(message: "missing required parameter '\(p.name)'"))
            } else {
                out[p.name] = .null
            }
        }
        return .success(out)
    }
}
