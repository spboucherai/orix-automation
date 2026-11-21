// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Run.swift
// Description      : One workflow run: scheduling, step dispatch, retries,
//                    timeouts, error routing, budgets, debugger gate,
//                    checkpoints and the final outcome.
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

/// Control handle and executor of one run. The debugger UI binds to `states()`, `pause()`, `resume()`, `stepOver()`, `cancel()`.
public actor WorkflowRun {
    public nonisolated let runID: String
    public nonisolated let workflowID: String
    public nonisolated let document: WorkflowDocument
    public nonisolated let isDryRun: Bool

    private struct Frame {
        var document: WorkflowDocument
        var params: [String: JSONValue]
        var vars: [String: JSONValue]
        /// Canonical roots `verify` may inspect: declared filesystem permissions.
        var readableRoots: [String]
    }

    /// Where a step list runs: result namespace, visible outer namespaces, variable frame and loop variables.
    private struct Scope: Sendable {
        var prefix: String
        var chain: [String]
        var frame: String
        var locals: [String: JSONValue]
        var depth: Int
    }

    private struct Exec: Sendable {
        var status: StepStatus
        var output: JSONValue = .null
        var error: String?
        var code: String?
        var note: String?

        static func failed(_ message: String, code: String) -> Exec { Exec(status: .failed, error: message, code: code) }
        static func ok(_ output: JSONValue = .null) -> Exec { Exec(status: .succeeded, output: output) }
        static func simulated(_ note: String, output: JSONValue = .null) -> Exec { Exec(status: .simulated, output: output, note: note) }
        static let canceled = Exec(status: .canceled, error: "canceled", code: "canceled")
    }

    private enum Halt { case canceled, timedOut(String), budget(String) }
    private enum Race: Sendable { case done(Exec), timeout, sleeperCanceled }

    private let deps: EngineDependencies
    private let options: WorkflowRunOptions
    private let restored: WorkflowCheckpoint?
    private let onFinished: @Sendable (String) async -> Void
    private let environment: [String: String]

    private var status: RunStatus = .queued
    private var frames: [String: Frame] = [:]
    private var restoredVariables: [String: [String: JSONValue]] = [:]
    private var results: [String: StepResult] = [:]
    private var order: [String] = []
    private var views: [String: [String: JSONValue]] = [:]
    private var containerState: [String: JSONValue] = [:]
    private var inFlight: [String: InFlightStep] = [:]
    private var manifests: [String: ToolManifest] = [:]
    private var usage = RunUsage()
    private var artifacts: [Artifact] = []
    private var verifications: [VerificationResult] = []
    private var frameOutputs: [String: [String: JSONValue]] = [:]
    private var simulations: [String] = []
    private var errors: [String] = []
    private var diagnostics: [WorkflowDiagnostic] = []
    private var halt: Halt?
    private var anyContinued = false
    private var startedAt: Date
    private var checkpointSequence = 0
    private var lastCheckpoint: WorkflowCheckpoint?

    // Debugger
    private var pauseRequested: Bool
    private var breakpoints: Set<String>
    private var gateWaiters: [(id: String, continuation: CheckedContinuation<Void, Never>)] = []
    private var stepCredits = 0
    private var busyLeaves = 0
    private var pendingApprovals: [String: CheckedContinuation<ApprovalResponse, Never>] = [:]

    // Concurrency gate
    private var activeSlots = 0
    private var slotWaiters: [CheckedContinuation<Bool, Never>] = []

    // Lifecycle
    private var rootTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var finalOutcome: WorkflowOutcome?
    /// Set when the final status is being computed; nothing may change the status afterwards.
    private var finishing = false
    private var outcomeWaiters: [CheckedContinuation<WorkflowOutcome, Never>] = []
    private var stateSequence = 0
    private var stateContinuations: [UUID: AsyncStream<WorkflowRunState>.Continuation] = [:]
    private let eventStream: AsyncStream<RunEvent>
    private let eventContinuation: AsyncStream<RunEvent>.Continuation
    private var eventPump: Task<Void, Never>?

    init(document: WorkflowDocument, options: WorkflowRunOptions, dependencies: EngineDependencies, restored: WorkflowCheckpoint?,
         onFinished: @escaping @Sendable (String) async -> Void) {
        runID = options.runID
        workflowID = document.metadata.id
        self.document = document
        isDryRun = options.dryRun
        deps = dependencies
        self.options = options
        self.restored = restored
        self.onFinished = onFinished
        pauseRequested = options.startPaused
        breakpoints = options.breakpoints
        startedAt = dependencies.clock.now()
        environment = WorkflowExpression.defaultEnvironment(now: dependencies.clock.now(), timeZone: .current)
        (eventStream, eventContinuation) = AsyncStream<RunEvent>.makeStream()
    }

    // MARK: - Public control surface

    /// Current state snapshot.
    public var state: WorkflowRunState {
        WorkflowRunState(runID: runID, status: status, pauseRequested: pauseRequested, pausedAt: gateWaiters.map(\.id),
                         running: inFlight.keys.sorted(), steps: currentStepStatuses(), breakpoints: breakpoints, sequence: stateSequence)
    }

    /// A stream of state snapshots: the current one first, then one per change, ending when the run ends.
    public func states() -> AsyncStream<WorkflowRunState> {
        let (stream, continuation) = AsyncStream<WorkflowRunState>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuation.yield(state)
        if finalOutcome != nil { continuation.finish(); return stream }
        let id = UUID()
        stateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.dropStateContinuation(id) } }
        return stream
    }

    private func dropStateContinuation(_ id: UUID) { stateContinuations[id] = nil }

    /// Waits for the run to end.
    public func outcome() async -> WorkflowOutcome {
        if let finalOutcome { return finalOutcome }
        return await withCheckedContinuation { outcomeWaiters.append($0) }
    }

    public var isFinished: Bool { finalOutcome != nil }

    /// Stops before the next step starts. Steps already running finish.
    public func pause() {
        guard !finishing else { return }
        pauseRequested = true
        refreshStatus()
    }

    /// Leaves the paused state; runs until the next breakpoint.
    public func resume() {
        pauseRequested = false
        stepCredits = 0
        let waiting = gateWaiters
        gateWaiters = []
        for w in waiting { w.continuation.resume() }
        refreshStatus()
    }

    /// Lets exactly one waiting step run, then pauses again before the next one.
    public func stepOver() {
        guard !finishing else { return }
        pauseRequested = true
        if gateWaiters.isEmpty { stepCredits += 1 } else { gateWaiters.removeFirst().continuation.resume() }
        refreshStatus()
    }

    /// Cancels the run; cancellation reaches running tools, agents and delays through task cancellation.
    public func cancel() { setHalt(.canceled) }

    public func setBreakpoints(_ ids: Set<String>) { breakpoints = ids; publish() }
    public func addBreakpoint(_ id: String) { breakpoints.insert(id); publish() }
    public func removeBreakpoint(_ id: String) { breakpoints.remove(id); publish() }

    /// Workflow variables (root frame), for the debugger's inspector.
    public func variables() -> [String: JSONValue] { frames[""]?.vars ?? [:] }
    public func parameters() -> [String: JSONValue] { frames[""]?.params ?? [:] }

    /// Changes a workflow variable. Meant to be used while paused; takes effect for steps that start afterwards.
    public func setVariable(_ name: String, to value: JSONValue) {
        frames[""]?.vars[name] = value
        emit(.log, text: "variable '\(name)' was modified from the debugger")
    }

    /// Result of a step instance by key or, failing that, the latest result of a step id.
    public func inspect(_ keyOrID: String) -> StepResult? {
        results[keyOrID] ?? order.reversed().compactMap { results[$0] }.first { $0.stepID == keyOrID }
    }

    // MARK: - Lifecycle

    func start() {
        guard rootTask == nil else { return }
        let stream = eventStream
        let sink = deps.events
        eventPump = Task { for await e in stream { await sink?.emit(e) } }
        rootTask = Task { await self.execute() }
    }

    private func execute() async {
        for m in await deps.tools.manifests() { manifests[m.identifier] = m }
        if let cp = restored {
            setStatus(.recovering)
            if restore(cp) { await finish(nil); return }
        }
        let structural = WorkflowValidator.structuralErrors(document)
        if !structural.isEmpty {
            errors.append(contentsOf: structural.map { "invalid workflow: \($0.message)" })
            diagnostics.append(contentsOf: structural)
            await finish(StepResult(key: "", stepID: "", kind: "workflow", status: .failed, error: errors.first))
            return
        }
        if frames[""] == nil {
            switch WorkflowEngine.resolveParameters(document, provided: options.parameters) {
            case .failure(let e):
                errors.append(e.message)
                await finish(StepResult(key: "", stepID: "", kind: "workflow", status: .failed, error: e.message))
                return
            case .success(let params):
                if let problem = makeFrame("", document: document, params: params) {
                    errors.append(problem)
                    await finish(StepResult(key: "", stepID: "", kind: "workflow", status: .failed, error: problem))
                    return
                }
            }
        }
        setStatus(.running)
        if let limit = document.spec.budget.maxDurationSeconds, limit > 0 {
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(min(limit, 86_400 * 365) * 1_000_000_000))
                if !Task.isCancelled { await self?.setHalt(.timedOut("the workflow ran longer than budget.maxDurationSeconds (\(Self.trim(limit)) s)")) }
            }
        }
        let root = Scope(prefix: "", chain: [""], frame: "", locals: [:], depth: 0)
        let failure = await runSteps(document.spec.steps, scope: root)
        if let failure, halt == nil, !document.spec.onError.isEmpty {
            await runErrorHandlers(document.spec.onError, frame: "", outer: root, failure: failure)
        }
        await finish(failure)
    }

    /// Builds a variable frame. Returns a message when the initial variables cannot be evaluated.
    private func makeFrame(_ id: String, document doc: WorkflowDocument, params: [String: JSONValue]) -> String? {
        var vars: [String: JSONValue] = [:]
        if let saved = restoredVariables[id] { vars = saved }
        else {
            let context = ExpressionContext(params: params, environment: environment, now: deps.clock.now())
            for key in doc.spec.variables.keys.sorted() {
                do { vars[key] = try WorkflowExpression.resolve(doc.spec.variables[key]!, context: context) }
                catch { return "variable '\(key)': \(Self.message(error))" }
            }
        }
        var roots: [String] = [PathResolver.resolveSymlinks(options.artifactsDirectory.path)]
        for cap in doc.declaredCapabilities(home: NSHomeDirectory(), parameters: params) {
            switch cap {
            case .fileRead(let p), .fileWrite(let p), .fileDelete(let p): roots.append(p)
            default: break
            }
        }
        frames[id] = Frame(document: doc, params: params, vars: vars, readableRoots: roots)
        return nil
    }

    /// Loads a checkpoint. Returns true when the run must stop at once (recovery required).
    private func restore(_ cp: WorkflowCheckpoint) -> Bool {
        restoredVariables = cp.variables
        containerState = cp.containerState
        usage = cp.usage
        artifacts = cp.artifacts
        verifications = cp.verifications
        frameOutputs = cp.outputs
        checkpointSequence = cp.sequence
        let kept = cp.results.values.filter { $0.status.isSuccess || $0.continued }
            .sorted { ($0.endedAt ?? .distantPast, $0.key) < ($1.endedAt ?? .distantPast, $1.key) }
        for r in kept { store(r) }
        anyContinued = kept.contains { $0.continued }
        var blocking: [InFlightStep] = []
        for step in cp.inFlight.sorted(by: { $0.key < $1.key }) where results[step.key] == nil && !step.isContainer {
            switch options.inFlightResolutions[step.key] {
            case .markSucceeded(let output)?:
                let now = deps.clock.now()
                store(StepResult(key: step.key, stepID: step.stepID, kind: step.kind, status: .succeeded, output: output, attempts: 1, startedAt: now,
                                 endedAt: now, note: "marked as succeeded by the operator during recovery"))
            case .rerun?: break
            case nil: if !step.idempotent { blocking.append(step) }
            }
        }
        emit(.log, text: "resumed from checkpoint \(cp.sequence): \(kept.count) completed step(s) will not run again")
        guard !blocking.isEmpty else { return false }
        for step in blocking {
            let message = "step '\(step.stepID)' was running when the previous process stopped and is not idempotent; it was not run again"
            errors.append(message + ". Check its effect, then resume with a resolution (rerun or markSucceeded) for key '\(step.key)'.")
            store(StepResult(key: step.key, stepID: step.stepID, kind: step.kind, status: .recoveryRequired, error: message, errorCode: "recovery_required"))
        }
        // Keep the interrupted checkpoint as the one to resume from.
        lastCheckpoint = cp
        return true
    }

    private func store(_ r: StepResult) {
        if results[r.key] == nil { order.append(r.key) }
        results[r.key] = r
        let prefix = r.key.lastIndex(of: "/").map { String(r.key[...$0]) } ?? ""
        views[prefix, default: [:]][r.stepID] = Self.view(r)
    }

    private static func view(_ r: StepResult) -> JSONValue {
        ["status": .string(r.status.rawValue), "output": r.output, "error": r.error.map(JSONValue.string) ?? .null, "attempts": .int(r.attempts)]
    }

    private func setHalt(_ h: Halt) {
        guard halt == nil, !finishing else { return }
        halt = h
        rootTask?.cancel()
        pauseRequested = false
        let waiting = gateWaiters
        gateWaiters = []
        for w in waiting { w.continuation.resume() }
        let slots = slotWaiters
        slotWaiters = []
        for s in slots { s.resume(returning: false) }
        let approvals = pendingApprovals
        pendingApprovals = [:]
        for a in approvals.values { a.resume(returning: .unanswered) }
    }

    private func finish(_ failure: StepResult?) async {
        watchdog?.cancel()
        finishing = true
        let final: RunStatus
        switch halt {
        case .canceled?: final = .canceled
        case .timedOut(let m)?: final = .timedOut; errors.append(m)
        case .budget(let m)?: final = .budgetExceeded; errors.append(m)
        case nil:
            if results.values.contains(where: { $0.status == .recoveryRequired }) { final = .recoveryRequired }
            else if let failure {
                final = WorkflowEngine.runStatus(forUnhandled: failure.status)
                if !failure.stepID.isEmpty { errors.append("step '\(failure.stepID)' \(failure.status.rawValue): \(failure.error ?? "no detail")") }
            } else { final = anyContinued ? .partiallySucceeded : .succeeded }
        }
        if lastCheckpoint == nil || final != .recoveryRequired { await saveCheckpoint(stepID: nil, announce: false) }
        setStatus(final)
        let outcome = WorkflowOutcome(runID: runID, workflowID: workflowID, status: final, dryRun: options.dryRun,
                                      steps: order.compactMap { results[$0] }, outputs: frameOutputs[""] ?? [:], artifacts: artifacts,
                                      verifications: verifications, usage: usage, simulations: simulations, errors: errors,
                                      diagnostics: diagnostics, startedAt: startedAt, endedAt: deps.clock.now(), checkpoint: lastCheckpoint)
        if final == .succeeded && !options.dryRun { await deps.checkpoints.remove(runID: runID) }
        eventContinuation.finish()
        await eventPump?.value
        finalOutcome = outcome
        for c in stateContinuations.values { c.finish() }
        stateContinuations = [:]
        let waiters = outcomeWaiters
        outcomeWaiters = []
        for w in waiters { w.resume(returning: outcome) }
        await onFinished(runID)
    }

    // MARK: - Events, state, checkpoints

    private func emit(_ kind: RunEvent.Kind, step: String? = nil, text: String, data: JSONValue = .null) {
        eventContinuation.yield(RunEvent(runID: runID, timestamp: deps.clock.now(), kind: kind, stepID: step,
                                         text: Redactor.shared.redact(text), data: data))
    }

    private func currentStepStatuses() -> [String: StepStatus] {
        var out: [String: StepStatus] = [:]
        for (k, r) in results { out[k] = r.status }
        for k in inFlight.keys { out[k] = .running }
        return out
    }

    private func publish() {
        stateSequence += 1
        let s = state
        for c in stateContinuations.values { c.yield(s) }
    }

    private func setStatus(_ new: RunStatus) {
        guard new != status else { publish(); return }
        let old = status
        status = new
        emit(.statusChanged, text: "\(old.rawValue) → \(new.rawValue)", data: ["from": .string(old.rawValue), "to": .string(new.rawValue)])
        publish()
    }

    /// Derives the in-flight status from what the run is doing right now.
    private func refreshStatus() {
        guard !finishing, status == .running || status == .paused || status == .waitingApproval else { publish(); return }
        if !pendingApprovals.isEmpty { setStatus(.waitingApproval) }
        else if pauseRequested, !gateWaiters.isEmpty, busyLeaves == 0 { setStatus(.paused) }
        else { setStatus(.running) }
    }

    private func saveCheckpoint(stepID: String?, announce: Bool = true) async {
        checkpointSequence += 1
        var variables: [String: [String: JSONValue]] = [:]
        for (id, f) in frames { variables[id] = f.vars }
        let cp = WorkflowCheckpoint(runID: runID, workflowID: workflowID, sequence: checkpointSequence, savedAt: deps.clock.now(), document: document,
                                    parameters: frames[""]?.params ?? options.parameters, dryRun: options.dryRun, mode: options.mode,
                                    variables: variables, results: results, containerState: containerState,
                                    inFlight: inFlight.values.sorted { $0.key < $1.key }, usage: usage, artifacts: artifacts,
                                    verifications: verifications, outputs: frameOutputs, startedAt: startedAt)
        lastCheckpoint = cp
        await deps.checkpoints.save(cp)
        if announce { emit(.checkpoint, step: stepID, text: "checkpoint \(cp.sequence)", data: ["sequence": .int(cp.sequence)]) }
    }

    // MARK: - Expression context

    private func context(_ scope: Scope) -> ExpressionContext {
        var steps: [String: JSONValue] = [:]
        for prefix in scope.chain.reversed() { for (k, v) in views[prefix] ?? [:] { steps[k] = v } }
        let frame = frames[scope.frame]
        return ExpressionContext(params: frame?.params ?? [:], vars: frame?.vars ?? [:], steps: steps, locals: scope.locals,
                                 environment: environment, now: deps.clock.now())
    }

    private static func message(_ error: Error) -> String {
        (error as? WorkflowExpressionError)?.message ?? (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private static func trim(_ d: Double) -> String { d.rounded() == d && abs(d) < 1e15 ? String(Int(d)) : String(d) }

    private func text(_ template: String, _ scope: Scope) throws -> String {
        try WorkflowExpression.interpolate(template, context: context(scope)).displayString
    }

    // MARK: - Scheduling

    private enum Readiness { case wait, run, skip(String) }

    private func readiness(_ step: WorkflowStep, scope: Scope, gates: [WorkflowStep]) -> Readiness {
        for need in step.needs {
            guard let r = results[scope.prefix + need] else { return .wait }
            if r.status == .skipped { return .skip("'\(need)' was skipped") }
            if !r.status.isSuccess && !r.continued { return .skip("'\(need)' did not succeed") }
        }
        for gate in gates {
            guard let r = results[scope.prefix + gate.id] else { return .wait }
            guard r.status.isSuccess else { return .skip("'\(gate.id)' did not run") }
            switch gate.kind {
            case .condition(let c):
                let branch = r.output["branch"]?.stringValue
                let taken = branch == "then" ? c.then : c.otherwise
                if !taken.contains(step.id) { return .skip("the condition '\(gate.id)' took the '\(branch ?? "?")' branch") }
            case .switch:
                let chosen = r.output["steps"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if !chosen.contains(step.id) { return .skip("the switch '\(gate.id)' selected another case") }
            default: break
            }
        }
        return .run
    }

    /// Runs a step list as a DAG. Returns the first failure that nothing handled, or nil.
    private func runSteps(_ steps: [WorkflowStep], scope: Scope) async -> StepResult? {
        let handlers = Set(steps.compactMap(\.onError))
        var gates: [String: [WorkflowStep]] = [:]
        for s in steps { for target in s.gatedStepIDs { gates[target, default: []].append(s) } }
        var pending = steps.filter { !handlers.contains($0.id) && results[scope.prefix + $0.id] == nil }
        var failure: StepResult?
        var running = 0
        await withTaskGroup(of: StepResult?.self) { group in
            while true {
                // A step's result is stored before its task is handed back by the group (the checkpoint save in between
                // suspends). Look at the stored results too, so that a failure which is already recorded stops the list
                // now, instead of first letting its dependents be marked "skipped" when another task happens to return
                // earlier. Without this the same failed run sometimes listed those dependents and sometimes did not.
                let failureRecorded = steps.contains { s in
                    guard let r = results[scope.prefix + s.id] else { return false }
                    return !r.status.isSuccess && r.status != .skipped && !r.continued
                }
                if failure == nil, !failureRecorded, halt == nil {
                    var progressed = true
                    while progressed {
                        progressed = false
                        var i = 0
                        while i < pending.count {
                            let step = pending[i]
                            switch readiness(step, scope: scope, gates: gates[step.id] ?? []) {
                            case .wait: i += 1
                            case .skip(let why):
                                pending.remove(at: i)
                                progressed = true
                                await complete(StepResult(key: scope.prefix + step.id, stepID: step.id, kind: step.kind.name, status: .skipped,
                                                          endedAt: deps.clock.now(), note: "skipped: \(why)"))
                            case .run:
                                pending.remove(at: i)
                                running += 1
                                group.addTask { await self.executeStep(step, scope: scope, siblings: steps) }
                            }
                        }
                    }
                }
                if running == 0 { break }
                let finished = await group.next() ?? nil
                running -= 1
                if let r = finished, !r.status.isSuccess, r.status != .skipped, !r.continued, failure == nil { failure = r }
            }
        }
        return failure
    }

    private func runErrorHandlers(_ steps: [WorkflowStep], frame: String, outer: Scope, failure: StepResult) async {
        var scope = outer
        scope.prefix = outer.prefix + "!onError/"
        scope.chain = [scope.prefix] + outer.chain
        scope.locals["error"] = Self.errorValue(failure)
        emit(.log, text: "running \(steps.count) workflow-level onError step(s) after the failure of '\(failure.stepID)'")
        if let f = await runSteps(steps, scope: scope) {
            errors.append("onError step '\(f.stepID)' \(f.status.rawValue): \(f.error ?? "no detail")")
        }
    }

    private static func errorValue(_ r: StepResult) -> JSONValue {
        ["stepID": .string(r.stepID), "message": .string(r.error ?? ""), "status": .string(r.status.rawValue),
         "code": r.errorCode.map(JSONValue.string) ?? .null]
    }

    /// Records a terminal result: namespace view, events, state, checkpoint.
    private func complete(_ result: StepResult) async {
        store(result)
        inFlight[result.key] = nil
        if result.continued { anyContinued = true }
        var data: [String: JSONValue] = ["key": .string(result.key), "status": .string(result.status.rawValue), "attempts": .int(result.attempts),
                                         "kind": .string(result.kind)]
        if let d = result.durationSeconds { data["durationMs"] = .int(Int(d * 1000)) }
        if let e = result.error { data["error"] = .string(Redactor.shared.redact(e)) }
        if let c = result.errorCode { data["code"] = .string(c) }
        if let h = result.handledBy { data["handledBy"] = .string(h) }
        if result.continued { data["continued"] = true }
        if let n = result.note { data["note"] = .string(n) }
        emit(.stepFinished, step: result.stepID, text: "\(result.stepID): \(result.status.rawValue)" + (result.note.map { " (\($0))" } ?? ""), data: .object(data))
        publish()
        await saveCheckpoint(stepID: result.stepID)
    }

    /// Debugger gate: waits here while the run is paused or the step has a breakpoint.
    private func gate(_ stepID: String) async {
        if breakpoints.contains(stepID), halt == nil {
            if !pauseRequested { emit(.log, step: stepID, text: "breakpoint hit at '\(stepID)'") }
            pauseRequested = true
        }
        guard pauseRequested, halt == nil else { return }
        if stepCredits > 0 { stepCredits -= 1; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            gateWaiters.append((stepID, c))
            refreshStatus()
        }
        refreshStatus()
    }

    private func idempotency(_ step: WorkflowStep) -> (idempotent: Bool, reason: String) {
        switch step.kind {
        case .tool(let t):
            guard let m = manifests[t.tool] else { return (false, "tool '\(t.tool)' is unknown") }
            return (m.idempotent, "tool '\(t.tool)' is not idempotent")
        case .notify: return (manifests["notifications.post"]?.idempotent ?? false, "posting a notification is not idempotent")
        case .agent: return (false, "agent steps are not idempotent")
        case .subworkflow, .foreach, .parallel, .loop: return (false, "container steps are not retried as a whole")
        default: return (true, "")
        }
    }

    private func executeStep(_ step: WorkflowStep, scope: Scope, siblings: [WorkflowStep], handlerKey: String? = nil) async -> StepResult? {
        let key = handlerKey ?? (scope.prefix + step.id)
        var result = StepResult(key: key, stepID: step.id, kind: step.kind.name, status: .running)
        var exec: Exec
        var started = false
        whenCheck: do {
            if let w = step.when {
                do {
                    if !(try WorkflowExpression.evaluateField(w, context: context(scope)).isTruthy) {
                        result.status = .skipped
                        result.endedAt = deps.clock.now()
                        result.note = "skipped: 'when' evaluated to false"
                        await complete(result)
                        return result
                    }
                } catch {
                    exec = expressionFailure(error, step: step, field: "when")
                    break whenCheck
                }
            }
            await gate(step.id)
            guard halt == nil else { return nil }
            if let limit = frames[""]?.document.spec.budget.maxDurationSeconds, deps.clock.now().timeIntervalSince(startedAt) > limit {
                setHalt(.timedOut("the workflow ran longer than budget.maxDurationSeconds (\(Self.trim(limit)) s)"))
                return nil
            }
            started = true
            result.startedAt = deps.clock.now()
            let container = step.isContainer || { if case .subworkflow = step.kind { return true }; return false }()
            inFlight[key] = InFlightStep(key: key, stepID: step.id, kind: step.kind.name, idempotent: idempotency(step).idempotent, isContainer: container)
            if !container { busyLeaves += 1 }
            emit(.stepStarted, step: step.id, text: "\(step.name ?? step.id) started", data: ["key": .string(key), "kind": .string(step.kind.name)])
            refreshStatus()
            await saveCheckpoint(stepID: step.id, announce: false)
            let (e, attempts) = await runWithPolicies(step, scope: scope, key: key)
            exec = e
            result.attempts = attempts
            if !container { busyLeaves -= 1 }
        }
        if !started { result.startedAt = deps.clock.now() }
        result.status = exec.status
        result.output = exec.output
        result.error = exec.error
        result.errorCode = exec.code
        result.note = exec.note
        result.endedAt = deps.clock.now()
        if !exec.status.isSuccess, halt == nil {
            if let h = step.onError, let handler = siblings.first(where: { $0.id == h }) {
                var hs = scope
                hs.locals["error"] = Self.errorValue(result)
                // The failed step is visible to its handler before the scope sees the final result.
                views[scope.prefix, default: [:]][step.id] = Self.view(result)
                var hk = scope.prefix + h
                var n = 2
                while results[hk] != nil { hk = "\(scope.prefix)\(h)~\(n)"; n += 1 }
                emit(.log, step: step.id, text: "routing the failure of '\(step.id)' to its onError step '\(h)'")
                if let hr = await executeStep(handler, scope: hs, siblings: siblings, handlerKey: hk), hr.status.isSuccess {
                    result.handledBy = h
                    result.continued = true
                }
            }
            if step.continueOnError { result.continued = true }
        }
        await complete(result)
        refreshStatus()
        return result
    }

    private func expressionFailure(_ error: Error, step: WorkflowStep, field: String) -> Exec {
        let message = "expression error in '\(field)': \(Self.message(error))"
        diagnostics.append(WorkflowDiagnostic(code: "expression-evaluation", message: message, stepID: step.id, path: field))
        return .failed(message, code: "expression")
    }

    private static let nonRetryableCodes: Set<String> = ["invalid_input", "unsupported", "permission_denied", "expression", "approval_denied",
                                                         "loop_bound", "fail", "not_found_tool"]

    private func runWithPolicies(_ step: WorkflowStep, scope: Scope, key: String) async -> (Exec, Int) {
        var attempt = 0
        while true {
            attempt += 1
            let n = attempt
            var exec: Exec
            if let limit = step.timeoutSeconds, limit > 0 {
                let race = await Self.race(seconds: limit) { await self.dispatch(step, scope: scope, key: key, attempt: n) }
                exec = race ?? Exec(status: .timedOut, error: "step timed out after \(Self.trim(limit)) s", code: "timeout")
            } else {
                exec = await dispatch(step, scope: scope, key: key, attempt: n)
            }
            if halt != nil, !exec.status.isSuccess, exec.status != .budgetExceeded { exec = .canceled }
            if exec.status.isSuccess || exec.status == .skipped { return (exec, attempt) }
            guard let policy = step.retry, policy.maxAttempts > attempt, halt == nil, exec.status == .failed || exec.status == .timedOut,
                  !Self.nonRetryableCodes.contains(exec.code ?? "") else { return (exec, attempt) }
            let (idempotent, reason) = idempotency(step)
            guard idempotent || policy.force else {
                emit(.retry, step: step.id, text: "'\(step.id)' failed and was not retried: \(reason) and retry.force is not set (a blind retry could repeat its side effects)",
                     data: ["retried": false, "attempt": .int(attempt), "reason": .string(reason)])
                return (exec, attempt)
            }
            let delay = policy.backoffSeconds * pow(policy.backoffMultiplier, Double(attempt - 1))
            emit(.retry, step: step.id, text: "'\(step.id)' attempt \(attempt) of \(policy.maxAttempts) failed (\(exec.error ?? exec.status.rawValue)); retrying in \(Self.trim(delay)) s"
                    + (idempotent ? "" : " (forced: the step is not idempotent)"),
                 data: ["retried": true, "attempt": .int(attempt), "maxAttempts": .int(policy.maxAttempts), "delaySeconds": .number(delay), "forced": .bool(!idempotent)])
            if delay > 0 {
                do { try await deps.clock.sleep(seconds: delay) } catch { return (.canceled, attempt) }
            }
            if halt != nil { return (.canceled, attempt) }
        }
    }

    /// Runs `operation` against a real-time limit. Nil means the limit was reached (the operation is cancelled).
    private nonisolated static func race(seconds: Double, _ operation: @escaping @Sendable () async -> Exec) async -> Exec? {
        await withTaskGroup(of: Race.self) { group in
            group.addTask { .done(await operation()) }
            group.addTask {
                do { try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400 * 365) * 1_000_000_000)); return .timeout }
                catch { return .sleeperCanceled }
            }
            var result: Exec?
            while let next = await group.next() {
                if case .done(let e) = next { result = e; break }
                if case .timeout = next { break }
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Concurrency gate

    /// Waits for a leaf slot. False means the run was halted while waiting and no slot is held.
    private func acquireSlot() async -> Bool {
        if halt != nil { return false }
        if activeSlots < deps.configuration.maxConcurrentSteps { activeSlots += 1; return true }
        return await withCheckedContinuation { slotWaiters.append($0) }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty { activeSlots -= 1 } else { slotWaiters.removeFirst().resume(returning: true) }
    }

    // MARK: - Dispatch

    private func dispatch(_ step: WorkflowStep, scope: Scope, key: String, attempt: Int) async -> Exec {
        if halt != nil { return .canceled }
        do {
            switch step.kind {
            case .tool(let t):
                let args = try WorkflowExpression.resolve(.object(t.arguments), context: context(scope))
                return await callTool(t.tool, arguments: args, stepID: step.id, key: key)
            case .notify(let n):
                let title = try n.title.map { try text($0, scope) } ?? (frames[scope.frame]?.document.metadata.name ?? "ORIX")
                return await callTool("notifications.post", arguments: ["title": .string(title), "body": .string(try text(n.message, scope))], stepID: step.id, key: key)
            case .agent(let a): return try await runAgent(a, step: step, scope: scope)
            case .condition(let c):
                let value = try WorkflowExpression.evaluateField(c.condition, context: context(scope)).isTruthy
                return .ok(["result": .bool(value), "branch": .string(value ? "then" : "else")])
            case .switch(let s):
                let ctx = context(scope)
                let value = try WorkflowExpression.evaluateField(s.on, context: ctx)
                for (i, c) in s.cases.enumerated() {
                    let candidate = try WorkflowExpression.resolve(c.value, context: ctx)
                    if Self.looselyEqual(candidate, value) {
                        return .ok(["value": value, "matched": .int(i), "steps": .array(c.steps.map(JSONValue.string))])
                    }
                }
                return .ok(["value": value, "matched": s.defaultSteps.isEmpty ? .null : "default", "steps": .array(s.defaultSteps.map(JSONValue.string))])
            case .foreach(let f): return try await runForeach(f, step: step, scope: scope, key: key)
            case .parallel(let p): return await runParallel(p, scope: scope, key: key)
            case .loop(let l): return try await runLoop(l, step: step, scope: scope, key: key)
            case .approval(let a): return try await runApproval(a, step: step, scope: scope)
            case .delay(let d):
                let value: JSONValue
                if case .string(let s) = d.seconds { value = try WorkflowExpression.evaluateField(s, context: context(scope)) } else { value = d.seconds }
                guard let seconds = value.doubleValue, seconds >= 0, seconds.isFinite else { return .failed("delay needs a non-negative number of seconds, got \(value.serialized())", code: "invalid_input") }
                if options.dryRun {
                    simulations.append("\(step.id): simulated: the \(Self.trim(seconds)) s delay was not waited")
                    return .simulated("simulated: the \(Self.trim(seconds)) s delay was not waited", output: ["seconds": .number(seconds)])
                }
                do { try await deps.clock.sleep(seconds: seconds) } catch { return .canceled }
                return .ok(["seconds": .number(seconds)])
            case .set(let s):
                let resolved = try WorkflowExpression.resolve(.object(s.values), context: context(scope))
                for (k, v) in resolved.objectValue ?? [:] { frames[scope.frame]?.vars[k] = v }
                return .ok(resolved)
            case .transform(let t):
                let value = try WorkflowExpression.evaluateField(t.expression, context: context(scope))
                if let into = t.into { frames[scope.frame]?.vars[into] = value }
                return .ok(value)
            case .verify(let v): return try runVerify(v, step: step, scope: scope)
            case .subworkflow(let s): return try await runSubworkflow(s, step: step, scope: scope, key: key)
            case .fail(let f): return .failed(try text(f.message, scope), code: "fail")
            case .output(let o):
                let resolved = try WorkflowExpression.resolve(.object(o.values), context: context(scope))
                for (k, v) in resolved.objectValue ?? [:] { frameOutputs[scope.frame, default: [:]][k] = v }
                var recorded: [JSONValue] = []
                for raw in o.artifacts {
                    let path = try PathResolver.canonical(try text(raw, scope), relativeTo: options.workingDirectory)
                    let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
                    if !artifacts.contains(where: { $0.path == path }) {
                        artifacts.append(Artifact(path: path, kind: "file", bytes: size ?? 0, createdAt: deps.clock.now(),
                                                  note: size == nil ? "declared by '\(step.id)'; the file does not exist" : "declared by '\(step.id)'"))
                    }
                    recorded.append(.string(path))
                }
                return .ok(["values": resolved, "artifacts": .array(recorded)])
            }
        } catch let e as WorkflowExpressionError {
            return expressionFailure(e, step: step, field: step.kind.name)
        } catch let e as ToolError {
            return .failed(e.failure.message, code: e.failure.code)
        } catch {
            return .failed(Self.message(error), code: "internal")
        }
    }

    private static func looselyEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = a.doubleValue, let y = b.doubleValue { return x == y }
        return a == b
    }

    private func invocationContext() -> InvocationContext {
        InvocationContext(runID: runID, workflowID: workflowID, mode: options.mode, workingDirectory: options.workingDirectory,
                          artifactsDirectory: options.artifactsDirectory, maxToolSeconds: deps.configuration.maxToolSeconds)
    }

    private func callTool(_ toolID: String, arguments: JSONValue, stepID: String, key: String) async -> Exec {
        var dryRun = false
        if options.dryRun {
            guard let m = manifests[toolID], m.supportsDryRun else {
                let why = manifests[toolID] == nil ? "the tool is unknown" : "the tool has no dry-run mode"
                let note = "simulated: not executed (\(toolID): \(why))"
                simulations.append("\(stepID): \(note)")
                return .simulated(note)
            }
            dryRun = true
        }
        if let max = frames[""]?.document.spec.budget.maxToolCalls, usage.toolCalls >= max {
            let message = "budget.maxToolCalls (\(max)) is exhausted; '\(toolID)' was not called"
            setHalt(.budget(message))
            return Exec(status: .budgetExceeded, error: message, code: "budget_tool_calls")
        }
        usage.toolCalls += 1
        guard await acquireSlot() else { return .canceled }
        let call = ToolCall(toolID: toolID, arguments: arguments, dryRun: dryRun, idempotencyKey: "\(runID)/\(key)")
        let result = await deps.tools.invoke(call, context: invocationContext())
        releaseSlot()
        for a in result.artifacts where !artifacts.contains(where: { $0.id == a.id }) { artifacts.append(a) }
        let status = WorkflowEngine.stepStatus(for: result.status)
        if dryRun {
            let note = result.status == .simulated
                ? "simulated: \(toolID) was invoked with dryRun: true — \(result.summary.isEmpty ? "nothing was changed" : result.summary)"
                : "dry run: \(toolID) was invoked with dryRun: true and answered \(result.status.rawValue)"
            simulations.append("\(stepID): \(note)")
            if result.status == .simulated || result.status == .succeeded { return .simulated(note, output: result.output) }
        }
        if status.isSuccess { return Exec(status: status, output: result.output) }
        let failure = result.failure
        return Exec(status: status, output: result.output, error: failure?.message ?? (result.summary.isEmpty ? "\(toolID) ended with status \(result.status.rawValue)" : result.summary),
                    code: failure?.code ?? result.status.rawValue)
    }

    private static func expectation(_ a: WorkflowAssertion, _ resolve: (String) throws -> String) rethrows -> Expectation? {
        switch a {
        case .fileExists(let p): return Expectation(kind: "file_exists", path: try resolve(p))
        case .fileNonEmpty(let p): return Expectation(kind: "file_nonempty", path: try resolve(p))
        case .fileContains(let p, let t): return Expectation(kind: "file_contains", path: try resolve(p), text: try resolve(t))
        case .dirNonEmpty(let p): return Expectation(kind: "dir_nonempty", path: try resolve(p))
        default: return nil
        }
    }

    private func runAgent(_ a: AgentStep, step: WorkflowStep, scope: Scope) async throws -> Exec {
        if options.dryRun {
            let note = "simulated: the agent was not run (no model call, no tool call)"
            simulations.append("\(step.id): \(note)")
            return .simulated(note)
        }
        guard let runner = deps.agents else { return .failed("no agent runtime is configured for this engine", code: "unsupported") }
        var profile: AgentProfile
        switch a.agent {
        case .profile(let name):
            guard let p = await deps.agentProfiles?(name) else { return .failed("unknown agent profile '\(name)'", code: "not_found") }
            profile = p
        case .inline(let i):
            var model = deps.configuration.defaultModel
            if let m = i.model {
                let parts = m.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return .failed("model '\(m)' must be written provider/model", code: "invalid_input") }
                model = ModelRef(provider: ProviderID(rawValue: parts[0]), model: parts[1])
            }
            guard let model else { return .failed("the inline agent names no model and the engine has no default model", code: "invalid_input") }
            profile = AgentProfile(name: step.name ?? step.id, instructions: try text(i.instructions, scope), model: model, toolPatterns: i.tools)
        }
        let spec = frames[""]?.document.spec.budget ?? WorkflowBudget()
        var budget = profile.budget
        if let c = spec.maxProviderCostUSD { budget.maxCostUSD = min(budget.maxCostUSD, max(0, c - usage.costUSD)) }
        if let t = spec.maxTokens { budget.maxTotalTokens = min(budget.maxTotalTokens, max(0, t - usage.tokens.totalTokens)) }
        if let t = spec.maxToolCalls { budget.maxToolCalls = min(budget.maxToolCalls, max(0, t - usage.toolCalls)) }
        if let d = spec.maxDurationSeconds { budget.maxWallSeconds = min(budget.maxWallSeconds, max(1, d - deps.clock.now().timeIntervalSince(startedAt))) }
        if let t = step.timeoutSeconds { budget.maxWallSeconds = min(budget.maxWallSeconds, t) }
        if budget.maxCostUSD <= 0, spec.maxProviderCostUSD != nil {
            let message = "budget.maxProviderCostUSD is exhausted; the agent was not started"
            setHalt(.budget(message))
            return Exec(status: .budgetExceeded, error: message, code: "budget_cost")
        }
        let expectations = try a.expect.compactMap { try Self.expectation($0) { try text($0, scope) } }
        let task = AgentTask(objective: try text(a.objective, scope), mode: options.mode, workingDirectory: options.workingDirectory.path,
                             budget: budget, inputs: try WorkflowExpression.resolve(.object(a.inputs), context: context(scope)),
                             expectations: expectations)
        guard await acquireSlot() else { return .canceled }
        let outcome = await runner.run(task: task, profile: profile, runID: runID, workflowID: workflowID, stepID: step.id)
        releaseSlot()
        usage.turns += outcome.usage.turns
        usage.toolCalls += outcome.usage.toolCalls
        usage.tokens = usage.tokens + outcome.usage.tokens
        usage.costUSD += outcome.usage.costUSD
        usage.costIsComplete = usage.costIsComplete && outcome.usage.costIsComplete
        emit(.usage, step: step.id, text: "agent used \(outcome.usage.tokens.totalTokens) tokens", data: ["costUSD": .number(outcome.usage.costUSD),
                                                                                                     "tokens": .int(outcome.usage.tokens.totalTokens)])
        for art in outcome.artifacts where !artifacts.contains(where: { $0.id == art.id }) { artifacts.append(art) }
        for v in outcome.verifications {
            verifications.append(v)
            emit(.verification, step: step.id, text: "\(v.passed ? "PASS" : "FAIL") \(v.assertion)", data: ["passed": .bool(v.passed), "kind": .string(v.kind)])
        }
        let output: JSONValue = ["text": .string(outcome.finalText), "result": outcome.result, "status": .string(outcome.status.rawValue)]
        var exec: Exec
        switch outcome.status {
        case .succeeded: exec = .ok(output)
        case .partiallySucceeded: exec = Exec(status: .failed, output: output, error: outcome.errorSummary ?? "the agent only partially met its expectations", code: "agent_partial")
        case .canceled: exec = Exec(status: .canceled, output: output, error: outcome.errorSummary ?? "canceled", code: "canceled")
        case .timedOut: exec = Exec(status: .timedOut, output: output, error: outcome.errorSummary ?? "the agent timed out", code: "timeout")
        case .waitingApproval: exec = Exec(status: .notApproved, output: output, error: outcome.errorSummary ?? "the agent is waiting for an approval", code: "not_approved")
        case .blockedPermission: exec = Exec(status: .blockedPermission, output: output, error: outcome.errorSummary ?? "a macOS permission is missing", code: "tcc_blocked")
        case .budgetExceeded: exec = Exec(status: .budgetExceeded, output: output, error: outcome.errorSummary ?? "the agent exhausted its budget", code: "budget")
        case .recoveryRequired: exec = Exec(status: .recoveryRequired, output: output, error: outcome.errorSummary ?? "the agent needs recovery", code: "recovery_required")
        default: exec = Exec(status: .failed, output: output, error: outcome.errorSummary ?? "the agent ended with status \(outcome.status.rawValue)", code: "agent_failed")
        }
        if let c = spec.maxProviderCostUSD, usage.costUSD > c {
            setHalt(.budget("provider cost \(String(format: "%.4f", usage.costUSD)) USD exceeded budget.maxProviderCostUSD (\(c))"))
            if !exec.status.isSuccess { exec.status = .budgetExceeded }
        } else if let t = spec.maxTokens, usage.tokens.totalTokens > t {
            setHalt(.budget("\(usage.tokens.totalTokens) tokens exceeded budget.maxTokens (\(t))"))
            if !exec.status.isSuccess { exec.status = .budgetExceeded }
        }
        return exec
    }

    private func runApproval(_ a: ApprovalStep, step: WorkflowStep, scope: Scope) async throws -> Exec {
        let message = try text(a.message, scope)
        if options.dryRun {
            let note = "simulated: approval was not requested"
            simulations.append("\(step.id): \(note)")
            return .simulated(note)
        }
        let prompt = WorkflowApprovalPrompt(id: UUID().uuidString, runID: runID, workflowID: workflowID, stepID: step.id, message: message)
        emit(.approvalRequested, step: step.id, text: message, data: ["promptID": .string(prompt.id)])
        var response = ApprovalResponse.unanswered
        if let handler = deps.approval {
            response = await withCheckedContinuation { (c: CheckedContinuation<ApprovalResponse, Never>) in
                pendingApprovals[prompt.id] = c
                refreshStatus()
                Task {
                    let answer = await handler(prompt)
                    self.resolveApproval(prompt.id, answer)
                }
            }
        }
        refreshStatus()
        switch response {
        case .approveOnce, .approveForRun, .approvePersistent:
            emit(.approvalResolved, step: step.id, text: "approved", data: ["approved": true])
            return .ok(["approved": true])
        case .deny(let reason):
            emit(.approvalResolved, step: step.id, text: "denied: \(reason)", data: ["approved": false])
            return .failed("approval denied: \(reason)", code: "approval_denied")
        case .unanswered:
            emit(.approvalResolved, step: step.id, text: "unanswered", data: ["approved": false, "unanswered": true])
            return Exec(status: .notApproved, error: "nobody answered the approval request", code: "not_approved")
        }
    }

    private func resolveApproval(_ id: String, _ response: ApprovalResponse) {
        pendingApprovals.removeValue(forKey: id)?.resume(returning: response)
    }

    // MARK: - Containers

    private func containerFailure(_ f: StepResult, _ what: String) -> Exec {
        Exec(status: f.status, error: "\(what)step '\(f.stepID)' \(f.status.rawValue): \(f.error ?? "no detail")", code: f.errorCode)
    }

    private func runForeach(_ f: ForeachStep, step: WorkflowStep, scope: Scope, key: String) async throws -> Exec {
        let items: [JSONValue]
        if let saved = containerState[key]?.arrayValue { items = saved }
        else {
            let value: JSONValue
            if case .string(let s) = f.items { value = try WorkflowExpression.evaluateField(s, context: context(scope)) }
            else { value = try WorkflowExpression.resolve(f.items, context: context(scope)) }
            switch value {
            case .array(let a): items = a
            case .null where options.dryRun:
                let note = "simulated: the items are unknown in a dry run (they come from a step that was not executed); the body was not run"
                simulations.append("\(step.id): \(note)")
                return .simulated(note, output: ["results": [], "count": 0])
            case .null: items = []
            default: return .failed("foreach needs a list, got \(value.serialized().prefix(80))", code: "invalid_input")
            }
            guard items.count <= deps.configuration.maxForeachItems else {
                return .failed("foreach has \(items.count) items; the limit is \(deps.configuration.maxForeachItems)", code: "invalid_input")
            }
            containerState[key] = .array(items)
        }
        var outputs = [JSONValue](repeating: .null, count: items.count)
        var failure: (Int, StepResult)?
        let width = max(1, f.concurrency)
        await withTaskGroup(of: (Int, StepResult?).self) { group in
            var next = 0
            var running = 0
            while true {
                while running < width, next < items.count, failure == nil, halt == nil {
                    let i = next
                    next += 1
                    running += 1
                    var child = scope
                    child.prefix = "\(key)[\(i)]/"
                    child.chain = [child.prefix] + scope.chain
                    child.locals[f.itemName] = items[i]
                    child.locals["index"] = .int(i)
                    let body = f.steps
                    group.addTask { (i, await self.runSteps(body, scope: child)) }
                }
                if running == 0 { break }
                guard let (i, fail) = await group.next() else { break }
                running -= 1
                if let fail { if failure == nil { failure = (i, fail) } }
                else {
                    let view = views["\(key)[\(i)]/"] ?? [:]
                    if let c = f.collect { outputs[i] = view[c]?["output"] ?? .null }
                    else { outputs[i] = .object(view.mapValues { $0["output"] ?? .null }) }
                }
            }
        }
        if halt != nil { return .canceled }
        if let (i, fail) = failure { return containerFailure(fail, "iteration \(i): ") }
        return .ok(["results": .array(outputs), "count": .int(items.count)])
    }

    private func runParallel(_ p: ParallelStep, scope: Scope, key: String) async -> Exec {
        var failure: StepResult?
        await withTaskGroup(of: StepResult?.self) { group in
            for b in p.branches {
                var child = scope
                child.prefix = "\(key)(\(b.name))/"
                child.chain = [child.prefix] + scope.chain
                let steps = b.steps
                group.addTask { await self.runSteps(steps, scope: child) }
            }
            for await r in group { if let r, failure == nil { failure = r } }
        }
        if halt != nil { return .canceled }
        if let failure { return containerFailure(failure, "") }
        var out: [String: JSONValue] = [:]
        for b in p.branches { out[b.name] = .object((views["\(key)(\(b.name))/"] ?? [:]).mapValues { $0["output"] ?? .null }) }
        return .ok(.object(out))
    }

    private func runLoop(_ l: LoopStep, step: WorkflowStep, scope: Scope, key: String) async throws -> Exec {
        var i = containerState[key]?.intValue ?? 0
        let last = "\(key)#last/"
        if views[last] == nil, i > 0 {
            for j in 0..<i { views[last, default: [:]].merge(views["\(key)#\(j)/"] ?? [:]) { _, new in new } }
        }
        var ranThisSession = 0
        while true {
            var around = scope
            around.chain = [last] + scope.chain
            around.locals["loop"] = ["index": .int(i)]
            guard try WorkflowExpression.evaluateField(l.condition, context: context(around)).isTruthy else { break }
            if i >= l.maxIterations {
                return Exec(status: .failed, output: ["iterations": .int(i), "exhausted": true],
                            error: "the loop reached maxIterations (\(l.maxIterations)) and its condition is still true", code: "loop_bound")
            }
            if options.dryRun, ranThisSession >= 1 {
                let note = "simulated: the loop body was walked once; further iterations depend on results a dry run does not have"
                simulations.append("\(step.id): \(note)")
                return .simulated(note, output: ["iterations": .int(i)])
            }
            containerState[key] = .int(i)
            var child = scope
            child.prefix = "\(key)#\(i)/"
            child.chain = [child.prefix, last] + scope.chain
            child.locals["loop"] = ["index": .int(i)]
            if let fail = await runSteps(l.steps, scope: child) { return containerFailure(fail, "iteration \(i): ") }
            if halt != nil { return .canceled }
            views[last, default: [:]].merge(views[child.prefix] ?? [:]) { _, new in new }
            i += 1
            ranThisSession += 1
            containerState[key] = .int(i)
        }
        return .ok(["iterations": .int(i), "exhausted": false])
    }

    private func runSubworkflow(_ s: SubworkflowStep, step: WorkflowStep, scope: Scope, key: String) async throws -> Exec {
        guard scope.depth < deps.configuration.maxSubworkflowDepth else {
            return .failed("subworkflows are nested deeper than \(deps.configuration.maxSubworkflowDepth) levels (recursion?)", code: "invalid_input")
        }
        guard let loader = deps.loader else { return .failed("no subworkflow loader is configured for this engine", code: "unsupported") }
        let doc: WorkflowDocument
        do { doc = try await loader.loadWorkflow(s.workflow) }
        catch { return .failed("could not load workflow '\(s.workflow)': \(Self.message(error))", code: "not_found") }
        if let problem = WorkflowValidator.structuralErrors(doc).first { return .failed("workflow '\(s.workflow)' is invalid: \(problem.message)", code: "invalid_input") }
        let inputs = try WorkflowExpression.resolve(.object(s.inputs), context: context(scope)).objectValue ?? [:]
        let frameID = key + ">"
        if frames[frameID] == nil {
            switch WorkflowEngine.resolveParameters(doc, provided: inputs) {
            case .failure(let e): return .failed("workflow '\(s.workflow)': \(e.message)", code: "invalid_input")
            case .success(let params):
                if let problem = makeFrame(frameID, document: doc, params: params) { return .failed("workflow '\(s.workflow)': \(problem)", code: "expression") }
            }
        }
        let child = Scope(prefix: frameID + "/", chain: [frameID + "/"], frame: frameID, locals: [:], depth: scope.depth + 1)
        if let fail = await runSteps(doc.spec.steps, scope: child) {
            if halt == nil, !doc.spec.onError.isEmpty { await runErrorHandlers(doc.spec.onError, frame: frameID, outer: child, failure: fail) }
            return containerFailure(fail, "workflow '\(s.workflow)': ")
        }
        if halt != nil { return .canceled }
        return .ok(.object(frameOutputs[frameID] ?? [:]))
    }

    // MARK: - Verification

    private func runVerify(_ v: VerifyStep, step: WorkflowStep, scope: Scope) throws -> Exec {
        if options.dryRun {
            let note = "simulated: \(v.assertions.count) assertion(s) were not evaluated (nothing was executed to verify)"
            simulations.append("\(step.id): \(note)")
            return .simulated(note)
        }
        var failed: [String] = []
        for a in v.assertions {
            let r = try check(a, scope: scope)
            verifications.append(r)
            emit(.verification, step: step.id, text: "\(r.passed ? "PASS" : "FAIL") \(r.assertion) — \(r.evidence)",
                 data: ["passed": .bool(r.passed), "kind": .string(r.kind), "assertion": .string(r.assertion)])
            if !r.passed { failed.append("\(r.assertion) (\(r.evidence))") }
        }
        let output: JSONValue = ["passed": .int(v.assertions.count - failed.count), "failed": .int(failed.count)]
        if failed.isEmpty { return .ok(output) }
        return Exec(status: .failed, output: output, error: "verification failed: " + failed.joined(separator: "; "), code: "verification_failed")
    }

    private func check(_ a: WorkflowAssertion, scope: Scope) throws -> VerificationResult {
        let now = deps.clock.now()
        func result(_ assertion: String, _ kind: String, _ passed: Bool, _ evidence: String) -> VerificationResult {
            VerificationResult(assertion: assertion, kind: kind, passed: passed, evidence: evidence, checkedAt: now)
        }
        /// Canonical path the workflow is allowed to inspect, or the reason it is not.
        func inspectable(_ raw: String) throws -> (path: String?, display: String, refusal: String) {
            let shown = try text(raw, scope)
            guard let path = try? PathResolver.canonical(shown, relativeTo: options.workingDirectory) else { return (nil, shown, "the path is not valid") }
            if PathResolver.isProtected(path) { return (nil, shown, "the path is a protected location") }
            let roots = frames[scope.frame]?.readableRoots ?? []
            guard roots.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else {
                return (nil, shown, "the path is outside the workflow's declared filesystem permissions")
            }
            return (path, shown, "")
        }
        let fm = FileManager.default
        switch a {
        case .fileExists(let raw):
            let (path, shown, refusal) = try inspectable(raw)
            guard let path else { return result("File \(shown) exists", "file_exists", false, refusal) }
            let exists = fm.fileExists(atPath: path)
            return result("File \(shown) exists", "file_exists", exists, exists ? "found at \(path)" : "nothing at \(path)")
        case .fileNonEmpty(let raw):
            let (path, shown, refusal) = try inspectable(raw)
            guard let path else { return result("File \(shown) is not empty", "file_nonempty", false, refusal) }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return result("File \(shown) is not empty", "file_nonempty", false, "no file at \(path)") }
            let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
            return result("File \(shown) is not empty", "file_nonempty", size > 0, "\(size) bytes")
        case .fileContains(let raw, let needleRaw):
            let (path, shown, refusal) = try inspectable(raw)
            let needle = try text(needleRaw, scope)
            let assertion = "File \(shown) contains \"\(needle.prefix(60))\""
            guard let path else { return result(assertion, "file_contains", false, refusal) }
            guard let handle = FileHandle(forReadingAtPath: path) else { return result(assertion, "file_contains", false, "cannot read \(path)") }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 16 * 1_048_576)) ?? Data()
            let found = !needle.isEmpty && String(decoding: data, as: UTF8.self).contains(needle)
            return result(assertion, "file_contains", found, found ? "text found" : "text not found in the first \(data.count) bytes")
        case .dirNonEmpty(let raw):
            let (path, shown, refusal) = try inspectable(raw)
            guard let path else { return result("Folder \(shown) is not empty", "dir_nonempty", false, refusal) }
            let entries = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { $0 != ".DS_Store" }
            return result("Folder \(shown) is not empty", "dir_nonempty", !entries.isEmpty, "\(entries.count) entr\(entries.count == 1 ? "y" : "ies")")
        case .equals(let l, let r):
            let ctx = context(scope)
            let a = try WorkflowExpression.resolve(l, context: ctx), b = try WorkflowExpression.resolve(r, context: ctx)
            let same = Self.looselyEqual(a, b)
            return result("\(l.displayString) equals \(r.displayString)", "custom", same, "\(a.serialized().prefix(120)) \(same ? "==" : "!=") \(b.serialized().prefix(120))")
        case .truthy(let v):
            let value: JSONValue
            if case .string(let s) = v { value = try WorkflowExpression.evaluateField(s, context: context(scope)) }
            else { value = try WorkflowExpression.resolve(v, context: context(scope)) }
            return result("\(v.displayString) is truthy", "custom", value.isTruthy, "value: \(value.serialized().prefix(120))")
        case .stepSucceeded(let id):
            var found: JSONValue?
            for prefix in scope.chain { if let v = views[prefix]?[id] { found = v; break } }
            let status = found?["status"]?.stringValue ?? "not run"
            return result("Step \(id) succeeded", "tool_succeeded", status == StepStatus.succeeded.rawValue, "status: \(status)")
        }
    }
}
