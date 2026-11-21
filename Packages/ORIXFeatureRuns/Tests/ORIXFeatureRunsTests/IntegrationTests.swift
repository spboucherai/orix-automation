// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureRuns/Tests/ORIXFeatureRunsTests/IntegrationTests.swift
// Description      : Integration tests on real services in a temporary folder
//                    (real SQLite, real subprocess): run list paging and
//                    filters, retry recovery, dashboard and scheduler loading,
//                    the console fed by the store and the live hub, one render
//                    per screen, and the 50 000-line console measurement.
// Module           : ORIXFeatureRunsTests
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
import Foundation
import ORIXAppUI
@_spi(Preview) @testable import ORIXFeatureRuns
import SwiftUI
import Testing

@MainActor
private func seedMany(_ store: ORIXStore, count: Int) async throws {
    let base = Date(timeIntervalSince1970: 1_790_000_000)
    let statuses: [RunStatus] = [.succeeded, .failed, .canceled, .succeeded, .timedOut]
    for i in 0..<count {
        let start = base.addingTimeInterval(Double(-i) * 3600)   // run 0 is the newest
        var r = RunRecord(id: String(format: "run-%03d", i), kind: i % 3 == 0 ? "workflow" : "agent", title: i % 10 == 0 ? "Invoice batch \(i)" : "Routine \(i)",
                          trigger: i % 4 == 0 ? "cron" : "manual", mode: .guided, status: statuses[i % statuses.count], queuedAt: start, startedAt: start,
                          endedAt: start.addingTimeInterval(30))
        if i == 7 { r.errorSummary = "the invoice folder is missing" }
        try await store.saveRun(r)
    }
}

private func pngSize(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }

@MainActor
private func render<V: View>(_ name: String, _ view: V, _ model: AppModel, size: CGSize = CGSize(width: 1280, height: 820)) async throws -> Int {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orix-runs-test-\(name).png")
    try await ShotRenderer.render(view.environment(model), size: size, to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return pngSize(url)
}

@Suite("Integration · real store and services", .serialized)
@MainActor
struct RunsIntegrationTests {
    @Test func listPagesSearchesAndFilters() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        defer { try? FileManager.default.removeItem(at: model.services.paths.root) }
        try await seedMany(model.services.store, count: 150)
        let list = RunsListModel(store: model.services.store, pageSize: 40)

        await list.reload()
        #expect(list.rows.count == 40 && list.hasMore)
        #expect(list.rows.first?.id == "run-000" && list.rows.last?.id == "run-039")
        await list.loadMore()
        #expect(list.rows.count == 80 && list.rows.last?.id == "run-079")
        await list.loadMore(); await list.loadMore()
        #expect(list.rows.count == 150 && !list.hasMore)
        #expect(Set(list.rows.map(\.id)).count == 150)
        await list.refresh()                       // a store change keeps what was loaded
        #expect(list.rows.count == 150)

        list.filter.search = "invoice"
        await list.reload()
        #expect(list.rows.count == 16)             // 15 titles + 1 error summary
        #expect(list.rows.contains { $0.id == "run-007" })

        list.filter = RunFilter(); list.filter.statuses = [.failed]
        await list.reload()
        #expect(list.rows.count == 30 && list.rows.allSatisfy { $0.status == .failed })

        list.filter.statuses = [.failed, .timedOut]; list.filter.kinds = ["workflow"]
        await list.reload()
        #expect(list.rows.count == 20 && list.rows.allSatisfy { $0.kind == "workflow" && [.failed, .timedOut].contains($0.status) })
        #expect(!list.hasMore)                     // a sparse filter is satisfied by scanning further pages

        list.filter = RunFilter(); list.filter.triggers = [.schedule]
        list.filter.from = Date(timeIntervalSince1970: 1_790_000_000 - 20 * 3600); list.filter.to = Date(timeIntervalSince1970: 1_790_000_000 - 4 * 3600)
        await list.reload()
        #expect(list.rows.map(\.id) == ["run-004", "run-008", "run-012", "run-016", "run-020"])

        list.filter = RunFilter(); list.filter.newestFirst = false
        await list.reload()
        #expect(list.rows.count == 150 && list.rows.first?.id == "run-149" && list.rows.last?.id == "run-000")
    }

    @Test func retryIsOfferedOnlyWhenInputsCanBeRecovered() async throws {
        let model = try await PreviewEnvironment.make()
        defer { try? FileManager.default.removeItem(at: model.services.paths.root) }
        let s = model.services
        // An agent run whose objective was recorded as its first message.
        let agent = try #require(try await s.store.run(id: "sample-0"))
        guard case .agent(let request, let note)? = await RetryPlan.recover(for: agent, services: s, defaultWorkspace: model.defaultWorkspace) else {
            Issue.record("an agent run with a recorded objective must be retryable"); return
        }
        #expect(request.objective == "Sample · Organise Downloads" && request.model == agent.model && request.workspaceAccess == .read)
        #expect(note.contains("read access"))
        // No objective anywhere: no retry.
        try await s.store.saveRun(RunRecord(id: "bare", kind: "agent", title: "Draft workflow: x", mode: .review, status: .succeeded))
        #expect(await RetryPlan.recover(for: try #require(try await s.store.run(id: "bare")), services: s, defaultWorkspace: model.defaultWorkspace) == nil)
        // A workflow run whose workflow no longer exists, and a run still in flight: no retry.
        #expect(await RetryPlan.recover(for: try #require(try await s.store.run(id: "sample-1")), services: s, defaultWorkspace: model.defaultWorkspace) == nil)
        try await s.store.saveRun(RunRecord(id: "live", kind: "agent", title: "live", mode: .guided, status: .running))
        #expect(await RetryPlan.recover(for: try #require(try await s.store.run(id: "live")), services: s, defaultWorkspace: model.defaultWorkspace) == nil)
        // A workflow run: retryable without a checkpoint only when the workflow takes no parameters.
        for w in await s.workflows.list() {
            let doc = try await s.workflows.document(workflowID: w.id)
            let record = RunRecord(id: "wf-\(w.id)", kind: "workflow", title: w.name, workflowID: w.id, workflowVersion: w.currentVersion, mode: .scheduled, status: .failed)
            let plan = await RetryPlan.recover(for: record, services: s, defaultWorkspace: model.defaultWorkspace)
            #expect((plan != nil) == doc.spec.parameters.isEmpty, "\(w.id)")
            if case .workflow(let r, _)? = plan { #expect(r.workflowID == w.id && r.version == w.currentVersion && r.mode == .guided && r.trigger == "manual") }
        }
    }

    @Test func dashboardAndSchedulerLoadRealState() async throws {
        let model = try await PreviewEnvironment.make()
        defer { try? FileManager.default.removeItem(at: model.services.paths.root) }
        let s = model.services
        try await s.store.saveRun(RunRecord(id: "needs-recovery", kind: "agent", title: "Interrupted", mode: .guided, status: .recoveryRequired, startedAt: Date()))
        let dash = DashboardModel()
        await dash.load(s)
        #expect(dash.loaded && dash.days.count == 30 && dash.recent.count == 7)
        #expect(dash.attention.map(\.id) == ["needs-recovery"])
        #expect(dash.workflows.count == 3 && dash.permissions.count == MacPermission.allCases.count)
        let month = PeriodMetrics.aggregate(days: dash.days, runs: dash.periodRuns, period: .month)
        #expect(month.runs == 7 && month.succeeded == 3)
        #expect(month.averageDuration == 42 && month.durationSample == 6)
        #expect(abs(month.costUSD - (0..<6).reduce(0.0) { $0 + 0.004 + Double($1) * 0.003 }) < 1e-9)

        let workflows = await s.workflows.list()
        // Built-in templates start with their permissions not accepted: enabling one of their schedules must warn.
        #expect(try await s.workflows.permissionReview(workflowID: workflows[0].id).accepted == false)
        var draft = ScheduleDraft()
        draft.workflowID = workflows[0].id; draft.name = workflows[0].name; draft.useRawCron = true; draft.rawCron = "0 9 * * MON"; draft.timezone = "America/Toronto"; draft.enabled = true
        let schedule = draft.makeSchedule(existing: nil)
        try await s.workflows.saveSchedule(schedule)
        let sched = SchedulerModel()
        await sched.load(s)
        let saved = try #require(sched.schedules.first { $0.id == schedule.id })
        #expect(TriggerDescriber.describe(saved.trigger, locale: Locale(identifier: "en_US")) == "Every Monday at 09:00 (America/Toronto)")
        let next = try #require(sched.next[schedule.id])
        #expect(next > Date() && next.timeIntervalSinceNow <= 7 * 86_400 + 60)
        #expect(sched.agenda.count == 7 && sched.agenda.flatMap(\.items).filter { $0.scheduleID == schedule.id }.count == 1)
        #expect(sched.schedulerActive == false)
        try await s.workflows.setSchedule(id: schedule.id, enabled: false)
        await sched.load(s)
        #expect(sched.next[schedule.id] == nil && sched.agenda.flatMap(\.items).allSatisfy { $0.scheduleID != schedule.id })
        try await s.workflows.removeSchedule(id: schedule.id)
        await sched.load(s)
        #expect(!sched.schedules.contains { $0.id == schedule.id })
    }

    @Test func consoleShowsStoredEventsAndLiveOutputOfARealScript() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        defer { try? FileManager.default.removeItem(at: model.services.paths.root) }
        let s = model.services
        let runID = "console-run"
        try await s.store.saveRun(RunRecord(id: runID, kind: "script", title: "Console test", mode: .guided, status: .running, startedAt: Date()))
        await s.store.emit(RunEvent(runID: runID, kind: .userMessage, text: "print two lines"))
        let console = ConsoleModel()
        await console.start(runID: runID, services: s)
        #expect(console.isLive)
        #expect(console.visible.map(\.text) == ["print two lines"])

        let approver = Task { for await pending in s.approvals.updates() { for r in pending { await s.approvals.resolve(id: r.id, response: .approveOnce) } } }
        let hub = s.runs.live
        let call = ToolCall(toolID: "shell.script", arguments: ["script": "echo alpha; echo beta; echo oops >&2; printf 'no newline'"])
        hub.publish(runID, .toolStarted(call))
        let artifacts = s.paths.artifacts.appendingPathComponent(runID)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let result = await s.executor.invoke(call, context: InvocationContext(runID: runID, mode: .guided, workingDirectory: s.paths.scratch, artifactsDirectory: artifacts,
                                                                              progress: { id, p in hub.publish(runID, .toolProgress(callID: id, p)) }))
        approver.cancel()
        #expect(result.status == .succeeded, "\(result.summary)")
        hub.publish(runID, .toolFinished(call, result))
        hub.publish(runID, .finished(.succeeded)); hub.finish(runID)
        try await Task.sleep(nanoseconds: 500_000_000)
        await console.refreshPersisted()

        let lines = console.buffer.lines
        #expect(lines.contains { $0.level == .stdout && $0.text == "alpha" })
        #expect(lines.contains { $0.level == .stdout && $0.text == "beta" })
        #expect(lines.contains { $0.level == .stdout && $0.text == "no newline" })     // an unfinished last line is not lost
        #expect(lines.contains { $0.level == .stderr && $0.text == "oops" })
        #expect(lines.filter { $0.text.hasPrefix("▶ shell.script") }.count == 1)        // live and stored copies of the call collapse
        #expect(lines.filter { $0.text.hasPrefix("■ shell.script succeeded") }.count == 1)
        #expect(lines.contains { $0.level == .approval })
        #expect(lines.last { $0.level == .status }?.text == "SUCCEEDED")
        #expect(!console.isLive)
        #expect(lines.map(\.time) == lines.map(\.time).sorted())

        console.levels = [.stdout, .stderr]
        #expect(console.visible.count == 4)
        console.query = "a"
        #expect(console.matches.count == 2 && console.currentMatch == 1)               // alpha, beta (oops and "no newline" have no a… except "no newline")
        console.clear()
        #expect(console.visible.isEmpty)
        await console.refreshPersisted()
        #expect(console.buffer.lines.isEmpty)                                          // clearing the view does not reload old events
        console.stop()
    }

    @Test func everyScreenRenders() async throws {
        let model = try await PreviewEnvironment.make()
        defer { try? FileManager.default.removeItem(at: model.services.paths.root) }
        let s = model.services
        let workflows = await s.workflows.list()
        try await s.workflows.saveSchedule(Schedule(workflowID: workflows[0].id, name: workflows[0].name, trigger: .cron(expression: "0 9 * * MON", timezone: "America/Toronto"), enabled: true))
        try await s.store.saveRun(RunRecord(id: "rec", kind: "agent", title: "Interrupted", mode: .guided, status: .recoveryRequired, startedAt: Date()))
        await model.refreshShared()
        #expect(try await render("dashboard", DashboardView(), model, size: CGSize(width: 1280, height: 1500)) > 150_000)
        model.selectedRunID = "sample-0"
        for tab in ["timeline", "receipt", "usage", "console"] {
            #expect(try await render("runs-\(tab)", RunsPreviewScreens.runs(tab: tab), model) > 80_000, "\(tab)")
        }
        for tab in ["schedules", "agenda", "queue"] {
            #expect(try await render("scheduler-\(tab)", RunsPreviewScreens.scheduler(tab: tab), model) > 50_000, "\(tab)")
        }
        let schedule = try #require(await s.workflows.schedules().first { $0.enabled })
        #expect(try await render("editor", RunsPreviewScreens.scheduleEditor(existing: schedule, workflows: workflows), model, size: CGSize(width: 640, height: 720)) > 40_000)
        #expect(try await render("recovery", RunsPreviewScreens.recovery(try #require(try await s.store.run(id: "rec"))), model, size: CGSize(width: 560, height: 420)) > 15_000)
        #expect(try await render("console", ConsoleView(runID: "sample-0").padding(16), model, size: CGSize(width: 1000, height: 500)) > 30_000)

        let empty = try await PreviewEnvironment.make(seed: false)
        defer { try? FileManager.default.removeItem(at: empty.services.paths.root) }
        #expect(try await render("dashboard-empty", DashboardView(), empty) > 60_000)
        #expect(try await render("runs-empty", RunsView(), empty) > 30_000)
        #expect(try await render("scheduler-empty", SchedulerView(), empty) > 40_000)
    }
}

@Suite("Performance · console with 50 000 lines", .serialized)
@MainActor
struct ConsolePerformanceTests {
    /// Streams 50 000 synthetic lines in bursts of 500 into a console that is on screen (off-screen window), the way the
    /// 100 ms flush would deliver them, and measures how long the main thread is held per burst, plus search and filter.
    @Test func burstOf50000LinesStaysResponsive() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        defer { try? FileManager.default.removeItem(at: model.services.paths.root) }
        _ = NSApplication.shared
        let console = ConsoleModel()
        let host = NSHostingView(rootView: RunsPreviewScreens.console(console).environment(model).frame(width: 1100, height: 600))
        host.frame = CGRect(x: 0, y: 0, width: 1100, height: 600)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1100, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        try await Task.sleep(nanoseconds: 300_000_000)

        let total = 50_000, burst = 500
        let start = Date()
        var held: [Double] = []
        var clock = ContinuousClock.now
        let wall = ContinuousClock.now
        for b in 0..<(total / burst) {
            let entries: [ConsoleAssembler.Entry] = (0..<burst).map { i in
                let n = b * burst + i
                return ("line \(n) of synthetic output: the quick brown fox jumps over the lazy dog \(n % 97 == 0 ? "NEEDLE" : "")", n % 50 == 0 ? .stderr : .stdout,
                        start.addingTimeInterval(Double(n) / 1000))
            }
            clock = .now
            console.ingest(entries)
            console.flush()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            held.append(Double((ContinuousClock.now - clock).components.attoseconds) / 1e15 + Double((ContinuousClock.now - clock).components.seconds) * 1000)
            await Task.yield()   // let SwiftUI apply the change, as between two flush ticks
            if b % 10 == 9 { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let elapsed = ContinuousClock.now - wall
        let totalMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15

        #expect(console.buffer.lines.count == 20_000)
        #expect(console.dropped == 30_000)
        #expect(console.buffer.lines.first?.text.hasPrefix("line 30000 ") == true)
        #expect(console.buffer.lines.last?.text.hasPrefix("line 49999 ") == true)


        func ms(_ work: () -> Void) -> Double {
            let t = ContinuousClock.now; work(); let d = ContinuousClock.now - t
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        // Search stays correct and cheap while lines keep arriving.
        console.query = "needle"
        let streamingSearchMs = ms {
            console.ingest((0..<500).map { i in ("late line \(i) \(i % 100 == 0 ? "needle" : "")", .stdout, start.addingTimeInterval(60 + Double(i) / 1000)) })
            console.flush()
        }
        #expect(console.matches == console.buffer.search("needle"))
        console.query = ""
        var found = 0
        let searchMs = ms { found = console.buffer.search("needle").count }
        #expect(found == (30_500..<50_000).filter { $0 % 97 == 0 }.count + 5)
        let queryMs = ms { console.query = "needle" }
        let filterMs = ms { console.levels = [.stderr] }
        #expect(console.visible.count == 390)
        let nextMs = ms { for _ in 0..<50 { console.nextMatch() } }
        let copyMs = ms { console.levels = Set(ConsoleLine.Level.allCases); _ = console.text(selection: []) }
        let settle = ms { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orix-console-50k.png")
        try await ShotRenderer.render(RunsPreviewScreens.console(console).environment(model), size: CGSize(width: 1100, height: 600), settle: 0.6, to: url)
        #expect(pngSize(url) > 40_000)
        try? FileManager.default.removeItem(at: url)
        window.orderOut(nil)

        let sorted = held.sorted()
        let mean = held.reduce(0, +) / Double(held.count), p95 = sorted[Int(Double(sorted.count) * 0.95)], worst = sorted.last ?? 0
        print(String(format: "MEASURE console 50k: %d bursts of %d lines, total %.0f ms; main thread held per burst (ingest + flush + layout + draw): mean %.1f ms, p95 %.1f ms, max %.1f ms; search over 20 000 lines %.1f ms; set query (search + refresh) %.1f ms; level filter %.1f ms; 50 next-match steps %.2f ms; copy all 20 000 lines %.1f ms; relayout after filter %.1f ms; one 500-line flush with a search active %.1f ms",
                     held.count, burst, totalMs, mean, p95, worst, searchMs, queryMs, filterMs, nextMs, copyMs, settle, streamingSearchMs))
        // Budgets: a burst must fit well inside the 100 ms flush period; interactions must feel immediate.
        #expect(mean < 50)
        #expect(p95 < 100)
        #expect(searchMs < 500)
        #expect(queryMs < 1000)
        #expect(filterMs < 500)
        #expect(streamingSearchMs < 100)
    }
}
