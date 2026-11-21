// ORIX OS Automation
// File: Packages/ORIXPersistence/Sources/ORIXPersistence/ORIXStore+Documents.swift
// Description: Generic Codable documents by collection, and versioned workflow sources with draft/published tracking.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

extension ORIXStore {
    // MARK: Generic documents

    /// Inserts or replaces a document. Collections are free-form names (`agents`, `sessions`, `memory`, `settings`…).
    public func put<T: Codable & Sendable>(_ value: T, collection: String, id: String) throws {
        guard !collection.isEmpty, !id.isEmpty else { throw StoreError.invalidArgument("collection and id cannot be empty") }
        try putRaw(json: try encode(value), collection: collection, id: id, createdAt: nil, updatedAt: Date())
        hub.publish(.collection(collection))
    }

    func putRaw(json: String, collection: String, id: String, createdAt: Date?, updatedAt: Date) throws {
        try db.run("""
        INSERT INTO documents(collection, id, created_at, updated_at, json) VALUES(?,?,?,?,?)
        ON CONFLICT(collection, id) DO UPDATE SET updated_at=excluded.updated_at, json=excluded.json
        """, [.text(collection), .text(id), .date(createdAt ?? updatedAt), .date(updatedAt), .text(json)])
    }

    public func get<T: Codable & Sendable>(_ type: T.Type, collection: String, id: String) throws -> T? {
        guard let json = try db.query("SELECT json FROM documents WHERE collection = ? AND id = ?", [.text(collection), .text(id)], { $0.text(0) }).first else { return nil }
        return try decode(T.self, from: json)
    }

    /// Every document of a collection, most recently updated first. Documents this version cannot decode are skipped and logged.
    public func all<T: Codable & Sendable>(_ type: T.Type, collection: String) throws -> [T] {
        let rows = try db.query("SELECT json FROM documents WHERE collection = ? ORDER BY updated_at DESC, rowid DESC", [.text(collection)]) { $0.text(0) }
        return decodeAll(T.self, rows, what: "\(collection) document")
    }

    /// Returns false when there was nothing to remove.
    @discardableResult
    public func remove(collection: String, id: String) throws -> Bool {
        let removed = try db.run("DELETE FROM documents WHERE collection = ? AND id = ?", [.text(collection), .text(id)]) > 0
        if removed { hub.publish(.collection(collection)) }
        return removed
    }

    public func count(collection: String) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM documents WHERE collection = ?", [.text(collection)])
    }

    /// Names of the collections that hold at least one document.
    public func collections() throws -> [String] {
        try db.query("SELECT DISTINCT collection FROM documents ORDER BY collection") { $0.text(0) }
    }

    // MARK: Workflows

    /// Saves `source` as the newest version of a workflow (creating the workflow at version 1) and returns that version.
    /// Saving a source and format identical to the current version creates nothing and returns the current version;
    /// the name is still updated.
    @discardableResult
    public func saveWorkflowVersion(workflowID: String, name: String, source: String, format: String = "yaml", note: String = "") throws -> Int {
        guard !workflowID.isEmpty else { throw StoreError.invalidArgument("workflowID cannot be empty") }
        guard format == "yaml" || format == "json" else { throw StoreError.invalidArgument("format must be yaml or json (got \(format))") }
        let now = Date()
        let version: Int = try db.transaction {
            guard let existing = try workflow(id: workflowID) else {
                try db.run("INSERT INTO workflows(id, name, current_version, published_version, created_at, updated_at) VALUES(?,?,1,NULL,?,?)",
                           [.text(workflowID), .text(name), .date(now), .date(now)])
                try insertVersion(WorkflowVersionRow(workflowID: workflowID, version: 1, source: source, format: format, note: note, createdAt: now))
                return 1
            }
            let current = try db.query("SELECT source, format FROM workflow_versions WHERE workflow_id = ? AND version = ?",
                                       [.text(workflowID), .int(existing.currentVersion)]) { ($0.text(0), $0.text(1)) }.first
            if let current, current.0 == source, current.1 == format {
                if existing.name != name {
                    try db.run("UPDATE workflows SET name = ?, updated_at = ? WHERE id = ?", [.text(name), .date(now), .text(workflowID)])
                }
                return existing.currentVersion
            }
            let next = try db.scalarInt("SELECT COALESCE(MAX(version), 0) + 1 FROM workflow_versions WHERE workflow_id = ?", [.text(workflowID)])
            try insertVersion(WorkflowVersionRow(workflowID: workflowID, version: next, source: source, format: format, note: note, createdAt: now))
            try db.run("UPDATE workflows SET name = ?, current_version = ?, updated_at = ? WHERE id = ?",
                       [.text(name), .int(next), .date(now), .text(workflowID)])
            return next
        }
        hub.publish(.workflow(workflowID))
        return version
    }

    func insertVersion(_ v: WorkflowVersionRow) throws {
        try db.run("INSERT INTO workflow_versions(workflow_id, version, source, format, note, created_at) VALUES(?,?,?,?,?,?)",
                   [.text(v.workflowID), .int(v.version), .text(v.source), .text(v.format), .text(v.note), .date(v.createdAt)])
    }

    /// Marks an existing version as the published one. `version: nil` unpublishes.
    public func publish(workflowID: String, version: Int?) throws {
        try db.transaction {
            guard try workflow(id: workflowID) != nil else { throw StoreError.notFound("Workflow \(workflowID)") }
            if let version {
                let exists = try db.scalarInt("SELECT COUNT(*) FROM workflow_versions WHERE workflow_id = ? AND version = ?", [.text(workflowID), .int(version)])
                guard exists == 1 else { throw StoreError.notFound("Version \(version) of workflow \(workflowID)") }
            }
            try db.run("UPDATE workflows SET published_version = ?, updated_at = ? WHERE id = ?",
                       [.optionalInt(version), .date(Date()), .text(workflowID)])
        }
        hub.publish(.workflow(workflowID))
    }

    private static let workflowColumns = "id, name, current_version, published_version, updated_at, created_at"

    private func workflowRow(_ row: Row) -> WorkflowRow {
        WorkflowRow(id: row.text(0), name: row.text(1), currentVersion: row.int(2), publishedVersion: row.optionalInt(3),
                    updatedAt: row.date(4), createdAt: row.date(5))
    }

    /// Most recently updated first.
    public func workflows() throws -> [WorkflowRow] {
        try db.query("SELECT \(Self.workflowColumns) FROM workflows ORDER BY updated_at DESC, id") { workflowRow($0) }
    }

    public func workflow(id: String) throws -> WorkflowRow? {
        try db.query("SELECT \(Self.workflowColumns) FROM workflows WHERE id = ?", [.text(id)]) { workflowRow($0) }.first
    }

    /// Full history, newest version first.
    public func workflowVersions(workflowID: String) throws -> [WorkflowVersionRow] {
        try db.query("SELECT version, source, format, note, created_at FROM workflow_versions WHERE workflow_id = ? ORDER BY version DESC", [.text(workflowID)]) {
            WorkflowVersionRow(workflowID: workflowID, version: $0.int(0), source: $0.text(1), format: $0.text(2), note: $0.text(3), createdAt: $0.date(4))
        }
    }

    /// One version's row. `version: nil` means the current (latest) version.
    public func workflowVersion(workflowID: String, version: Int? = nil) throws -> WorkflowVersionRow? {
        let rows: [WorkflowVersionRow]
        if let version {
            rows = try db.query("SELECT version, source, format, note, created_at FROM workflow_versions WHERE workflow_id = ? AND version = ?", [.text(workflowID), .int(version)]) {
                WorkflowVersionRow(workflowID: workflowID, version: $0.int(0), source: $0.text(1), format: $0.text(2), note: $0.text(3), createdAt: $0.date(4))
            }
        } else {
            rows = try db.query("""
            SELECT v.version, v.source, v.format, v.note, v.created_at FROM workflow_versions v
            JOIN workflows w ON w.id = v.workflow_id AND w.current_version = v.version WHERE v.workflow_id = ?
            """, [.text(workflowID)]) {
                WorkflowVersionRow(workflowID: workflowID, version: $0.int(0), source: $0.text(1), format: $0.text(2), note: $0.text(3), createdAt: $0.date(4))
            }
        }
        return rows.first
    }

    /// The source text of a version. `version: nil` means the current (latest) version.
    public func workflowSource(workflowID: String, version: Int? = nil) throws -> String? {
        try workflowVersion(workflowID: workflowID, version: version)?.source
    }

    /// Deletes a workflow and its whole history. Past runs keep their `workflowID`. Returns false when it did not exist.
    @discardableResult
    public func deleteWorkflow(id: String) throws -> Bool {
        let removed = try db.run("DELETE FROM workflows WHERE id = ?", [.text(id)]) > 0
        if removed { hub.publish(.workflow(id)) }
        return removed
    }
}
