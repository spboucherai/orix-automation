// ORIX OS Automation
// File: Packages/ORIXServices/Sources/ORIXServices/WorkflowService.swift
// Description: Workflows end to end: storage with versions, validation, permission review and acceptance, runs (live, dry, debug), generation from natural language, schedules and the scheduler engine.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import CryptoKit
import Foundation
import ORIXAgentRuntime
import ORIXCore
import ORIXPersistence
import ORIXScheduler
import ORIXSecurity
import ORIXToolRegistry
import ORIXWorkflowEngine

public struct WorkflowRunRequest: Sendable {
    public var workflowID: String
    public var version: Int?
    public var parameters: [String: JSONValue] = [:]
    public var mode: ExecutionMode = .guided
    public var dryRun = false
    public var trigger = "manual"
    public var breakpoints: Set<String> = []
    public var startPaused = false
    public init(workflowID: String) { self.workflowID = workflowID }
}

public struct SavedWorkflow: Sendable {
    public var id: String
    public var version: Int
    public var document: WorkflowDocument
    public var diagnostics: [WorkflowDiagnostic]
    /// True when this save changed the declared permissions: earlier acceptance was withdrawn.
    public var permissionsReset: Bool
}

public struct PermissionReview: Sendable {
    public var proposed: [PermissionGrant]
    /// True when the user already accepted exactly these capabilities for this workflow.
    public var accepted: Bool
}

struct AcceptedPermissions: Codable, Sendable { var digest: String; var acceptedAt: Date; var parameters: [String: JSONValue] }

struct StoreWorkflowCheckpoints: WorkflowCheckpointStoring {
    let store: ORIXStore
    func save(_ checkpoint: WorkflowCheckpoint) async {
        // Saves may arrive out of order: keep the highest sequence.
        if let old = try? await store.get(WorkflowCheckpoint.self, collection: Collections.workflowCheckpoints, id: checkpoint.runID), old.sequence > checkpoint.sequence { return }
        try? await store.put(checkpoint, collection: Collections.workflowCheckpoints, id: checkpoint.runID)
    }
    func latest(runID: String) async -> WorkflowCheckpoint? { try? await store.get(WorkflowCheckpoint.self, collection: Collections.workflowCheckpoints, id: runID) }
    func remove(runID: String) async { _ = try? await store.remove(collection: Collections.workflowCheckpoints, id: runID) }
}

struct StoreSubworkflowLoader: SubworkflowLoading {
    let service: WorkflowService
    func loadWorkflow(_ reference: String) async throws -> WorkflowDocument { try await service.document(workflowID: reference) }
}

public actor WorkflowService {
    let store: ORIXStore
    let policy: PolicyEngine
    let executor: ToolExecutor
    let runs: RunManager
    let providers: ProviderHub
    let approvals: ApprovalCenter
    let interaction: InteractionCenter
    let paths: ORIXPaths
    let scheduleStore: StoreScheduleStore
    private var handles: [String: WorkflowRun] = [:]
    private var scheduler: SchedulerEngine?
    private var schedulerTask: Task<Void, Never>?
    private var monitor: TriggerMonitor?

    init(store: ORIXStore, policy: PolicyEngine, executor: ToolExecutor, runs: RunManager, providers: ProviderHub, approvals: ApprovalCenter,
         interaction: InteractionCenter, paths: ORIXPaths) {
        self.store = store; self.policy = policy; self.executor = executor; self.runs = runs; self.providers = providers
        self.approvals = approvals; self.interaction = interaction; self.paths = paths
        scheduleStore = StoreScheduleStore(store: store)
    }

    // MARK: Storage and validation

    public func list() async -> [WorkflowRow] { (try? await store.workflows()) ?? [] }

    public func source(workflowID: String, version: Int? = nil) async throws -> String {
        guard let s = try await store.workflowSource(workflowID: workflowID, version: version) else { throw RunError.notFound("Workflow \(workflowID)") }
        return s
    }

    public func document(workflowID: String, version: Int? = nil) async throws -> WorkflowDocument {
        guard let v = try await store.workflowVersion(workflowID: workflowID, version: version) else { throw RunError.notFound("Workflow \(workflowID)") }
        return try WorkflowCodec.parse(v.source, format: v.format == "json" ? .json : .yaml)
    }

    public func versions(workflowID: String) async -> [WorkflowVersionRow] { (try? await store.workflowVersions(workflowID: workflowID)) ?? [] }

    /// Parses and validates source against the tools, agents and workflows that exist right now.
    public func diagnose(_ source: String, format: WorkflowFormat = .yaml) async -> (document: WorkflowDocument?, diagnostics: [WorkflowDiagnostic]) {
        let tools = await executor.manifests()
        let agents = await runs.agents.profileNames()
        let ids = await list().map(\.id)
        return WorkflowCodec.diagnose(source: source, format: format, tools: tools, agents: agents, workflows: ids)
    }

    /// Saves a new version. Source with errors is refused; warnings are returned. The workflow id is `metadata.id`.
    public func save(source: String, format: WorkflowFormat = .yaml, note: String = "") async throws -> SavedWorkflow {
        let (doc, diagnostics) = await diagnose(source, format: format)
        guard let doc, !diagnostics.contains(where: { $0.severity == .error }) else {
            let first = diagnostics.first { $0.severity == .error }
            throw RunError.invalid("The workflow has errors and was not saved" + (first.map { ": line \($0.line): \($0.message)" } ?? "."))
        }
        let id = doc.metadata.id
        let before = try? await document(workflowID: id)
        let version = try await store.saveWorkflowVersion(workflowID: id, name: doc.metadata.name, source: source, format: format == .json ? "json" : "yaml", note: note)
        var reset = false
        if let before, before.spec.permissions != doc.spec.permissions {
            // Authority follows the document: changed permissions withdraw the earlier acceptance.
            await revokeAcceptance(workflowID: id)
            reset = true
        }
        await syncSchedules(workflowID: id, document: doc)
        return SavedWorkflow(id: id, version: version, document: doc, diagnostics: diagnostics, permissionsReset: reset)
    }

    public func delete(workflowID: String) async throws {
        await revokeAcceptance(workflowID: workflowID)
        for s in (try? await scheduleStore.schedules()) ?? [] where s.workflowID == workflowID { try? await scheduleStore.removeSchedule(id: s.id) }
        _ = try await store.deleteWorkflow(id: workflowID)
        scheduler?.storeDidChange()
    }

    /// Copies a built-in example into the user's workflows (as an editable first version).
    public func installBuiltIn(slug: String) async throws -> SavedWorkflow {
        guard let b = BuiltInWorkflows.workflow(slug: slug) else { throw RunError.notFound("Template \(slug)") }
        return try await save(source: b.yaml, note: "Created from the built-in template")
    }

    public func exportBundle(to url: URL) async throws -> BundleSummary { try await store.exportBundle(to: url) }
    public func importBundle(from url: URL) async throws -> BundleSummary { try await store.importBundle(from: url) }

    // MARK: Permissions

    static func digest(_ caps: [Capability]) -> String {
        let text = caps.map(\.displayString).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func resolvedParameters(_ doc: WorkflowDocument, _ provided: [String: JSONValue]) throws -> [String: JSONValue] {
        switch WorkflowEngine.resolveParameters(doc, provided: provided) {
        case .success(let p): return p
        case .failure(let e): throw RunError.invalid("Parameters are not valid: \(e.message)")
        }
    }

    /// What this workflow asks for with these parameters, and whether the user already accepted exactly that.
    public func permissionReview(workflowID: String, parameters: [String: JSONValue] = [:]) async throws -> PermissionReview {
        let doc = try await document(workflowID: workflowID)
        let params = try resolvedParameters(doc, parameters)
        let caps = doc.declaredCapabilities(home: NSHomeDirectory(), parameters: params)
        let accepted = try? await store.get(AcceptedPermissions.self, collection: "workflow-permissions", id: workflowID)
        let proposed = doc.proposedGrants(workflowID: workflowID, home: NSHomeDirectory(), parameters: params)
        return PermissionReview(proposed: proposed, accepted: accepted?.digest == Self.digest(caps))
    }

    /// The user accepted the declared permissions: they become workflow-scoped grants, replacing any earlier set.
    public func acceptPermissions(workflowID: String, parameters: [String: JSONValue] = [:]) async throws {
        let doc = try await document(workflowID: workflowID)
        let params = try resolvedParameters(doc, parameters)
        await revokeAcceptance(workflowID: workflowID)
        for g in doc.proposedGrants(workflowID: workflowID, home: NSHomeDirectory(), parameters: params) { await policy.add(g) }
        let caps = doc.declaredCapabilities(home: NSHomeDirectory(), parameters: params)
        try await store.put(AcceptedPermissions(digest: Self.digest(caps), acceptedAt: Date(), parameters: params), collection: "workflow-permissions", id: workflowID)
    }

    public func revokeAcceptance(workflowID: String) async {
        for g in await policy.grantsForWorkflow(workflowID) where g.isActive() { await policy.revoke(id: g.id) }
        _ = try? await store.remove(collection: "workflow-permissions", id: workflowID)
    }

    // MARK: Runs

    func makeEngine() async -> WorkflowEngine {
        let settings = await runs.settings()
        var options = AgentRunOptions(); options.verifier = settings.verifierModel
        let runtime = AgentRuntime(deps: AgentDependencies(providers: providers, tools: executor, events: store, memory: runs.memory,
                                                           interaction: interaction, agents: runs.agents, artifactsRoot: paths.artifacts), options: options)
        let agents = runs.agents
        let approvals = self.approvals
        let defaultModel = settings.defaultModel
        return WorkflowEngine(
            tools: executor, agents: runtime, events: store, checkpoints: StoreWorkflowCheckpoints(store: store),
            loader: StoreSubworkflowLoader(service: self),
            approval: { prompt in
                // A manual gate is shown through the same approval surface as tool approvals.
                let access = AccessRequest(runID: prompt.runID, callID: prompt.id, workflowID: prompt.workflowID, toolID: "workflow.approval",
                                           capabilities: [], tier: .consequential, sideEffect: .write, mode: .guided,
                                           summary: prompt.message, argumentsPreview: ["step": .string(prompt.stepID)])
                return await approvals.requestApproval(ApprovalRequest(id: prompt.id, access: access, missing: [], reason: "Manual gate in the workflow (step \(prompt.stepID))"))
            },
            agentProfiles: { name in
                guard var p = await agents.profile(named: name) else { return nil }
                if p.model.model.isEmpty, let d = defaultModel { p.model = d }
                return p
            },
            configuration: WorkflowEngineConfiguration(defaultModel: defaultModel))
    }

    @discardableResult
    public func startRun(_ req: WorkflowRunRequest) async throws -> String {
        guard let row = try await store.workflowVersion(workflowID: req.workflowID, version: req.version) else { throw RunError.notFound("Workflow \(req.workflowID)") }
        let doc = try WorkflowCodec.parse(row.source, format: row.format == "json" ? .json : .yaml)
        let params = try resolvedParameters(doc, req.parameters)
        let settings = await runs.settings()
        if doc.allSteps.contains(where: { if case .agent = $0.step.kind { return true }; return false }) && !req.dryRun {
            _ = try await runs.capped(settings.defaultBudget, settings: settings)   // refuses when today's limit is spent
        }
        let runID = UUID().uuidString
        let workDir = paths.scratch.appendingPathComponent(doc.metadata.id)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let artifacts = paths.artifacts.appendingPathComponent(runID)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let record = RunRecord(id: runID, kind: "workflow", title: doc.metadata.name + (req.dryRun ? " (dry run)" : ""), workflowID: doc.metadata.id,
                               workflowVersion: row.version, trigger: req.trigger, mode: req.mode, status: .running, startedAt: Date())
        try await store.saveRun(record)

        let engine = await makeEngine()
        let options = WorkflowRunOptions(runID: runID, parameters: params, mode: req.mode, dryRun: req.dryRun, workingDirectory: workDir,
                                         artifactsDirectory: artifacts, breakpoints: req.breakpoints, startPaused: req.startPaused)
        let handle = await engine.start(doc, options: options)
        handles[runID] = handle
        let hub = runs.live
        let watcher = Task {
            var last: [String: StepStatus] = [:]
            for await state in await handle.states() {
                for (k, s) in state.steps where last[k] != s { hub.publish(runID, .stepStatus(stepID: k, status: s.rawValue)) }
                last = state.steps
                hub.publish(runID, .status(state.status))
            }
        }
        let description = doc.metadata.description
        let snapshot = record
        let task = Task { [self] () -> RunRecord in
            let outcome = await handle.outcome()
            watcher.cancel()
            let receipt = await buildReceipt(outcome, title: snapshot.title, objective: description.isEmpty ? snapshot.title : description)
            let final = await runs.finalize(snapshot, status: outcome.status, usage: outcome.usage, error: outcome.errors.first, receipt: receipt)
            forget(runID)
            return final
        }
        await runs.register(runID: runID, task: task, cancel: { await handle.cancel() })
        return runID
    }

    private func forget(_ runID: String) { handles[runID] = nil }

    /// The debugger handle of a live workflow run (pause, step over, breakpoints, variables).
    public func handle(runID: String) -> WorkflowRun? { handles[runID] }

    func buildReceipt(_ o: WorkflowOutcome, title: String, objective: String) async -> RunReceipt {
        let events = (try? await store.events(runID: o.runID, afterSeq: 0, limit: 5000)) ?? []
        let calls = events.filter { $0.kind == .toolFinished }.map { e in
            ToolCallRecord(id: e.data["callID"]?.stringValue ?? e.id, toolID: e.data["toolID"]?.stringValue ?? "?", arguments: e.data["arguments"] ?? .null,
                           status: ToolStatus(rawValue: e.data["status"]?.stringValue ?? "") ?? .failed, summary: e.data["summary"]?.stringValue ?? e.text,
                           durationMs: e.data["durationMs"]?.intValue ?? 0, tier: (e.data["tier"]?.intValue).flatMap(ApprovalTier.init(rawValue:)), startedAt: e.timestamp)
        }
        var limitations = o.simulations
        if o.dryRun { limitations.insert("Dry run: nothing was changed. Steps listed below were simulated or not executed.", at: 0) }
        limitations += o.steps.filter { $0.status == .skipped }.map { "Step \($0.stepID) was skipped" + ($0.note.map { ": \($0)" } ?? "") }
        return RunReceipt(runID: o.runID, title: title, status: o.status, objective: objective, model: nil, startedAt: o.startedAt, endedAt: o.endedAt,
                          usage: o.usage, toolCalls: calls,
                          permissionsUsed: Array(Set(calls.filter { $0.status == .succeeded }.map { "\($0.toolID) (\(($0.tier ?? .readOnly).label))" })).sorted(),
                          artifacts: o.artifacts, verifications: o.verifications, agentSummary: "",
                          limitations: limitations, errors: o.errors + o.diagnostics.filter { $0.severity == .error }.map(\.message))
    }

    /// Continues a workflow run from its last checkpoint after a crash. Steps that were mid-flight and are not safe to
    /// repeat need an explicit decision per step key.
    public func resumeRun(runID: String, resolutions: [String: ORIXWorkflowEngine.InFlightResolution] = [:]) async throws {
        guard let cp = await StoreWorkflowCheckpoints(store: store).latest(runID: runID), var record = try await store.run(id: runID) else {
            throw RunError.notFound("A checkpoint for this run")
        }
        let engine = await makeEngine()
        let options = WorkflowRunOptions(runID: runID, parameters: cp.parameters, mode: cp.mode, dryRun: cp.dryRun,
                                         workingDirectory: paths.scratch.appendingPathComponent(cp.workflowID),
                                         artifactsDirectory: paths.artifacts.appendingPathComponent(runID), inFlightResolutions: resolutions)
        record.status = .recovering; record.endedAt = nil
        try await store.saveRun(record)
        let handle = await engine.resume(from: cp, options: options)
        handles[runID] = handle
        let title = record.title
        let snapshot = record
        let task = Task { [self] () -> RunRecord in
            let outcome = await handle.outcome()
            let receipt = await buildReceipt(outcome, title: title, objective: title)
            let final = await runs.finalize(snapshot, status: outcome.status, usage: outcome.usage, error: outcome.errors.first, receipt: receipt)
            forget(runID)
            return final
        }
        await runs.register(runID: runID, task: task, cancel: { await handle.cancel() })
    }

    // MARK: Natural language → workflow

    static let authoringGuide = """
    You write automations for ORIX OS Automation as one YAML document. Output only the YAML, no prose and no code fence.
    Shape:
    apiVersion: orix.ai/v1
    kind: Automation
    metadata: { id: kebab-case-id, name: Title, description: One sentence }
    spec:
      triggers: [ { type: manual } ]          # also schedule {cron, timezone}, interval {seconds}, fileChange {path, glob}, login
      parameters: [ { name, type: string|number|boolean|array|path, default, description } ]
      permissions:                            # the least that the steps need; folders as ${{ params.x }}
        filesystem: { read: [], write: [] }
        processes: []                         # executables for shell.run
        scripts: []                           # bash, python, applescript …
        network: []                           # hosts
      steps:
        - id: camelCaseId
          tool: family.action                 # exactly one of tool / agent / verify / approval / foreach / condition / set / transform / delay / notify / output
          with: { arg: value }
          needs: [earlierStepId]
    Rules: use only the tools listed below with exactly their argument names; expressions are ${{ … }} with params.x, vars.x, steps.<id>.output.<field>; \
    a step may only read outputs of steps listed in its needs (directly or transitively); never delete files, use filesystem.trash; put an approval step \
    before anything consequential; end with a verify step asserting the files that must exist (fileExists / fileNonEmpty / fileContains with path).
    """

    /// Asks a model to write a workflow for an objective, validates it, and gives the model one chance to repair
    /// validator errors. Returns the source and remaining diagnostics; nothing is saved or run.
    public func generate(objective: String, model: ModelRef? = nil) async throws -> (source: String, diagnostics: [WorkflowDiagnostic], usage: TokenUsage) {
        let settings = await runs.settings()
        guard let ref = model ?? settings.plannerModel ?? settings.defaultModel else { throw RunError.noModel }
        _ = try await runs.capped(.quick, settings: settings)
        let provider = try await providers.provider(for: ref.provider)
        let tools = await executor.manifests().filter { !$0.identifier.hasPrefix("skills.") }
        let catalog = tools.map { m -> String in
            let props = m.inputSchema.raw["properties"]?.objectValue ?? [:]
            let required = Set(m.inputSchema.raw["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let args = props.keys.sorted().map { required.contains($0) ? "\($0)*" : $0 }.joined(separator: ", ")
            let outs = (m.outputSchema.raw["properties"]?.objectValue ?? [:]).keys.sorted().joined(separator: ", ")
            return "- \(m.identifier)(\(args)) → {\(outs)} — \(m.summary.prefix(140))"
        }.joined(separator: "\n")
        let example = BuiltInWorkflows.workflow(slug: "system-health-report")?.yaml ?? BuiltInWorkflows.all().first?.yaml ?? ""
        let system = Self.authoringGuide + "\n\nTools (* = required argument):\n" + catalog + "\n\nA complete valid example:\n" + example
        var messages: [LLMMessage] = [.user("Write an automation for this objective:\n\(objective)")]
        var usage = TokenUsage()
        var source = ""
        var diagnostics: [WorkflowDiagnostic] = []
        for attempt in 0..<2 {
            let r = try await provider.complete(LLMRequest(model: ref.model, system: system, messages: messages, maxOutputTokens: 4000, cacheSystemAndTools: true))
            usage = usage + r.usage
            source = Self.stripFence(r.text)
            diagnostics = await diagnose(source).diagnostics
            let errors = diagnostics.filter { $0.severity == .error }
            if errors.isEmpty || attempt == 1 { break }
            messages.append(.assistant(r.text))
            messages.append(.user("The validator reported these errors. Return the corrected YAML only.\n" +
                                  errors.prefix(20).map { "line \($0.line): \($0.message)" }.joined(separator: "\n")))
        }
        // The generation cost is recorded as a small run so it shows in usage totals.
        var record = RunRecord(kind: "agent", title: "Draft workflow: " + String(objective.prefix(60)), trigger: "manual", mode: .review, status: .running, model: ref, startedAt: Date())
        var u = RunUsage(); u.turns = 1; u.tokens = usage
        if let c = usage.costUSD(model: await providers.modelInfo(ref)) { u.costUSD = c } else { u.costIsComplete = false }
        record.usage = u; record.status = diagnostics.contains { $0.severity == .error } ? .partiallySucceeded : .succeeded; record.endedAt = Date()
        try? await store.saveRun(record)
        return (source, diagnostics, usage)
    }

    static func stripFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let end = t.range(of: "```", options: .backwards) { t = String(t[..<end.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: Schedules

    /// Mirrors a document's non-manual triggers as schedules (`<workflowID>#<index>`), keeping the user's enabled/paused state.
    func syncSchedules(workflowID: String, document: WorkflowDocument) async {
        let existing = ((try? await scheduleStore.schedules()) ?? []).filter { $0.workflowID == workflowID && $0.id.hasPrefix(workflowID + "#") }
        var keep = Set<String>()
        for (i, t) in document.spec.triggers.enumerated() {
            let spec: TriggerSpec
            switch t {
            case .manual: continue
            case .schedule(let cron, let tz): spec = .cron(expression: cron, timezone: tz)
            case .once(let at):
                guard let d = ISO8601DateFormatter().date(from: at) else { continue }
                spec = .once(at: d)
            case .interval(let s): spec = .interval(seconds: s)
            case .fileChange(let path, let glob, let debounce):
                let p = (try? PathResolver.canonical(path, relativeTo: URL(fileURLWithPath: NSHomeDirectory()))) ?? path
                spec = .fileChange(path: p, recursive: true, glob: glob, debounceSeconds: debounce ?? 2)
            case .login: spec = .login
            case .appLaunch(let b): spec = .appLaunch(bundleID: b)
            }
            let id = "\(workflowID)#\(i)"
            keep.insert(id)
            var s = existing.first { $0.id == id } ?? Schedule(id: id, workflowID: workflowID, name: document.metadata.name, trigger: spec, enabled: false)
            // A new schedule starts disabled: the user turns it on in the Scheduler after reviewing permissions.
            s.trigger = spec; s.name = document.metadata.name
            try? await scheduleStore.saveSchedule(s)
        }
        for s in existing where !keep.contains(s.id) { try? await scheduleStore.removeSchedule(id: s.id) }
        scheduler?.storeDidChange()
        await refreshMonitor()
    }

    public func schedules() async -> [Schedule] { (try? await scheduleStore.schedules()) ?? [] }
    public func queue() async -> [QueueItem] { ((try? await scheduleStore.queueItems()) ?? []).sorted { $0.enqueuedAt > $1.enqueuedAt } }

    public func saveSchedule(_ schedule: Schedule) async throws {
        let problems = schedule.problems()
        guard problems.isEmpty else { throw RunError.invalid(problems.joined(separator: "; ")) }
        if let scheduler { _ = try await scheduler.save(schedule) } else { try await scheduleStore.saveSchedule(schedule) }
        await refreshMonitor()
    }

    public func removeSchedule(id: String) async throws {
        try await scheduleStore.removeSchedule(id: id)
        scheduler?.storeDidChange(); await refreshMonitor()
    }

    public func setSchedule(id: String, enabled: Bool) async throws {
        guard var s = try await scheduleStore.schedule(id: id) else { throw RunError.notFound("Schedule") }
        s.enabled = enabled
        try await saveSchedule(s)
    }

    public func upcoming(limit: Int = 20) async -> [(Schedule, Date)] {
        if let scheduler, let u = try? await scheduler.upcoming(limit: limit) { return u }
        let now = Date()
        return await schedules().filter { $0.enabled && !$0.paused }.compactMap { s in s.trigger.nextFireDate(after: now, anchor: s.createdAt).map { (s, $0) } }
            .sorted { $0.1 < $1.1 }.prefix(limit).map { $0 }
    }

    private func refreshMonitor() async { monitor?.update(schedules: await schedules()) }

    /// Starts the scheduler loop in this process. Only the lease holder fires; a second process stays passive and takes
    /// over if the first one stops. Scheduled runs use mode `.scheduled`: nothing is auto-approved.
    public func startScheduler(owner: String) async {
        guard scheduler == nil else { return }
        let engine = SchedulerEngine(store: scheduleStore, launcher: { [weak self] item, schedule in
            guard let self else { return .failed(runID: nil, error: "The service stopped", retryable: true) }
            return await self.launch(item, schedule)
        }, owner: owner)
        scheduler = engine
        let m = TriggerMonitor(engine: engine)
        monitor = m
        m.update(schedules: await schedules())
        schedulerTask = Task { await engine.run() }
        // Writes from another process (the app editing schedules) wake the engine.
        Task { [weak engine] in for await _ in ORIXStore.darwinChanges() { engine?.storeDidChange() } }
    }

    public func stopScheduler() async {
        monitor?.stop(); monitor = nil
        await scheduler?.stop()
        schedulerTask?.cancel(); schedulerTask = nil; scheduler = nil
    }

    public func schedulerIsActive() async -> Bool { await scheduler?.isActive ?? false }

    func launch(_ item: QueueItem, _ schedule: Schedule) async -> RunLaunchResult {
        var req = WorkflowRunRequest(workflowID: schedule.workflowID)
        req.mode = .scheduled; req.trigger = schedule.trigger.kind
        if let accepted = try? await store.get(AcceptedPermissions.self, collection: "workflow-permissions", id: schedule.workflowID) { req.parameters = accepted.parameters }
        do {
            let runID = try await startRun(req)
            guard let final = await runs.wait(runID: runID) else { return .failed(runID: runID, error: "The run record is missing", retryable: false) }
            switch final.status {
            case .succeeded, .partiallySucceeded: return .succeeded(runID: runID)
            case .waitingApproval, .blockedPermission: return .waitingApproval(runID: runID)
            case .canceled: return .canceled(runID: runID)
            default: return .failed(runID: runID, error: final.errorSummary ?? final.status.rawValue, retryable: final.status == .timedOut)
            }
        } catch {
            return .failed(runID: nil, error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, retryable: false)
        }
    }
}
