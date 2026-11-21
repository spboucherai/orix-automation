// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXPersistence/Sources/ORIXPersistence/ORIXStore+Maintenance.swift
// Description      : Dashboard aggregates, online backup, export/import of
//                    workflows and documents (never grants or secrets), size
//                    and pruning.
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

extension ORIXStore {
    // MARK: Aggregates

    /// One entry per local calendar day for the last `days` days (today included), oldest first; days without runs are zero.
    public func usageByDay(days: Int = 30) throws -> [DailyUsage] {
        let days = max(1, days)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var byDay: [Date: DailyUsage] = [:]
        var order: [Date] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: first) else { continue }
            let start = calendar.startOfDay(for: day)
            byDay[start] = DailyUsage(date: start, day: formatter.string(from: start))
            order.append(start)
        }
        let failed: Set<String> = [RunStatus.failed, .timedOut, .budgetExceeded, .blockedPermission, .recoveryRequired].reduce(into: []) { $0.insert($1.rawValue) }
        let rows = try db.query("SELECT queued_at, status, tokens, cost_usd FROM runs WHERE queued_at >= ?", [.date(first)]) {
            ($0.date(0), $0.text(1), $0.int(2), $0.double(3))
        }
        for (queuedAt, status, tokens, cost) in rows {
            let start = calendar.startOfDay(for: queuedAt)
            guard var usage = byDay[start] else { continue }
            usage.runs += 1
            if status == RunStatus.succeeded.rawValue { usage.succeeded += 1 }
            if failed.contains(status) { usage.failed += 1 }
            usage.tokens += tokens
            usage.costUSD += cost
            byDay[start] = usage
        }
        return order.compactMap { byDay[$0] }
    }

    /// Number of runs per status. `sinceDays: nil` counts everything; otherwise runs queued in the last N×24 h.
    public func statusCounts(sinceDays: Int? = nil) throws -> [RunStatus: Int] {
        let rows: [(String, Int)]
        if let sinceDays {
            let cutoff = Date().addingTimeInterval(-Double(max(0, sinceDays)) * 86_400)
            rows = try db.query("SELECT status, COUNT(*) FROM runs WHERE queued_at >= ? GROUP BY status", [.date(cutoff)]) { ($0.text(0), $0.int(1)) }
        } else {
            rows = try db.query("SELECT status, COUNT(*) FROM runs GROUP BY status") { ($0.text(0), $0.int(1)) }
        }
        var out: [RunStatus: Int] = [:]
        for (raw, count) in rows { if let status = RunStatus(rawValue: raw) { out[status] = count } }
        return out
    }

    // MARK: Maintenance

    /// Writes a consistent, compacted copy of the whole database (grants included: a backup is for this Mac) to `destination`
    /// while the store stays in use. Refuses to overwrite an existing file.
    public func backup(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StoreError.fileExists(destination.path) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try db.run("VACUUM INTO ?", [.text(destination.path)])
    }

    /// Bytes used on disk by the database and its write-ahead log (page count × page size for an in-memory store).
    public func databaseSizeBytes() throws -> Int {
        guard let url else {
            return try db.scalarInt("PRAGMA page_count") * db.scalarInt("PRAGMA page_size")
        }
        var total = 0
        for path in [url.path, url.path + "-wal"] {
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber { total += size.intValue }
        }
        return total
    }

    /// Deletes finished runs (with their events and receipts) that ended more than `olderThanDays` days ago.
    /// Runs still in flight are never pruned. Returns how many runs were deleted.
    @discardableResult
    public func pruneRuns(olderThanDays: Int) throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(max(0, olderThanDays)) * 86_400)
        let condition = "status NOT IN (\(Self.nonTerminalList)) AND COALESCE(ended_at, started_at, queued_at) < ?1"
        let ids: [String] = try db.transaction {
            let ids = try db.query("SELECT id FROM runs WHERE \(condition)", [.date(cutoff)]) { $0.text(0) }
            guard !ids.isEmpty else { return [] }
            try db.run("DELETE FROM events WHERE run_id IN (SELECT id FROM runs WHERE \(condition))", [.date(cutoff)])
            try db.run("DELETE FROM receipts WHERE run_id IN (SELECT id FROM runs WHERE \(condition))", [.date(cutoff)])
            try db.run("DELETE FROM runs WHERE \(condition)", [.date(cutoff)])
            return ids
        }
        if !ids.isEmpty {
            _ = try? db.query("PRAGMA wal_checkpoint(PASSIVE)") { _ in () }
            for id in ids { hub.publish(.run(id)) }
        }
        return ids.count
    }

    // MARK: Export / import

    /// Collections never exported or imported, whatever the caller asks: their names say they hold sensitive material.
    public static func isSensitiveCollection(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["secret", "credential", "grant", "keychain", "token", "password", "apikey", "api_key"].contains { n.contains($0) }
    }

    /// Builds the portable bundle: every workflow with its history and every document outside the excluded collections.
    /// Grants, runs, events, receipts and leases are never part of it. String values and workflow sources pass through
    /// `Redactor.shared`, so registered secrets and credential-shaped text are replaced by the placeholder
    /// (template expressions such as `{{ secrets.name }}` are references, not secrets, and are kept).
    public func makeBundle(excludingCollections: Set<String> = []) throws -> (bundle: StoreBundle, summary: BundleSummary) {
        var summary = BundleSummary()
        var redacted = 0
        var workflowItems: [StoreBundle.Workflow] = []
        for row in try workflows().sorted(by: { $0.id < $1.id }) {
            var versions = try workflowVersions(workflowID: row.id).sorted { $0.version < $1.version }
            for i in versions.indices {
                versions[i].source = Self.scrub(versions[i].source, count: &redacted)
                versions[i].note = Self.scrub(versions[i].note, count: &redacted)
            }
            summary.workflowVersions += versions.count
            workflowItems.append(.init(row: row, versions: versions))
        }
        summary.workflows = workflowItems.count

        var documents: [StoreBundle.Document] = []
        var excluded: Set<String> = []
        let rows = try db.query("SELECT collection, id, created_at, updated_at, json FROM documents ORDER BY collection, id") {
            ($0.text(0), $0.text(1), $0.date(2), $0.date(3), $0.text(4))
        }
        for (collection, id, createdAt, updatedAt, json) in rows {
            if excludingCollections.contains(collection) || Self.isSensitiveCollection(collection) { excluded.insert(collection); continue }
            let value: JSONValue
            do { value = try JSONValue.parse(json) } catch { throw StoreError.encoding("document \(collection)/\(id) is not valid JSON") }
            documents.append(.init(collection: collection, id: id, createdAt: createdAt, updatedAt: updatedAt, value: Self.scrub(value, count: &redacted)))
        }
        summary.documents = documents.count
        summary.excludedCollections = excluded.sorted()
        summary.redactedValues = redacted
        let bundle = StoreBundle(format: StoreBundle.formatIdentifier, version: StoreBundle.currentVersion, exportedAt: Date(),
                                 workflows: workflowItems, documents: documents)
        return (bundle, summary)
    }

    /// Writes the bundle as one JSON file (replacing `destination` atomically).
    @discardableResult
    public func exportBundle(to destination: URL, excludingCollections: Set<String> = []) throws -> BundleSummary {
        let (bundle, summary) = try makeBundle(excludingCollections: excludingCollections)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(bundle) } catch { throw StoreError.encoding(String(describing: error)) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return summary
    }

    /// Merges a bundle into this store, in one transaction:
    /// - a workflow that does not exist here is created with its full history and published version;
    /// - a workflow that exists keeps its local history, and the bundle's current source is appended as a new version
    ///   when it differs (nothing local is ever overwritten or deleted);
    /// - documents are inserted, and replace local ones with the same collection/id only when `overwriteDocuments` is true.
    /// Sensitive collections are ignored even if a hand-edited file contains them. Grants cannot be imported.
    @discardableResult
    public func importBundle(from source: URL, overwriteDocuments: Bool = true) throws -> BundleSummary {
        let bundle: StoreBundle
        do { bundle = try JSONDecoder().decode(StoreBundle.self, from: try Data(contentsOf: source)) }
        catch { throw StoreError.invalidBundle(String(describing: error)) }
        guard bundle.format == StoreBundle.formatIdentifier else { throw StoreError.invalidBundle("unexpected format \(bundle.format)") }
        guard bundle.version <= StoreBundle.currentVersion else {
            throw StoreError.invalidBundle("bundle version \(bundle.version) is newer than this app supports (\(StoreBundle.currentVersion))")
        }
        for item in bundle.workflows {
            guard !item.row.id.isEmpty, !item.versions.isEmpty, item.versions.allSatisfy({ $0.format == "yaml" || $0.format == "json" }) else {
                throw StoreError.invalidBundle("workflow \(item.row.id) has no usable version")
            }
        }

        var summary = BundleSummary()
        var excluded: Set<String> = []
        var touchedCollections: Set<String> = []
        try db.transaction {
            for item in bundle.workflows {
                let versions = item.versions.sorted { $0.version < $1.version }
                if try workflow(id: item.row.id) == nil {
                    let current = versions.last!.version
                    let published = item.row.publishedVersion.flatMap { p in versions.contains { $0.version == p } ? p : nil }
                    try db.run("INSERT INTO workflows(id, name, current_version, published_version, created_at, updated_at) VALUES(?,?,?,?,?,?)",
                               [.text(item.row.id), .text(item.row.name), .int(current), .optionalInt(published), .date(item.row.createdAt), .date(item.row.updatedAt)])
                    for var v in versions { v.workflowID = item.row.id; try insertVersion(v) }
                    summary.workflowVersions += versions.count
                } else {
                    let latest = versions.first { $0.version == item.row.currentVersion } ?? versions.last!
                    let before = try workflow(id: item.row.id)?.currentVersion
                    let after = try saveWorkflowVersion(workflowID: item.row.id, name: item.row.name, source: latest.source, format: latest.format,
                                                        note: latest.note.isEmpty ? "Imported" : latest.note)
                    if after != before { summary.workflowVersions += 1 }
                }
                summary.workflows += 1
            }
            for doc in bundle.documents {
                if Self.isSensitiveCollection(doc.collection) { excluded.insert(doc.collection); continue }
                guard !doc.collection.isEmpty, !doc.id.isEmpty else { continue }
                let exists = try db.scalarInt("SELECT COUNT(*) FROM documents WHERE collection = ? AND id = ?", [.text(doc.collection), .text(doc.id)]) > 0
                if exists && !overwriteDocuments { continue }
                try putRaw(json: doc.value.serialized(), collection: doc.collection, id: doc.id, createdAt: doc.createdAt, updatedAt: doc.updatedAt)
                touchedCollections.insert(doc.collection)
                summary.documents += 1
            }
        }
        summary.excludedCollections = excluded.sorted()
        for item in bundle.workflows { hub.publish(.workflow(item.row.id)) }
        for collection in touchedCollections.sorted() { hub.publish(.collection(collection)) }
        return summary
    }

    // MARK: Scrubbing

    private static let templatePattern = try! NSRegularExpression(pattern: #"\{\{[^{}\n]*\}\}|\$\{[^{}\n]*\}"#)

    /// Redacts secrets in `text` while leaving template expressions intact.
    static func scrub(_ text: String, count: inout Int) -> String {
        guard !text.isEmpty else { return text }
        // Template expressions are swapped for short inert markers so the key=value pattern cannot swallow them.
        var expressions: [String] = []
        var masked = ""
        var cursor = text.startIndex
        let ns = text as NSString
        for match in templatePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(match.range, in: text) else { continue }
            masked += text[cursor..<range.lowerBound]
            masked += "\u{1}\(expressions.count)\u{2}"
            expressions.append(String(text[range]))
            cursor = range.upperBound
        }
        masked += text[cursor...]
        let redacted = Redactor.shared.redact(masked)
        if redacted != masked { count += 1 }
        guard !expressions.isEmpty else { return redacted }
        var out = redacted
        for (i, expression) in expressions.enumerated() {
            out = out.replacingOccurrences(of: "\u{1}\(i)\u{2}", with: expression)
        }
        return out
    }

    /// Redacts string values only; keys and numbers are kept so documents still decode after an import.
    static func scrub(_ value: JSONValue, count: inout Int) -> JSONValue {
        switch value {
        case .string(let s): return .string(scrub(s, count: &count))
        case .array(let a): return .array(a.map { scrub($0, count: &count) })
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o { out[k] = scrub(v, count: &count) }
            return .object(out)
        default: return value
        }
    }
}
