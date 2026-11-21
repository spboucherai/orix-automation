// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/RetryPolicy.swift
// Description: Bounded exponential backoff with jitter (honours retry-after, attempt and total-time caps) and a provider wrapper that retries only before the first stream event.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public struct RetryPolicy: Sendable, Hashable {
    /// Total number of attempts, the first one included. 1 disables retries.
    public var maxAttempts: Int
    public var baseDelaySeconds: Double
    public var multiplier: Double
    /// Upper bound of one computed backoff delay (a server `retry-after` may exceed it, up to the total cap).
    public var maxDelaySeconds: Double
    /// Fraction of the delay randomised either way: 0.25 → delay × [0.75, 1.25].
    public var jitter: Double
    /// Upper bound on the sum of all waits of one call. A wait that would cross it is not started.
    public var totalDelayCapSeconds: Double

    public init(maxAttempts: Int = 4, baseDelaySeconds: Double = 0.5, multiplier: Double = 2, maxDelaySeconds: Double = 20,
                jitter: Double = 0.25, totalDelayCapSeconds: Double = 60) {
        self.maxAttempts = max(1, maxAttempts); self.baseDelaySeconds = max(0, baseDelaySeconds); self.multiplier = max(1, multiplier)
        self.maxDelaySeconds = max(0, maxDelaySeconds); self.jitter = min(max(0, jitter), 1); self.totalDelayCapSeconds = max(0, totalDelayCapSeconds)
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Wait before the next attempt, or nil to give up.
    /// - Parameters:
    ///   - failedAttempts: attempts that have failed so far (1 after the first failure).
    ///   - elapsedDelaySeconds: time already spent waiting in this call.
    ///   - randomUnit: a value in 0…1 used for jitter (injected so tests are deterministic).
    public func delay(afterFailedAttempts failedAttempts: Int, error: LLMError, elapsedDelaySeconds: Double = 0,
                      randomUnit: Double = Double.random(in: 0...1)) -> Double? {
        guard error.isRetryable, failedAttempts >= 1, failedAttempts < maxAttempts else { return nil }
        let exponential = min(maxDelaySeconds, baseDelaySeconds * pow(multiplier, Double(failedAttempts - 1)))
        var wait = exponential * (1 - jitter + 2 * jitter * min(max(randomUnit, 0), 1))
        if case .rateLimited(let retryAfter) = error, let retryAfter, retryAfter > wait { wait = retryAfter } // never earlier than the server asked
        guard elapsedDelaySeconds + wait <= totalDelayCapSeconds else { return nil }
        return wait
    }
}

/// Wraps a provider with `RetryPolicy`.
///
/// A stream is retried **only while nothing has been delivered**: once the first event of an attempt has reached the
/// consumer, a later failure is passed on unchanged, because replaying would duplicate text or tool calls. Only errors with
/// `LLMError.isRetryable` are retried. The wrapper emits no event of its own.
public final class RetryingProvider: LLMProvider {
    public typealias Sleep = @Sendable (_ seconds: Double) async throws -> Void
    /// Called before each wait: failed attempts so far, the error, the wait in seconds.
    public typealias RetryObserver = @Sendable (_ failedAttempts: Int, _ error: LLMError, _ delaySeconds: Double) -> Void

    public let base: any LLMProvider
    public let policy: RetryPolicy
    private let sleep: Sleep
    private let onRetry: RetryObserver?

    public var id: ProviderID { base.id }

    public init(_ base: any LLMProvider, policy: RetryPolicy = .default, onRetry: RetryObserver? = nil,
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }) {
        self.base = base; self.policy = policy; self.onRetry = onRetry; self.sleep = sleep
    }

    public func listModels() async throws -> [ModelInfo] {
        var failed = 0, waited = 0.0
        while true {
            do { return try await base.listModels() } catch {
                let e = Transport.llmError(from: error)
                failed += 1
                guard let wait = policy.delay(afterFailedAttempts: failed, error: e, elapsedDelaySeconds: waited) else { throw e }
                onRetry?(failed, e, wait)
                do { try await sleep(wait) } catch { throw LLMError.canceled }
                waited += wait
            }
        }
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let base = base, policy = policy, sleep = sleep, onRetry = onRetry
        return Transport.stream { continuation in
            var failed = 0, waited = 0.0
            while true {
                var delivered = false
                do {
                    for try await event in base.stream(request) {
                        delivered = true
                        continuation.yield(event)
                    }
                    return
                } catch {
                    let e = Transport.llmError(from: error)
                    failed += 1
                    guard !delivered, let wait = policy.delay(afterFailedAttempts: failed, error: e, elapsedDelaySeconds: waited) else { throw e }
                    onRetry?(failed, e, wait)
                    do { try await sleep(wait) } catch { throw LLMError.canceled }
                    waited += wait
                }
            }
        }
    }
}
