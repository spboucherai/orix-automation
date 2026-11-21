// ORIX OS Automation
// File: Packages/ORIXPersistence/Sources/ORIXPersistence/Database.swift
// Description: Thin wrapper over the system sqlite3 library: WAL, busy timeout, foreign keys, cached prepared statements with typed binding, transactions and user_version migrations.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import SQLite3

/// An error reported by SQLite, with the extended result code.
public struct SQLiteError: Error, Sendable, Hashable, LocalizedError {
    public let code: Int32
    public let message: String
    public let sql: String

    public var primaryCode: Int32 { code & 0xFF }
    /// The file is not a database or its structure is damaged.
    public var isCorruption: Bool { primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB }
    public var isBusy: Bool { primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED }
    public var errorDescription: String? { "SQLite error \(code): \(message)" }
}

enum SQLValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func int(_ v: Int) -> SQLValue { .int(Int64(v)) }
    static func optionalText(_ v: String?) -> SQLValue { v.map(SQLValue.text) ?? .null }
    static func optionalInt(_ v: Int?) -> SQLValue { v.map { .int(Int64($0)) } ?? .null }
    /// Dates are stored as seconds since the reference date (2001-01-01 UTC), the exact value `Date` holds.
    static func date(_ v: Date) -> SQLValue { .double(v.timeIntervalSinceReferenceDate) }
    static func optionalDate(_ v: Date?) -> SQLValue { v.map(SQLValue.date) ?? .null }
}

/// One result row. Valid only inside the mapping closure of `Database.query`.
struct Row {
    fileprivate let statement: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
    func optionalInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
    func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
    func optionalText(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    func date(_ i: Int32) -> Date { Date(timeIntervalSinceReferenceDate: double(i)) }
    func optionalDate(_ i: Int32) -> Date? { isNull(i) ? nil : date(i) }
}

struct Migration: Sendable {
    let version: Int
    let sql: String
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Not thread-safe by itself beyond SQLite's own serialized mode: `ORIXStore` (an actor) owns it.
final class Database: @unchecked Sendable {
    let path: String
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var transactionDepth = 0

    init(path: String, busyTimeoutMs: Int32 = 5000) throws {
        self.path = path
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(h)
            throw SQLiteError(code: rc, message: message, sql: "open \(path)")
        }
        handle = h
        sqlite3_extended_result_codes(h, 1)
        sqlite3_busy_timeout(h, busyTimeoutMs)
    }

    deinit { close() }

    func close() {
        for (_, s) in statements { sqlite3_finalize(s) }
        statements.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    /// WAL so readers in another process never block the writer; NORMAL sync is durable across app crashes in WAL mode.
    func configure() throws {
        _ = try query("PRAGMA journal_mode = WAL") { $0.text(0) }
        try exec("PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
    }

    /// Returns nil when the file passes `PRAGMA quick_check`, else a description of the damage.
    func quickCheck() throws -> String? {
        let rows = try query("PRAGMA quick_check(5)") { $0.text(0) }
        if rows == ["ok"] { return nil }
        return rows.joined(separator: "; ")
    }

    // MARK: Statements

    private func failure(_ sql: String) -> SQLiteError {
        SQLiteError(code: sqlite3_extended_errcode(handle), message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let s = statements[sql] { return s }
        guard handle != nil else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed", sql: sql) }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else { throw failure(sql) }
        statements[sql] = s
        return s
    }

    private func bind(_ s: OpaquePointer, _ params: [SQLValue], sql: String) throws {
        for (offset, value) in params.enumerated() {
            let i = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(s, i)
            case .int(let v): rc = sqlite3_bind_int64(s, i, v)
            case .double(let v): rc = sqlite3_bind_double(s, i, v)
            case .text(let v): rc = sqlite3_bind_text(s, i, v, -1, sqliteTransient)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(s, i, $0.baseAddress, Int32($0.count), sqliteTransient) }
            }
            guard rc == SQLITE_OK else { throw failure(sql) }
        }
    }

    /// Runs a statement that returns no rows. Returns the number of rows changed.
    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        let s = try prepared(sql)
        defer { sqlite3_reset(s); sqlite3_clear_bindings(s) }
        try bind(s, params, sql: sql)
        var rc = sqlite3_step(s)
        while rc == SQLITE_ROW { rc = sqlite3_step(s) }
        guard rc == SQLITE_DONE else { throw failure(sql) }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ params: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        let s = try prepared(sql)
        defer { sqlite3_reset(s); sqlite3_clear_bindings(s) }
        try bind(s, params, sql: sql)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw failure(sql) }
            out.append(try map(Row(statement: s)))
        }
        return out
    }

    func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        try query(sql, params) { $0.int(0) }.first ?? 0
    }

    /// Runs one or more statements without parameters (DDL, pragmas).
    func exec(_ sql: String) throws {
        guard handle != nil else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed", sql: sql) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure(sql) }
    }

    /// `BEGIN IMMEDIATE … COMMIT`: the write lock is taken up front, so two processes queue instead of deadlocking.
    /// Nested calls join the outer transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 { return try body() }
        try run("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let value = try body()
            transactionDepth = 0
            try run("COMMIT")
            return value
        } catch {
            transactionDepth = 0
            _ = try? run("ROLLBACK")
            throw error
        }
    }

    // MARK: Migrations

    func userVersion() throws -> Int { try scalarInt("PRAGMA user_version") }

    /// Applies, in order and each in its own transaction, every migration above the file's `user_version`
    /// (up to `target` when given). Safe when two processes open the same file at once.
    func migrate(_ migrations: [Migration], upTo target: Int? = nil) throws {
        let supported = migrations.map(\.version).max() ?? 0
        let current = try userVersion()
        if current > supported { throw StoreError.newerSchema(found: current, supported: supported) }
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current && migration.version <= (target ?? supported) {
            try transaction {
                // Another process may have applied it while this one waited for the write lock.
                guard try userVersion() < migration.version else { return }
                try exec(migration.sql)
                try exec("PRAGMA user_version = \(migration.version)")
            }
        }
    }
}
