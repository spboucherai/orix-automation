// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/StudioModel+Run.swift
// Description: Running the open workflow from the studio: permission review, run / dry run / debug, live step status from the run handle and the live hub, debugger controls, and last-run data from the store.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAppUI

extension WorkflowStudioModel {
    // MARK: Derived

    var runIsLive: Bool {
        if let s = runState?.status { return !s.isTerminal }
        if let s = runRecord?.status { return !s.isTerminal && runHandle != nil }
        return false
    }

    var runStatus: RunStatus? { runOutcome?.status ?? runState?.status ?? runRecord?.status }
    var runIsPaused: Bool { runIsLive && (runState?.status == .paused || !(runState?.pausedAt.isEmpty ?? true) || (runState?.pauseRequested ?? false)) }
    var runIsDry: Bool { runOutcome?.dryRun ?? (runRecord?.title.hasSuffix("(dry run)") ?? (runKind == .dryRun)) }

    /// `each[2]/copy` → `copy`; `par(left)/a` → `a`; `poll#3/check` → `check`.
    nonisolated static func stepID(fromKey key: String) -> String { key.split(separator: "/").last.map(String.init) ?? key }

    /// True when a step of the selected run is held for a person: an approval gate, or a tool call awaiting approval.
    func isWaitingApproval(_ id: String) -> Bool {
        guard let runID = activeRunID, stepInfo[id]?.status == .running else { return false }
        if app.pendingApprovals.contains(where: { $0.access.runID == runID && $0.access.argumentsPreview["step"]?.stringValue == id }) { return true }
        return runState?.status == .waitingApproval
    }

    // MARK: Starting

    /// First half of every run button: saves if needed, then either starts directly (permissions already accepted with
    /// the default parameters) or opens the review sheet.
    func requestRun(_ kind: RunKind, alwaysReview: Bool = false) async {
        guard let id = workflowID, !isStartingRun else { return }
        isStartingRun = true
        defer { isStartingRun = false }
        if isDirty { guard await save() else { return } }
        do {
            let review = try await services.workflows.permissionReview(workflowID: id, parameters: [:])
            if review.accepted && !alwaysReview { await start(kind, parameters: [:], accept: false) }
            else { runRequest = kind }
        } catch {
            // Usually a required parameter without a default: the sheet asks for it.
            runRequest = kind
        }
    }

    /// Starts the run. `accept` first records the declared permissions as workflow-scoped grants.
    @discardableResult
    func start(_ kind: RunKind, parameters: [String: JSONValue], accept: Bool) async -> String? {
        guard let id = workflowID else { return nil }
        do {
            if accept { try await services.workflows.acceptPermissions(workflowID: id, parameters: parameters) }
            var req = WorkflowRunRequest(workflowID: id)
            req.parameters = parameters
            req.mode = app.settings.defaultMode
            req.dryRun = kind == .dryRun
            req.trigger = kind == .debug ? "debug" : "manual"
            if kind == .debug { req.startPaused = true; req.breakpoints = breakpoints }
            let runID = try await services.workflows.startRun(req)
            runKind = kind
            await attach(runID: runID)
            showDrawer = true
            return runID
        } catch {
            app.report(error)
            return nil
        }
    }

    // MARK: Observing

    func detachRun() {
        for t in runTasks { t.cancel() }
        runTasks = []
        activeRunID = nil; runRecord = nil; runState = nil; stepInfo = [:]; runOutcome = nil; runReceipt = nil; runVariables = [:]; runHandle = nil
    }

    /// After opening a workflow: show the data of its most recent run, if there is one.
    func adoptLatestRun() async {
        guard let id = workflowID, activeRunID == nil else { return }
        if let selected = app.selectedRunID, let r = try? await services.store.run(id: selected), r.workflowID == id { await attach(runID: selected); return }
        if let latest = (try? await services.store.runs(limit: 1, workflowID: id))?.first { await attach(runID: latest.id) }
    }

    /// Binds the canvas, inspector and drawer to a run: live when this process holds its handle, from the store otherwise.
    func attach(runID: String) async {
        detachRun()
        activeRunID = runID
        // Look for the handle first: without one the run already ended (or belongs to another process) and the store is current.
        let handle = await services.workflows.handle(runID: runID)
        runHandle = handle
        runRecord = try? await services.store.run(id: runID)
        await refreshRunFromStore()
        guard let handle else { return }
        let hub = services.runs.live
        runTasks.append(Task { [weak self] in
            for await update in hub.subscribe(runID: runID) {
                guard let self, self.activeRunID == runID else { return }
                switch update {
                case .stepStatus(let key, let raw):
                    if let s = StepStatus(rawValue: raw) { self.note(step: Self.stepID(fromKey: key), status: s, at: Date()) }
                case .finished: return
                default: break
                }
            }
        })
        runTasks.append(Task { [weak self] in
            for await state in await handle.states() {
                guard let self, self.activeRunID == runID else { return }
                await self.apply(state, handle: handle)
            }
            let outcome = await handle.outcome()
            guard let self, self.activeRunID == runID else { return }
            await self.finish(outcome)
        })
    }

    private func note(step id: String, status: StepStatus, at date: Date) {
        var info = stepInfo[id] ?? StepRunInfo(status: status)
        if status == .running {
            if info.status != .running || info.startedAt == nil { info.startedAt = date; info.endedAt = nil }
        } else if status.isTerminal, info.endedAt == nil || info.status == .running {
            info.endedAt = date
            if info.startedAt == nil { info.startedAt = date }
        }
        info.status = status
        stepInfo[id] = info
    }

    /// Folds instance statuses (loop iterations, parallel branches) into one status per step id.
    nonisolated static func aggregate(_ steps: [String: StepStatus]) -> [String: (status: StepStatus, instances: Int)] {
        func rank(_ s: StepStatus) -> Int {
            switch s {
            case .running: return 6
            case .failed, .timedOut, .blockedPermission, .notApproved, .budgetExceeded, .recoveryRequired: return 5
            case .canceled: return 4
            case .succeeded: return 3
            case .simulated: return 2
            case .skipped: return 1
            case .pending: return 0
            }
        }
        var out: [String: (status: StepStatus, instances: Int)] = [:]
        for (key, status) in steps {
            let id = stepID(fromKey: key)
            if let cur = out[id] { out[id] = (rank(status) > rank(cur.status) ? status : cur.status, cur.instances + 1) }
            else { out[id] = (status, 1) }
        }
        return out
    }

    private func apply(_ state: WorkflowRunState, handle: WorkflowRun) async {
        runState = state
        let now = Date()
        for (id, entry) in Self.aggregate(state.steps) {
            note(step: id, status: entry.status, at: now)
            stepInfo[id]?.instances = entry.instances
            if entry.status.isTerminal, let r = await handle.inspect(id) { fill(id, from: r) }
        }
        if state.status == .paused || !state.pausedAt.isEmpty { runVariables = await handle.variables() }
    }

    private func fill(_ id: String, from r: StepResult) {
        var info = stepInfo[id] ?? StepRunInfo(status: r.status)
        info.attempts = r.attempts
        info.error = r.error
        info.note = r.note
        info.output = r.output
        if let s = r.startedAt { info.startedAt = s }
        if let e = r.endedAt { info.endedAt = e }
        stepInfo[id] = info
    }

    private func finish(_ outcome: WorkflowOutcome) async {
        runOutcome = outcome
        var statuses: [String: StepStatus] = [:]
        for r in outcome.steps where !r.stepID.isEmpty { statuses[r.key] = r.status }
        for (id, entry) in Self.aggregate(statuses) {
            var info = stepInfo[id] ?? StepRunInfo(status: entry.status)
            info.status = entry.status; info.instances = entry.instances
            stepInfo[id] = info
            if let r = outcome.step(id) { fill(id, from: r) }
        }
        runVariables = [:]
        // The service writes the record and the receipt right after the outcome.
        if let final = await services.runs.wait(runID: outcome.runID) { runRecord = final }
        runReceipt = try? await services.store.receipt(runID: outcome.runID)
        runHandle = nil
        if var s = runState { s.status = outcome.status; s.pausedAt = []; s.running = []; runState = s }
    }

    /// Reads what the store keeps about the selected run: its record, receipt, step events and, when it still exists,
    /// the checkpoint (step outputs).
    func refreshRunFromStore() async {
        guard let runID = activeRunID else { return }
        if let r = try? await services.store.run(id: runID) { runRecord = r }
        runReceipt = try? await services.store.receipt(runID: runID)
        let events = (try? await services.store.events(runID: runID, afterSeq: 0, limit: 5000)) ?? []
        var info: [String: StepRunInfo] = [:]
        for e in events {
            guard let id = e.stepID else { continue }
            if e.kind == .stepStarted {
                var i = info[id] ?? StepRunInfo(status: .running)
                i.status = .running; i.startedAt = e.timestamp; i.endedAt = nil
                info[id] = i
            } else if e.kind == .stepFinished {
                var i = info[id] ?? StepRunInfo(status: .pending)
                i.status = StepStatus(rawValue: e.data["status"]?.stringValue ?? "") ?? i.status
                i.attempts = e.data["attempts"]?.intValue ?? i.attempts
                i.error = e.data["error"]?.stringValue
                i.note = e.data["note"]?.stringValue
                i.endedAt = e.timestamp
                if let ms = e.data["durationMs"]?.intValue { i.startedAt = e.timestamp.addingTimeInterval(-Double(ms) / 1000) }
                else if i.startedAt == nil { i.startedAt = e.timestamp }
                info[id] = i
            }
        }
        // A run that ended while a step was mid-flight (stopped process): do not show it as still running.
        if runRecord?.status.isTerminal ?? true { for (k, v) in info where v.status == .running { info[k]?.status = .canceled; info[k]?.endedAt = runRecord?.endedAt } }
        if let cp = try? await services.store.get(WorkflowCheckpoint.self, collection: Collections.workflowCheckpoints, id: runID) {
            for (_, r) in cp.results where info[r.stepID] != nil && !r.output.isNull { info[r.stepID]?.output = r.output }
        }
        if let outcome = runOutcome, outcome.runID == runID { for r in outcome.steps where info[r.stepID] != nil { info[r.stepID]?.output = r.output } }
        if runHandle != nil {
            // Live: the handle is the authority; the store only fills in what it has not reported yet.
            for (k, v) in info where stepInfo[k] == nil { stepInfo[k] = v }
        } else {
            stepInfo = info
        }
    }

    // MARK: Debugger controls

    func pauseRun() { if let h = runHandle { Task { await h.pause() } } }
    func resumeRun() { if let h = runHandle { Task { await h.resume() } } }
    func stepOver() { if let h = runHandle { Task { await h.stepOver() } } }
    func stopRun() { if let id = activeRunID { app.cancel(runID: id) } }

    /// Changes a workflow variable of the paused run. Returns the reason when the text is not a value.
    func setVariable(_ name: String, text: String) async -> String? {
        guard let h = runHandle else { return String(localized: "The run is not active any more.") }
        let value = ArgumentForm.parseLoose(text)
        await h.setVariable(name, to: value)
        runVariables = await h.variables()
        return nil
    }
}
