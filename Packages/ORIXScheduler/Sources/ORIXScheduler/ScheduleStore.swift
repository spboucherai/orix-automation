// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXScheduler/Sources/ORIXScheduler/ScheduleStore.swift
// Description      : The small storage contract the scheduler needs (schedules,
//                    queue with atomic enqueue/claim, leases) and an in-memory
//                    implementation.
// Module           : ORIXScheduler
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

/// Durable storage for the scheduler. Deliberately small so it maps onto a generic document store:
/// two collections (`schedules`, `queue`) of Codable documents keyed by `id`, plus named leases.
///
/// Three operations must be atomic with respect to other processes using the same store:
/// `enqueue` (insert unless the dedup key exists), `claimNext` (pending → running) and `acquireLease`.
public protocol ScheduleStoring: Sendable {
    // Schedules
    func schedules() async throws -> [Schedule]
    func schedule(id: String) async throws -> Schedule?
    /// Inserts or replaces.
    func saveSchedule(_ schedule: Schedule) async throws
    func removeSchedule(id: String) async throws

    // Queue
    func queueItems() async throws -> [QueueItem]
    func queueItem(id: String) async throws -> QueueItem?
    func queueItem(dedupKey: String) async throws -> QueueItem?
    /// Inserts `item` unless an item with the same `dedupKey` already exists. Returns true when it was inserted.
    func enqueue(_ item: QueueItem) async throws -> Bool
    /// Replaces an existing item (matched by `id`).
    func updateQueueItem(_ item: QueueItem) async throws
    func removeQueueItem(id: String) async throws
    /// Atomically takes the pending item with the earliest `dueAt <= now` (ties: earliest `enqueuedAt`) for which
    /// `eligible` returns true, marks it `running` and returns it. Nil when there is none.
    func claimNext(now: Date, eligible: @Sendable (QueueItem) -> Bool) async throws -> QueueItem?

    // Leases
    /// Takes or renews the lease `name` for `owner` for `ttlSeconds`. Returns false when another owner holds an
    /// unexpired lease.
    func acquireLease(name: String, owner: String, ttlSeconds: Double) async throws -> Bool
    /// Releases the lease if `owner` holds it.
    func releaseLease(name: String, owner: String) async throws
}

public extension ScheduleStoring {
    /// Claims the next due pending item, whatever it is.
    func claimNext(now: Date) async throws -> QueueItem? {
        try await claimNext(now: now, eligible: { _ in true })
    }
}

/// In-memory store for tests and previews. Lease expiry is measured with the `now` closure so tests can drive it
/// with a manual clock.
public actor InMemoryScheduleStore: ScheduleStoring {
    private var scheduleMap: [String: Schedule] = [:]
    private var queue: [String: QueueItem] = [:]
    private var keys: [String: String] = [:]
    private var leases: [String: (owner: String, expiresAt: Date)] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func schedules() -> [Schedule] {
        scheduleMap.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
    public func schedule(id: String) -> Schedule? { scheduleMap[id] }
    public func saveSchedule(_ schedule: Schedule) { scheduleMap[schedule.id] = schedule }
    public func removeSchedule(id: String) { scheduleMap[id] = nil }

    public func queueItems() -> [QueueItem] {
        queue.values.sorted { ($0.dueAt, $0.enqueuedAt, $0.id) < ($1.dueAt, $1.enqueuedAt, $1.id) }
    }
    public func queueItem(id: String) -> QueueItem? { queue[id] }
    public func queueItem(dedupKey: String) -> QueueItem? { keys[dedupKey].flatMap { queue[$0] } }

    public func enqueue(_ item: QueueItem) -> Bool {
        guard keys[item.dedupKey] == nil, queue[item.id] == nil else { return false }
        queue[item.id] = item
        keys[item.dedupKey] = item.id
        return true
    }

    public func updateQueueItem(_ item: QueueItem) {
        guard let old = queue[item.id] else { return }
        if old.dedupKey != item.dedupKey {
            keys[old.dedupKey] = nil
            keys[item.dedupKey] = item.id
        }
        queue[item.id] = item
    }

    public func removeQueueItem(id: String) {
        if let old = queue.removeValue(forKey: id) { keys[old.dedupKey] = nil }
    }

    public func claimNext(now: Date, eligible: @Sendable (QueueItem) -> Bool) -> QueueItem? {
        let candidate = queue.values
            .filter { $0.status == .pending && $0.dueAt <= now && eligible($0) }
            .min { ($0.dueAt, $0.enqueuedAt, $0.id) < ($1.dueAt, $1.enqueuedAt, $1.id) }
        guard var item = candidate else { return nil }
        item.status = .running
        queue[item.id] = item
        return item
    }

    public func acquireLease(name: String, owner: String, ttlSeconds: Double) -> Bool {
        let t = now()
        if let held = leases[name], held.owner != owner, held.expiresAt > t { return false }
        leases[name] = (owner, t.addingTimeInterval(ttlSeconds))
        return true
    }

    public func releaseLease(name: String, owner: String) {
        if leases[name]?.owner == owner { leases[name] = nil }
    }

    /// Who holds `name` right now, for tests and diagnostics.
    public func leaseOwner(name: String) -> String? {
        guard let held = leases[name], held.expiresAt > now() else { return nil }
        return held.owner
    }
}
