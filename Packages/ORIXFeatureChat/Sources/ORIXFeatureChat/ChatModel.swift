// ORIX OS Automation
// File: Packages/ORIXFeatureChat/Sources/ORIXFeatureChat/ChatModel.swift
// Description: Chat state: persisted sessions, the transcript built from each run's stored events, live streaming text and tool output, and the actions of the composer.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Observation
import ORIXAppUI

/// A conversation as stored: the session plus the runs it produced, in order.
public struct ChatSessionRecord: Codable, Sendable, Hashable, Identifiable {
    public var session: AgentSession
    public var runIDs: [String]
    public var agent: String
    public var access: WorkspaceAccess
    public var id: String { session.id }
}

/// One thing shown in the transcript.
public enum ChatItem: Identifiable, Hashable, Sendable {
    case user(id: String, text: String, date: Date)
    case assistant(id: String, text: String, date: Date)
    case reasoning(id: String, text: String)
    case plan(id: String, plan: AgentPlan)
    case tool(ToolActivity)
    case notice(id: String, kind: RunEvent.Kind, text: String)
    case verification(id: String, passed: Bool, text: String)
    case outcome(RunOutcomeSummary)

    public var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _, _), .reasoning(let id, _), .plan(let id, _), .notice(let id, _, _), .verification(let id, _, _): return id
        case .tool(let t): return "tool-" + t.id
        case .outcome(let o): return "outcome-" + o.runID
        }
    }
}

public struct ToolActivity: Identifiable, Hashable, Sendable {
    public var id: String
    public var toolID: String
    public var arguments: JSONValue
    /// Nil while running.
    public var status: ToolStatus?
    public var summary: String
    public var durationMs: Int?
    public var tier: ApprovalTier?
    public var liveOutput: String
}

public struct RunOutcomeSummary: Hashable, Sendable {
    public var runID: String
    public var status: RunStatus
    public var usage: RunUsage
    public var artifacts: [Artifact]
    public var limitations: [String]
    public var errors: [String]
    public var duration: Double?
}

@MainActor
@Observable
public final class ChatModel {
    let app: AppModel
    var services: ORIXServices { app.services }

    public private(set) var sessions: [ChatSessionRecord] = []
    public var currentID: String?
    public private(set) var items: [ChatItem] = []
    public private(set) var streamingText = ""
    public private(set) var streamingReasoning = ""
    public private(set) var activeRunID: String?
    public private(set) var activeStatus: RunStatus?
    public private(set) var liveUsage: RunUsage?
    public private(set) var currentPlan: AgentPlan?
    public private(set) var isPaused = false

    // Composer
    public var draft = ""
    public var mode: ExecutionMode = .guided
    public var agent = "general"
    public var modelChoice: ModelRef?
    public var workspace = ""
    public var access: WorkspaceAccess = .read
    public private(set) var agentNames: [String] = []
    public private(set) var modelOptions: [ModelInfo] = []

    private var timelines: [String: RunTimelineModel] = [:]
    private var liveTask: Task<Void, Never>?
    private var liveTools: [String: ToolActivity] = [:]

    public init(app: AppModel) {
        self.app = app
        mode = app.settings.defaultMode
        workspace = app.defaultWorkspace
    }

    public var current: ChatSessionRecord? { sessions.first { $0.id == currentID } }
    public var isRunning: Bool { activeRunID != nil }
    public var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Loading

    public func load() async {
        sessions = ((try? await services.store.all(ChatSessionRecord.self, collection: Collections.sessions)) ?? []).sorted { $0.session.updatedAt > $1.session.updatedAt }
        agentNames = await services.agents.profileNames()
        var options: [ModelInfo] = []
        for p in app.configuredProviders { options += ModelRegistry.models(for: p) }
        modelOptions = options
        if currentID == nil { currentID = sessions.first?.id }
        if let c = current, !isRunning { agent = c.agent; access = c.access; workspace = c.session.workingDirectory; mode = c.session.mode }
        await rebuild()
    }

    public func select(_ id: String?) async {
        guard !isRunning else { return }
        currentID = id
        timelines = [:]
        if let c = current { agent = c.agent; access = c.access; workspace = c.session.workingDirectory; mode = c.session.mode }
        await rebuild()
    }

    public func newSession() async {
        guard !isRunning else { return }
        currentID = nil; items = []; timelines = [:]; currentPlan = nil; liveUsage = nil
        workspace = app.defaultWorkspace; mode = app.settings.defaultMode
    }

    public func delete(_ id: String) async {
        guard activeRunID == nil || currentID != id else { return }
        _ = try? await services.store.remove(collection: Collections.sessions, id: id)
        _ = try? await services.store.remove(collection: Collections.sessionMessages, id: id)
        if currentID == id { currentID = nil; items = [] }
        await load()
    }

    /// Rebuilds the transcript of the current session from stored events. Called on every store change.
    public func rebuild() async {
        guard let c = current else { if !isRunning { items = [] }; return }
        var out: [ChatItem] = []
        for runID in c.runIDs {
            let t = timelines[runID] ?? RunTimelineModel(runID: runID, services: services)
            timelines[runID] = t
            await t.refresh()
            out += Self.items(from: t.events, live: runID == activeRunID ? liveTools : [:])
            if let run = t.run, run.status.isTerminal, let receipt = try? await services.store.receipt(runID: runID) {
                out.append(.outcome(RunOutcomeSummary(runID: runID, status: run.status, usage: run.usage, artifacts: receipt.artifacts,
                                                      limitations: receipt.limitations, errors: receipt.errors, duration: run.durationSeconds)))
            } else if let run = t.run, run.status.isTerminal {
                out.append(.outcome(RunOutcomeSummary(runID: runID, status: run.status, usage: run.usage, artifacts: [], limitations: [],
                                                      errors: run.errorSummary.map { [$0] } ?? [], duration: run.durationSeconds)))
            }
        }
        items = out
    }

    /// Turns persisted run events into transcript items. Pure, so it is unit-tested.
    nonisolated static func items(from events: [RunEvent], live: [String: ToolActivity]) -> [ChatItem] {
        var out: [ChatItem] = []
        var seenTools = Set<String>()
        for e in events {
            switch e.kind {
            case .userMessage: out.append(.user(id: e.id, text: e.text, date: e.timestamp))
            case .assistantText: out.append(.assistant(id: e.id, text: e.text, date: e.timestamp))
            case .reasoningSummary: out.append(.reasoning(id: e.id, text: e.text))
            case .planUpdated:
                if let plan = try? e.data.decode(AgentPlan.self) {
                    out.removeAll { if case .plan = $0 { return true }; return false }   // show the latest revision only
                    out.append(.plan(id: e.id, plan: plan))
                }
            case .toolFinished:
                let id = e.data["callID"]?.stringValue ?? e.id
                seenTools.insert(id)
                out.append(.tool(ToolActivity(id: id, toolID: e.data["toolID"]?.stringValue ?? "tool", arguments: e.data["arguments"] ?? .null,
                                              status: ToolStatus(rawValue: e.data["status"]?.stringValue ?? "") ?? .failed,
                                              summary: e.data["summary"]?.stringValue ?? e.text, durationMs: e.data["durationMs"]?.intValue,
                                              tier: (e.data["tier"]?.intValue).flatMap(ApprovalTier.init(rawValue:)), liveOutput: "")))
            case .verification:
                out.append(.verification(id: e.id, passed: e.data["passed"]?.boolValue ?? e.text.hasPrefix("PASS"), text: e.text))
            case .retry, .error, .checkpoint, .memory, .approvalResolved:
                out.append(.notice(id: e.id, kind: e.kind, text: e.text))
            case .log:
                if e.text.hasPrefix("Question for the user") || e.text.hasPrefix("Delegating") || e.text.hasPrefix("Blocked") { out.append(.notice(id: e.id, kind: e.kind, text: e.text)) }
            case .statusChanged, .toolRequested, .toolProgress, .approvalRequested, .stepStarted, .stepFinished, .usage, .receipt: break
            }
        }
        for t in live.values.sorted(by: { $0.id < $1.id }) where !seenTools.contains(t.id) { out.append(.tool(t)) }
        return out
    }

    // MARK: Sending

    public func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let runID = activeRunID {
            // The agent is working: queue the message as an instruction for the next turn boundary.
            await services.runs.steer(runID: runID, text)
            draft = ""
            return
        }
        var record = current ?? ChatSessionRecord(
            session: AgentSession(title: String(text.prefix(60)), model: modelChoice ?? app.settings.defaultModel ?? ModelRef(provider: .anthropic, model: ""),
                                  mode: mode, workingDirectory: workspace),
            runIDs: [], agent: agent, access: access)
        record.session.mode = mode; record.session.workingDirectory = workspace; record.agent = agent; record.access = access
        var req = AgentRunRequest(objective: text, workingDirectory: workspace)
        req.mode = mode; req.agent = agent; req.model = modelChoice; req.workspaceAccess = access; req.sessionID = record.id
        guard let runID = await app.startAgentRun(req) else { return }
        draft = ""
        record.runIDs.append(runID); record.session.updatedAt = Date()
        try? await services.store.put(record, collection: Collections.sessions, id: record.id)
        if !sessions.contains(where: { $0.id == record.id }) { sessions.insert(record, at: 0) } else if let i = sessions.firstIndex(where: { $0.id == record.id }) { sessions[i] = record }
        currentID = record.id
        follow(runID)
        await rebuild()
    }

    /// Subscribes to the live (non-persisted) updates of a run.
    func follow(_ runID: String) {
        activeRunID = runID; activeStatus = .running; streamingText = ""; streamingReasoning = ""; liveTools = [:]; liveUsage = nil; currentPlan = nil; isPaused = false
        liveTask?.cancel()
        let stream = services.runs.live.subscribe(runID: runID)
        liveTask = Task { [weak self] in
            for await update in stream { await self?.apply(update, runID: runID) }
            await self?.finished(runID)
        }
    }

    private func apply(_ update: LiveUpdate, runID: String) async {
        switch update {
        case .text(let d): streamingText += d
        case .reasoning(let d): streamingReasoning += d
        case .toolStarted(let call):
            // The model's text for this turn is persisted before its tools run: stop showing the streamed copy.
            streamingText = ""; streamingReasoning = ""
            liveTools[call.id] = ToolActivity(id: call.id, toolID: call.toolID, arguments: Redactor.shared.redact(call.arguments), status: nil, summary: "", durationMs: nil, tier: nil, liveOutput: "")
            await rebuild()
        case .toolProgress(let callID, let p):
            if var t = liveTools[callID] {
                t.liveOutput = String((t.liveOutput + p.text).suffix(4000)); liveTools[callID] = t
                if let i = items.firstIndex(where: { $0.id == "tool-" + callID }) { items[i] = .tool(t) }
            }
        case .toolFinished(let call, _): liveTools[call.id] = nil
        case .plan(let p): currentPlan = p
        case .status(let s):
            activeStatus = s; isPaused = s == .paused
            if s == .recovering { streamingText = "" }
        case .usage(let u): liveUsage = u
        case .stepStatus: break
        case .finished(let s): activeStatus = s
        }
    }

    private func finished(_ runID: String) async {
        guard activeRunID == runID else { return }
        activeRunID = nil; streamingText = ""; streamingReasoning = ""; liveTools = [:]; isPaused = false
        await rebuild()
    }

    public func stop() { if let id = activeRunID { app.cancel(runID: id) } }

    public func togglePause() async {
        guard let id = activeRunID else { return }
        if isPaused { await services.runs.resume(runID: id); isPaused = false } else { await services.runs.pause(runID: id); isPaused = true }
    }

    /// Sends the previous objective again as a new run in the same session.
    public func retryLast() async {
        guard !isRunning, let last = items.last(where: { if case .user = $0 { return true }; return false }), case .user(_, let text, _) = last else { return }
        draft = text
        await send()
    }
}
