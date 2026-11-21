// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/RunsModel.swift
// Description      : Runs logic without UI: filters, the paginated list model,
//                    what a retry would start, per-tool usage totals, and the
//                    receipt export formats.
// Module           : ORIXFeatureRuns
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
import Observation
import ORIXAppUI

/// How a run was started, grouped the way a person thinks about it.
public enum TriggerGroup: String, CaseIterable, Identifiable, Sendable {
    case manual, schedule, fileChange, systemEvent, agent, debug
    public var id: String { rawValue }

    public static func of(_ raw: String) -> TriggerGroup? {
        switch raw {
        case "manual": return .manual
        case "schedule", "cron", "once", "interval": return .schedule
        case "file", "fileChange": return .fileChange
        case "login", "appLaunch", "powerConnected", "networkAvailable": return .systemEvent
        case "agent": return .agent
        case "debug": return .debug
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .manual: return String(localized: "Started by hand")
        case .schedule: return String(localized: "Schedule")
        case .fileChange: return String(localized: "File change")
        case .systemEvent: return String(localized: "System event")
        case .agent: return String(localized: "Another agent")
        case .debug: return String(localized: "Debugger")
        }
    }

    public static func title(raw: String) -> String { of(raw)?.title ?? raw }
}

public enum RunKind {
    public static let known = ["agent", "workflow", "script"]
    public static func title(_ kind: String) -> String {
        switch kind {
        case "agent": return String(localized: "Agent")
        case "workflow": return String(localized: "Workflow")
        case "script": return String(localized: "Script")
        default: return kind
        }
    }
    public static func symbol(_ kind: String) -> String {
        switch kind {
        case "agent": return "sparkles"
        case "workflow": return "point.3.connected.trianglepath.dotted"
        case "script": return "chevron.left.forwardslash.chevron.right"
        default: return "circle"
        }
    }
}

public extension ExecutionMode {
    var title: String {
        switch self {
        case .quick: return String(localized: "Quick action")
        case .guided: return String(localized: "Guided")
        case .autonomous: return String(localized: "Autonomous")
        case .scheduled: return String(localized: "Scheduled")
        case .review: return String(localized: "Review (read-only)")
        }
    }
}

public struct RunFilter: Equatable, Sendable {
    public var search = ""
    public var statuses: Set<RunStatus> = []
    public var kinds: Set<String> = []
    public var triggers: Set<TriggerGroup> = []
    public var from: Date?
    public var to: Date?
    public var newestFirst = true
    public init() {}

    /// The store can filter on one status; more than one is filtered here.
    public var storeStatus: RunStatus? { statuses.count == 1 ? statuses.first : nil }

    public var isActive: Bool { !statuses.isEmpty || !kinds.isEmpty || !triggers.isEmpty || from != nil || to != nil }
    public var activeCount: Int { statuses.count + kinds.count + triggers.count + (from != nil ? 1 : 0) + (to != nil ? 1 : 0) }

    /// Everything except the text search (the store does that one).
    public func matches(_ r: RunRecord) -> Bool {
        if !statuses.isEmpty, !statuses.contains(r.status) { return false }
        if !kinds.isEmpty, !kinds.contains(r.kind) { return false }
        if !triggers.isEmpty {
            guard let g = TriggerGroup.of(r.trigger), triggers.contains(g) else { return false }
        }
        let when = r.startedAt ?? r.queuedAt
        if let from, when < from { return false }
        if let to, when > to { return false }
        return true
    }
}

/// The run history list: pages from the store, filters what the store cannot, keeps what is loaded current.
@MainActor
@Observable
public final class RunsListModel {
    public private(set) var rows: [RunRecord] = []
    public private(set) var hasMore = true
    public private(set) var isLoading = false
    public private(set) var loadError: String?
    public var filter = RunFilter()
    public let pageSize: Int

    @ObservationIgnored private let store: ORIXStore
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var generation = 0
    /// Most store rows scanned for one page when filters reject nearly everything.
    static let scanLimit = 4000

    public init(store: ORIXStore, pageSize: Int = 60) { self.store = store; self.pageSize = pageSize }

    /// Starts over with the current filter.
    public func reload() async {
        generation += 1
        offset = 0; hasMore = true
        let target = filter.newestFirst ? pageSize : Int.max
        let (loaded, error) = await fetch(atLeast: target, into: [], generation: generation)
        if let loaded { rows = present(loaded) }
        loadError = error
    }

    /// Loads the next page (newest-first order only: oldest-first already loaded everything).
    public func loadMore() async {
        guard hasMore, !isLoading, filter.newestFirst else { return }
        let (loaded, error) = await fetch(atLeast: rows.count + pageSize, into: rows, generation: generation)
        if let loaded { rows = loaded }
        loadError = error
    }

    /// Re-reads what is already on screen after a store change, keeping the scroll position meaningful.
    public func refresh() async {
        guard !isLoading else { return }
        let wanted = max(pageSize, rows.count)
        generation += 1
        offset = 0; hasMore = true
        let (loaded, error) = await fetch(atLeast: filter.newestFirst ? wanted : Int.max, into: [], generation: generation)
        if let loaded { rows = present(loaded) }
        loadError = error
    }

    private func present(_ newestFirst: [RunRecord]) -> [RunRecord] { filter.newestFirst ? newestFirst : newestFirst.reversed() }

    private func fetch(atLeast target: Int, into start: [RunRecord], generation g: Int) async -> ([RunRecord]?, String?) {
        isLoading = true
        defer { if g == generation { isLoading = false } }
        var out = start
        var scanned = 0
        let f = filter
        do {
            while out.count < target, hasMore, scanned < Self.scanLimit || !f.newestFirst {
                let batch = try await store.runs(limit: pageSize, offset: offset, status: f.storeStatus, search: f.search.isEmpty ? nil : f.search)
                guard g == generation else { return (nil, nil) }
                offset += batch.count; scanned += batch.count
                out.append(contentsOf: batch.filter(f.matches))
                if batch.count < pageSize { hasMore = false }
                // The store returns newest first: once a page is entirely before the range, nothing later can match.
                if let from = f.from, let last = batch.last, last.queuedAt < from.addingTimeInterval(-86_400) { hasMore = false }
                if scanned >= 50_000 { hasMore = false }
            }
            return (out, nil)
        } catch {
            return (out, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

/// What "Retry" would start, recovered from the run's record, events and checkpoint.
public enum RetryPlan: Sendable {
    case workflow(WorkflowRunRequest, note: String)
    case agent(AgentRunRequest, note: String)

    public var note: String {
        switch self { case .workflow(_, let n), .agent(_, let n): return n }
    }

    /// Nil when the original inputs cannot be recovered: then no Retry is offered.
    @MainActor
    public static func recover(for run: RunRecord, services: ORIXServices, defaultWorkspace: String) async -> RetryPlan? {
        guard run.status.isTerminal, run.status != .recoveryRequired else { return nil }
        switch run.kind {
        case "workflow":
            guard let id = run.workflowID, let doc = try? await services.workflows.document(workflowID: id, version: run.workflowVersion) else { return nil }
            let checkpoint = try? await services.store.get(WorkflowCheckpoint.self, collection: Collections.workflowCheckpoints, id: run.id)
            var request = WorkflowRunRequest(workflowID: id)
            request.version = run.workflowVersion
            request.mode = run.mode == .scheduled ? .guided : run.mode
            request.dryRun = checkpoint?.dryRun ?? run.title.hasSuffix(" (dry run)")
            if let checkpoint {
                request.parameters = checkpoint.parameters
                return .workflow(request, note: String(localized: "Runs version \(run.workflowVersion ?? 0) of the workflow again with the same parameters. Steps that already changed something will run again."))
            }
            // A successful run leaves no checkpoint. Without declared parameters there is nothing to recover.
            guard doc.spec.parameters.isEmpty else { return nil }
            return .workflow(request, note: String(localized: "Runs version \(run.workflowVersion ?? 0) of the workflow again. It takes no parameters. Steps that already changed something will run again."))
        case "agent":
            let checkpoint = try? await services.store.get(AgentCheckpoint.self, collection: Collections.agentCheckpoints, id: run.id)
            let events = (try? await services.store.events(runID: run.id, afterSeq: 0, limit: 40)) ?? []
            guard let objective = checkpoint?.task.objective ?? events.first(where: { $0.kind == .userMessage })?.text, !objective.isEmpty else { return nil }
            let folder = checkpoint?.task.workingDirectory ?? defaultWorkspace
            var request = AgentRunRequest(objective: objective, workingDirectory: folder)
            request.model = run.model; request.mode = run.mode == .scheduled ? .guided : run.mode
            request.title = run.title; request.workspaceAccess = .read
            return .agent(request, note: String(localized: "Sends the same objective to the agent as a new run, with read access to \(PathResolver.display(folder)). Anything else will be asked for again."))
        default:
            return nil
        }
    }
}

/// Calls and time per tool, for the Usage tab.
public struct ToolUsageRow: Identifiable, Sendable, Hashable {
    public var toolID: String
    public var calls: Int
    public var failed: Int
    public var totalMs: Int
    public var id: String { toolID }

    public static func aggregate(_ calls: [ToolCallRecord]) -> [ToolUsageRow] {
        var by: [String: ToolUsageRow] = [:]
        for c in calls {
            var row = by[c.toolID] ?? ToolUsageRow(toolID: c.toolID, calls: 0, failed: 0, totalMs: 0)
            row.calls += 1; row.totalMs += c.durationMs
            if c.status != .succeeded && c.status != .simulated { row.failed += 1 }
            by[c.toolID] = row
        }
        return by.values.sorted { ($0.totalMs, $0.calls, $1.toolID) > ($1.totalMs, $1.calls, $0.toolID) }
    }

    /// The same records rebuilt from a run's events, for runs that have no receipt (still running, or crashed).
    public static func calls(from events: [RunEvent]) -> [ToolCallRecord] {
        events.filter { $0.kind == .toolFinished }.map { e in
            ToolCallRecord(id: e.data["callID"]?.stringValue ?? e.id, toolID: e.data["toolID"]?.stringValue ?? "?", arguments: e.data["arguments"] ?? .null,
                           status: ToolStatus(rawValue: e.data["status"]?.stringValue ?? "") ?? .failed, summary: e.data["summary"]?.stringValue ?? e.text,
                           durationMs: e.data["durationMs"]?.intValue ?? 0, tier: (e.data["tier"]?.intValue).flatMap(ApprovalTier.init(rawValue:)), startedAt: e.timestamp)
        }
    }
}

public enum ReceiptExport {
    /// The human-readable receipt (the runtime's own Markdown).
    public static func markdown(_ receipt: RunReceipt) -> String { receipt.markdown() }

    /// The machine-readable receipt: pretty-printed JSON, stable key order, ISO 8601 dates.
    public static func json(_ receipt: RunReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(receipt)
    }

    public static func fileName(_ receipt: RunReceipt, ext: String) -> String {
        let slug = receipt.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        return "receipt-\(collapsed.prefix(40).isEmpty ? "run" : String(collapsed.prefix(40)))-\(receipt.runID.prefix(8)).\(ext)"
    }
}
