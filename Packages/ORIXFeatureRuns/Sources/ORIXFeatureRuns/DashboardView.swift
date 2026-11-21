// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/DashboardView.swift
// Description: The Dashboard: what needs attention, active runs, period metrics and charts from the store, spend against the daily limit, recent runs and workflows, next scheduled runs, provider and macOS permission status.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Charts
import ORIXAppUI
import SwiftUI

public enum DashboardPeriod: Int, CaseIterable, Identifiable, Sendable {
    case today = 1, week = 7, month = 30
    public var id: Int { rawValue }
    var title: LocalizedStringKey {
        switch self { case .today: return "Today"; case .week: return "7 days"; case .month: return "30 days" }
    }
}

/// Totals for one period, computed from the store's daily usage and the run records of that period.
public struct PeriodMetrics: Equatable, Sendable {
    public var runs = 0
    public var succeeded = 0
    public var failed = 0
    public var inFlight = 0
    public var tokens = 0
    public var costUSD = 0.0
    /// False when at least one run of the period had a turn without price information.
    public var costIsComplete = true
    public var averageDuration: Double?
    /// Finished runs the average is taken over.
    public var durationSample = 0

    /// Share of finished runs that succeeded; nil when nothing has finished.
    public var successRate: Double? {
        let finished = runs - inFlight
        return finished > 0 ? Double(succeeded) / Double(finished) : nil
    }

    /// `days` is `usageByDay` (oldest first, today last); `runs` are the run records queued in the period (any order).
    public static func aggregate(days: [DailyUsage], runs: [RunRecord], period: DashboardPeriod) -> PeriodMetrics {
        var m = PeriodMetrics()
        let window = days.suffix(period.rawValue)
        for d in window { m.runs += d.runs; m.succeeded += d.succeeded; m.failed += d.failed; m.tokens += d.tokens; m.costUSD += d.costUSD }
        guard let start = window.first?.date else { return m }
        let inPeriod = runs.filter { $0.queuedAt >= start }
        m.inFlight = inPeriod.filter { !$0.status.isTerminal }.count
        m.costIsComplete = inPeriod.allSatisfy(\.usage.costIsComplete)
        let durations = inPeriod.compactMap { r -> Double? in
            guard r.status.isTerminal, let s = r.startedAt, let e = r.endedAt, e >= s else { return nil }
            return e.timeIntervalSince(s)
        }
        m.durationSample = durations.count
        m.averageDuration = durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count)
        return m
    }
}

@MainActor
@Observable
final class DashboardModel {
    var loaded = false
    var days: [DailyUsage] = []
    var periodRuns: [RunRecord] = []
    var periodRunsCapped = false
    var attention: [RunRecord] = []
    var recent: [RunRecord] = []
    var workflows: [WorkflowRow] = []
    var upcoming: [(Schedule, Date)] = []
    var permissions: [MacPermission: PermissionStatus] = [:]
    var activeHere: Set<String> = []
    var providerTest: ProviderTestResult?
    var testing = false
    static let recordCap = 3000

    func load(_ services: ORIXServices) async {
        let store = services.store
        days = (try? await store.usageByDay(days: 30)) ?? []
        recent = (try? await store.runs(limit: 8)) ?? []
        var records: [RunRecord] = []
        if let start = days.first?.date {
            var offset = 0
            while records.count < Self.recordCap {
                let batch = (try? await store.runs(limit: 500, offset: offset)) ?? []
                records.append(contentsOf: batch.filter { $0.queuedAt >= start })
                offset += batch.count
                if batch.count < 500 || (batch.last.map { $0.queuedAt < start } ?? true) { break }
            }
            periodRunsCapped = records.count >= Self.recordCap
        }
        periodRuns = records
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let recovery = (try? await store.runs(limit: 20, status: .recoveryRequired)) ?? []
        let blocked = ((try? await store.runs(limit: 20, status: .blockedPermission)) ?? []).filter { ($0.endedAt ?? $0.queuedAt) >= weekAgo }
        let waiting = (try? await store.runs(limit: 20, status: .waitingApproval)) ?? []
        attention = (waiting + recovery + blocked).sorted { $0.queuedAt > $1.queuedAt }
        workflows = Array(await services.workflows.list().sorted { $0.updatedAt > $1.updatedAt }.prefix(6))
        upcoming = await services.workflows.upcoming(limit: 6)
        permissions = services.permissionSnapshot()
        activeHere = Set(await services.runs.activeRunIDs())
        loaded = true
    }
}

public struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var data = DashboardModel()
    @State private var period: DashboardPeriod = .week
    @State private var recovering: RunRecord?

    public init() {}

    private var metrics: PeriodMetrics { PeriodMetrics.aggregate(days: data.days, runs: data.periodRuns, period: period) }
    private var hasNoRuns: Bool { data.loaded && data.recent.isEmpty && model.activeRuns.isEmpty }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader("Dashboard", subtitle: "What is running, what needs you, and what it cost.") {
                    if !hasNoRuns {
                        Picker(selection: $period) { ForEach(DashboardPeriod.allCases) { Text($0.title).tag($0) } } label: { Text("Period") }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            .accessibilityIdentifier("dashboard.period")
                    }
                }
                attentionSection
                if !data.loaded { skeleton }
                else if hasNoRuns { firstRun }
                else {
                    activeSection
                    tiles
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Theme.Space.l) { chartCard.frame(minWidth: 520); spendCard.frame(width: 300) }
                        VStack(spacing: Theme.Space.l) { chartCard; spendCard }
                    }
                }
                if data.loaded {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: Theme.Space.l, alignment: .top)], alignment: .leading, spacing: Theme.Space.l) {
                        if !hasNoRuns { recentRunsCard }
                        workflowsCard
                        upcomingCard
                        providersCard
                        permissionsCard
                    }
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .task(id: model.revision) { await data.load(model.services) }
        .sheet(item: $recovering) { RecoverySheet(run: $0) }
    }

    // MARK: Attention

    @ViewBuilder private var attentionSection: some View {
        let pending = model.pendingApprovals.count + model.pendingInteractions.count
        if pending > 0 || !data.attention.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Needs your attention", subtitle: "Runs wait here until you answer; nothing is approved on its own.")
                AttentionStack()
                ForEach(data.attention) { run in
                    Card(padding: Theme.Space.m) {
                        HStack(spacing: Theme.Space.m) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: Theme.Space.s) { StatusBadge(run.status); Text(run.title).font(Theme.Font.bodyStrong).lineLimit(1) }
                                Text(attentionText(run)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Theme.Space.s)
                            switch run.status {
                            case .recoveryRequired:
                                Button { recovering = run } label: { Text("Recover") }.buttonStyle(PrimaryButtonStyle())
                                    .accessibilityIdentifier("dashboard.attention.recover")
                            case .blockedPermission:
                                Button { model.open(.section(.permissions)) } label: { Text("Open Permissions") }.buttonStyle(SecondaryButtonStyle())
                            default: EmptyView()
                            }
                            Button { model.open(.run(run.id)) } label: { Text("Open run") }.buttonStyle(SecondaryButtonStyle())
                                .accessibilityIdentifier("dashboard.attention.open")
                        }
                    }
                }
            }
        }
    }

    private func attentionText(_ run: RunRecord) -> String {
        switch run.status {
        case .waitingApproval:
            return model.pendingApprovals.contains { $0.access.runID == run.id }
                ? String(localized: "Waiting for your answer to the approval above.")
                : String(localized: "Waiting for an approval. Open the run to see what it asks for.")
        case .recoveryRequired: return String(localized: "ORIX stopped while this run was working. Choose whether it continues.")
        case .blockedPermission: return run.errorSummary ?? String(localized: "macOS refused a permission this run needs. Grant it, then run again.")
        default: return run.errorSummary ?? ""
        }
    }

    // MARK: Active

    @ViewBuilder private var activeSection: some View {
        if !model.activeRuns.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Active runs", subtitle: "\(model.activeRuns.count) in flight")
                Card(padding: Theme.Space.s) {
                    VStack(spacing: 0) {
                        ForEach(model.activeRuns) { run in
                            HStack(spacing: Theme.Space.m) {
                                RowButton { model.open(.run(run.id)) } label: {
                                    HStack(spacing: Theme.Space.m) {
                                        StatusBadge(run.status)
                                        Text(run.title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                                        Spacer(minLength: Theme.Space.s)
                                        if let m = run.model { ProviderGlyph(provider: m.provider, size: 18); Text(m.model).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1) }
                                        ElapsedText(run: run).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).frame(minWidth: 70, alignment: .trailing)
                                    }
                                }
                                if data.activeHere.contains(run.id) {
                                    Button { model.cancel(runID: run.id) } label: { Label("Stop", systemImage: "stop.fill") }
                                        .buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
                                        .accessibilityLabel(Text("Stop \(run.title)")).accessibilityIdentifier("dashboard.active.stop")
                                } else {
                                    Text("Background agent").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                                        .help(Text("This run belongs to another ORIX process and cannot be stopped from this window."))
                                }
                            }
                            .padding(.horizontal, Theme.Space.xs)
                        }
                    }
                }
            }
        }
    }

    // MARK: Metrics

    private var tiles: some View {
        let m = metrics
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
            MetricTile(title: "Runs", value: "\(m.runs)", detail: m.inFlight > 0 ? String(localized: "\(m.inFlight) still running") : String(localized: "\(m.failed) failed"),
                       symbol: "list.bullet.rectangle")
            MetricTile(title: "Success rate", value: m.successRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—",
                       detail: m.successRate == nil ? String(localized: "No finished run yet") : String(localized: "\(m.succeeded) of \(m.runs - m.inFlight) finished runs"),
                       symbol: "checkmark.seal", tint: Theme.success)
            MetricTile(title: "Tokens", value: Format.tokens(m.tokens), detail: String(localized: "Input, output and cache"), symbol: "text.word.spacing", tint: Theme.blue)
            MetricTile(title: "Cost", value: Format.cost(m.costUSD, complete: m.costIsComplete),
                       detail: m.costIsComplete ? String(localized: "From provider prices") : String(localized: "At least: some turns had no price"),
                       symbol: "dollarsign.circle", tint: Theme.violet)
            MetricTile(title: "Average duration", value: Format.duration(m.averageDuration),
                       detail: data.periodRunsCapped ? String(localized: "Over the latest \(m.durationSample) finished runs") : String(localized: "Over \(m.durationSample) finished runs"),
                       symbol: "timer", tint: Theme.blue)
        }
        .accessibilityIdentifier("dashboard.metrics")
    }

    private struct OutcomePoint: Identifiable { let id: String; let date: Date; let outcome: String; let count: Int }

    private var chartCard: some View {
        let window = Array(data.days.suffix(max(7, period.rawValue)))
        let ok = String(localized: "Succeeded"), ko = String(localized: "Failed"), other = String(localized: "Other or running")
        let points = window.flatMap { d in
            [OutcomePoint(id: d.day + "s", date: d.date, outcome: ok, count: d.succeeded),
             OutcomePoint(id: d.day + "f", date: d.date, outcome: ko, count: d.failed),
             OutcomePoint(id: d.day + "o", date: d.date, outcome: other, count: max(0, d.runs - d.succeeded - d.failed))]
        }
        let anyCost = window.contains { $0.costUSD > 0 }
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardTitle("Runs per day", symbol: "chart.bar") { Text("Last \(window.count) days").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                Chart(points) { p in
                    BarMark(x: .value("Day", p.date, unit: .day), y: .value("Runs", p.count), width: .ratio(0.62))
                        .foregroundStyle(by: .value("Outcome", p.outcome))
                        .cornerRadius(2)
                }
                .chartForegroundStyleScale([ok: Theme.success, ko: Theme.danger, other: Theme.neutral])
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Theme.stroke); AxisValueLabel().foregroundStyle(Theme.textSecondary) } }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: window.count > 10 ? 5 : 1)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Theme.textSecondary) } }
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 150)
                .transaction { $0.animation = nil }
                .accessibilityLabel(Text("Runs per day, stacked by outcome"))

                HStack {
                    Text("Cost per day").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if !anyCost { Text("No cost recorded in this period").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                }
                Chart(window) { d in
                    LineMark(x: .value("Day", d.date, unit: .day), y: .value("Cost", d.costUSD)).foregroundStyle(Theme.violet).lineStyle(StrokeStyle(lineWidth: 2))
                    PointMark(x: .value("Day", d.date, unit: .day), y: .value("Cost", d.costUSD)).foregroundStyle(Theme.violet).symbolSize(d.costUSD > 0 ? 28 : 8)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.stroke)
                    AxisValueLabel { if let x = v.as(Double.self) { Text(Format.cost(x)) } }.foregroundStyle(Theme.textSecondary)
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: window.count > 10 ? 5 : 1)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(Theme.textSecondary) } }
                .frame(height: 90)
                .transaction { $0.animation = nil }
                .accessibilityLabel(Text("Cost per day in US dollars"))
            }
        }
    }

    private var spendCard: some View {
        let today = data.days.last?.costUSD ?? 0
        let limit = model.settings.dailySpendLimitUSD
        let todayComplete = data.periodRuns.filter { r in data.days.last.map { r.queuedAt >= $0.date } ?? false }.allSatisfy(\.usage.costIsComplete)
        let fraction = limit > 0 ? today / limit : (today > 0 ? 1 : 0)
        let detail: String = {
            if limit <= 0 { return String(localized: "The limit is zero: runs that need a model will not start.") }
            if fraction >= 1 { return String(localized: "Limit reached: new model runs are refused until tomorrow.") }
            return String(localized: "\(Format.cost(max(0, limit - today))) left today (\(fraction.formatted(.percent.precision(.fractionLength(0)))) used)")
        }()
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardTitle("Daily spend", symbol: "gauge.with.dots.needle.50percent")
                LabeledMeter(title: "Spent today against your limit", valueText: "\(Format.cost(today, complete: todayComplete)) / \(Format.cost(limit))", fraction: fraction, detail: detail)
                    .accessibilityIdentifier("dashboard.spendMeter")
                Text("The limit is checked before every run that calls a model.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.open(.section(.settings)) } label: { Text("Change the limit in Settings") }.buttonStyle(.link).font(Theme.Font.caption)
            }
        }
    }

    // MARK: Lists

    private var recentRunsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardTitle("Recent runs", symbol: "clock.arrow.circlepath") {
                    Button { model.open(.section(.runs)) } label: { Text("All runs") }.buttonStyle(.link).font(Theme.Font.caption)
                }
                ForEach(data.recent) { run in
                    RowButton { model.open(.run(run.id)) } label: { RunLine(run: run) }
                        .accessibilityIdentifier("dashboard.recentRun")
                }
            }
        }
    }

    private var workflowsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardTitle("Recent workflows", symbol: "point.3.connected.trianglepath.dotted") {
                    Button { model.open(.section(.workflows)) } label: { Text("Workflow Studio") }.buttonStyle(.link).font(Theme.Font.caption)
                }
                if data.workflows.isEmpty {
                    emptyLine("No workflow yet. Start from a template in Workflow Studio.")
                }
                ForEach(data.workflows) { w in
                    RowButton { model.open(.workflow(w.id)) } label: {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: "doc.text").foregroundStyle(Theme.textSecondary).frame(width: 18)
                            Text(w.name).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                            Pill(text: String(localized: "v\(w.currentVersion)"))
                            Spacer(minLength: Theme.Space.s)
                            Text(String(localized: "Edited \(Format.relative(w.updatedAt))")).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private var upcomingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardTitle("Next scheduled runs", symbol: "calendar.badge.clock") {
                    Button { model.open(.section(.scheduler)) } label: { Text("Scheduler") }.buttonStyle(.link).font(Theme.Font.caption)
                }
                if data.upcoming.isEmpty {
                    emptyLine("Nothing is scheduled. Enable a schedule in the Scheduler.")
                }
                ForEach(Array(data.upcoming.enumerated()), id: \.offset) { _, entry in
                    RowButton { model.open(.section(.scheduler)) } label: {
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: TriggerDescriber.symbol(entry.0.trigger)).foregroundStyle(Theme.textSecondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.0.name).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                                Text(TriggerDescriber.describe(entry.0.trigger)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            Spacer(minLength: Theme.Space.s)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(Format.dateTime(entry.1)).font(Theme.Font.caption).foregroundStyle(Theme.text)
                                Text(Format.relative(entry.1)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private var providersCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardTitle("Providers", symbol: "key") {
                    Button { model.open(.section(.settings)) } label: { Text("Manage keys") }.buttonStyle(.link).font(Theme.Font.caption)
                }
                ForEach(ProviderID.all, id: \.self) { p in
                    let configured = model.configuredProviders.contains(p)
                    HStack(spacing: Theme.Space.s) {
                        ProviderGlyph(provider: p)
                        Text(p.displayName).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                        Spacer()
                        Label(configured ? String(localized: "Key saved") : String(localized: "No key"), systemImage: configured ? "checkmark.circle.fill" : "minus.circle")
                            .font(Theme.Font.caption).foregroundStyle(configured ? Theme.success : Theme.textTertiary)
                    }
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                }
                Divider().overlay(Theme.stroke)
                if let ref = model.settings.defaultModel, !ref.model.isEmpty {
                    HStack(spacing: Theme.Space.s) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Default model").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            Text(ref.displayString).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).lineLimit(1)
                        }
                        Spacer(minLength: Theme.Space.s)
                        if data.testing { ProgressView().controlSize(.small) }
                        Button {
                            data.testing = true; data.providerTest = nil
                            Task { data.providerTest = await model.services.providers.test(ref); data.testing = false }
                        } label: { Text("Test") }
                            .buttonStyle(SecondaryButtonStyle()).disabled(data.testing)
                            .help(Text("Sends one tiny request (at most 8 output tokens) to check the key and the model."))
                            .accessibilityIdentifier("dashboard.providers.test")
                    }
                    .padding(.horizontal, Theme.Space.s)
                    if let r = data.providerTest, r.model == ref {
                        Banner(kind: r.ok ? .success : .error,
                               text: r.ok ? String(localized: "It answered in \(r.latencyMs) ms.") : (r.message.map { Redactor.shared.redact($0) } ?? String(localized: "The test failed.")))
                    }
                } else {
                    emptyLine("No default model is chosen yet. Add a key and pick one in Settings.")
                }
            }
        }
    }

    private var permissionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardTitle("macOS permissions", symbol: "lock.shield") {
                    Button { model.open(.section(.permissions)) } label: { Text("Permissions") }.buttonStyle(.link).font(Theme.Font.caption)
                }
                ForEach(MacPermission.allCases, id: \.self) { p in
                    let status = data.permissions[p] ?? .unknown
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: Self.symbol(p)).foregroundStyle(Theme.textSecondary).frame(width: 18)
                        Text(Self.title(p)).font(Theme.Font.body).foregroundStyle(Theme.text)
                        Spacer()
                        Label(Self.statusText(p, status), systemImage: Self.statusSymbol(status))
                            .font(Theme.Font.caption).foregroundStyle(status == .granted ? Theme.success : Theme.textSecondary)
                    }
                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                }
                Text("ORIX never grants these itself: macOS asks you the first time a tool needs one.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Space.s).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func title(_ p: MacPermission) -> String {
        switch p {
        case .accessibility: return String(localized: "Accessibility")
        case .screenRecording: return String(localized: "Screen recording")
        case .appleEvents: return String(localized: "Automation of other apps")
        case .fullDiskAccess: return String(localized: "Full disk access")
        case .notifications: return String(localized: "Notifications")
        }
    }
    static func symbol(_ p: MacPermission) -> String {
        switch p {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .appleEvents: return "applescript"
        case .fullDiskAccess: return "internaldrive"
        case .notifications: return "bell"
        }
    }
    static func statusText(_ p: MacPermission, _ s: PermissionStatus) -> String {
        switch s {
        case .granted: return String(localized: "Allowed")
        case .denied: return String(localized: "Not allowed")
        case .notDetermined: return String(localized: "Not asked yet")
        case .unknown: return p == .appleEvents ? String(localized: "Asked per app") : String(localized: "Cannot tell here")
        }
    }
    static func statusSymbol(_ s: PermissionStatus) -> String {
        switch s {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle"
        case .notDetermined: return "questionmark.circle"
        case .unknown: return "circle.dashed"
        }
    }

    private func emptyLine(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.s)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: First run and loading

    private var firstRun: some View {
        Card(padding: Theme.Space.xl) {
            VStack(spacing: Theme.Space.l) {
                Image(systemName: "sparkles").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accentGradient)
                    .frame(width: 68, height: 68).background(Theme.accentSoft, in: Circle())
                Text("Nothing has run yet").font(Theme.Font.title).foregroundStyle(Theme.text)
                Text("Give ORIX a first job. Every run will show up here with its status, cost and proof of what it did.")
                    .font(Theme.Font.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 460)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                    starter("bubble.left.and.text.bubble.right", "Ask the agent", "Describe a task in your own words and watch it work.", id: "dashboard.start.chat") { model.open(.section(.chat)) }
                    starter("square.grid.2x2", "Browse templates", "Start from a ready-made workflow and adapt it.", id: "dashboard.start.templates") { model.open(.section(.workflows)) }
                    starter("key", model.configuredProviders.isEmpty ? "Add a provider" : "Manage providers",
                            model.configuredProviders.isEmpty ? "Add your own API key. It stays in your Keychain." : "\(model.configuredProviders.count) provider key saved in your Keychain.",
                            id: "dashboard.start.provider") { model.open(.section(.settings)) }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func starter(_ symbol: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.violet)
                Text(title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.m).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.strokeStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier(id)
    }

    private var skeleton: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
            ForEach(0..<5, id: \.self) { _ in
                Card { VStack(alignment: .leading, spacing: Theme.Space.m) { SkeletonLine(width: 90); SkeletonLine(width: 60, height: 22); SkeletonLine(width: 120) } }
            }
        }
    }
}
