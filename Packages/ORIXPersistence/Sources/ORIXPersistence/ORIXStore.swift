// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXPersistence/Sources/ORIXPersistence/ORIXStore.swift
// Description      : The durable store actor: opening with corruption recovery
//                    and migrations, runs, events with atomic per-run sequence
//                    numbers, receipts, change notification.
// Module           : ORIXPersistence
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
import ORIXCore
import os

/// SQLite store shared by the app and its background agent. Each process opens its own `ORIXStore` on the same file;
/// SQLite (WAL, immediate write transactions, busy timeout) serialises writers across processes.
public actor ORIXStore: RunEventSink, GrantStoring {
    public static let darwinNotificationName = "ai.spboucher.orix.automation.store.changed"

    /// Nil for an in-memory store.
    public nonisolated let url: URL?
    /// Set when the file found at `url` was damaged: it was kept aside and a fresh database was created. Show it to the user.
    public nonisolated let recoveryNote: String?
    /// Where the damaged file was moved, when `recoveryNote` is set.
    public nonisolated let quarantinedFile: URL?

    let db: Database
    nonisolated let hub: ChangeHub
    nonisolated let logger = Logger(subsystem: "ai.spboucher.orix.automation", category: "persistence")

    // MARK: Opening

    public init(url: URL) throws {
        let opened = try Self.open(url: url)
        self.url = url
        self.db = opened.db
        self.recoveryNote = opened.note
        self.quarantinedFile = opened.quarantined
        self.hub = ChangeHub(postsDarwin: true, darwinName: Self.darwinNotificationName)
        if let note = opened.note { logger.error("\(note, privacy: .public)") }
    }

    private init(memory: Database) {
        url = nil; db = memory; recoveryNote = nil; quarantinedFile = nil
        hub = ChangeHub(postsDarwin: false, darwinName: Self.darwinNotificationName)
    }

    /// A private, non-durable store (tests, previews). It posts no cross-process notification.
    public static func inMemory() throws -> ORIXStore {
        let db = try Database(path: ":memory:")
        try db.configure()
        try db.migrate(Schema.migrations)
        return ORIXStore(memory: db)
    }

    private static func open(url: URL) throws -> (db: Database, note: String?, quarantined: URL?) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            return (try openChecked(path: url.path), nil, nil)
        } catch let error as SQLiteError where error.isCorruption {
            // Never delete user data: the damaged file is kept next to the new one.
            let aside = try quarantine(url)
            let db = try openChecked(path: url.path)
            let note = "The database \(url.lastPathComponent) was damaged (\(error.message)). It was kept as \(aside.lastPathComponent) "
                + "and a new, empty database was created. Workflows can be restored from an export or a backup."
            return (db, note, aside)
        }
    }

    /// Opens, checks integrity before anything is written, then configures and migrates.
    private static func openChecked(path: String) throws -> Database {
        let db = try Database(path: path)
        if let damage = try db.quickCheck() {
            db.close()
            throw SQLiteError(code: 11 /* SQLITE_CORRUPT */, message: "integrity check failed: \(damage)", sql: "PRAGMA quick_check")
        }
        try db.configure()
        try db.migrate(Schema.migrations)
        return db
    }

    private static func quarantine(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var target = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)")
        var n = 1
        while fm.fileExists(atPath: target.path) {
            n += 1
            target = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)-\(n)")
        }
        try fm.moveItem(at: url, to: target)
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
            try? fm.moveItem(atPath: url.path + suffix, toPath: target.path + suffix)
        }
        return target
    }

    // MARK: Change notification

    /// In-process changes. Each access returns an independent stream that starts with the next change.
    public nonisolated var changes: AsyncStream<StoreChange> { hub.stream() }

    /// Fires when any process (this one included) wrote to a file-backed store. It carries no detail: re-query what you show.
    public static func darwinChanges() -> AsyncStream<Void> { ChangeHub.darwinStream(name: darwinNotificationName) }

    // MARK: Coding

    func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) }
        catch { throw StoreError.encoding(String(describing: error)) }
    }

    func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(text.utf8)) }
        catch { throw StoreError.encoding(String(describing: error)) }
    }

    /// Decodes rows, skipping (and logging) any that this version cannot read rather than hiding all the others.
    func decodeAll<T: Decodable>(_ type: T.Type, _ rows: [String], what: String) -> [T] {
        rows.compactMap { text in
            do { return try decode(T.self, from: text) } catch {
                logger.error("unreadable \(what, privacy: .public) row skipped: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    // MARK: Runs

    static let nonTerminalStatuses: [String] = RunStatus.allCases.filter { !$0.isTerminal }.map(\.rawValue)
    static var nonTerminalList: String { nonTerminalStatuses.map { "'\($0)'" }.joined(separator: ",") }

    /// Inserts or replaces a run. Saving also refreshes the run's heartbeat used by `markInterruptedRuns`.
    public func saveRun(_ run: RunRecord) throws {
        try writeRun(run, updatedAt: Date())
        hub.publish(.run(run.id))
    }

    func writeRun(_ run: RunRecord, updatedAt: Date) throws {
        let json = try encode(run)
        try db.run("""
        INSERT INTO runs(id, kind, title, session_id, workflow_id, workflow_version, trigger_kind, mode, status, queued_at, started_at,
                         ended_at, tokens, cost_usd, error_summary, parent_run_id, updated_at, json)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, title=excluded.title, session_id=excluded.session_id,
            workflow_id=excluded.workflow_id, workflow_version=excluded.workflow_version, trigger_kind=excluded.trigger_kind,
            mode=excluded.mode, status=excluded.status, queued_at=excluded.queued_at, started_at=excluded.started_at,
            ended_at=excluded.ended_at, tokens=excluded.tokens, cost_usd=excluded.cost_usd, error_summary=excluded.error_summary,
            parent_run_id=excluded.parent_run_id, updated_at=excluded.updated_at, json=excluded.json
        """, [
            .text(run.id), .text(run.kind), .text(run.title), .optionalText(run.sessionID), .optionalText(run.workflowID),
            .optionalInt(run.workflowVersion), .text(run.trigger), .text(run.mode.rawValue), .text(run.status.rawValue),
            .date(run.queuedAt), .optionalDate(run.startedAt), .optionalDate(run.endedAt), .int(run.usage.tokens.totalTokens),
            .double(run.usage.costUSD), .optionalText(run.errorSummary), .optionalText(run.parentRunID), .date(updatedAt), .text(json),
        ])
    }

    public func run(id: String) throws -> RunRecord? {
        guard let json = try db.query("SELECT json FROM runs WHERE id = ?", [.text(id)], { $0.text(0) }).first else { return nil }
        return try decode(RunRecord.self, from: json)
    }

    /// Newest first. `search` matches a substring of the title or the error summary, case-insensitively.
    public func runs(limit: Int = 100, offset: Int = 0, status: RunStatus? = nil, workflowID: String? = nil, search: String? = nil) throws -> [RunRecord] {
        var clauses: [String] = []
        var params: [SQLValue] = []
        if let status { clauses.append("status = ?"); params.append(.text(status.rawValue)) }
        if let workflowID { clauses.append("workflow_id = ?"); params.append(.text(workflowID)) }
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            clauses.append("(title LIKE ? ESCAPE '\\' OR IFNULL(error_summary, '') LIKE ? ESCAPE '\\')")
            params.append(.text("%\(escaped)%")); params.append(.text("%\(escaped)%"))
        }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        params.append(.int(max(0, limit))); params.append(.int(max(0, offset)))
        let rows = try db.query("SELECT json FROM runs \(filter) ORDER BY queued_at DESC, id DESC LIMIT ? OFFSET ?", params) { $0.text(0) }
        return decodeAll(RunRecord.self, rows, what: "run")
    }

    /// Runs in a non-terminal state (queued, running, paused, recovering, waiting for approval), newest first.
    public func activeRuns() throws -> [RunRecord] {
        let rows = try db.query("SELECT json FROM runs WHERE status IN (\(Self.nonTerminalList)) ORDER BY queued_at DESC, id DESC") { $0.text(0) }
        return decodeAll(RunRecord.self, rows, what: "run")
    }

    /// Deletes a run with its events and receipt. Returns false when it did not exist.
    @discardableResult
    public func deleteRun(id: String) throws -> Bool {
        let removed = try db.transaction {
            try db.run("DELETE FROM events WHERE run_id = ?", [.text(id)])
            try db.run("DELETE FROM receipts WHERE run_id = ?", [.text(id)])
            return try db.run("DELETE FROM runs WHERE id = ?", [.text(id)]) > 0
        }
        hub.publish(.run(id))
        return removed
    }

    /// Crash recovery. Non-terminal runs whose last save is older than `olderThan` were left behind by a process that
    /// stopped: they become `RECOVERY_REQUIRED` and are returned. Pass the start time of the current process (or
    /// "now minus the heartbeat interval" when another live process may own runs) so live runs are not touched.
    @discardableResult
    public func markInterruptedRuns(olderThan: Date = Date()) throws -> [RunRecord] {
        let now = Date()
        let marked: [RunRecord] = try db.transaction {
            let rows = try db.query("SELECT json FROM runs WHERE status IN (\(Self.nonTerminalList)) AND updated_at < ? ORDER BY queued_at",
                                    [.date(olderThan)]) { $0.text(0) }
            var out: [RunRecord] = []
            for var run in decodeAll(RunRecord.self, rows, what: "run") {
                let previous = run.status
                run.status = .recoveryRequired
                if run.errorSummary == nil {
                    run.errorSummary = "Interrupted while \(previous.rawValue): the process running it stopped before it finished."
                }
                try writeRun(run, updatedAt: now)
                out.append(run)
            }
            return out
        }
        for run in marked { hub.publish(.run(run.id)) }
        return marked
    }

    // MARK: Events

    /// Appends an event and returns it with the sequence number the store assigned: 1, 2, 3 … per run, without gaps,
    /// also when several processes append to the same run.
    @discardableResult
    public func append(_ event: RunEvent) throws -> RunEvent {
        // One INSERT: SQLite takes the write lock before it evaluates the MAX subquery, so the number is unique.
        let seq = try db.query("""
        INSERT INTO events(run_id, seq, id, ts, kind, step_id, text, data)
        VALUES(?1, (SELECT COALESCE(MAX(seq), 0) + 1 FROM events WHERE run_id = ?1), ?2, ?3, ?4, ?5, ?6, ?7)
        RETURNING seq
        """, [.text(event.runID), .text(event.id), .date(event.timestamp), .text(event.kind.rawValue), .optionalText(event.stepID),
              .text(event.text), .text(event.data.serialized())]) { $0.int(0) }.first
        guard let seq else { throw StoreError.encoding("the event insert returned no sequence number") }
        var stored = event
        stored.seq = seq
        hub.publish(.events(event.runID))
        return stored
    }

    /// `RunEventSink`: never throws. A failed write is logged; the timeline then misses that event.
    public func emit(_ event: RunEvent) async {
        do { try append(event) } catch {
            logger.error("event \(event.kind.rawValue, privacy: .public) of run \(event.runID, privacy: .public) was not stored: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Events of a run with `seq > afterSeq`, in order.
    public func events(runID: String, afterSeq: Int = 0, limit: Int = 1000) throws -> [RunEvent] {
        try db.query("SELECT seq, id, ts, kind, step_id, text, data FROM events WHERE run_id = ? AND seq > ? ORDER BY seq LIMIT ?",
                     [.text(runID), .int(afterSeq), .int(max(0, limit))]) { row -> RunEvent? in
            guard let kind = RunEvent.Kind(rawValue: row.text(3)) else { return nil }
            let data = (try? JSONValue.parse(row.text(6))) ?? .null
            return RunEvent(id: row.text(1), runID: runID, seq: row.int(0), timestamp: row.date(2), kind: kind,
                            stepID: row.optionalText(4), text: row.text(5), data: data)
        }.compactMap { $0 }
    }

    public func eventCount(runID: String) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM events WHERE run_id = ?", [.text(runID)])
    }

    // MARK: Receipts

    public func saveReceipt(_ receipt: RunReceipt) throws {
        try db.run("INSERT INTO receipts(run_id, saved_at, json) VALUES(?,?,?) ON CONFLICT(run_id) DO UPDATE SET saved_at=excluded.saved_at, json=excluded.json",
                   [.text(receipt.runID), .date(Date()), .text(try encode(receipt))])
        hub.publish(.run(receipt.runID))
    }

    public func receipt(runID: String) throws -> RunReceipt? {
        guard let json = try db.query("SELECT json FROM receipts WHERE run_id = ?", [.text(runID)], { $0.text(0) }).first else { return nil }
        return try decode(RunReceipt.self, from: json)
    }
}
