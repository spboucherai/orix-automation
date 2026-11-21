// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/ScheduleEditor.swift
// Description      : The sheet that adds, edits or deletes a schedule:
//                    workflow, trigger (friendly cron builder or raw cron
//                    validated live, once, interval, file change, system
//                    events), time zone, missed-run and concurrency policies,
//                    retries.
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

import AppKit
import ORIXAppUI
import SwiftUI
import UniformTypeIdentifiers

extension ScheduleDraft.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .cron: return "At set times"
        case .once: return "Once"
        case .interval: return "Every so often"
        case .fileChange: return "When files change"
        case .login: return "When I log in"
        case .appLaunch: return "When an app opens"
        case .powerConnected: return "When power is connected"
        case .networkAvailable: return "When the network is available"
        }
    }
}

struct ScheduleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: Schedule?
    let workflows: [WorkflowRow]
    let onChange: () async -> Void
    @State private var draft = ScheduleDraft()
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmDelete = false
    @State private var permissionWarning: String?
    @State private var permissionChecked = false

    /// Schedules mirrored from a workflow's own triggers are rewritten whenever that workflow is saved.
    private var mirrored: Bool { existing.map { $0.id.hasPrefix($0.workflowID + "#") } ?? false }

    var body: some View {
        let problems = draft.problems()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(existing == nil ? "New schedule" : "Edit schedule").font(Theme.Font.title).foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(Theme.Space.l)
            Divider().overlay(Theme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if mirrored {
                        Banner(kind: .info, text: String(localized: "This schedule comes from the workflow's own triggers. Changes to its trigger made here last until the workflow is saved again; to change it for good, edit the workflow."))
                    }
                    if let failure { Banner(kind: .error, text: failure) }
                    section("Workflow") {
                        Picker(selection: $draft.workflowID) {
                            Text("Choose a workflow").tag("")
                            ForEach(workflows) { w in Text(w.name).tag(w.id) }
                        } label: { Text("Workflow") }
                        .labelsHidden().frame(maxWidth: 360).disabled(mirrored)
                        .accessibilityIdentifier("scheduler.editor.workflow")
                    }
                    section("Start") {
                        Picker(selection: $draft.kind) { ForEach(ScheduleDraft.Kind.allCases) { Text($0.title).tag($0) } } label: { Text("Trigger") }
                            .labelsHidden().frame(maxWidth: 360)
                            .accessibilityIdentifier("scheduler.editor.kind")
                        trigger
                        Text(TriggerDescriber.describe(draft.trigger)).font(Theme.Font.bodyStrong).foregroundStyle(Theme.violet)
                            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("scheduler.editor.summary")
                    }
                    section("If a run is missed (Mac asleep or off)") {
                        Picker(selection: $draft.missed) {
                            Text("Skip it").tag(ScheduleDraft.Missed.skip)
                            Text("Run once when the Mac is back").tag(ScheduleDraft.Missed.runOnce)
                            Text("Catch up on several").tag(ScheduleDraft.Missed.runAll)
                        } label: { Text("Missed runs") }.labelsHidden().frame(maxWidth: 360)
                        if draft.missed == .runAll { Stepper(value: $draft.missedMax, in: 1...50) { Text("At most \(draft.missedMax) missed runs, oldest first") } }
                    }
                    section("If the previous run is still going") {
                        Picker(selection: $draft.concurrency) {
                            Text("Skip the new one").tag(ScheduleDraft.Concurrency.skipIfRunning)
                            Text("Wait, then run").tag(ScheduleDraft.Concurrency.queue)
                            Text("Run side by side").tag(ScheduleDraft.Concurrency.parallel)
                        } label: { Text("Concurrency") }.labelsHidden().frame(maxWidth: 360)
                        if draft.concurrency == .parallel { Stepper(value: $draft.parallelMax, in: 2...16) { Text("Up to \(draft.parallelMax) at the same time") } }
                    }
                    section("After a failure") {
                        Stepper(value: $draft.maxRetries, in: 0...10) { Text(draft.maxRetries == 0 ? "Do not retry" : "Retry up to \(draft.maxRetries) times") }
                        if draft.maxRetries > 0 {
                            HStack {
                                Text("Wait before the first retry")
                                TextField(String(localized: "Seconds"), value: $draft.backoff, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                                Text("seconds, doubled each time")
                            }
                        }
                        Text("Only failures that are safe to repeat are retried. A step that already changed something is never repeated blindly.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    section("State") {
                        Toggle(isOn: $draft.enabled) { Text("Enabled") }.toggleStyle(.switch).accessibilityIdentifier("scheduler.editor.enabled")
                        if draft.enabled, let w = permissionWarning {
                            Banner(kind: .warning, text: w, actionTitle: "Review the permissions") { model.open(.workflow(draft.workflowID)); dismiss() }
                        }
                    }
                }
                .font(Theme.Font.body)
                .padding(Theme.Space.l)
            }
            Divider().overlay(Theme.stroke)
            HStack(spacing: Theme.Space.s) {
                if existing != nil, !mirrored {
                    Button(role: .destructive) { confirmDelete = true } label: { Text("Delete schedule") }.buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
                        .accessibilityIdentifier("scheduler.editor.delete")
                        .confirmationDialog(Text("Delete this schedule?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button(role: .destructive) { delete() } label: { Text("Delete schedule") }
                            Button(role: .cancel) {} label: { Text("Cancel") }
                        } message: { Text("The workflow stays; it just stops starting on its own. Runs already in the queue are not started.") }
                }
                if let first = problems.first { Label(first, systemImage: "exclamationmark.circle").font(Theme.Font.caption).foregroundStyle(Theme.warning).lineLimit(2) }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button { dismiss() } label: { Text("Cancel") }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button { save() } label: { Text("Save") }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(saving || !problems.isEmpty).accessibilityIdentifier("scheduler.editor.save")
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 640, height: 720)
        .background(Theme.surface)
        .onAppear {
            if let existing { draft = ScheduleDraft(schedule: existing) }
            else if workflows.count == 1 { draft.workflowID = workflows[0].id }
        }
        .task(id: draft.workflowID) { await checkPermissions() }
    }

    private func checkPermissions() async {
        permissionWarning = nil
        guard !draft.workflowID.isEmpty else { return }
        let text = String(localized: "This workflow's permissions are not accepted yet. Scheduled runs will stop at “Waiting for approval” until you accept them.")
        do {
            if try await model.services.workflows.permissionReview(workflowID: draft.workflowID).accepted == false { permissionWarning = text }
        } catch {
            permissionWarning = text + " " + Redactor.shared.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func section<C: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).textCase(.uppercase)
            content()
        }
    }

    // MARK: Trigger forms

    @ViewBuilder private var trigger: some View {
        switch draft.kind {
        case .cron: cron
        case .once:
            DatePicker(selection: $draft.onceAt, displayedComponents: [.date, .hourAndMinute]) { Text("Date and time") }.frame(maxWidth: 360)
        case .interval:
            HStack {
                Text("Every")
                TextField(String(localized: "Amount"), value: $draft.intervalValue, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                Picker(selection: $draft.intervalUnit) {
                    Text("seconds").tag(ScheduleDraft.IntervalUnit.seconds); Text("minutes").tag(ScheduleDraft.IntervalUnit.minutes)
                    Text("hours").tag(ScheduleDraft.IntervalUnit.hours); Text("days").tag(ScheduleDraft.IntervalUnit.days)
                } label: { Text("Unit") }.labelsHidden().frame(width: 120)
            }
            Text("Counted from when the schedule was created, in elapsed time: it does not shift with daylight saving.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        case .fileChange:
            HStack {
                TextField(String(localized: "Folder to watch"), text: $draft.path).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("scheduler.editor.folder")
                Button { chooseFolder() } label: { Text("Choose…") }.buttonStyle(SecondaryButtonStyle())
            }
            HStack {
                TextField(String(localized: "Only files matching (for example *.pdf)"), text: $draft.glob).textFieldStyle(.roundedBorder)
                Toggle(isOn: $draft.recursive) { Text("Include subfolders") }.toggleStyle(.checkbox)
            }
            HStack {
                Text("Wait")
                TextField(String(localized: "Seconds"), value: $draft.debounce, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                Text("seconds after the last change before starting")
            }
            Text("Choosing a folder here does not grant access to it: the workflow's own permissions decide what it may read.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        case .appLaunch:
            HStack {
                TextField(String(localized: "Bundle identifier (for example com.apple.Safari)"), text: $draft.bundleID).textFieldStyle(.roundedBorder)
                Button { chooseApp() } label: { Text("Choose app…") }.buttonStyle(SecondaryButtonStyle())
            }
        case .login:
            note("Starts once each time you log in to this Mac while ORIX or its background agent is running.")
        case .powerConnected:
            note("Starts each time the power adapter is plugged in.")
        case .networkAvailable:
            note("Starts each time this Mac goes from no network to a working connection.")
        }
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var cron: some View {
        Picker(selection: $draft.useRawCron) { Text("Simple").tag(false); Text("Cron expression").tag(true) } label: { Text("Editor") }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
            .onChange(of: draft.useRawCron) { _, raw in
                if raw { draft.rawCron = draft.preset.expression } else if let p = CronPreset.match(draft.rawCron) { draft.apply(p) }
            }
            .accessibilityIdentifier("scheduler.editor.cronMode")
        if draft.useRawCron {
            TextField(String(localized: "minute hour day month weekday"), text: $draft.rawCron).textFieldStyle(.roundedBorder).font(Theme.Font.mono).frame(maxWidth: 360)
                .accessibilityIdentifier("scheduler.editor.cron")
            Text("Five fields: minute, hour, day of month, month, day of week. For example 0 9 * * MON-FRI.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        } else {
            Picker(selection: $draft.shape) {
                Text("Every few minutes").tag(ScheduleDraft.BuilderShape.minutes)
                Text("Every hour").tag(ScheduleDraft.BuilderShape.hourly)
                Text("Every day").tag(ScheduleDraft.BuilderShape.daily)
                Text("Every weekday (Monday to Friday)").tag(ScheduleDraft.BuilderShape.weekdays)
                Text("On chosen days of the week").tag(ScheduleDraft.BuilderShape.weekly)
                Text("Once a month").tag(ScheduleDraft.BuilderShape.monthly)
            } label: { Text("Repeat") }.labelsHidden().frame(maxWidth: 360)
            switch draft.shape {
            case .minutes: Stepper(value: $draft.everyMinutes, in: 1...59) { Text("Every \(draft.everyMinutes) minutes") }
            case .hourly: Stepper(value: $draft.minute, in: 0...59) { Text("At minute \(draft.minute) of every hour") }
            case .daily, .weekdays: timeOfDay
            case .weekly:
                HStack(spacing: 4) {
                    let symbols = Calendar.current.shortWeekdaySymbols
                    ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { d in
                        let on = draft.weekdays.contains(d)
                        Button { if on { draft.weekdays.remove(d) } else { draft.weekdays.insert(d) } } label: {
                            HStack(spacing: 3) {
                                if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                                Text(symbols[d]).font(Theme.Font.caption)
                            }
                            .foregroundStyle(on ? Theme.violet : Theme.textSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(on ? Theme.accentSoft : Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).strokeBorder(on ? Theme.violet.opacity(0.5) : Theme.stroke))
                        }
                        .buttonStyle(.plain).accessibilityLabel(Text(Calendar.current.weekdaySymbols[d])).accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                timeOfDay
            case .monthly:
                Stepper(value: $draft.dayOfMonth, in: 1...31) { Text("On day \(draft.dayOfMonth) of the month") }
                if draft.dayOfMonth > 28 { note("Months that have no such day are skipped.") }
                timeOfDay
            }
        }
        Picker(selection: $draft.timezone) {
            Text("This Mac's time zone (\(TimeZone.current.identifier))").tag("")
            Divider()
            ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
        } label: { Text("Time zone") }
        .frame(maxWidth: 420).accessibilityIdentifier("scheduler.editor.timezone")
        cronPreview
    }

    private var timeOfDay: some View {
        HStack {
            Text("At")
            Picker(selection: $draft.hour) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } } label: { Text("Hour") }.labelsHidden().frame(width: 70)
            Text(verbatim: ":")
            Picker(selection: $draft.minute) { ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } } label: { Text("Minute") }.labelsHidden().frame(width: 70)
        }
    }

    @ViewBuilder private var cronPreview: some View {
        switch draft.cronPreview() {
        case .failure(let e):
            Label(e.description, systemImage: "xmark.octagon.fill").font(Theme.Font.caption).foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("scheduler.editor.cronError")
        case .success(let dates):
            VStack(alignment: .leading, spacing: 3) {
                Label("Valid. Next 5 runs:", systemImage: "checkmark.circle.fill").font(Theme.Font.caption).foregroundStyle(Theme.success)
                ForEach(dates, id: \.self) { d in
                    Text(verbatim: Self.previewLine(d, zone: draft.timezone)).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                }
            }
            .padding(Theme.Space.s).frame(maxWidth: 420, alignment: .leading)
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            .accessibilityIdentifier("scheduler.editor.cronPreview")
        }
    }

    /// "Mon 23 Nov 2026, 09:00 EST" in the chosen zone.
    static func previewLine(_ date: Date, zone: String) -> String {
        let f = DateFormatter()
        f.timeZone = zone.isEmpty ? .current : (TimeZone(identifier: zone) ?? .current)
        f.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy HH:mm zzz")
        return f.string(from: date)
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { draft.path = url.path }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { draft.bundleID = id }
    }

    private func save() {
        saving = true; failure = nil
        if draft.name.isEmpty || existing == nil { draft.name = workflows.first { $0.id == draft.workflowID }?.name ?? draft.workflowID }
        var schedule = draft.makeSchedule(existing: existing)
        if case .fileChange(let p, let r, let g, let d) = schedule.trigger,
           let canonical = try? PathResolver.canonical(p, relativeTo: URL(fileURLWithPath: NSHomeDirectory())) {
            schedule.trigger = .fileChange(path: canonical, recursive: r, glob: g, debounceSeconds: d)
        }
        Task {
            do {
                try await model.services.workflows.saveSchedule(schedule)
                await onChange()
                dismiss()
            } catch { failure = Redactor.shared.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            saving = false
        }
    }

    private func delete() {
        guard let existing else { return }
        saving = true
        Task {
            do { try await model.services.workflows.removeSchedule(id: existing.id); await onChange(); dismiss() }
            catch { failure = Redactor.shared.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            saving = false
        }
    }
}
