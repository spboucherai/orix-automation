// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/ToolSupport.swift
// Description: Helpers shared by the built-in tools: canonical path arguments, checksums, reversible-overwrite backups, artifacts, confinement profiles and subprocess calls.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import CryptoKit
import ORIXCore

extension ToolInput {
    /// The canonical absolute path for a required path argument.
    func path(_ key: String, _ context: ToolExecutionContext) throws -> String {
        try PathResolver.canonical(try string(key), relativeTo: context.workingDirectory)
    }

    /// The canonical absolute path for an optional path argument.
    func optionalPath(_ key: String, _ context: ToolExecutionContext) throws -> String? {
        guard let raw = optionalString(key) else { return nil }
        return try PathResolver.canonical(raw, relativeTo: context.workingDirectory)
    }

    /// String-to-string map argument (`env`, `headers`).
    func stringMap(_ key: String) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in arguments[key]?.objectValue ?? [:] { if let s = v.stringValue { out[k] = s } }
        return out
    }
}

enum ToolSupport {
    static var fm: FileManager { FileManager.default }

    static func kind(of path: String) -> (exists: Bool, isDirectory: Bool) {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        return (exists, isDir.boolValue)
    }

    static func requireExists(_ path: String) throws {
        guard kind(of: path).exists else { throw ToolError.notFound("No such file or directory: \(PathResolver.display(path))") }
    }

    static func requireFile(_ path: String) throws {
        let k = kind(of: path)
        guard k.exists else { throw ToolError.notFound("No such file: \(PathResolver.display(path))") }
        guard !k.isDirectory else { throw ToolError.invalidInput("\(PathResolver.display(path)) is a directory, not a file") }
    }

    static func requireDirectory(_ path: String) throws {
        let k = kind(of: path)
        guard k.exists else { throw ToolError.notFound("No such directory: \(PathResolver.display(path))") }
        guard k.isDirectory else { throw ToolError.invalidInput("\(PathResolver.display(path)) is not a directory") }
    }

    /// Runs Foundation file work and converts anything that is not already a `ToolError` into `.io`.
    static func io<T>(_ what: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let e as ToolError { throw e }
        catch { throw ToolError.io("\(what): \(error.localizedDescription)") }
    }

    static func fileSize(_ path: String) -> Int {
        ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func iso(_ date: Date?) -> JSONValue {
        guard let date else { return .null }
        return .string(ISO8601DateFormatter().string(from: date))
    }

    /// Streaming SHA-256 of a file.
    static func sha256(path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw ToolError.io("Cannot open \(PathResolver.display(path))") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try io("Reading \(PathResolver.display(path))") { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The canonical artifacts directory of the run, created on demand.
    static func artifactsDirectory(_ context: ToolExecutionContext, subdirectory: String? = nil) throws -> String {
        var dir = PathResolver.resolveSymlinks(context.artifactsDirectory.path)
        if let subdirectory { dir += "/" + subdirectory }
        try io("Creating the artifacts directory") { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        return dir
    }

    /// Copies a file that is about to be overwritten into `<artifacts>/backups` and returns the copy's path.
    static func backup(_ path: String, context: ToolExecutionContext) throws -> String {
        let dir = try artifactsDirectory(context, subdirectory: "backups")
        let name = (path as NSString).lastPathComponent
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let target = "\(dir)/\(stamp)-\(UUID().uuidString.prefix(6))-\(name)"
        try io("Backing up \(PathResolver.display(path))") { try fm.copyItem(atPath: path, toPath: target) }
        return target
    }

    static func artifact(_ path: String, kind: String = "file", note: String = "", hash: Bool = true) -> Artifact {
        Artifact(path: path, kind: kind, bytes: fileSize(path), sha256: hash ? (try? sha256(path: path)) : nil, note: note)
    }

    /// The Seatbelt profile for a subprocess of this call: the run's confinement, the artifacts directory, and the
    /// extra roots the call's own approved capabilities cover.
    static func profile(_ context: ToolExecutionContext, extraWrite: [String] = [], network: Bool? = nil) -> SeatbeltProfile {
        SeatbeltProfile(confinement: context.confinement,
                        extraWriteRoots: [PathResolver.resolveSymlinks(context.artifactsDirectory.path)] + extraWrite, allowNetwork: network)
    }

    /// Runs a subprocess with the call's progress stream attached and maps timeout/cancel to `ToolError`.
    static func run(_ spec: ProcessSpec, context: ToolExecutionContext, runner: ProcessRunner = .shared, stream: Bool = false) async throws -> ProcessOutput {
        var spec = spec
        if stream {
            let progress = context.progress
            spec.onOutput = { s, text in progress(ToolProgress(stream: s == .stdout ? .stdout : .stderr, text: text)) }
        }
        let output = try await runner.run(spec)
        try output.throwIfInterrupted(timeoutSeconds: spec.timeoutSeconds)
        return output
    }

    /// Lexical normalisation of an absolute path (`.` and `..` removed); never touches the file system.
    static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Glob match (`*`, `?`, `[a-z]`) on a single name, case-insensitive like the default macOS file system.
    static func glob(_ pattern: String, matches name: String) -> Bool {
        fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }

    static func plural(_ n: Int, _ word: String, _ many: String? = nil) -> String { "\(n) \(n == 1 ? word : (many ?? word + "s"))" }
}

/// Short builders for manifests.
enum Schema {
    static func input(_ properties: [String: JSONSchema], required: [String] = []) -> JSONSchema {
        .object(properties, required: required, additional: false)
    }
    static func output(_ properties: [String: JSONSchema], required: [String] = []) -> JSONSchema {
        .object(properties, required: required, additional: true)
    }
    static let path = JSONSchema.string("Absolute path, ~/ path, or path relative to the working directory.")
    static let timeout = JSONSchema(raw: ["type": "number", "description": "Seconds before the call is stopped.", "minimum": 0.1, "maximum": 3600])
}
