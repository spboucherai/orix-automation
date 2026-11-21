// ORIX OS Automation
// File: Packages/ORIXScheduler/Sources/ORIXScheduler/Models.swift
// Description: Scheduler data models: trigger specifications, missed-run and concurrency policies, schedules, queue items and launch results.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation

/// What starts a workflow.
public enum TriggerSpec: Codable, Sendable, Hashable {
    /// 5-field cron expression evaluated in `timezone` (an IANA identifier such as `America/Toronto`); nil means the
    /// Mac's current time zone at evaluation time.
    case cron(expression: String, timezone: String?)
    case once(at: Date)
    /// Every `seconds` of elapsed time, counted from the schedule's `createdAt` (first firing one interval after it).
    case interval(seconds: Double)
    case fileChange(path: String, recursive: Bool, glob: String?, debounceSeconds: Double)
    case login
    case appLaunch(bundleID: String)
    case powerConnected
    case networkAvailable
    case manual

    /// `cron`, `once`, `interval`, `fileChange`, `login`, `appLaunch`, `powerConnected`, `networkAvailable`, `manual`.
    public var kind: String {
        switch self {
        case .cron: return "cron"
        case .once: return "once"
        case .interval: return "interval"
        case .fileChange: return "fileChange"
        case .login: return "login"
        case .appLaunch: return "appLaunch"
        case .powerConnected: return "powerConnected"
        case .networkAvailable: return "networkAvailable"
        case .manual: return "manual"
        }
    }

    /// True for triggers the engine computes from the clock (`cron`, `once`, `interval`). The others are events
    /// reported by `TriggerMonitor` or by the user.
    public var isTimeBased: Bool {
        switch self {
        case .cron, .once, .interval: return true
        default: return false
        }
    }

    /// Problems that make the trigger unusable. Empty means valid.
    public func problems() -> [String] {
        switch self {
        case .cron(let expression, let timezone):
            var out: [String] = []
            do { _ = try CronExpression(expression) } catch { out.append("\(error)") }
            if let timezone, TimeZone(identifier: timezone) == nil { out.append("unknown time zone '\(timezone)'") }
            return out
        case .interval(let seconds):
            return seconds >= 1 && seconds.isFinite ? [] : ["interval must be at least 1 second (got \(seconds))"]
        case .fileChange(let path, _, _, let debounce):
            var out: [String] = []
            if path.trimmingCharacters(in: .whitespaces).isEmpty { out.append("fileChange path is empty") }
            if debounce < 0 || !debounce.isFinite { out.append("debounceSeconds must be zero or positive") }
            return out
        case .appLaunch(let bundleID):
            return bundleID.isEmpty ? ["appLaunch bundleID is empty"] : []
        case .once, .login, .powerConnected, .networkAvailable, .manual:
            return []
        }
    }

    /// The first scheduled instant strictly after `date`. `anchor` is the schedule's creation date (used by
    /// `interval`). Nil for event triggers, for a `once` already in the past and for an invalid cron trigger.
    public func nextFireDate(after date: Date, anchor: Date) -> Date? {
        switch self {
        case .cron(let expression, let timezone):
            guard let cron = try? CronExpression(expression) else { return nil }
            guard let tz = timezone.map({ TimeZone(identifier: $0) }) ?? TimeZone.current else { return nil }
            return cron.nextFireDate(after: date, in: tz)
        case .once(let at):
            return at > date ? at : nil
        case .interval(let seconds):
            guard seconds >= 1, seconds.isFinite else { return nil }
            let elapsed = date.timeIntervalSince(anchor)
            var k = max(1, (elapsed / seconds).rounded(.down) + 1)
            var candidate = anchor.addingTimeInterval(k * seconds)
            while candidate <= date { k += 1; candidate = anchor.addingTimeInterval(k * seconds) }
            return candidate
        default:
            return nil
        }
    }

    /// The last scheduled instant `d` with `lowerBound < d <= upperBound`, or nil when there is none.
    public func latestFireDate(after lowerBound: Date, atOrBefore upperBound: Date, anchor: Date) -> Date? {
        guard lowerBound < upperBound else { return nil }
        switch self {
        case .once(let at):
            return at > lowerBound && at <= upperBound ? at : nil
        case .interval(let seconds):
            guard seconds >= 1, seconds.isFinite else { return nil }
            var k = (upperBound.timeIntervalSince(anchor) / seconds).rounded(.down)
            while k >= 1, anchor.addingTimeInterval(k * seconds) > upperBound { k -= 1 }
            guard k >= 1 else { return nil }
            let candidate = anchor.addingTimeInterval(k * seconds)
            return candidate > lowerBound ? candidate : nil
        case .cron:
            // Cron instants are whole seconds, so a binary search on "is there still a firing after s?" finds the last one.
            guard let first = nextFireDate(after: lowerBound, anchor: anchor), first <= upperBound else { return nil }
            var lo = Int(lowerBound.timeIntervalSince1970.rounded(.down))
            var hi = Int(upperBound.timeIntervalSince1970.rounded(.down))
            while hi - lo > 1 {
                let mid = lo + (hi - lo) / 2
                if let n = nextFireDate(after: Date(timeIntervalSince1970: TimeInterval(mid)), anchor: anchor), n <= upperBound { lo = mid } else { hi = mid }
            }
            return nextFireDate(after: Date(timeIntervalSince1970: TimeInterval(lo)), anchor: anchor)
        default:
            return nil
        }
    }
}

/// What to do with scheduled instants that passed while the scheduler was not running (sleep, restart, Mac off).
public enum MissedRunPolicy: Codable, Sendable, Hashable {
    /// Record them as skipped; run nothing.
    case skip
    /// Run once, for the most recent missed instant.
    case runOnce
    /// Run the most recent `max` missed instants, oldest first.
    case runAll(max: Int)
}

/// What to do when a firing is due while the same workflow is still running.
public enum ConcurrencyPolicy: Codable, Sendable, Hashable {
    /// Drop the new firing (recorded as `skipped`).
    case skipIfRunning
    /// Keep it pending until the running one ends.
    case queue
    /// Allow up to `max` simultaneous runs of the workflow.
    case parallel(max: Int)

    /// How many runs of one workflow may be in flight under this policy.
    public var capacity: Int {
        switch self {
        case .skipIfRunning, .queue: return 1
        case .parallel(let max): return Swift.max(1, max)
        }
    }
}

public struct Schedule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var workflowID: String
    public var name: String
    public var trigger: TriggerSpec
    /// A disabled schedule never fires on its own and its pending queue items are canceled.
    public var enabled: Bool
    /// A paused schedule does not fire and its pending queue items are held until it is resumed.
    public var paused: Bool
    public var missedRunPolicy: MissedRunPolicy
    public var concurrency: ConcurrencyPolicy
    /// Extra attempts after a failure the launcher reports as retryable.
    public var maxRetries: Int
    /// Delay before the first retry; doubled for each further retry.
    public var retryBackoffSeconds: Double
    /// Scheduled instant (time triggers) or event time of the last firing that was enqueued.
    public var lastFiredAt: Date?
    public var nextFireAt: Date?
    public var createdAt: Date
    /// Every scheduled instant at or before this date has been handled (enqueued or recorded as skipped). The missed-run
    /// window is `lastEvaluatedAt…now`.
    public var lastEvaluatedAt: Date?

    public init(id: String = UUID().uuidString, workflowID: String, name: String, trigger: TriggerSpec, enabled: Bool = true,
                paused: Bool = false, missedRunPolicy: MissedRunPolicy = .skip, concurrency: ConcurrencyPolicy = .skipIfRunning,
                maxRetries: Int = 0, retryBackoffSeconds: Double = 30, lastFiredAt: Date? = nil, nextFireAt: Date? = nil,
                createdAt: Date = Date(), lastEvaluatedAt: Date? = nil) {
        self.id = id; self.workflowID = workflowID; self.name = name; self.trigger = trigger; self.enabled = enabled
        self.paused = paused; self.missedRunPolicy = missedRunPolicy; self.concurrency = concurrency
        self.maxRetries = maxRetries; self.retryBackoffSeconds = retryBackoffSeconds; self.lastFiredAt = lastFiredAt
        self.nextFireAt = nextFireAt; self.createdAt = createdAt; self.lastEvaluatedAt = lastEvaluatedAt
    }

    /// Problems that make the schedule unusable. Empty means valid.
    public func problems() -> [String] {
        var out = trigger.problems()
        if id.isEmpty { out.append("id is empty") }
        if workflowID.isEmpty { out.append("workflowID is empty") }
        if maxRetries < 0 { out.append("maxRetries must be zero or positive") }
        if retryBackoffSeconds < 0 { out.append("retryBackoffSeconds must be zero or positive") }
        if case .runAll(let max) = missedRunPolicy, max < 1 { out.append("runAll(max:) must be at least 1") }
        if case .parallel(let max) = concurrency, max < 1 { out.append("parallel(max:) must be at least 1") }
        return out
    }
}

public struct QueueItem: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending, running, succeeded, failed, skipped, canceled, waitingApproval
        /// True when nothing more will happen to the item.
        public var isTerminal: Bool {
            switch self {
            case .pending, .running, .waitingApproval: return false
            default: return true
            }
        }
    }

    public var id: String
    public var scheduleID: String
    public var workflowID: String
    /// When the item may start: the scheduled instant, or the retry time after a failure.
    public var dueAt: Date
    public var enqueuedAt: Date
    /// 1 for the first attempt.
    public var attempt: Int
    public var status: Status
    /// `scheduleID@scheduledInstant`. Two items never share a key.
    public var dedupKey: String
    /// Why the item exists or why it ended the way it did, in plain words.
    public var reason: String
    public var runID: String?
    public var lastError: String?

    public init(id: String = UUID().uuidString, scheduleID: String, workflowID: String, dueAt: Date, enqueuedAt: Date,
                attempt: Int = 1, status: Status = .pending, dedupKey: String, reason: String = "", runID: String? = nil,
                lastError: String? = nil) {
        self.id = id; self.scheduleID = scheduleID; self.workflowID = workflowID; self.dueAt = dueAt
        self.enqueuedAt = enqueuedAt; self.attempt = attempt; self.status = status; self.dedupKey = dedupKey
        self.reason = reason; self.runID = runID; self.lastError = lastError
    }

    /// The dedup key of a scheduled instant: `scheduleID@<milliseconds since 1970>`.
    public static func dedupKey(scheduleID: String, instant: Date) -> String {
        "\(scheduleID)@\(Int64((instant.timeIntervalSince1970 * 1000).rounded()))"
    }
}

/// What the launcher reports once the run it started has ended (or parked).
public enum RunLaunchResult: Sendable, Hashable {
    case succeeded(runID: String?)
    /// `retryable` must be true only when running the workflow again cannot repeat a side effect that already happened.
    case failed(runID: String?, error: String, retryable: Bool)
    /// The run is parked on an approval request. The scheduler keeps the item visible and never approves it itself.
    case waitingApproval(runID: String?)
    case canceled(runID: String?)
}
