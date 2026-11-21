// ORIX OS Automation
// File: Packages/ORIXScheduler/Sources/ORIXScheduler/SchedulerEngine.swift
// Description: The scheduler: computes due firings, enqueues them idempotently, applies missed-run and concurrency policies, retries, parks approvals and holds the single-scheduler lease.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import Foundation

public struct SchedulerConfiguration: Sendable, Hashable {
    /// Name of the lease that makes one scheduler active at a time.
    public var leaseName: String
    /// The active scheduler renews the lease at every tick; another one takes over once it has expired.
    public var leaseTTLSeconds: Double
    /// A scheduled instant handled within this delay is "on time". Older instants are "missed" and go through the
    /// schedule's `MissedRunPolicy`.
    public var lateToleranceSeconds: Double
    /// Upper bound on runs in flight across all workflows.
    public var maxConcurrentRuns: Int
    /// Ceiling for the retry delay.
    public var maxBackoffSeconds: Double
    /// Longest the run loop sleeps between two ticks (also the lease renewal rhythm). Keep it below a third of the TTL.
    public var heartbeatSeconds: Double
    /// Re-evaluate immediately when the Mac wakes from sleep (`NSWorkspace.didWakeNotification`).
    public var observesSystemWake: Bool
    /// Missed instants are counted up to this number for reporting.
    public var missedCountCap: Int

    public init(leaseName: String = "orix.scheduler", leaseTTLSeconds: Double = 30, lateToleranceSeconds: Double = 120,
                maxConcurrentRuns: Int = 4, maxBackoffSeconds: Double = 3600, heartbeatSeconds: Double = 10,
                observesSystemWake: Bool = true, missedCountCap: Int = 10_000) {
        self.leaseName = leaseName; self.leaseTTLSeconds = leaseTTLSeconds; self.lateToleranceSeconds = lateToleranceSeconds
        self.maxConcurrentRuns = maxConcurrentRuns; self.maxBackoffSeconds = maxBackoffSeconds
        self.heartbeatSeconds = heartbeatSeconds; self.observesSystemWake = observesSystemWake; self.missedCountCap = missedCountCap
    }
}

/// What one `tick()` did.
public struct TickSummary: Sendable, Hashable {
    /// False when another scheduler holds the lease: nothing was evaluated.
    public var active: Bool
    /// Items newly added as `pending`.
    public var enqueued: Int
    /// Items recorded as `skipped` (missed-run policy or `skipIfRunning`).
    public var skipped: Int
    /// Launcher invocations started.
    public var launched: Int
    /// A store failure that interrupted the tick.
    public var error: String?
    public init(active: Bool = false, enqueued: Int = 0, skipped: Int = 0, launched: Int = 0, error: String? = nil) {
        self.active = active; self.enqueued = enqueued; self.skipped = skipped; self.launched = launched; self.error = error
    }
}

public enum SchedulerError: Error, Sendable, Hashable, LocalizedError {
    case unknownSchedule(String)
    case unknownQueueItem(String)
    case invalidSchedule([String])
    case notWaitingApproval(String)

    public var errorDescription: String? {
        switch self {
        case .unknownSchedule(let id): return "No schedule with id \(id)."
        case .unknownQueueItem(let id): return "No queue item with id \(id)."
        case .invalidSchedule(let problems): return "The schedule is not valid: " + problems.joined(separator: "; ")
        case .notWaitingApproval(let id): return "Queue item \(id) is not waiting for approval."
        }
    }
}

/// The scheduler engine.
///
/// **Firing.** For `cron`, `once` and `interval` triggers the engine computes every scheduled instant in the window
/// `lastEvaluatedAt…now` and enqueues one `QueueItem` per instant with the dedup key `scheduleID@instant`. The store
/// refuses a second item with the same key, so a restart, a crash between two writes or a second process can never
/// enqueue one instant twice.
///
/// **Missed runs.** Instants older than `lateToleranceSeconds` (the Mac slept, was off, or the scheduler was not
/// running) are never reported as run: they go through the schedule's `MissedRunPolicy`, and whatever is not run is
/// recorded as one `skipped` item that says how many instants were missed and when.
///
/// **Concurrency.** Runs of one workflow are limited by the schedule's `ConcurrencyPolicy` (per-workflow lock); a run
/// parked on an approval still holds the lock because it is the same run that will resume.
///
/// **Retries.** Only when the launcher reports `.failed(retryable: true)`, at most `maxRetries` times, with a doubling
/// delay. A run interrupted by a scheduler restart is marked failed and is not retried automatically.
///
/// **Single scheduler.** Only the engine holding the lease evaluates and launches. Others stay passive and take over
/// when the lease expires.
public actor SchedulerEngine {
    public typealias Launcher = @Sendable (QueueItem, Schedule) async -> RunLaunchResult

    private let store: any ScheduleStoring
    private let clock: any SchedulerClock
    private let launcher: Launcher
    public nonisolated let owner: String
    public nonisolated let configuration: SchedulerConfiguration
    private nonisolated let wake = WakeSignal()

    /// True while this engine holds the lease (as of the last tick).
    public private(set) var isActive = false
    /// Launchers that have not reported yet: what counts against the concurrency limits and what `cancel` reaches.
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// The same tasks, kept until their completion handling (including the dispatch it triggers) is over, for `settle()`.
    private var unsettled: [String: Task<Void, Never>] = [:]
    private var wakeObserver: (any NSObjectProtocol)?
    private var stopped = false
    private var dispatching = false
    private var redispatch = false

    public init(store: any ScheduleStoring, clock: any SchedulerClock = SystemSchedulerClock(), launcher: @escaping Launcher,
                owner: String, configuration: SchedulerConfiguration = SchedulerConfiguration()) {
        self.store = store; self.clock = clock; self.launcher = launcher; self.owner = owner; self.configuration = configuration
    }

    // MARK: Schedules

    /// Validates and stores a schedule. A new schedule starts counting from now: nothing before this moment is "missed".
    @discardableResult
    public func save(_ schedule: Schedule) async throws -> Schedule {
        let problems = schedule.problems()
        guard problems.isEmpty else { throw SchedulerError.invalidSchedule(problems) }
        var s = schedule
        let now = clock.now()
        if s.lastEvaluatedAt == nil { s.lastEvaluatedAt = now }
        s.nextFireAt = isLive(s) ? s.trigger.nextFireDate(after: max(now, s.lastEvaluatedAt ?? now), anchor: s.createdAt) : nil
        try await store.saveSchedule(s)
        wake.signal()
        return s
    }

    /// Removes the schedule and cancels its pending items.
    public func remove(scheduleID: String) async throws {
        try await store.removeSchedule(id: scheduleID)
        try await cancelPending(scheduleID: scheduleID, reason: "schedule removed")
        wake.signal()
    }

    public func schedules() async throws -> [Schedule] { try await store.schedules() }
    public func schedule(id: String) async throws -> Schedule? { try await store.schedule(id: id) }

    /// Queue items, optionally filtered by status, ordered by due date.
    public func queue(status: QueueItem.Status? = nil) async throws -> [QueueItem] {
        let all = try await store.queueItems()
        return status.map { s in all.filter { $0.status == s } } ?? all
    }

    /// Stops the schedule from firing and holds its pending items. Running items are not interrupted.
    public func pause(scheduleID: String) async throws {
        try await mutate(scheduleID) { s, _ in s.paused = true; s.nextFireAt = nil }
    }

    /// Resumes a paused schedule. Instants that passed while it was paused are not treated as missed.
    public func resume(scheduleID: String) async throws {
        try await mutate(scheduleID) { s, now in
            s.paused = false
            s.lastEvaluatedAt = now
            s.nextFireAt = s.enabled ? s.trigger.nextFireDate(after: now, anchor: s.createdAt) : nil
        }
    }

    /// Disables the schedule and cancels its pending items. `runNow` still works on a disabled schedule.
    public func disable(scheduleID: String) async throws {
        try await mutate(scheduleID) { s, _ in s.enabled = false; s.nextFireAt = nil }
        try await cancelPending(scheduleID: scheduleID, reason: "schedule disabled")
    }

    /// Re-enables the schedule, counting from now.
    public func enable(scheduleID: String) async throws {
        try await mutate(scheduleID) { s, now in
            s.enabled = true
            s.lastEvaluatedAt = now
            s.nextFireAt = s.paused ? nil : s.trigger.nextFireDate(after: now, anchor: s.createdAt)
        }
    }

    private func mutate(_ scheduleID: String, _ change: (inout Schedule, Date) -> Void) async throws {
        guard var s = try await store.schedule(id: scheduleID) else { throw SchedulerError.unknownSchedule(scheduleID) }
        change(&s, clock.now())
        try await store.saveSchedule(s)
        wake.signal()
    }

    private func cancelPending(scheduleID: String, reason: String) async throws {
        for var item in try await store.queueItems() where item.scheduleID == scheduleID && item.status == .pending {
            item.status = .canceled
            item.reason = reason
            try await store.updateQueueItem(item)
        }
    }

    private func isLive(_ s: Schedule) -> Bool { s.enabled && !s.paused && s.trigger.isTimeBased }

    // MARK: Manual and event firings

    /// Enqueues one run of the schedule right now, at the user's request. Works on paused and disabled schedules; the
    /// concurrency policy still applies when the item is dispatched.
    @discardableResult
    public func runNow(scheduleID: String) async throws -> QueueItem {
        guard var s = try await store.schedule(id: scheduleID) else { throw SchedulerError.unknownSchedule(scheduleID) }
        let now = clock.now()
        let item = QueueItem(scheduleID: s.id, workflowID: s.workflowID, dueAt: now, enqueuedAt: now,
                             dedupKey: "\(s.id)@manual-\(UUID().uuidString)", reason: "manual: run now")
        _ = try await store.enqueue(item)
        s.lastFiredAt = now
        try await store.saveSchedule(s)
        wake.signal()
        return item
    }

    /// Enqueues a run for an event trigger (file change, login, app launch, power, network). Returns nil when the
    /// schedule is unknown, disabled or paused, or when `dedupKey` was already used.
    @discardableResult
    public func fire(scheduleID: String, reason: String, dedupKey: String? = nil) async throws -> QueueItem? {
        guard var s = try await store.schedule(id: scheduleID), s.enabled, !s.paused else { return nil }
        let now = clock.now()
        let key = dedupKey ?? "\(s.id)@event-\(Int64((now.timeIntervalSince1970 * 1000).rounded()))-\(UUID().uuidString.prefix(8))"
        let item = QueueItem(scheduleID: s.id, workflowID: s.workflowID, dueAt: now, enqueuedAt: now, dedupKey: key, reason: reason)
        guard try await store.enqueue(item) else { return nil }
        s.lastFiredAt = now
        try await store.saveSchedule(s)
        wake.signal()
        return item
    }

    /// Cancels a queue item. A pending or parked item becomes `canceled`; a running one has its launcher task
    /// canceled and is marked `canceled` (the launcher's late result is ignored).
    public func cancel(queueItemID: String) async throws {
        guard var item = try await store.queueItem(id: queueItemID) else { throw SchedulerError.unknownQueueItem(queueItemID) }
        guard !item.status.isTerminal else { return }
        if item.status == .running { inFlight[item.id]?.cancel() }
        item.status = .canceled
        item.reason = item.reason.isEmpty ? "canceled" : item.reason + " — canceled"
        try await store.updateQueueItem(item)
        wake.signal()
    }

    /// Reports the outcome of a run that was parked on an approval, once a person has answered and the run has ended.
    /// The scheduler never calls this itself.
    public func resolveApproval(queueItemID: String, result: RunLaunchResult) async throws {
        guard let item = try await store.queueItem(id: queueItemID) else { throw SchedulerError.unknownQueueItem(queueItemID) }
        guard item.status == .waitingApproval else { throw SchedulerError.notWaitingApproval(queueItemID) }
        try await apply(result, to: item)
        wake.signal()
    }

    /// The next scheduled instants across all live time-based schedules, soonest first.
    public func upcoming(limit: Int = 20) async throws -> [(Schedule, Date)] {
        guard limit > 0 else { return [] }
        let now = clock.now()
        var out: [(Schedule, Date)] = []
        for s in try await store.schedules() where isLive(s) {
            var cursor = now
            var count = 0
            while count < limit, let next = s.trigger.nextFireDate(after: cursor, anchor: s.createdAt) {
                out.append((s, next))
                cursor = next
                count += 1
            }
        }
        out.sort { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
        return Array(out.prefix(limit))
    }

    // MARK: Tick

    /// One deterministic pass: take or renew the lease, enqueue what is due, apply policies and start what may start.
    /// Launchers run in child tasks; `settle()` waits for them.
    @discardableResult
    public func tick() async -> TickSummary {
        var summary = TickSummary()
        do {
            let held = try await store.acquireLease(name: configuration.leaseName, owner: owner, ttlSeconds: configuration.leaseTTLSeconds)
            guard held else { isActive = false; return summary }
            summary.active = true
            if !isActive {
                isActive = true
                try await recoverInterruptedRuns()
            }
            let now = clock.now()
            for schedule in try await store.schedules() where isLive(schedule) {
                try await evaluate(schedule, now: now, into: &summary)
            }
            try await dispatch(into: &summary)
        } catch {
            summary.error = "\(error)"
        }
        return summary
    }

    /// Waits until no launcher is in flight (including the ones started by completions).
    public func settle() async {
        while let task = unsettled.values.first { await task.value }
    }

    /// Wakes the run loop. Call it after writing to the store from outside the engine.
    public nonisolated func storeDidChange() { wake.signal() }

    /// The run loop: tick, then sleep until the next due instant, a store change, a system wake or the heartbeat.
    /// Returns when the calling task is canceled or after `stop()`.
    public func run() async {
        stopped = false
        installWakeObserver()
        while !Task.isCancelled && !stopped {
            await tick()
            let now = clock.now()
            var deadline = now.addingTimeInterval(configuration.heartbeatSeconds)
            if isActive, let next = try? await nextDueDate(after: now) { deadline = min(deadline, next) }
            await wake.wait(until: deadline, clock: clock)
        }
        removeWakeObserver()
    }

    /// Ends the run loop and gives the lease back so another scheduler can take over at once. Runs in flight continue.
    public func stop() async {
        stopped = true
        isActive = false
        try? await store.releaseLease(name: configuration.leaseName, owner: owner)
        wake.signal()
    }

    private func nextDueDate(after now: Date) async throws -> Date? {
        var next: Date?
        func consider(_ d: Date?) { if let d, d > now, next.map({ d < $0 }) ?? true { next = d } }
        for s in try await store.schedules() where isLive(s) { consider(s.nextFireAt) }
        for item in try await store.queueItems() where item.status == .pending { consider(item.dueAt) }
        return next
    }

    private func installWakeObserver() {
        guard configuration.observesSystemWake, wakeObserver == nil else { return }
        let signal = wake
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in signal.signal() }
    }

    private func removeWakeObserver() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    // MARK: Evaluation

    private func evaluate(_ schedule: Schedule, now: Date, into summary: inout TickSummary) async throws {
        var s = schedule
        let trigger = s.trigger
        let anchor = s.createdAt
        let cursor = s.lastEvaluatedAt ?? s.lastFiredAt ?? s.createdAt
        guard cursor < now, let first = trigger.nextFireDate(after: cursor, anchor: anchor), first <= now else {
            let next = trigger.nextFireDate(after: max(cursor, now), anchor: anchor)
            if s.nextFireAt != next {
                s.nextFireAt = next
                try await store.saveSchedule(s)
            }
            return
        }

        let onTimeStart = max(cursor, now.addingTimeInterval(-configuration.lateToleranceSeconds))
        var onTime: [Date] = []
        var probe = onTimeStart
        while onTime.count < 1000, let next = trigger.nextFireDate(after: probe, anchor: anchor), next <= now {
            onTime.append(next)
            probe = next
        }

        var fired: [Date] = []
        if cursor < onTimeStart, let latestMissed = trigger.latestFireDate(after: cursor, atOrBefore: onTimeStart, anchor: anchor) {
            // Count the missed instants (bounded) and find the first one, for the record.
            var missedCount = 0
            var firstMissed: Date?
            var c = cursor
            while missedCount < configuration.missedCountCap, let next = trigger.nextFireDate(after: c, anchor: anchor), next <= onTimeStart {
                if firstMissed == nil { firstMissed = next }
                missedCount += 1
                c = next
            }
            let capped = missedCount >= configuration.missedCountCap
            let countText = capped ? "at least \(missedCount)" : "\(missedCount)"

            var toRun: [Date] = []
            switch s.missedRunPolicy {
            case .skip:
                break
            case .runOnce:
                // An on-time firing in the same pass already runs the workflow once.
                if onTime.isEmpty { toRun = [latestMissed] }
            case .runAll(let maxRuns):
                var end = latestMissed
                toRun = [end]
                while toRun.count < min(maxRuns, missedCount),
                      let previous = trigger.latestFireDate(after: cursor, atOrBefore: end.addingTimeInterval(-1), anchor: anchor) {
                    toRun.insert(previous, at: 0)
                    end = previous
                }
            }
            for instant in toRun {
                let item = QueueItem(scheduleID: s.id, workflowID: s.workflowID, dueAt: instant, enqueuedAt: now,
                                     dedupKey: QueueItem.dedupKey(scheduleID: s.id, instant: instant),
                                     reason: "catch-up: scheduled for \(Self.stamp(instant)), missed while the scheduler was not running")
                if try await store.enqueue(item) { summary.enqueued += 1 }
                fired.append(instant)
            }
            let notRun = capped ? nil : missedCount - toRun.count
            if notRun.map({ $0 > 0 }) ?? true {
                let policy: String
                switch s.missedRunPolicy {
                case .skip: policy = "skip"
                case .runOnce: policy = onTime.isEmpty ? "runOnce" : "runOnce (covered by the on-time run)"
                case .runAll(let m): policy = "runAll(max: \(m))"
                }
                let notRunText = notRun.map(String.init) ?? countText
                let item = QueueItem(
                    scheduleID: s.id, workflowID: s.workflowID, dueAt: latestMissed, enqueuedAt: now, status: .skipped,
                    dedupKey: "\(s.id)@missed-\(Int64((latestMissed.timeIntervalSince1970 * 1000).rounded()))",
                    reason: "missed: \(countText) scheduled firing(s) between \(Self.stamp(firstMissed ?? latestMissed)) and \(Self.stamp(latestMissed)) passed while the scheduler was not running; \(notRunText) not run (policy \(policy))")
                if try await store.enqueue(item) { summary.skipped += 1 }
            }
        }

        for instant in onTime {
            let item = QueueItem(scheduleID: s.id, workflowID: s.workflowID, dueAt: instant, enqueuedAt: now,
                                 dedupKey: QueueItem.dedupKey(scheduleID: s.id, instant: instant),
                                 reason: "scheduled for \(Self.stamp(instant))")
            if try await store.enqueue(item) { summary.enqueued += 1 }
            fired.append(instant)
        }

        if let last = fired.max() { s.lastFiredAt = max(s.lastFiredAt ?? last, last) }
        s.lastEvaluatedAt = now
        s.nextFireAt = trigger.nextFireDate(after: now, anchor: anchor)
        try await store.saveSchedule(s)
    }

    private static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: Dispatch

    private func recoverInterruptedRuns() async throws {
        for var item in try await store.queueItems() where item.status == .running && inFlight[item.id] == nil {
            item.status = .failed
            item.lastError = "interrupted: the scheduler stopped while this run was in flight; it is not retried automatically"
            try await store.updateQueueItem(item)
        }
    }

    /// Dispatch passes never interleave: a pass requested while one is running is replayed right after it, so two
    /// passes can never both see a workflow as free and start it twice.
    private func dispatch(into summary: inout TickSummary) async throws {
        if dispatching { redispatch = true; return }
        dispatching = true
        defer { dispatching = false }
        repeat {
            redispatch = false
            try await dispatchPass(into: &summary)
        } while redispatch
    }

    private func dispatchPass(into summary: inout TickSummary) async throws {
        while inFlight.count < configuration.maxConcurrentRuns {
            let now = clock.now()
            let items = try await store.queueItems()
            let schedules = Dictionary(try await store.schedules().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var busy: [String: Int] = [:]
            for item in items where item.status == .running || item.status == .waitingApproval {
                busy[item.workflowID, default: 0] += 1
            }

            // Items that cannot run at all: schedule gone, or skipIfRunning while the workflow is busy.
            var held: Set<String> = []
            for var item in items where item.status == .pending && item.dueAt <= now {
                guard let schedule = schedules[item.scheduleID] else {
                    item.status = .canceled
                    item.reason = "schedule removed"
                    try await store.updateQueueItem(item)
                    continue
                }
                // A paused schedule holds its items, except the ones the user asked for with `runNow`.
                if schedule.paused && !item.dedupKey.hasPrefix("\(schedule.id)@manual-") { held.insert(item.id); continue }
                let inUse = busy[item.workflowID, default: 0]
                if inUse >= schedule.concurrency.capacity {
                    if case .skipIfRunning = schedule.concurrency {
                        item.status = .skipped
                        item.reason = "skipped: a previous run of this workflow was still active (policy skipIfRunning)"
                        try await store.updateQueueItem(item)
                        summary.skipped += 1
                    } else {
                        held.insert(item.id)
                    }
                }
            }

            let heldIDs = held
            guard let claimed = try await store.claimNext(now: now, eligible: { !heldIDs.contains($0.id) }) else { return }
            guard let schedule = schedules[claimed.scheduleID] else {
                var item = claimed
                item.status = .canceled
                item.reason = "schedule removed"
                try await store.updateQueueItem(item)
                continue
            }
            let launcher = self.launcher
            summary.launched += 1
            let task = Task { [weak self] in
                let result = await launcher(claimed, schedule)
                await self?.finish(itemID: claimed.id, result: result)
            }
            inFlight[claimed.id] = task
            unsettled[claimed.id] = task
        }
    }

    private func finish(itemID: String, result: RunLaunchResult) async {
        inFlight[itemID] = nil
        do {
            // A canceled item keeps its status: the late result is ignored.
            if let item = try await store.queueItem(id: itemID), item.status == .running {
                try await apply(result, to: item)
            }
            var summary = TickSummary()
            if isActive { try await dispatch(into: &summary) }
        } catch {
            // The store failed; the next tick will find the item still `running` and this engine no longer tracks it.
        }
        unsettled[itemID] = nil
        wake.signal()
    }

    private func apply(_ result: RunLaunchResult, to original: QueueItem) async throws {
        var item = original
        switch result {
        case .succeeded(let runID):
            item.status = .succeeded
            item.runID = runID ?? item.runID
        case .canceled(let runID):
            item.status = .canceled
            item.runID = runID ?? item.runID
        case .waitingApproval(let runID):
            item.status = .waitingApproval
            item.runID = runID ?? item.runID
            item.reason = item.reason.isEmpty ? "waiting for approval" : item.reason + " — waiting for approval"
        case .failed(let runID, let error, let retryable):
            item.runID = runID ?? item.runID
            item.lastError = error
            let schedule = try await store.schedule(id: item.scheduleID)
            if retryable, let schedule, item.attempt <= schedule.maxRetries {
                let delay = min(configuration.maxBackoffSeconds, schedule.retryBackoffSeconds * pow(2, Double(item.attempt - 1)))
                item.attempt += 1
                item.status = .pending
                item.dueAt = clock.now().addingTimeInterval(delay)
            } else {
                item.status = .failed
            }
        }
        try await store.updateQueueItem(item)
    }
}
