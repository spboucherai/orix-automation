// ORIX OS Automation
// File: Packages/ORIXPersistence/Sources/ORIXPersistence/Models.swift
// Description: Public value types of the store: errors, change notifications, workflow rows, dashboard aggregates and the export bundle.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public enum StoreError: Error, Sendable, Hashable, LocalizedError {
    /// The file was written by a newer version of the app; it is left untouched.
    case newerSchema(found: Int, supported: Int)
    case notFound(String)
    case invalidArgument(String)
    case invalidBundle(String)
    case fileExists(String)
    case encoding(String)

    public var errorDescription: String? {
        switch self {
        case .newerSchema(let found, let supported):
            return "This database uses schema \(found), newer than this version supports (\(supported)). Update ORIX OS Automation; the file was not modified."
        case .notFound(let what): return "\(what) was not found."
        case .invalidArgument(let m): return m
        case .invalidBundle(let m): return "The file is not a valid ORIX export: \(m)"
        case .fileExists(let path): return "A file already exists at \(path). Choose another name; nothing was overwritten."
        case .encoding(let m): return "Could not encode or decode stored data: \(m)"
        }
    }
}

/// What changed, for in-process observers of `ORIXStore.changes`.
public enum StoreChange: Sendable, Hashable {
    case run(String)
    /// New events exist for this run.
    case events(String)
    case workflow(String)
    case collection(String)
    case grants
}

public struct WorkflowRow: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Latest saved version (drafts included).
    public var currentVersion: Int
    /// Version that triggers and "Run" use, when one was published.
    public var publishedVersion: Int?
    public var updatedAt: Date
    public var createdAt: Date

    public init(id: String, name: String, currentVersion: Int, publishedVersion: Int? = nil, updatedAt: Date, createdAt: Date) {
        self.id = id; self.name = name; self.currentVersion = currentVersion; self.publishedVersion = publishedVersion
        self.updatedAt = updatedAt; self.createdAt = createdAt
    }
}

public struct WorkflowVersionRow: Codable, Sendable, Hashable, Identifiable {
    public var workflowID: String
    public var version: Int
    public var source: String
    /// `yaml` or `json`.
    public var format: String
    public var note: String
    public var createdAt: Date
    public var id: String { "\(workflowID)@\(version)" }

    public init(workflowID: String, version: Int, source: String, format: String, note: String = "", createdAt: Date) {
        self.workflowID = workflowID; self.version = version; self.source = source; self.format = format
        self.note = note; self.createdAt = createdAt
    }
}

/// Runs queued on one local calendar day.
public struct DailyUsage: Codable, Sendable, Hashable, Identifiable {
    /// Local midnight that starts the day.
    public var date: Date
    /// `yyyy-MM-dd` in the local time zone.
    public var day: String
    public var runs: Int
    /// `SUCCEEDED` only.
    public var succeeded: Int
    /// `FAILED`, `TIMED_OUT`, `BUDGET_EXCEEDED`, `BLOCKED_PERMISSION`, `RECOVERY_REQUIRED`.
    public var failed: Int
    public var tokens: Int
    /// Sum of the known costs; runs without price information contribute 0.
    public var costUSD: Double
    public var id: String { day }

    public init(date: Date, day: String, runs: Int = 0, succeeded: Int = 0, failed: Int = 0, tokens: Int = 0, costUSD: Double = 0) {
        self.date = date; self.day = day; self.runs = runs; self.succeeded = succeeded; self.failed = failed
        self.tokens = tokens; self.costUSD = costUSD
    }
}

/// The portable export: workflows with their full history, and generic documents. Never grants, runs or secrets.
public struct StoreBundle: Codable, Sendable, Hashable {
    public static let formatIdentifier = "ai.spboucher.orix.automation.bundle"
    public static let currentVersion = 1

    public struct Workflow: Codable, Sendable, Hashable {
        public var row: WorkflowRow
        public var versions: [WorkflowVersionRow]
    }
    public struct Document: Codable, Sendable, Hashable {
        public var collection: String
        public var id: String
        public var createdAt: Date
        public var updatedAt: Date
        public var value: JSONValue
    }

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var workflows: [Workflow]
    public var documents: [Document]
}

public struct BundleSummary: Sendable, Hashable {
    public var workflows: Int
    public var workflowVersions: Int
    public var documents: Int
    /// Collections left out because their name marks them as sensitive or the caller excluded them.
    public var excludedCollections: [String]
    /// String values in which a credential-shaped or registered secret was replaced by the redaction placeholder.
    public var redactedValues: Int

    public init(workflows: Int = 0, workflowVersions: Int = 0, documents: Int = 0, excludedCollections: [String] = [], redactedValues: Int = 0) {
        self.workflows = workflows; self.workflowVersions = workflowVersions; self.documents = documents
        self.excludedCollections = excludedCollections; self.redactedValues = redactedValues
    }
}
