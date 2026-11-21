// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/RunDetailView.swift
// Description: Detail of one run: header with identifiers and timing, the actions that really exist for its state (stop, pause, retry, recover, export, delete), and the Timeline, Receipt, Usage and Console tabs.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI
import UniformTypeIdentifiers

enum RunTab: String, CaseIterable, Identifiable {
    case timeline, receipt, usage, console
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .timeline: return "Timeline"; case .receipt: return "Receipt"; case .usage: return "Usage"; case .console: return "Console" }
    }
}

@MainActor
@Observable
final class RunDetailModel {
    var run: RunRecord?
    var missing = false
    var receipt: RunReceipt?
    var retry: RetryPlan?
    var activeHere = false
    var toolCalls: [ToolCallRecord] = []
    var busy = false

    func load(runID: String, services: ORIXServices, defaultWorkspace: String) async {
        guard let r = try? await services.store.run(id: runID) else { missing = true; run = nil; return }
        run = r; missing = false
        receipt = try? await services.store.receipt(runID: runID)
        activeHere = await services.runs.isActive(runID)
        retry = await RetryPlan.recover(for: r, services: services, defaultWorkspace: defaultWorkspace)
        if let receipt, !receipt.toolCalls.isEmpty { toolCalls = receipt.toolCalls }
        else { toolCalls = ToolUsageRow.calls(from: (try? await services.store.events(runID: runID, afterSeq: 0, limit: 5000)) ?? []) }
    }
}

struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    let runID: String
    var initialTab: RunTab = .timeline
    @State private var detail = RunDetailModel()
    @State private var tab: RunTab = .timeline
    @State private var confirmDelete = false
    @State private var confirmRetry = false
    @State private var recovering = false

    var body: some View {
        Group {
            if let run = detail.run {
                VStack(alignment: .leading, spacing: 0) {
                    header(run)
                    Divider().overlay(Theme.stroke)
                    Group {
                        switch tab {
                        case .timeline: RunTimelineTab(runID: runID)
                        case .receipt: ReceiptTab(run: run, receipt: detail.receipt)
                        case .usage: UsageTab(run: run, calls: detail.toolCalls)
                        case .console: ConsoleView(runID: runID).padding(Theme.Space.m)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if detail.missing {
                EmptyState(symbol: "questionmark.folder", title: "This run is gone", message: "It was deleted from the history.",
                           actionTitle: "Back to the list") { model.selectedRunID = nil }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.m) { SkeletonLine(width: 240, height: 20); SkeletonLine(width: 380); SkeletonLine(width: 320) }
                    .padding(Theme.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { tab = initialTab }
        .task(id: model.revision) { await detail.load(runID: runID, services: model.services, defaultWorkspace: model.defaultWorkspace) }
        .sheet(isPresented: $recovering) { if let run = detail.run { RecoverySheet(run: run) } }
    }

    // MARK: Header

    private func header(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(run.title).font(Theme.Font.title).foregroundStyle(Theme.text).lineLimit(2).textSelection(.enabled)
                    HStack(spacing: Theme.Space.s) {
                        StatusBadge(run.status)
                        Pill(text: RunKind.title(run.kind), symbol: RunKind.symbol(run.kind))
                        Pill(text: run.mode.title, symbol: "dial.medium")
                        Pill(text: TriggerGroup.title(raw: run.trigger), symbol: "bolt")
                    }
                }
                Spacer(minLength: Theme.Space.m)
                actions(run)
            }
            if let error = run.errorSummary, !error.isEmpty { Banner(kind: run.status == .canceled ? .info : .error, text: error) }
            if run.status == .recoveryRequired {
                Banner(kind: .warning, text: String(localized: "ORIX stopped while this run was working. Nothing was retried. Choose whether it continues."),
                       actionTitle: "Recover") { recovering = true }
            }
            if !run.status.isTerminal && !detail.activeHere {
                Banner(kind: .info, text: String(localized: "This run belongs to another ORIX process (the background agent). It can be watched here but not stopped from this window."))
            }
            AttentionStack(runID: runID)
            facts(run)
            Picker(selection: $tab) { ForEach(RunTab.allCases) { Text($0.title).tag($0) } } label: { Text("View") }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                .accessibilityIdentifier("runs.detail.tabs")
        }
        .padding(Theme.Space.l)
        .background(Theme.surface)
    }

    private func facts(_ run: RunRecord) -> some View {
        let queue = run.startedAt.map { max(0, $0.timeIntervalSince(run.queuedAt)) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: Theme.Space.l, alignment: .topLeading)], alignment: .leading, spacing: 6) {
            fact("Run id", run.id, mono: true, copyLabel: "Copy run id")
            if let s = run.sessionID { fact("Conversation id", s, mono: true, copyLabel: "Copy conversation id") }
            if let p = run.parentRunID { fact("Started by run", p, mono: true, copyLabel: "Copy parent run id") }
            if let m = run.model { fact("Model", m.displayString) }
            if let w = run.workflowID {
                HStack(alignment: .center, spacing: 6) {
                    Text("Workflow").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).frame(width: 96, alignment: .leading)
                    Button { model.open(.workflow(w)) } label: {
                        Text(run.workflowVersion.map { String(localized: "\(w), version \($0)") } ?? w).font(Theme.Font.body).lineLimit(1)
                    }
                    .buttonStyle(.link).accessibilityIdentifier("runs.detail.workflowLink")
                }
                .frame(height: 20)
            }
            fact("Started", Format.dateTime(run.startedAt))
            fact("Ended", run.endedAt.map { Format.dateTime($0) } ?? String(localized: "Still in flight"))
            HStack(alignment: .center, spacing: 6) {
                Text("Duration").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).frame(width: 96, alignment: .leading)
                ElapsedText(run: run).font(Theme.Font.body).foregroundStyle(Theme.text).monospacedDigit()
            }
            .frame(height: 20)
            fact("Waited in queue", Format.duration(queue))
        }
    }

    private func fact(_ key: LocalizedStringKey, _ value: String, mono: Bool = false, copyLabel: LocalizedStringKey? = nil) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(key).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).frame(width: 96, alignment: .leading)
            Text(value).font(mono ? Theme.Font.monoSmall : Theme.Font.body).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            if let copyLabel { CopyButton(value: value, label: copyLabel) }
        }
        .frame(height: 20)
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    @ViewBuilder private func actions(_ run: RunRecord) -> some View {
        HStack(spacing: Theme.Space.s) {
            if detail.busy { ProgressView().controlSize(.small) }
            if !run.status.isTerminal, detail.activeHere {
                if run.kind == "agent" {
                    if run.status == .paused {
                        Button { Task { await model.services.runs.resume(runID: run.id) } } label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("runs.detail.resume")
                    } else if run.status == .running {
                        Button { Task { await model.services.runs.pause(runID: run.id) } } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(SecondaryButtonStyle()).help(Text("Stops before the next action. The current one finishes."))
                            .accessibilityIdentifier("runs.detail.pause")
                    }
                }
                Button { model.cancel(runID: run.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).accessibilityIdentifier("runs.detail.stop")
            }
            if run.status == .recoveryRequired {
                Button { recovering = true } label: { Label("Recover", systemImage: "bandage") }.buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("runs.detail.recover")
            }
            if detail.retry != nil {
                Button { confirmRetry = true } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(SecondaryButtonStyle())
                    .disabled(detail.busy).accessibilityIdentifier("runs.detail.retry")
                    .confirmationDialog(Text("Run this again?"), isPresented: $confirmRetry, titleVisibility: .visible) {
                        Button { retry() } label: { Text("Run again") }
                        Button(role: .cancel) {} label: { Text("Cancel") }
                    } message: { Text(detail.retry?.note ?? "") }
            }
            Menu {
                Button { copy(run.id) } label: { Label("Copy run id", systemImage: "doc.on.doc") }
                if let receipt = detail.receipt {
                    Divider()
                    Button { export(receipt, markdown: true) } label: { Label("Export receipt as Markdown…", systemImage: "doc.richtext") }
                    Button { export(receipt, markdown: false) } label: { Label("Export receipt as JSON…", systemImage: "curlybraces") }
                }
                if run.status.isTerminal {
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete run…", systemImage: "trash") }
                }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(Text("More actions")).accessibilityIdentifier("runs.detail.more")
                .confirmationDialog(Text("Delete this run?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button(role: .destructive) {
                        Task {
                            do { _ = try await model.services.store.deleteRun(id: run.id); model.selectedRunID = nil }
                            catch { model.report(error) }
                        }
                    } label: { Text("Delete run") }
                    Button(role: .cancel) {} label: { Text("Cancel") }
                } message: { Text("Its timeline, receipt and usage figures are removed for good. Files it produced stay where they are.") }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func retry() {
        guard let plan = detail.retry else { return }
        detail.busy = true
        Task {
            let id: String?
            switch plan {
            case .workflow(let request, _): id = await model.startWorkflowRun(request)
            case .agent(let request, _): id = await model.startAgentRun(request)
            }
            detail.busy = false
            if let id { model.open(.run(id)) }
        }
    }

    private func export(_ receipt: RunReceipt, markdown: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ReceiptExport.fileName(receipt, ext: markdown ? "md" : "json")
        panel.allowedContentTypes = [markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = markdown ? Data(ReceiptExport.markdown(receipt).utf8) : try ReceiptExport.json(receipt)
            try data.write(to: url, options: .atomic)
            model.notice(String(localized: "Receipt saved to \(PathResolver.display(url.path))."), kind: .success)
        } catch { model.report(error) }
    }
}

// MARK: - Timeline

/// The run's events with kind filters; tool events open to show what was recorded about the call.
struct RunTimelineTab: View {
    @Environment(AppModel.self) private var model
    let runID: String
    @State private var timeline: RunTimelineModel?
    @State private var groups: Set<Group> = []
    @State private var expanded: Set<String> = []

    enum Group: String, CaseIterable, Identifiable {
        case messages, tools, approvals, steps, verification, errors, notes
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .messages: return "Messages"; case .tools: return "Tool calls"; case .approvals: return "Approvals"; case .steps: return "Steps"
            case .verification: return "Verification"; case .errors: return "Errors"; case .notes: return "Notes"
            }
        }
        var kinds: Set<RunEvent.Kind> {
            switch self {
            case .messages: return [.userMessage, .assistantText, .reasoningSummary, .planUpdated]
            case .tools: return [.toolRequested, .toolFinished]
            case .approvals: return [.approvalRequested, .approvalResolved]
            case .steps: return [.stepStarted, .stepFinished, .statusChanged]
            case .verification: return [.verification, .receipt]
            case .errors: return [.error, .retry]
            case .notes: return [.log, .checkpoint, .memory]
            }
        }
    }

    private var shown: [RunEvent] {
        let kinds = groups.reduce(into: Set<RunEvent.Kind>()) { $0.formUnion($1.kinds) }
        return (timeline?.events ?? []).filter { e in e.kind != .toolProgress && e.kind != .usage && (groups.isEmpty || kinds.contains(e.kind)) }
    }

    var body: some View {
        let events = shown
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(title: "Everything", isOn: groups.isEmpty) { groups = [] }
                    ForEach(Group.allCases) { g in
                        chip(title: g.title, isOn: groups.contains(g)) { if groups.contains(g) { groups.remove(g) } else { groups.insert(g) } }
                    }
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
            }
            .accessibilityIdentifier("runs.timeline.filters")
            Divider().overlay(Theme.stroke)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { e in row(e).id(e.id) }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                }
                .onChange(of: events.count) { _, _ in
                    if timeline?.run?.status.isTerminal == false { proxy.scrollTo("tail", anchor: .bottom) }
                }
            }
            .overlay {
                if events.isEmpty {
                    Text(timeline == nil ? "Loading the timeline" : (groups.isEmpty ? "No event was recorded for this run." : "No event of these kinds."))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .task(id: runID) {
            let t = RunTimelineModel(runID: runID, services: model.services)
            await t.refresh()
            timeline = t
        }
        .task(id: model.revision) { await timeline?.refresh() }
    }

    private func chip(title: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                Text(title).font(Theme.Font.caption)
            }
            .foregroundStyle(isOn ? Theme.violet : Theme.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(isOn ? Theme.accentSoft : Theme.surfaceSunken, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Theme.violet.opacity(0.5) : Theme.stroke))
        }
        .buttonStyle(.plain).accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder private func row(_ e: RunEvent) -> some View {
        if e.kind == .toolFinished || e.kind == .toolRequested {
            let open = expanded.contains(e.id)
            VStack(alignment: .leading, spacing: 0) {
                Button { if open { expanded.remove(e.id) } else { expanded.insert(e.id) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary).frame(width: 10)
                        RunEventRow(event: e)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(open ? "Hides the details of this call" : "Shows the details of this call"))
                if open { ToolEventDetail(event: e).padding(.leading, 100).padding(.bottom, Theme.Space.s) }
            }
        } else {
            RunEventRow(event: e).padding(.leading, 14)
        }
    }
}

/// What the store recorded about one tool call: redacted arguments, result data, duration, tier, artifacts.
struct ToolEventDetail: View {
    let event: RunEvent
    @State private var showAll = false
    static let previewLimit = 1500

    private var resultData: JSONValue {
        if let output = event.data["output"] { return output }
        var rest = event.data.objectValue ?? [:]
        for k in ["arguments", "callID", "toolID", "tier", "durationMs", "artifacts"] { rest[k] = nil }
        return .object(rest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                if let t = event.data["tier"]?.intValue.flatMap(ApprovalTier.init(rawValue:)) { TierBadge(tier: t) }
                if let ms = event.data["durationMs"]?.intValue { Pill(text: Format.duration(Double(ms) / 1000), symbol: "timer") }
                if event.data["dryRun"]?.boolValue == true { Pill(text: String(localized: "dry run"), symbol: "eye", color: Theme.info) }
                if event.data["replayed"]?.boolValue == true { Pill(text: String(localized: "stored result reused"), symbol: "arrow.uturn.backward") }
                if event.data["truncated"]?.boolValue == true { Pill(text: String(localized: "output was cut"), symbol: "scissors", color: Theme.warning) }
            }
            block("Arguments (secrets hidden)", (event.data["arguments"] ?? .null).serialized(pretty: true))
            if event.kind == .toolFinished {
                block(event.data["output"] == nil ? "Recorded result" : "Output", resultData.serialized(pretty: true))
                if event.data["output"] == nil {
                    Text("The full output of a call is given to the agent but not stored in the history; this is the summary that was recorded.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let artifacts = event.data["artifacts"]?.arrayValue, !artifacts.isEmpty {
                Text("Artifacts").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                ForEach(artifacts.compactMap(\.stringValue), id: \.self) { path in ArtifactPathRow(path: path) }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func block(_ title: LocalizedStringKey, _ text: String) -> some View {
        let long = text.count > Self.previewLimit
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                Spacer()
                CopyButton(value: text, label: "Copy")
            }
            Text(verbatim: long && !showAll ? String(text.prefix(Self.previewLimit)) + "\n…" : text)
                .font(Theme.Font.monoSmall).foregroundStyle(Theme.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.s)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            if long {
                Button { showAll.toggle() } label: { Text(showAll ? "Show less" : "Show more (\(text.count) characters)") }.buttonStyle(.link).font(Theme.Font.caption)
            }
        }
    }
}

// MARK: - Usage

struct UsageTab: View {
    let run: RunRecord
    let calls: [ToolCallRecord]

    var body: some View {
        let u = run.usage
        let rows = ToolUsageRow.aggregate(calls)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                    MetricTile(title: "Turns", value: "\(u.turns)", detail: String(localized: "Model requests"), symbol: "arrow.triangle.2.circlepath", tint: Theme.blue)
                    MetricTile(title: "Tool calls", value: "\(u.toolCalls)", detail: String(localized: "Tools used: \(rows.count)"), symbol: "wrench.and.screwdriver")
                    MetricTile(title: "Tokens", value: Format.tokens(u.tokens.totalTokens), detail: String(localized: "\(u.tokens.totalTokens) in total"), symbol: "text.word.spacing", tint: Theme.blue)
                    MetricTile(title: "Cost", value: Format.cost(u.costUSD, complete: u.costIsComplete),
                               detail: u.costIsComplete ? String(localized: "Complete") : String(localized: "Incomplete"), symbol: "dollarsign.circle")
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        CardTitle("Tokens", symbol: "text.word.spacing")
                        tokenRow("Input", u.tokens.inputTokens, total: u.tokens.totalTokens)
                        tokenRow("Output", u.tokens.outputTokens, total: u.tokens.totalTokens)
                        tokenRow("Read from cache", u.tokens.cacheReadTokens, total: u.tokens.totalTokens)
                        tokenRow("Written to cache", u.tokens.cacheWriteTokens, total: u.tokens.totalTokens)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        CardTitle("Cost", symbol: "dollarsign.circle")
                        Text(Format.cost(u.costUSD, complete: u.costIsComplete)).font(Theme.Font.metric).foregroundStyle(Theme.text)
                        Text(u.costIsComplete
                             ? "Computed from the token counts the provider reported and its listed prices."
                             : "This is a lower bound: at least one turn used a model with no price information, so its cost is not included.")
                            .font(Theme.Font.caption).foregroundStyle(u.costIsComplete ? Theme.textSecondary : Theme.warning).fixedSize(horizontal: false, vertical: true)
                        if let reported = u.tokens.reportedCostUSD { KeyValueRow(key: "Provider-reported", value: Format.cost(reported)) }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        CardTitle("Tools", symbol: "wrench.and.screwdriver")
                        if rows.isEmpty {
                            Text("This run called no tool.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        } else {
                            Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: 6) {
                                GridRow {
                                    Text("Tool"); Text("Calls").gridColumnAlignment(.trailing); Text("Failed").gridColumnAlignment(.trailing); Text("Total time").gridColumnAlignment(.trailing)
                                }
                                .font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                                Divider().gridCellUnsizedAxes(.horizontal)
                                ForEach(rows) { r in
                                    GridRow {
                                        Text(r.toolID).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                                        Text("\(r.calls)").monospacedDigit()
                                        Text("\(r.failed)").monospacedDigit().foregroundStyle(r.failed > 0 ? Theme.danger : Theme.textSecondary)
                                        Text(Format.duration(Double(r.totalMs) / 1000)).monospacedDigit()
                                    }
                                    .font(Theme.Font.body)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.l)
        }
    }

    private func tokenRow(_ title: LocalizedStringKey, _ n: Int, total: Int) -> some View {
        LabeledMeterRow(title: title, value: "\(n)", fraction: total > 0 ? Double(n) / Double(total) : 0)
    }
}

struct LabeledMeterRow: View {
    let title: LocalizedStringKey
    let value: String
    let fraction: Double
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(title).font(Theme.Font.body).foregroundStyle(Theme.text).frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                    Capsule().fill(Theme.blue).frame(width: fraction > 0 ? max(3, geo.size.width * fraction) : 0)
                }
            }
            .frame(height: 6)
            Text(value).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).frame(width: 80, alignment: .trailing)
            Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title)).accessibilityValue(Text(value))
    }
}
