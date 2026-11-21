// ORIX OS Automation
// File: Packages/ORIXScheduler/Sources/ORIXScheduler/SchedulerClock.swift
// Description: Injectable clock for the scheduler (system clock and a manual clock for deterministic tests) and the wake signal used by the run loop.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation

public protocol SchedulerClock: Sendable {
    func now() -> Date
    /// Suspends until `now() >= deadline`. Throws `CancellationError` when the task is canceled first.
    func sleep(until deadline: Date) async throws
}

/// Wall-clock time. Long sleeps are cut into slices so a clock change or a wake from system sleep is noticed quickly.
public struct SystemSchedulerClock: SchedulerClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(until deadline: Date) async throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 30) * 1_000_000_000))
        }
    }
}

/// A clock that only moves when a test moves it.
public final class ManualSchedulerClock: SchedulerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]

    public init(now: Date) { current = now }

    public func now() -> Date { lock.withLock { current } }

    /// Moves the clock forward and wakes every sleeper whose deadline has been reached.
    public func advance(by seconds: TimeInterval) {
        set(now().addingTimeInterval(seconds))
    }

    public func set(_ date: Date) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            current = date
            let ready = sleepers.filter { $0.value.deadline <= date }
            for key in ready.keys { sleepers[key] = nil }
            return ready.values.map(\.continuation)
        }
        for c in due { c.resume() }
    }

    /// Number of tasks currently suspended in `sleep(until:)`.
    public var sleeperCount: Int { lock.withLock { sleepers.count } }

    public func sleep(until deadline: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                enum Outcome { case done, canceled, parked }
                let outcome: Outcome = lock.withLock {
                    if current >= deadline { return .done }
                    if Task.isCancelled { return .canceled }
                    sleepers[id] = (deadline, c)
                    return .parked
                }
                switch outcome {
                case .done: c.resume()
                case .canceled: c.resume(throwing: CancellationError())
                case .parked: break
                }
            }
        } onCancel: {
            let c = lock.withLock { sleepers.removeValue(forKey: id)?.continuation }
            c?.resume(throwing: CancellationError())
        }
    }
}

/// A level-triggered wake-up: `signal()` releases the current waiters, or is remembered for the next `wait()`.
final class WakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            if waiters.isEmpty { pending = true; return [] }
            let all = Array(waiters.values)
            waiters = [:]
            return all
        }
        for c in toResume { c.resume() }
    }

    /// Returns when signaled, or when the task is canceled.
    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if pending { pending = false; return true }
                    if Task.isCancelled { return true }
                    waiters[id] = c
                    return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            let c = lock.withLock { waiters.removeValue(forKey: id) }
            c?.resume()
        }
    }

    /// Waits for a signal or for the clock to reach `deadline`, whichever comes first.
    func wait(until deadline: Date, clock: any SchedulerClock) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await clock.sleep(until: deadline) }
            group.addTask { await self.wait() }
            await group.next()
            group.cancelAll()
        }
    }
}
