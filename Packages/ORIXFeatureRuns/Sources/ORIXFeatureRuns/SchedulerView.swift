// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/SchedulerView.swift
// Description: The Scheduler section: an honest status banner, the schedules with plain-language triggers and policies, the seven-day agenda, and the run queue.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

@MainActor
@Observable
final class SchedulerModel {
    var loaded = false
    var schedules: [Schedule] = []
    var next: [String: Date] = [:]
    var queue: [QueueItem] = []
    var workflows: [WorkflowRow] = []
    var schedulerActive = false
    var agenda: [AgendaDay] = []
    var agendaTruncated: [String] = []
    var busy: Set<String> = []

    func load(_ services: ORIXServices) async {
        schedules = await services.workflows.schedules()
        let upcoming = await services.workflows.upcoming(limit: 200)
        next = Dictionary(upcoming.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        queue = await services.workflows.queue()
        workflows = await services.workflows.list()
        schedulerActive = await services.workflows.schedulerIsActive()
        (agenda, agendaTruncated) = AgendaBuilder.build(schedules: schedules, from: Date())
        loaded = true
    }

    func workflowName(_ id: String) -> String { workflows.first { $0.id == id }?.name ?? id }
    func scheduleName(_ id: String) -> String { schedules.first { $0.id == id }?.name ?? id }
}

enum SchedulerTab: String, CaseIterable, Identifiable {
    case schedules, agenda, queue
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self { case .schedules: return "Schedules"; case .agenda: return "Next 7 days"; case .queue: return "Queue" }
    }
}

/// A schedule being edited, or a new one.
struct EditorTarget: Identifiable {
    let id = UUID()
    var existing: Schedule?
}

public struct SchedulerView: View {
    @Environment(AppModel.self) private var model
    @State private var data = SchedulerModel()
    @State private var tab: SchedulerTab = .schedules
    @State private var editing: EditorTarget?
    @State private var enableWarning: Schedule?
    @State private var enableWarningDetail = ""
    var initialTab: SchedulerTab = .schedules

    public init() {}
    init(initialTab: SchedulerTab) { self.initialTab = initialTab }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PageHeader("Scheduler", subtitle: "Workflows that start on their own, and when.") {
                    Button { editing = EditorTarget(existing: nil) } label: { Label("New schedule", systemImage: "plus") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(data.workflows.isEmpty)
                        .help(Text(data.workflows.isEmpty ? "Create a workflow first: a schedule starts a workflow." : "Schedule a workflow"))
                        .accessibilityIdentifier("scheduler.new")
                }
                statusBanner
                Picker(selection: $tab) { ForEach(SchedulerTab.allCases) { Text($0.title).tag($0) } } label: { Text("View") }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                    .accessibilityIdentifier("scheduler.tabs")
            }
            .padding([.horizontal, .top], Theme.Space.xl).padding(.bottom, Theme.Space.m)
            ScrollView {
                Group {
                    if !data.loaded { VStack(alignment: .leading, spacing: Theme.Space.m) { SkeletonLine(width: 300); SkeletonLine(width: 420); SkeletonLine(width: 360) } }
                    else {
                        switch tab {
                        case .schedules: schedulesList
                        case .agenda: agenda
                        case .queue: queue
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.xl).padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: 1400, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.canvas)
        .onAppear { tab = initialTab }
        .task(id: model.revision) { await data.load(model.services) }
        .sheet(item: $editing) { target in
            ScheduleEditor(existing: target.existing, workflows: data.workflows) { await data.load(model.services) }
        }
        .confirmationDialog(Text("This workflow's permissions are not accepted yet"), isPresented: Binding(get: { enableWarning != nil }, set: { if !$0 { enableWarning = nil } }),
                            titleVisibility: .visible, presenting: enableWarning) { schedule in
            Button { model.open(.workflow(schedule.workflowID)) } label: { Text("Review the permissions") }
            Button { Task { await setEnabled(schedule, true, force: true) } } label: { Text("Enable anyway") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: { _ in
            Text("A scheduled run never approves anything by itself. Until you accept what “\(enableWarning.map { data.workflowName($0.workflowID) } ?? "")” asks for, each run will stop at “Waiting for approval” and do nothing until someone answers. \(enableWarningDetail)")
        }
    }

    // MARK: Status

    private var statusBanner: some View {
        let active = data.schedulerActive
        let agent = model.settings.backgroundAgentEnabled
        return Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.l) {
                    Label(active ? String(localized: "Scheduler running in this app") : String(localized: "Scheduler not running in this app"),
                          systemImage: active ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(active ? Theme.success : Theme.warning)
                    Label(agent ? String(localized: "Background agent enabled") : String(localized: "Background agent off"),
                          systemImage: agent ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(agent ? Theme.success : Theme.textSecondary)
                    Spacer()
                    if !agent { Button { model.open(.section(.settings)) } label: { Text("Background agent settings") }.buttonStyle(.link).font(Theme.Font.caption) }
                }
                .font(Theme.Font.bodyStrong)
                Text(active || agent
                     ? "Schedules run only while this Mac is on and awake, and either this app or the background agent is running. Runs missed during sleep or shutdown follow each schedule's own missed-run policy. Steps that control the screen need an unlocked session."
                     : "Nothing is firing schedules right now: no scheduler is active in this app and the background agent is off. Schedules run only while this Mac is on and awake and one of the two is running. Missed runs follow each schedule's policy; steps that control the screen need an unlocked session.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scheduler.status")
    }

    // MARK: Schedules

    @ViewBuilder private var schedulesList: some View {
        if data.schedules.isEmpty {
            EmptyState(symbol: "calendar.badge.plus", title: "No schedule yet",
                       message: data.workflows.isEmpty ? "A schedule starts a workflow. Create a workflow first, then schedule it here."
                                                       : "Pick a workflow and say when it should start: at a time, on an interval, or when something happens.",
                       actionTitle: data.workflows.isEmpty ? "Open Workflow Studio" : "New schedule") {
                if data.workflows.isEmpty { model.open(.section(.workflows)) } else { editing = EditorTarget(existing: nil) }
            }
            .frame(minHeight: 320)
        } else {
            LazyVStack(spacing: Theme.Space.m) {
                ForEach(data.schedules) { s in scheduleCard(s) }
            }
        }
    }

    private func scheduleCard(_ s: Schedule) -> some View {
        let problems = s.problems()
        return Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: TriggerDescriber.symbol(s.trigger)).font(.system(size: 15, weight: .medium)).foregroundStyle(s.enabled ? Theme.violet : Theme.textTertiary)
                        .frame(width: 32, height: 32).background((s.enabled ? Theme.violet : Theme.textTertiary).opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Theme.Space.s) {
                            Button { model.open(.workflow(s.workflowID)) } label: { Text(data.workflowName(s.workflowID)).font(Theme.Font.heading).foregroundStyle(Theme.text).lineLimit(1) }
                                .buttonStyle(.plain).help(Text("Open the workflow"))
                            if s.paused { Pill(text: String(localized: "Paused"), symbol: "pause.fill", color: Theme.warning) }
                            if !s.enabled { Pill(text: String(localized: "Off"), symbol: "power") }
                        }
                        Text(TriggerDescriber.describe(s.trigger)).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.m)
                    if data.busy.contains(s.id) { ProgressView().controlSize(.small) }
                    Toggle(isOn: Binding(get: { s.enabled }, set: { on in Task { await setEnabled(s, on, force: false) } })) { Text("Enabled") }
                        .toggleStyle(.switch).labelsHidden().disabled(data.busy.contains(s.id))
                        .accessibilityLabel(Text("Enable the schedule for \(data.workflowName(s.workflowID))")).accessibilityIdentifier("scheduler.enabled")
                    Menu {
                        Button { editing = EditorTarget(existing: s) } label: { Label("Edit…", systemImage: "pencil") }
                        Button { Task { await setPaused(s, !s.paused) } } label: { Label(s.paused ? "Resume" : "Pause", systemImage: s.paused ? "play" : "pause") }
                        Button { Task { if let id = await model.startWorkflowRun(WorkflowRunRequest(workflowID: s.workflowID)) { model.open(.run(id)) } } } label: {
                            Label("Run the workflow now", systemImage: "play.circle")
                        }
                    } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(Text("Schedule actions")).accessibilityIdentifier("scheduler.rowMenu")
                }
                if !problems.isEmpty { Banner(kind: .error, text: problems.joined(separator: "; ")) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: Theme.Space.l, alignment: .topLeading)], alignment: .leading, spacing: 4) {
                    detail("Next run", nextText(s))
                    detail("Last fired", s.lastFiredAt.map { "\(Format.dateTime($0)) (\(Format.relative($0)))" } ?? String(localized: "Never"))
                    detail("If a run is missed", TriggerDescriber.describe(s.missedRunPolicy))
                    detail("If one is still running", TriggerDescriber.describe(s.concurrency))
                    if s.maxRetries > 0 { detail("Retries", String(localized: "\(s.maxRetries), first after \(Format.duration(s.retryBackoffSeconds))")) }
                }
                .padding(.leading, 44)
            }
        }
        .accessibilityIdentifier("scheduler.row")
    }

    private func nextText(_ s: Schedule) -> String {
        if !s.enabled { return String(localized: "Off") }
        if s.paused { return String(localized: "Paused") }
        if let d = data.next[s.id] ?? s.trigger.nextFireDate(after: Date(), anchor: s.createdAt) { return "\(Format.dateTime(d)) (\(Format.relative(d)))" }
        if case .once = s.trigger { return String(localized: "Already passed") }
        return s.trigger.isTimeBased ? String(localized: "Never fires") : String(localized: "When the event happens")
    }

    private func detail(_ key: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func setEnabled(_ s: Schedule, _ on: Bool, force: Bool) async {
        if on && !force {
            do {
                if try await model.services.workflows.permissionReview(workflowID: s.workflowID).accepted == false {
                    enableWarningDetail = ""; enableWarning = s; return
                }
            } catch {
                enableWarningDetail = Redactor.shared.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                enableWarning = s; return
            }
        }
        data.busy.insert(s.id)
        do { try await model.services.workflows.setSchedule(id: s.id, enabled: on) } catch { model.report(error) }
        data.busy.remove(s.id)
        await data.load(model.services)
    }

    private func setPaused(_ s: Schedule, _ paused: Bool) async {
        var copy = s; copy.paused = paused
        data.busy.insert(s.id)
        do { try await model.services.workflows.saveSchedule(copy) } catch { model.report(error) }
        data.busy.remove(s.id)
        await data.load(model.services)
    }

    // MARK: Agenda

    @ViewBuilder private var agenda: some View {
        let eventSchedules = data.schedules.filter { $0.enabled && !$0.paused && !$0.trigger.isTimeBased }
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Computed from each schedule's own time zone, daylight-saving changes included. Days are shown in this Mac's time zone (\(TimeZone.current.identifier)).")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if !data.agendaTruncated.isEmpty {
                Banner(kind: .info, text: String(localized: "Very frequent schedules are shown up to \(AgendaBuilder.perScheduleCap) times: \(data.agendaTruncated.joined(separator: ", "))."))
            }
            if data.agenda.allSatisfy(\.items.isEmpty) && eventSchedules.isEmpty {
                EmptyState(symbol: "calendar", title: "Nothing in the next 7 days", message: "No enabled schedule fires at a set time this week.").frame(minHeight: 260)
            } else {
                ForEach(data.agenda) { day in
                    HStack(alignment: .top, spacing: Theme.Space.l) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(day.start.formatted(.dateTime.weekday(.wide))).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                            Text(day.start.formatted(.dateTime.day().month(.abbreviated))).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            if Calendar.current.isDateInToday(day.start) { Pill(text: String(localized: "Today"), color: Theme.violet) }
                        }
                        .frame(width: 110, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            if day.items.isEmpty { Text("Nothing scheduled").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(.vertical, 4) }
                            ForEach(day.items) { item in
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                                    Text(item.times.map { AgendaBuilder.clock($0) }.joined(separator: "  ")
                                         + (item.total > item.times.count ? String(localized: "  … \(item.total) times, last at \(AgendaBuilder.clock(item.last))") : ""))
                                        .font(Theme.Font.mono).foregroundStyle(Theme.text).frame(minWidth: 130, alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(item.name).font(Theme.Font.body).foregroundStyle(Theme.text).lineLimit(1)
                                    if let zone = AgendaBuilder.foreignZone(item) {
                                        Pill(text: String(localized: "\(item.times.map { AgendaBuilder.clock($0, in: zone) }.joined(separator: ", ")) in \(zone.identifier)"), symbol: "globe")
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.stroke))
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().overlay(Theme.stroke)
                }
                if !eventSchedules.isEmpty {
                    Text("Started by events, at no set time").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                    ForEach(eventSchedules) { s in
                        HStack(spacing: Theme.Space.s) {
                            Image(systemName: TriggerDescriber.symbol(s.trigger)).foregroundStyle(Theme.textSecondary).frame(width: 18)
                            Text(s.name).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                            Text(TriggerDescriber.describe(s.trigger)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("scheduler.agenda")
    }

    // MARK: Queue

    @ViewBuilder private var queue: some View {
        if data.queue.isEmpty {
            EmptyState(symbol: "tray", title: "The queue is empty", message: "Scheduled runs appear here when they are due, with what happened to each.").frame(minHeight: 260)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Newest first. Finished entries are kept for a while as a record of what the scheduler did.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                ForEach(data.queue.prefix(200)) { item in
                    Card(padding: Theme.Space.m) {
                        HStack(alignment: .top, spacing: Theme.Space.m) {
                            QueueStatusBadge(status: item.status)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(data.scheduleName(item.scheduleID)).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                                Text("Due \(Format.dateTime(item.dueAt)) · attempt \(item.attempt)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                if !item.reason.isEmpty { Text(item.reason).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                                if let e = item.lastError, !e.isEmpty { Label(e, systemImage: "exclamationmark.triangle").font(Theme.Font.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: Theme.Space.s)
                            if let runID = item.runID {
                                Button { model.open(.run(runID)) } label: { Text("Open run") }.buttonStyle(SecondaryButtonStyle())
                                    .accessibilityIdentifier("scheduler.queue.openRun")
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("scheduler.queue")
        }
    }
}

struct QueueStatusBadge: View {
    let status: QueueItem.Status
    var body: some View {
        let (label, symbol, color): (String, String, Color) = {
            switch status {
            case .pending: return (String(localized: "Waiting"), "clock", Theme.neutral)
            case .running: return (String(localized: "Running"), "play.circle.fill", Theme.blue)
            case .succeeded: return (String(localized: "Succeeded"), "checkmark.circle.fill", Theme.success)
            case .failed: return (String(localized: "Failed"), "xmark.octagon.fill", Theme.danger)
            case .skipped: return (String(localized: "Skipped"), "forward.end", Theme.neutral)
            case .canceled: return (String(localized: "Canceled"), "stop.circle.fill", Theme.neutral)
            case .waitingApproval: return (String(localized: "Waiting for approval"), "hand.raised.fill", Theme.violet)
            }
        }()
        Label(label, systemImage: symbol).font(Theme.Font.captionStrong).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3).background(color.opacity(0.13), in: Capsule())
            .frame(minWidth: 130, alignment: .leading)
    }
}
