// ORIX OS Automation
// File: Packages/ORIXSecurity/Sources/ORIXSecurity/AuditLog.swift
// Description: Append-only, hash-chained JSONL audit trail. Each line carries the previous line's hash, so edits and removals inside the file are detectable.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import CryptoKit
import Foundation
import ORIXCore
import os

public struct AuditVerification: Sendable, Hashable {
    /// True when every line links to the one before it and matches its own hash.
    public var isValid: Bool
    /// Lines that verified before the first problem (all of them when valid).
    public var verifiedEntries: Int
    /// 1-based line number of the first line that does not verify.
    public var firstBrokenLine: Int?
    public var reason: String?

    public static func ok(entries: Int) -> AuditVerification { .init(isValid: true, verifiedEntries: entries, firstBrokenLine: nil, reason: nil) }
    public static func broken(line: Int, reason: String) -> AuditVerification {
        .init(isValid: false, verifiedEntries: line - 1, firstBrokenLine: line, reason: reason)
    }
}

public enum AuditLogError: Error, Sendable, Hashable, LocalizedError {
    case io(String)
    public var errorDescription: String? {
        switch self { case .io(let m): return "Audit log: \(m)" }
    }
}

/// One line per entry: `{"hash":"<sha256>","prev":"<sha256 of previous line>","entry":{…}}`.
/// `hash` = SHA-256(prev hash bytes + the exact entry JSON bytes). The first line links to 64 zeros.
/// Appends take an exclusive file lock and re-read the tail, so two processes can share one file without breaking the chain.
public actor AuditLog: AuditSink {
    public static let genesisHash = String(repeating: "0", count: 64)

    public nonisolated let url: URL
    private let fd: Int32
    private var knownSize: Int64 = 0
    private var lastHash = AuditLog.genesisHash
    private var endsWithNewline = true
    /// Entries that could not be written (disk full, file removed…). Reported, never hidden.
    public private(set) var writeFailures = 0
    private let logger = Logger(subsystem: "ai.spboucher.orix.automation", category: "audit")

    public init(url: URL) throws {
        self.url = url
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw AuditLogError.io("cannot create \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AuditLogError.io("cannot open \(url.path): \(String(cString: strerror(errno)))") }
        fd = descriptor
        let state = try Self.scan(fd: descriptor, from: 0, lastHash: Self.genesisHash, endsWithNewline: true)
        knownSize = state.size; lastHash = state.lastHash; endsWithNewline = state.endsWithNewline
    }

    deinit { close(fd) }

    // MARK: AuditSink

    public func record(_ entry: AuditEntry) async {
        do { try append(entry) } catch {
            writeFailures += 1
            logger.error("audit entry \(entry.kind.rawValue, privacy: .public) was not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Appends one entry, redacting `detail` and `data` first. Throws when the file cannot be written.
    public func append(_ entry: AuditEntry) throws {
        var clean = entry
        clean.detail = Redactor.shared.redact(entry.detail)
        clean.data = Redactor.shared.redact(entry.data)
        let body: Data
        do { body = try Self.encoder().encode(clean) } catch { throw AuditLogError.io("cannot encode entry: \(error.localizedDescription)") }

        guard flock(fd, LOCK_EX) == 0 else { throw AuditLogError.io("cannot lock: \(String(cString: strerror(errno)))") }
        defer { flock(fd, LOCK_UN) }
        try refresh()

        let hash = Self.hash(prev: lastHash, body: body)
        var line = Data()
        if !endsWithNewline { line.append(0x0A) }
        line.append(Data("{\"hash\":\"\(hash)\",\"prev\":\"\(lastHash)\",\"entry\":".utf8))
        line.append(body)
        line.append(contentsOf: [0x7D, 0x0A])
        try Self.writeAll(fd: fd, line)
        fsync(fd)
        knownSize += Int64(line.count)
        lastHash = hash
        endsWithNewline = true
    }

    // MARK: Reading

    /// The most recent `limit` entries, oldest first. Lines that cannot be decoded are skipped (see `verify()`).
    public func entries(limit: Int = 500) -> [AuditEntry] {
        guard limit > 0, let data = try? Self.readAll(fd: fd) else { return [] }
        let decoder = Self.decoder()
        var out: [AuditEntry] = []
        for line in Self.lines(data).suffix(limit) {
            guard let parsed = Self.parse(line), let entry = try? decoder.decode(AuditEntry.self, from: parsed.body) else { continue }
            out.append(entry)
        }
        return out
    }

    public func entryCount() -> Int {
        guard let data = try? Self.readAll(fd: fd) else { return 0 }
        return Self.lines(data).count
    }

    /// Walks the whole chain. Detects edited, reordered, inserted and removed lines. Removal of the newest lines
    /// (truncation at the end) leaves a valid shorter chain and cannot be detected from the file alone.
    public func verify() -> AuditVerification {
        guard let data = try? Self.readAll(fd: fd) else { return .broken(line: 1, reason: "the file cannot be read") }
        var expectedPrev = Self.genesisHash
        var index = 0
        for line in Self.lines(data) {
            index += 1
            guard let parsed = Self.parse(line) else { return .broken(line: index, reason: "the line is not a well-formed audit record") }
            guard parsed.prev == expectedPrev else {
                return .broken(line: index, reason: "the line does not link to the one before it (a line was removed, inserted or reordered)")
            }
            guard Self.hash(prev: parsed.prev, body: parsed.body) == parsed.hash else {
                return .broken(line: index, reason: "the line's content does not match its hash (it was edited)")
            }
            expectedPrev = parsed.hash
        }
        return .ok(entries: index)
    }

    // MARK: Chain state

    /// Picks up lines appended by another process (or a truncated/replaced file) before linking a new line.
    private func refresh() throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw AuditLogError.io("cannot stat: \(String(cString: strerror(errno)))") }
        let size = Int64(info.st_size)
        if size == knownSize { return }
        let state = size > knownSize
            ? try Self.scan(fd: fd, from: knownSize, lastHash: lastHash, endsWithNewline: endsWithNewline)
            : try Self.scan(fd: fd, from: 0, lastHash: Self.genesisHash, endsWithNewline: true)
        knownSize = state.size; lastHash = state.lastHash; endsWithNewline = state.endsWithNewline
    }

    private static func scan(fd: Int32, from offset: Int64, lastHash: String, endsWithNewline: Bool) throws -> (size: Int64, lastHash: String, endsWithNewline: Bool) {
        let data = try read(fd: fd, from: offset)
        var hash = lastHash
        for line in lines(data) { if let parsed = parse(line) { hash = parsed.hash } }
        let newline = data.isEmpty ? endsWithNewline : data.last == 0x0A
        return (offset + Int64(data.count), hash, newline)
    }

    // MARK: Format

    private static let hashPrefix = Array("{\"hash\":\"".utf8)
    private static let prevPrefix = Array("\",\"prev\":\"".utf8)
    private static let entryPrefix = Array("\",\"entry\":".utf8)

    static func parse(_ line: Data) -> (hash: String, prev: String, body: Data)? {
        let bytes = [UInt8](line)
        let fixed = hashPrefix.count + 64 + prevPrefix.count + 64 + entryPrefix.count
        guard bytes.count > fixed + 2, bytes.last == 0x7D else { return nil }
        var i = 0
        func take(_ expected: [UInt8]) -> Bool {
            guard Array(bytes[i..<(i + expected.count)]) == expected else { return false }
            i += expected.count
            return true
        }
        func hex() -> String? {
            let slice = bytes[i..<(i + 64)]
            guard slice.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
            i += 64
            return String(decoding: slice, as: UTF8.self)
        }
        guard take(hashPrefix), let hash = hex(), take(prevPrefix), let prev = hex(), take(entryPrefix) else { return nil }
        return (hash, prev, Data(bytes[i..<(bytes.count - 1)]))
    }

    static func hash(prev: String, body: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(prev.utf8))
        hasher.update(data: body)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func lines(_ data: Data) -> [Data] {
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    // MARK: File access

    private static func readAll(fd: Int32) throws -> Data { try read(fd: fd, from: 0) }

    private static func read(fd: Int32, from offset: Int64) throws -> Data {
        var out = Data()
        var position = off_t(offset)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, position) }
            if n < 0 {
                if errno == EINTR { continue }
                throw AuditLogError.io("cannot read: \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            out.append(contentsOf: buffer[0..<n])
            position += off_t(n)
        }
        return out
    }

    private static func writeAll(fd: Int32, _ data: Data) throws {
        var written = 0
        let bytes = [UInt8](data)
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + written, bytes.count - written) }
            if n < 0 {
                if errno == EINTR { continue }
                throw AuditLogError.io("cannot write: \(String(cString: strerror(errno)))")
            }
            written += n
        }
    }
}
