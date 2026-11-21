// ORIX OS Automation
// File: Packages/ORIXAppUI/Sources/ORIXAppUI/RunTimeline.swift
// Description: The persisted timeline of a run (messages, tool calls, approvals, verification, errors), loaded incrementally from the store and refreshed while the run is live.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXCore
import ORIXServices
import SwiftUI

public extension RunEvent.Kind {
    var symbol: String {
        switch self {
        case .statusChanged: return "circle.dotted"
        case .userMessage: return "person.fill"
        case .assistantText: return "sparkles"
        case .reasoningSummary: return "brain"
        case .planUpdated: return "list.bullet.clipboard"
        case .toolRequested: return "wrench.and.screwdriver"
        case .toolProgress: return "ellipsis"
        case .toolFinished: return "wrench.and.screwdriver.fill"
        case .approvalRequested: return "hand.raised"
        case .approvalResolved: return "hand.thumbsup"
        case .stepStarted: return "play"
        case .stepFinished: return "checkmark"
        case .verification: return "checkmark.seal"
        case .usage: return "gauge.with.dots.needle.50percent"
        case .retry: return "arrow.clockwise"
        case .checkpoint: return "bookmark"
        case .memory: return "tray.full"
        case .log: return "text.alignleft"
        case .error: return "exclamationmark.triangle.fill"
        case .receipt: return "doc.text.fill"
        }
    }

    var tint: Color {
        switch self {
        case .error: return Theme.danger
        case .approvalRequested, .approvalResolved, .planUpdated: return Theme.violet
        case .verification: return Theme.success
        case .retry: return Theme.warning
        case .userMessage: return Theme.blue
        default: return Theme.textSecondary
        }
    }
}

/// Loads the events of one run and keeps them current. Shared by Chat, Runs and the studios.
@MainActor
@Observable
public final class RunTimelineModel {
    public private(set) var events: [RunEvent] = []
    public private(set) var run: RunRecord?
    public let runID: String
    private let services: ORIXServices
    private var lastSeq = 0

    public init(runID: String, services: ORIXServices) { self.runID = runID; self.services = services }

    /// Fetches events after the last one seen. Cheap to call on every store change.
    public func refresh() async {
        run = try? await services.store.run(id: runID)
        while true {
            let batch = (try? await services.store.events(runID: runID, afterSeq: lastSeq, limit: 500)) ?? []
            guard !batch.isEmpty else { break }
            events.append(contentsOf: batch)
            lastSeq = batch.last?.seq ?? lastSeq
            if batch.count < 500 { break }
        }
    }
}

public struct RunEventRow: View {
    let event: RunEvent
    public init(event: RunEvent) { self.event = event }

    private var toolStatus: ToolStatus? { event.kind == .toolFinished ? ToolStatus(rawValue: event.data["status"]?.stringValue ?? "") : nil }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(Format.time(event.timestamp)).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).frame(width: 64, alignment: .leading)
            Image(systemName: event.kind.symbol).font(.system(size: 11)).foregroundStyle(event.kind.tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let tool = event.data["toolID"]?.stringValue { Text(tool).font(Theme.Font.monoSmall).foregroundStyle(Theme.text) }
                    if let s = toolStatus { StatusBadge(tool: s, compact: false) }
                    if let step = event.stepID { Pill(text: step, symbol: "smallcircle.filled.circle") }
                    if let ms = event.data["durationMs"]?.intValue, event.kind == .toolFinished { Text(Format.duration(Double(ms) / 1000)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                }
                if !event.text.isEmpty && event.kind != .receipt {
                    Text(event.text).font(event.kind == .assistantText || event.kind == .userMessage ? Theme.Font.body : Theme.Font.monoSmall)
                        .foregroundStyle(event.kind == .error ? Theme.danger : Theme.text).textSelection(.enabled)
                        .lineLimit(event.kind == .assistantText || event.kind == .userMessage ? nil : 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if event.kind == .receipt {
                    Text("Execution receipt recorded").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// A scrolling, virtualised list of a run's events that follows the tail while the run is live.
public struct RunEventList: View {
    @Environment(AppModel.self) private var model
    @State private var timeline: RunTimelineModel?
    let runID: String
    var kinds: Set<RunEvent.Kind>?

    public init(runID: String, kinds: Set<RunEvent.Kind>? = nil) { self.runID = runID; self.kinds = kinds }

    public var body: some View {
        let shown = (timeline?.events ?? []).filter { e in e.kind != .toolProgress && e.kind != .usage && (kinds?.contains(e.kind) ?? true) }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { e in RunEventRow(event: e).id(e.id) }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
            }
            .onChange(of: shown.count) { _, _ in
                if timeline?.run?.status.isTerminal == false { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
        .overlay { if shown.isEmpty { Text("No events yet").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) } }
        .task(id: runID) {
            let t = RunTimelineModel(runID: runID, services: model.services)
            timeline = t
            await t.refresh()
        }
        .task(id: model.revision) { await timeline?.refresh() }
    }
}
