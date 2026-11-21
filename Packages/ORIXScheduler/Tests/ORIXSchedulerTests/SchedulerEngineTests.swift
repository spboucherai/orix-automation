// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXScheduler/Tests/ORIXSchedulerTests/SchedulerEngineTests.swift
// Description      : Engine tests with a manual clock and the in-memory store:
//                    dedup, missed-run policies, concurrency, retries,
//                    pause/resume/runNow/cancel, approval parking, lease
//                    takeover, run loop.
// Module           : ORIXSchedulerTests
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
import Testing
@testable import ORIXScheduler

/// Records launches and answers them from a script. Optionally holds every launch until `release()`.
final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _launches: [QueueItem] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var held: Bool
    private let answer: @Sendable (QueueItem) -> RunLaunchResult

    init(held: Bool = false, answer: @escaping @Sendable (QueueItem) -> RunLaunchResult = { .succeeded(runID: "run-\($0.id.prefix(6))") }) {
        self.held = held
        self.answer = answer
    }

    var launches: [QueueItem] { lock.withLock { _launches } }
    var count: Int { launches.count }

    func launch(_ item: QueueItem, _ schedule: Schedule) async -> RunLaunchResult {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go: Bool = lock.withLock {
                _launches.append(item)
                if held { waiting.append(c); return false }
                return true
            }
            if go { c.resume() }
        }
        return answer(item)
    }

    /// Lets every held launch finish, and the following ones run straight through.
    func release() {
        let all: [CheckedContinuation<Void, Never>] = lock.withLock {
            held = false
            let w = waiting
            waiting = []
            return w
        }
        for c in all { c.resume() }
    }
}

struct Harness {
    let clock: ManualSchedulerClock
    let store: InMemoryScheduleStore
    let recorder: LaunchRecorder
    let engine: SchedulerEngine

    init(start: String, recorder: LaunchRecorder = LaunchRecorder(), owner: String = "engine-A",
         configuration: SchedulerConfiguration = SchedulerConfiguration(observesSystemWake: false)) {
        let clock = ManualSchedulerClock(now: utc(start))
        self.clock = clock
        store = InMemoryScheduleStore(now: { clock.now() })
        self.recorder = recorder
        engine = SchedulerEngine(store: store, clock: clock, launcher: { await recorder.launch($0, $1) }, owner: owner, configuration: configuration)
    }

    func secondEngine(owner: String, recorder: LaunchRecorder) -> SchedulerEngine {
        SchedulerEngine(store: store, clock: clock, launcher: { await recorder.launch($0, $1) }, owner: owner,
                        configuration: SchedulerConfiguration(observesSystemWake: false))
    }

    /// One tick, then wait for every launcher to finish.
    @discardableResult func step() async -> TickSummary {
        let summary = await engine.tick()
        await engine.settle()
        return summary
    }

    func items(_ status: QueueItem.Status? = nil) async -> [QueueItem] {
        (try? await engine.queue(status: status)) ?? []
    }
}

/// Daily at 09:00 Toronto. In June, 09:00 EDT is 13:00Z.
func dailyNine(_ policy: MissedRunPolicy = .skip, concurrency: ConcurrencyPolicy = .skipIfRunning, createdAt: String) -> Schedule {
    Schedule(id: "daily", workflowID: "wf-report", name: "Daily report", trigger: .cron(expression: "0 9 * * *", timezone: "America/Toronto"),
             missedRunPolicy: policy, concurrency: concurrency, createdAt: utc(createdAt))
}

@Suite("Scheduler engine: firing and dedup (unit, manual clock, in-memory store)")
struct EngineFiringTests {
    @Test func firesWhenDueAndNotBefore() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        let saved = try await h.engine.save(dailyNine(createdAt: "2026-06-01T12:00:00Z"))
        #expect(saved.nextFireAt == utc("2026-06-01T13:00:00Z"))
        var summary = await h.step()
        #expect(summary == TickSummary(active: true))
        h.clock.set(utc("2026-06-01T12:59:59Z"))
        #expect(await h.step().enqueued == 0)
        h.clock.set(utc("2026-06-01T13:00:00Z"))
        summary = await h.step()
        #expect(summary.enqueued == 1 && summary.launched == 1 && summary.skipped == 0)
        let items = await h.items()
        #expect(items.count == 1)
        #expect(items[0].status == .succeeded && items[0].attempt == 1 && items[0].runID != nil)
        #expect(items[0].dueAt == utc("2026-06-01T13:00:00Z"))
        #expect(items[0].dedupKey == "daily@\(Int64(utc("2026-06-01T13:00:00Z").timeIntervalSince1970 * 1000))")
        let schedule = try #require(try await h.engine.schedule(id: "daily"))
        #expect(schedule.lastFiredAt == utc("2026-06-01T13:00:00Z") && schedule.nextFireAt == utc("2026-06-02T13:00:00Z"))
        // Ticking again at the same instant changes nothing.
        #expect(await h.step().enqueued == 0)
        #expect(h.recorder.count == 1)
    }

    @Test func aRestartNeverEnqueuesTheSameInstantTwice() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        try await h.engine.save(dailyNine(.runAll(max: 5), createdAt: "2026-06-01T12:00:00Z"))
        h.clock.set(utc("2026-06-01T13:00:05Z"))
        await h.step()
        #expect(h.recorder.count == 1)

        // Simulate a crash right after the enqueue: the schedule's cursor was never saved.
        var stale = try #require(await h.store.schedule(id: "daily"))
        stale.lastEvaluatedAt = utc("2026-06-01T12:00:00Z")
        stale.lastFiredAt = nil
        await h.store.saveSchedule(stale)

        let afterRestart = LaunchRecorder()
        let restarted = h.secondEngine(owner: "engine-A", recorder: afterRestart)
        let summary = await restarted.tick()
        await restarted.settle()
        #expect(summary.active && summary.enqueued == 0 && summary.launched == 0)
        #expect(afterRestart.count == 0)
        #expect(await h.items().count == 1)

        // Even long after: the instant is now "missed", the policy says run it, and the key still refuses a duplicate.
        h.clock.set(utc("2026-06-01T15:00:00Z"))
        stale.lastEvaluatedAt = utc("2026-06-01T12:00:00Z")
        await h.store.saveSchedule(stale)
        let later = await restarted.tick()
        await restarted.settle()
        #expect(later.enqueued == 0 && afterRestart.count == 0)
        #expect(await h.items().filter { $0.status != .skipped }.count == 1)
    }

    @Test func theStoreRefusesASecondItemWithTheSameKey() async throws {
        let store = InMemoryScheduleStore()
        let now = utc("2026-06-01T13:00:00Z")
        let key = QueueItem.dedupKey(scheduleID: "s", instant: now)
        #expect(await store.enqueue(QueueItem(scheduleID: "s", workflowID: "w", dueAt: now, enqueuedAt: now, dedupKey: key)))
        #expect(await store.enqueue(QueueItem(scheduleID: "s", workflowID: "w", dueAt: now, enqueuedAt: now, dedupKey: key)) == false)
        #expect(await store.queueItem(dedupKey: key) != nil)
        #expect(await store.queueItems().count == 1)
        // Atomic claim: one claimer gets it, the next gets nothing.
        let claims = await withTaskGroup(of: QueueItem?.self) { group -> [QueueItem] in
            for _ in 0..<8 { group.addTask { try? await store.claimNext(now: now) } }
            var out: [QueueItem] = []
            for await c in group { if let c { out.append(c) } }
            return out
        }
        #expect(claims.count == 1 && claims[0].status == .running)
    }

    @Test func onceAndIntervalTriggers() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        try await h.engine.save(Schedule(id: "once", workflowID: "wf-a", name: "Once", trigger: .once(at: utc("2026-06-01T12:10:00Z")), createdAt: utc("2026-06-01T12:00:00Z")))
        try await h.engine.save(Schedule(id: "every", workflowID: "wf-b", name: "Every 4 min", trigger: .interval(seconds: 240), createdAt: utc("2026-06-01T12:00:00Z")))
        var launchedFor: [String: Int] = [:]
        for minute in 1...20 {
            h.clock.set(utc("2026-06-01T12:00:00Z").addingTimeInterval(Double(minute) * 60))
            await h.step()
        }
        for item in h.recorder.launches { launchedFor[item.scheduleID, default: 0] += 1 }
        #expect(launchedFor == ["once": 1, "every": 5])
        #expect(try await h.engine.schedule(id: "once")?.nextFireAt == nil)
        #expect(try await h.engine.schedule(id: "every")?.nextFireAt == utc("2026-06-01T12:24:00Z"))
        let everyDue = await h.items().filter { $0.scheduleID == "every" }.map(\.dueAt)
        #expect(everyDue == [4, 8, 12, 16, 20].map { utc("2026-06-01T12:00:00Z").addingTimeInterval($0 * 60) })
    }

    @Test func invalidSchedulesAreRefused() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        await #expect(throws: SchedulerError.self) {
            try await h.engine.save(Schedule(workflowID: "w", name: "bad", trigger: .cron(expression: "61 * * * *", timezone: nil)))
        }
        await #expect(throws: SchedulerError.self) {
            try await h.engine.save(Schedule(workflowID: "w", name: "bad", trigger: .cron(expression: "0 9 * * *", timezone: "Mars/Olympus")))
        }
        await #expect(throws: SchedulerError.self) {
            try await h.engine.save(Schedule(workflowID: "w", name: "bad", trigger: .interval(seconds: 0.1)))
        }
        await #expect(throws: SchedulerError.self) { try await h.engine.runNow(scheduleID: "nope") }
        #expect(try await h.engine.schedules().isEmpty)
    }

    @Test func upcomingMergesSchedulesInOrder() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        try await h.engine.save(dailyNine(createdAt: "2026-06-01T12:00:00Z"))
        try await h.engine.save(Schedule(id: "six-hourly", workflowID: "wf-b", name: "Six-hourly", trigger: .cron(expression: "0 */6 * * *", timezone: "UTC"), createdAt: utc("2026-06-01T12:00:00Z")))
        try await h.engine.save(Schedule(id: "paused", workflowID: "wf-c", name: "Paused", trigger: .interval(seconds: 60), paused: true, createdAt: utc("2026-06-01T12:00:00Z")))
        try await h.engine.save(Schedule(id: "manual", workflowID: "wf-d", name: "Manual", trigger: .manual, createdAt: utc("2026-06-01T12:00:00Z")))
        let upcoming = try await h.engine.upcoming(limit: 5)
        #expect(upcoming.map(\.0.id) == ["daily", "six-hourly", "six-hourly", "six-hourly", "six-hourly"])
        #expect(upcoming.map(\.1) == ["2026-06-01T13:00:00Z", "2026-06-01T18:00:00Z", "2026-06-02T00:00:00Z", "2026-06-02T06:00:00Z", "2026-06-02T12:00:00Z"].map(utc))
        #expect(try await h.engine.upcoming(limit: 0).isEmpty)
    }
}

@Suite("Scheduler engine: missed runs after a three-day gap (unit, manual clock)")
struct EngineMissedRunTests {
    /// Runs on day 0 at 09:00, then the Mac is off until day 3 at 15:00 Toronto: 09:00 was missed on days 1, 2 and 3.
    private func afterGap(_ policy: MissedRunPolicy, wakeAt: String = "2026-06-04T19:00:00Z") async throws -> Harness {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        try await h.engine.save(dailyNine(policy, concurrency: .queue, createdAt: "2026-06-01T12:00:00Z"))
        h.clock.set(utc("2026-06-01T13:00:00Z"))
        await h.step()
        #expect(h.recorder.count == 1)
        h.clock.set(utc(wakeAt))
        return h
    }

    @Test func skipRunsNothingAndSaysWhatWasMissed() async throws {
        let h = try await afterGap(.skip)
        let summary = await h.step()
        #expect(summary.enqueued == 0 && summary.launched == 0 && summary.skipped == 1)
        #expect(h.recorder.count == 1)
        let skipped = await h.items(.skipped)
        #expect(skipped.count == 1)
        #expect(skipped[0].reason.contains("3 scheduled firing(s)") && skipped[0].reason.contains("3 not run (policy skip)"))
        #expect(skipped[0].reason.contains("2026-06-02T13:00:00Z") && skipped[0].reason.contains("2026-06-04T13:00:00Z"))
        #expect(skipped[0].runID == nil)
        // It never claims a run for the missed days, and does not repeat the record.
        #expect(await h.items(.succeeded).count == 1)
        #expect(await h.step().skipped == 0)
        #expect(try await h.engine.schedule(id: "daily")?.nextFireAt == utc("2026-06-05T13:00:00Z"))
    }

    @Test func runOnceRunsTheLatestMissedInstantOnly() async throws {
        let h = try await afterGap(.runOnce)
        let summary = await h.step()
        #expect(summary.enqueued == 1 && summary.launched == 1 && summary.skipped == 1)
        #expect(h.recorder.count == 2)
        let caughtUp = h.recorder.launches[1]
        #expect(caughtUp.dueAt == utc("2026-06-04T13:00:00Z") && caughtUp.reason.hasPrefix("catch-up"))
        #expect(await h.items(.skipped).first?.reason.contains("2 not run (policy runOnce)") == true)
        #expect(await h.step() == TickSummary(active: true))
    }

    @Test func runOnceDoesNotDoubleAnOnTimeRun() async throws {
        // Wakes 30 s after day 3's 09:00: that one is on time; days 1 and 2 were missed.
        let h = try await afterGap(.runOnce, wakeAt: "2026-06-04T13:00:30Z")
        let summary = await h.step()
        #expect(summary.enqueued == 1 && summary.launched == 1 && summary.skipped == 1)
        #expect(h.recorder.launches.last?.reason.hasPrefix("scheduled for") == true)
        #expect(await h.items(.skipped).first?.reason.contains("2 not run (policy runOnce (covered by the on-time run))") == true)
    }

    @Test func runAllIsBoundedByMax() async throws {
        let two = try await afterGap(.runAll(max: 2))
        var summary = await two.step()
        #expect(summary.enqueued == 2 && summary.skipped == 1)
        #expect(two.recorder.launches.dropFirst().map(\.dueAt) == ["2026-06-03T13:00:00Z", "2026-06-04T13:00:00Z"].map(utc))
        #expect(await two.items(.skipped).first?.reason.contains("1 not run (policy runAll(max: 2))") == true)

        let ten = try await afterGap(.runAll(max: 10))
        summary = await ten.step()
        #expect(summary.enqueued == 3 && summary.skipped == 0)
        #expect(ten.recorder.launches.dropFirst().map(\.dueAt) == ["2026-06-02T13:00:00Z", "2026-06-03T13:00:00Z", "2026-06-04T13:00:00Z"].map(utc))
        #expect(await ten.items(.skipped).isEmpty)
        #expect(await ten.items(.succeeded).count == 4)
    }

    @Test func aBusyEveryMinuteScheduleIsSummarisedNotReplayed() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        try await h.engine.save(Schedule(id: "minutely", workflowID: "wf", name: "Every minute", trigger: .cron(expression: "* * * * *", timezone: "UTC"),
                                         missedRunPolicy: .runOnce, concurrency: .queue, createdAt: utc("2026-06-01T12:00:00Z")))
        h.clock.set(utc("2026-06-04T12:00:30Z")) // three days later
        let summary = await h.step()
        // 4320 instants passed; the last two (11:59, 12:00) are within the tolerance and run on time.
        #expect(summary.enqueued == 2 && summary.skipped == 1)
        let reason = try #require(await h.items(.skipped).first?.reason)
        #expect(reason.contains("4318 scheduled firing(s)"), "\(reason)")
    }
}

@Suite("Scheduler engine: concurrency, retries and control (unit, manual clock)")
struct EngineControlTests {
    private func everyMinute(_ concurrency: ConcurrencyPolicy, maxRetries: Int = 0, backoff: Double = 10) -> Schedule {
        Schedule(id: "s", workflowID: "wf", name: "Every minute", trigger: .interval(seconds: 60), concurrency: concurrency,
                 maxRetries: maxRetries, retryBackoffSeconds: backoff, createdAt: utc("2026-06-01T12:00:00Z"))
    }

    private func advance(_ h: Harness, toMinute m: Double) { h.clock.set(utc("2026-06-01T12:00:00Z").addingTimeInterval(m * 60)) }

    @Test func skipIfRunningDropsOverlappingFirings() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(held: true))
        try await h.engine.save(everyMinute(.skipIfRunning))
        advance(h, toMinute: 1)
        #expect(await h.engine.tick().launched == 1)
        advance(h, toMinute: 2)
        let second = await h.engine.tick()
        #expect(second.enqueued == 1 && second.launched == 0 && second.skipped == 1)
        #expect(await h.items(.running).count == 1)
        #expect(await h.items(.skipped).first?.reason.contains("skipIfRunning") == true)
        h.recorder.release()
        await h.engine.settle()
        advance(h, toMinute: 3)
        await h.step()
        #expect(h.recorder.count == 2)
        #expect(await h.items(.succeeded).count == 2)
    }

    @Test func queueHoldsOverlappingFiringsUntilTheWorkflowIsFree() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(held: true))
        try await h.engine.save(everyMinute(.queue))
        for m in 1...3 {
            advance(h, toMinute: Double(m))
            await h.engine.tick()
        }
        #expect(await eventually { h.recorder.count == 1 })
        #expect(await h.items(.running).count == 1)
        #expect(await h.items(.pending).count == 2)
        // The per-workflow lock also covers another schedule of the same workflow.
        try await h.engine.save(Schedule(id: "other", workflowID: "wf", name: "Other", trigger: .manual, concurrency: .queue, createdAt: utc("2026-06-01T12:00:00Z")))
        h.clock.advance(by: 1)
        try await h.engine.runNow(scheduleID: "other")
        #expect(await h.engine.tick().launched == 0)
        // Completion starts the next one without waiting for a tick, one at a time, oldest first.
        h.recorder.release()
        await h.engine.settle()
        #expect(h.recorder.count == 4)
        #expect(h.recorder.launches.map(\.scheduleID) == ["s", "s", "s", "other"])
        #expect(await h.items(.succeeded).count == 4)
    }

    @Test func parallelAllowsUpToMaxRuns() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(held: true))
        try await h.engine.save(everyMinute(.parallel(max: 2)))
        for m in 1...3 {
            advance(h, toMinute: Double(m))
            await h.engine.tick()
        }
        #expect(await eventually { h.recorder.count == 2 })
        #expect(await h.items(.running).count == 2)
        #expect(await h.items(.pending).count == 1)
        h.recorder.release()
        await h.engine.settle()
        #expect(h.recorder.count == 3)
    }

    @Test func theGlobalLimitCapsRunsAcrossWorkflows() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(held: true),
                        configuration: SchedulerConfiguration(maxConcurrentRuns: 2, observesSystemWake: false))
        for i in 0..<4 {
            try await h.engine.save(Schedule(id: "s\(i)", workflowID: "wf\(i)", name: "S\(i)", trigger: .manual, createdAt: utc("2026-06-01T12:00:00Z")))
            try await h.engine.runNow(scheduleID: "s\(i)")
        }
        #expect(await h.engine.tick().launched == 2)
        #expect(await h.items(.pending).count == 2)
        h.recorder.release()
        await h.engine.settle()
        #expect(h.recorder.count == 4)
    }

    @Test func retriesOnlyRetryableFailuresWithDoublingBackoff() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(answer: { _ in .failed(runID: "r", error: "network down", retryable: true) }))
        try await h.engine.save(Schedule(id: "s", workflowID: "wf", name: "Once", trigger: .once(at: utc("2026-06-01T12:01:00Z")),
                                         maxRetries: 2, retryBackoffSeconds: 10, createdAt: utc("2026-06-01T12:00:00Z")))
        advance(h, toMinute: 1)
        await h.step()
        var item = try #require(await h.items().first)
        #expect(item.status == .pending && item.attempt == 2 && item.lastError == "network down")
        #expect(item.dueAt == utc("2026-06-01T12:01:10Z"))
        // Not before the backoff has elapsed.
        h.clock.advance(by: 9)
        #expect(await h.step().launched == 0)
        h.clock.advance(by: 1)
        #expect(await h.step().launched == 1)
        item = try #require(await h.items().first)
        #expect(item.status == .pending && item.attempt == 3 && item.dueAt == utc("2026-06-01T12:01:30Z"))
        h.clock.advance(by: 20)
        await h.step()
        item = try #require(await h.items().first)
        #expect(item.status == .failed && item.attempt == 3)
        #expect(h.recorder.count == 3)
        h.clock.advance(by: 3600)
        await h.step()
        #expect(h.recorder.count == 3)
    }

    @Test func nonRetryableFailuresAndZeroRetriesAreFinal() async throws {
        let notRetryable = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(answer: { _ in .failed(runID: nil, error: "mail already sent", retryable: false) }))
        try await notRetryable.engine.save(everyMinute(.queue, maxRetries: 5))
        advance(notRetryable, toMinute: 1)
        await notRetryable.step()
        #expect(await notRetryable.items(.failed).count == 1)
        #expect(notRetryable.recorder.count == 1)

        let noRetries = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(answer: { _ in .failed(runID: nil, error: "boom", retryable: true) }))
        try await noRetries.engine.save(everyMinute(.queue, maxRetries: 0))
        advance(noRetries, toMinute: 1)
        await noRetries.step()
        #expect(await noRetries.items(.failed).first?.lastError == "boom")
        #expect(noRetries.recorder.count == 1)
    }

    @Test func backoffIsCapped() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(answer: { _ in .failed(runID: nil, error: "x", retryable: true) }),
                        configuration: SchedulerConfiguration(maxBackoffSeconds: 25, observesSystemWake: false))
        try await h.engine.save(Schedule(id: "s", workflowID: "wf", name: "Manual", trigger: .manual, maxRetries: 4, retryBackoffSeconds: 10, createdAt: utc("2026-06-01T12:00:00Z")))
        try await h.engine.runNow(scheduleID: "s")
        var delays: [Double] = []
        for _ in 0..<4 {
            await h.step()
            let item = try #require(await h.items().first)
            delays.append(item.dueAt.timeIntervalSince(h.clock.now()))
            h.clock.set(item.dueAt)
        }
        #expect(delays == [10, 20, 25, 25])
    }

    @Test func pauseHoldsAndResumeDoesNotCatchUp() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        try await h.engine.save(Schedule(id: "s", workflowID: "wf", name: "Every minute", trigger: .interval(seconds: 60),
                                         missedRunPolicy: .runAll(max: 100), createdAt: utc("2026-06-01T12:00:00Z")))
        try await h.engine.pause(scheduleID: "s")
        #expect(try await h.engine.schedule(id: "s")?.nextFireAt == nil)
        advance(h, toMinute: 30)
        #expect(await h.step() == TickSummary(active: true))
        try await h.engine.resume(scheduleID: "s")
        #expect(try await h.engine.schedule(id: "s")?.nextFireAt == utc("2026-06-01T12:31:00Z"))
        #expect(await h.step().enqueued == 0)
        advance(h, toMinute: 31)
        #expect(await h.step().enqueued == 1)
        #expect(h.recorder.count == 1)
    }

    @Test func runNowWorksWhilePausedAndIsNotDeduplicated() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        try await h.engine.save(everyMinute(.queue))
        try await h.engine.pause(scheduleID: "s")
        let first = try await h.engine.runNow(scheduleID: "s")
        let second = try await h.engine.runNow(scheduleID: "s")
        #expect(first.dedupKey != second.dedupKey && first.reason == "manual: run now")
        await h.step()
        #expect(h.recorder.count == 2)
        #expect(await h.items(.succeeded).count == 2)
        #expect(try await h.engine.schedule(id: "s")?.lastFiredAt == utc("2026-06-01T12:00:00Z"))
    }

    @Test func cancelPendingRunningAndFinishedItems() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(held: true))
        try await h.engine.save(everyMinute(.queue))
        advance(h, toMinute: 1)
        await h.engine.tick()
        advance(h, toMinute: 2)
        await h.engine.tick()
        let running = try #require(await h.items(.running).first)
        let pending = try #require(await h.items(.pending).first)
        try await h.engine.cancel(queueItemID: pending.id)
        try await h.engine.cancel(queueItemID: running.id)
        #expect(await h.items(.canceled).count == 2)
        // The launcher's late "succeeded" does not resurrect the canceled run.
        h.recorder.release()
        await h.engine.settle()
        #expect(await h.items(.canceled).count == 2)
        #expect(await h.items(.succeeded).isEmpty)
        #expect(h.recorder.count == 1)
        // Canceling a finished item is a no-op; an unknown one is an error.
        try await h.engine.cancel(queueItemID: running.id)
        await #expect(throws: SchedulerError.self) { try await h.engine.cancel(queueItemID: "nope") }
    }

    @Test func disableCancelsPendingAndStopsFiring() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(held: true))
        try await h.engine.save(everyMinute(.queue))
        for m in 1...3 { advance(h, toMinute: Double(m)); await h.engine.tick() }
        try await h.engine.disable(scheduleID: "s")
        #expect(await h.items(.canceled).map(\.reason) == ["schedule disabled", "schedule disabled"])
        h.recorder.release()
        await h.engine.settle()
        advance(h, toMinute: 10)
        #expect(await h.step() == TickSummary(active: true))
        #expect(h.recorder.count == 1)
        try await h.engine.enable(scheduleID: "s")
        advance(h, toMinute: 11)
        #expect(await h.step().enqueued == 1)
        // Removing the schedule cancels what is still pending.
        try await h.engine.pause(scheduleID: "s")
        _ = try await h.engine.fire(scheduleID: "s", reason: "ignored while paused")
        try await h.engine.resume(scheduleID: "s")
        advance(h, toMinute: 12)
        try await h.engine.remove(scheduleID: "s")
        #expect(await h.step().launched == 0)
    }

    @Test func eventFiringRespectsEnabledPausedAndDedupKeys() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        try await h.engine.save(Schedule(id: "login", workflowID: "wf", name: "At login", trigger: .login, concurrency: .queue, createdAt: utc("2026-06-01T12:00:00Z")))
        #expect(try await h.engine.fire(scheduleID: "login", reason: "login", dedupKey: "login@login-1") != nil)
        #expect(try await h.engine.fire(scheduleID: "login", reason: "login", dedupKey: "login@login-1") == nil)
        #expect(try await h.engine.fire(scheduleID: "missing", reason: "x") == nil)
        try await h.engine.pause(scheduleID: "login")
        #expect(try await h.engine.fire(scheduleID: "login", reason: "x") == nil)
        try await h.engine.resume(scheduleID: "login")
        try await h.engine.disable(scheduleID: "login")
        #expect(try await h.engine.fire(scheduleID: "login", reason: "x") == nil)
        #expect(await h.items().count == 1)
    }
}

@Suite("Scheduler engine: approvals, lease and run loop (unit, manual clock)")
struct EngineApprovalLeaseTests {
    @Test func waitingApprovalItemsStayParkedAndVisible() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(answer: { _ in .waitingApproval(runID: "run-42") }))
        try await h.engine.save(Schedule(id: "s", workflowID: "wf", name: "Every minute", trigger: .interval(seconds: 60), createdAt: utc("2026-06-01T12:00:00Z")))
        h.clock.advance(by: 60)
        await h.step()
        let parked = try #require(await h.items(.waitingApproval).first)
        #expect(parked.runID == "run-42" && parked.reason.contains("waiting for approval"))
        // Hours of ticking never approve, relaunch or drop it; the workflow stays locked.
        for _ in 0..<5 {
            h.clock.advance(by: 3600)
            await h.step()
        }
        #expect(h.recorder.count == 1)
        #expect(await h.items(.waitingApproval).map(\.id) == [parked.id])
        #expect(await h.items(.succeeded).isEmpty)
        #expect(await h.items(.skipped).contains { $0.reason.contains("skipIfRunning") })
        // Only an explicit resolution ends it.
        await #expect(throws: SchedulerError.self) { try await h.engine.resolveApproval(queueItemID: "nope", result: .succeeded(runID: nil)) }
        try await h.engine.resolveApproval(queueItemID: parked.id, result: .succeeded(runID: "run-42"))
        #expect(await h.store.queueItem(id: parked.id)?.status == .succeeded)
        await #expect(throws: SchedulerError.self) { try await h.engine.resolveApproval(queueItemID: parked.id, result: .succeeded(runID: nil)) }
    }

    @Test func aParkedItemCanBeCanceled() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", recorder: LaunchRecorder(answer: { _ in .waitingApproval(runID: nil) }))
        try await h.engine.save(Schedule(id: "s", workflowID: "wf", name: "Manual", trigger: .manual, createdAt: utc("2026-06-01T12:00:00Z")))
        let item = try await h.engine.runNow(scheduleID: "s")
        await h.step()
        try await h.engine.cancel(queueItemID: item.id)
        #expect(await h.store.queueItem(id: item.id)?.status == .canceled)
    }

    @Test func aSecondEngineStaysPassiveThenTakesOverWhenTheLeaseExpires() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        let recorderB = LaunchRecorder()
        let b = h.secondEngine(owner: "engine-B", recorder: recorderB)
        try await h.engine.save(Schedule(id: "s", workflowID: "wf", name: "Every minute", trigger: .interval(seconds: 60),
                                         missedRunPolicy: .runAll(max: 10), createdAt: utc("2026-06-01T12:00:00Z")))
        #expect(await h.engine.tick().active)
        #expect(await b.tick().active == false)
        #expect(await b.isActive == false)
        #expect(await h.store.leaseOwner(name: "orix.scheduler") == "engine-A")

        // A keeps renewing: B stays passive even when something is due.
        h.clock.advance(by: 20)
        await h.engine.tick()
        h.clock.advance(by: 20)
        await h.engine.tick()
        h.clock.advance(by: 20) // 12:01:00, due
        let passive = await b.tick()
        #expect(passive == TickSummary(active: false))
        #expect(recorderB.count == 0)
        await h.step()
        #expect(h.recorder.count == 1)

        // A dies. Its lease (30 s) runs out; B takes over and handles what A never did.
        h.clock.advance(by: 29)
        #expect(await b.tick().active == false)
        h.clock.advance(by: 32) // 12:02:01
        let takeover = await b.tick()
        await b.settle()
        #expect(takeover.active && takeover.enqueued == 1)
        #expect(recorderB.count == 1 && h.recorder.count == 1)
        #expect(await h.store.leaseOwner(name: "orix.scheduler") == "engine-B")
        // A comes back: it is the passive one now, and no instant ran twice.
        #expect(await h.engine.tick().active == false)
        #expect(await h.engine.isActive == false)
        let due = await h.items(.succeeded).map(\.dueAt)
        #expect(due == [utc("2026-06-01T12:01:00Z"), utc("2026-06-01T12:02:00Z")])
    }

    @Test func stopReleasesTheLeaseImmediately() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        let b = h.secondEngine(owner: "engine-B", recorder: LaunchRecorder())
        await h.engine.tick()
        #expect(await b.tick().active == false)
        await h.engine.stop()
        #expect(await b.tick().active)
    }

    @Test func runsInterruptedByARestartAreMarkedFailedAndNotRelaunched() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z")
        try await h.engine.save(Schedule(id: "s", workflowID: "wf", name: "Manual", trigger: .manual, maxRetries: 3, createdAt: utc("2026-06-01T12:00:00Z")))
        let now = h.clock.now()
        _ = await h.store.enqueue(QueueItem(id: "orphan", scheduleID: "s", workflowID: "wf", dueAt: now, enqueuedAt: now, status: .running, dedupKey: "s@orphan"))
        let summary = await h.step()
        #expect(summary.launched == 0 && h.recorder.count == 0)
        let orphan = try #require(await h.store.queueItem(id: "orphan"))
        #expect(orphan.status == .failed && orphan.lastError?.contains("interrupted") == true)
    }

    @Test func theRunLoopSleepsUntilTheNextInstantAndWakesOnChanges() async throws {
        let h = Harness(start: "2026-06-01T12:00:00Z", configuration: SchedulerConfiguration(heartbeatSeconds: 3600, observesSystemWake: false))
        try await h.engine.save(dailyNine(createdAt: "2026-06-01T12:00:00Z"))
        let loop = Task { await h.engine.run() }
        defer { loop.cancel() }

        func eventually(_ what: String, _ condition: @Sendable () async -> Bool) async {
            for _ in 0..<400 {
                if await condition() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            Issue.record("timed out waiting for: \(what)")
        }
        // The loop parks on the clock; nothing fires early.
        await eventually("loop asleep") { h.clock.sleeperCount == 1 }
        #expect(h.recorder.count == 0)
        // Reaching the instant wakes it without any poke.
        h.clock.set(utc("2026-06-01T13:00:00Z"))
        await eventually("scheduled run") { await h.items(.succeeded).count == 1 }
        // A change made through the engine wakes it at once, with the clock standing still.
        await eventually("loop asleep again") { h.clock.sleeperCount == 1 }
        try await h.engine.runNow(scheduleID: "daily")
        await eventually("manual run") { await h.items(.succeeded).count == 2 }
        // So does an outside store change announced with storeDidChange().
        await eventually("loop asleep again") { h.clock.sleeperCount == 1 }
        let now = h.clock.now()
        _ = await h.store.enqueue(QueueItem(scheduleID: "daily", workflowID: "wf-report", dueAt: now, enqueuedAt: now, dedupKey: "daily@external"))
        h.engine.storeDidChange()
        await eventually("external item") { await h.items(.succeeded).count == 3 }
        await h.engine.stop()
        await eventually("loop ended") { h.clock.sleeperCount == 0 }
        _ = await loop.value
    }
}

@Suite("Scheduler models (unit)")
struct SchedulerModelTests {
    @Test func modelsRoundTripThroughJSON() throws {
        let triggers: [TriggerSpec] = [
            .cron(expression: "0 9 * * MON", timezone: "America/Toronto"), .cron(expression: "@daily", timezone: nil),
            .once(at: utc("2026-06-01T12:00:00Z")), .interval(seconds: 90),
            .fileChange(path: "/tmp/in", recursive: true, glob: "*.pdf", debounceSeconds: 2), .login,
            .appLaunch(bundleID: "com.apple.Safari"), .powerConnected, .networkAvailable, .manual,
        ]
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        for (i, trigger) in triggers.enumerated() {
            let schedule = Schedule(workflowID: "wf", name: "S\(i)", trigger: trigger, missedRunPolicy: i % 2 == 0 ? .runAll(max: 3) : .runOnce,
                                    concurrency: i % 2 == 0 ? .parallel(max: 2) : .queue, maxRetries: 2, lastFiredAt: utc("2026-06-01T12:00:00Z"))
            #expect(try decoder.decode(Schedule.self, from: encoder.encode(schedule)) == schedule)
            #expect(schedule.problems().isEmpty)
        }
        let item = QueueItem(scheduleID: "s", workflowID: "wf", dueAt: utc("2026-06-01T12:00:00Z"), enqueuedAt: utc("2026-06-01T12:00:01Z"),
                             attempt: 2, status: .waitingApproval, dedupKey: "s@1", reason: "r", runID: "run", lastError: "e")
        #expect(try decoder.decode(QueueItem.self, from: encoder.encode(item)) == item)
        #expect(Set(QueueItem.Status.allCases.map(\.rawValue)) == ["pending", "running", "succeeded", "failed", "skipped", "canceled", "waitingApproval"])
        #expect(QueueItem.Status.allCases.filter { !$0.isTerminal } == [.pending, .running, .waitingApproval])
    }

    @Test func triggerMathForIntervalAndOnce() {
        let anchor = utc("2026-06-01T12:00:00Z")
        let every = TriggerSpec.interval(seconds: 90)
        #expect(every.nextFireDate(after: anchor, anchor: anchor) == anchor.addingTimeInterval(90))
        #expect(every.nextFireDate(after: anchor.addingTimeInterval(90), anchor: anchor) == anchor.addingTimeInterval(180))
        #expect(every.nextFireDate(after: anchor.addingTimeInterval(-500), anchor: anchor) == anchor.addingTimeInterval(90))
        #expect(every.latestFireDate(after: anchor, atOrBefore: anchor.addingTimeInterval(400), anchor: anchor) == anchor.addingTimeInterval(360))
        #expect(every.latestFireDate(after: anchor, atOrBefore: anchor.addingTimeInterval(89), anchor: anchor) == nil)
        let once = TriggerSpec.once(at: anchor.addingTimeInterval(10))
        #expect(once.nextFireDate(after: anchor, anchor: anchor) == anchor.addingTimeInterval(10))
        #expect(once.nextFireDate(after: anchor.addingTimeInterval(10), anchor: anchor) == nil)
        #expect(once.latestFireDate(after: anchor, atOrBefore: anchor.addingTimeInterval(60), anchor: anchor) == anchor.addingTimeInterval(10))
        #expect(TriggerSpec.manual.nextFireDate(after: anchor, anchor: anchor) == nil && !TriggerSpec.login.isTimeBased)
        #expect(TriggerSpec.cron(expression: "bad", timezone: nil).problems().count == 1)
        #expect(Schedule(workflowID: "", name: "x", trigger: .manual, missedRunPolicy: .runAll(max: 0), concurrency: .parallel(max: 0), maxRetries: -1).problems().count == 4)
        #expect(ConcurrencyPolicy.parallel(max: 3).capacity == 3 && ConcurrencyPolicy.queue.capacity == 1)
    }

    @Test func manualClockSleepersWakeInOrderAndHonourCancellation() async throws {
        let clock = ManualSchedulerClock(now: utc("2026-06-01T12:00:00Z"))
        try await clock.sleep(until: utc("2026-06-01T11:00:00Z")) // already past
        let sleeper = Task { try await clock.sleep(until: utc("2026-06-01T12:00:10Z")); return clock.now() }
        while clock.sleeperCount == 0 { await Task.yield() }
        clock.advance(by: 5)
        #expect(clock.sleeperCount == 1)
        clock.advance(by: 5)
        #expect(try await sleeper.value == utc("2026-06-01T12:00:10Z"))
        let canceled = Task { try await clock.sleep(until: utc("2027-01-01T00:00:00Z")) }
        while clock.sleeperCount == 0 { await Task.yield() }
        canceled.cancel()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(clock.sleeperCount == 0)
    }
}
