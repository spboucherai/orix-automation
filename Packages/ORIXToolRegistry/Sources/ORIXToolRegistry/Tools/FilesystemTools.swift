// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/FilesystemTools.swift
// Description: filesystem.* tools: list, search, read, write, mkdir, copy, move, metadata, checksum, compare, trash and permanent delete.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import UniformTypeIdentifiers
import ORIXCore

private var fm: FileManager { FileManager.default }

private func show(_ path: String) -> String { PathResolver.display(path) }

/// `lstat`-based entry description (symlinks are reported, never followed).
private func entry(_ path: String, name: String? = nil) -> [String: JSONValue] {
    var st = stat()
    guard lstat(path, &st) == 0 else { return ["name": .string(name ?? (path as NSString).lastPathComponent), "path": .string(path), "type": "unknown"] }
    let type: String
    switch st.st_mode & S_IFMT {
    case S_IFDIR: type = "directory"
    case S_IFLNK: type = "symlink"
    case S_IFREG: type = "file"
    default: type = "other"
    }
    return [
        "name": .string(name ?? (path as NSString).lastPathComponent), "path": .string(path), "type": .string(type),
        "size": .int(Int(st.st_size)),
        "modified": ToolSupport.iso(Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))),
    ]
}

/// Depth-first walk that never follows symlinks. `visit` returns false to stop.
private func walk(_ root: String, maxDepth: Int, includeHidden: Bool, visit: (_ path: String, _ relative: String, _ isDirectory: Bool) throws -> Bool) throws {
    func descend(_ dir: String, _ rel: String, _ depth: Int) throws -> Bool {
        try Task.checkCancellation()
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return true }
        for name in names.sorted() {
            if !includeHidden && name.hasPrefix(".") { continue }
            let full = dir == "/" ? "/" + name : dir + "/" + name
            let relative = rel.isEmpty ? name : rel + "/" + name
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            if try !visit(full, relative, isDir) { return false }
            if isDir && depth < maxDepth { if try !descend(full, relative, depth + 1) { return false } }
        }
        return true
    }
    _ = try descend(root, "", 1)
}

// MARK: - list

public struct FilesystemListTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.list", name: "List directory",
        summary: "Lists the entries of a directory (name, type, size, modification date), optionally recursively to a bounded depth.",
        family: "filesystem",
        inputSchema: Schema.input([
            "path": Schema.path, "recursive": .boolean("Descend into subdirectories."),
            "maxDepth": .integer("Depth limit when recursive (default 3).", minimum: 1, maximum: 32),
            "includeHidden": .boolean("Include dot files (default false)."),
            "limit": .integer("Maximum entries returned (default 500).", minimum: 1, maximum: 10_000),
        ], required: ["path"]),
        outputSchema: Schema.output(["path": .string(), "entries": .array(of: .any), "count": .integer(), "truncated": .boolean()],
                                    required: ["path", "entries", "count", "truncated"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true, outputIsUntrusted: true,
        examples: [["path": "~/Downloads", "recursive": false]])

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "List \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        try ToolSupport.requireDirectory(path)
        let limit = input.int("limit", default: 500)
        let depth = input.bool("recursive", default: false) ? input.int("maxDepth", default: 3) : 1
        var entries: [JSONValue] = []
        var truncated = false
        try walk(path, maxDepth: depth, includeHidden: input.bool("includeHidden", default: false)) { full, relative, _ in
            if entries.count >= limit { truncated = true; return false }
            entries.append(.object(entry(full, name: relative)))
            return true
        }
        var result = ToolResult.success(["path": .string(path), "entries": .array(entries), "count": .int(entries.count), "truncated": .bool(truncated)],
                                        summary: "\(ToolSupport.plural(entries.count, "entry", "entries")) in \(show(path))")
        result.truncated = truncated
        return result
    }
}

// MARK: - search

public struct FilesystemSearchTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.search", name: "Search files",
        summary: "Finds files under a directory by name glob and/or by content (substring or regular expression). Results and scanned bytes are bounded.",
        family: "filesystem",
        inputSchema: Schema.input([
            "path": Schema.path, "pattern": .string("Name glob such as *.pdf (matched on the file name)."),
            "content": .string("Text to find inside files."), "regex": .boolean("Treat content as a regular expression."),
            "caseSensitive": .boolean("Content matching is case-sensitive (default false)."),
            "includeHidden": .boolean(), "maxDepth": .integer(minimum: 1, maximum: 64),
            "maxResults": .integer("Default 100.", minimum: 1, maximum: 2_000),
            "maxFileBytes": .integer("Files larger than this are not scanned for content (default 2 MB).", minimum: 1, maximum: 50_000_000),
        ], required: ["path"]),
        outputSchema: Schema.output(["matches": .array(of: .any), "count": .integer(), "truncated": .boolean(), "filesScanned": .integer()],
                                    required: ["matches", "count", "truncated"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 120, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        let pattern = input.optionalString("pattern"), content = input.optionalString("content")
        guard pattern != nil || content != nil else { throw ToolError.invalidInput("give pattern (name glob), content, or both") }
        if let content {
            guard !content.isEmpty else { throw ToolError.invalidInput("content is empty") }
            if input.bool("regex", default: false), (try? NSRegularExpression(pattern: content)) == nil {
                throw ToolError.invalidInput("content is not a valid regular expression")
            }
        }
        let what = [pattern.map { "name \($0)" }, content.map { "text “\($0.prefix(60))”" }].compactMap { $0 }.joined(separator: " and ")
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Search \(show(path)) for \(what)")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let root = try input.path("path", context)
        try ToolSupport.requireDirectory(root)
        let pattern = input.optionalString("pattern"), content = input.optionalString("content")
        let caseSensitive = input.bool("caseSensitive", default: false)
        let maxResults = input.int("maxResults", default: 100), maxFileBytes = input.int("maxFileBytes", default: 2_000_000)
        var regex: NSRegularExpression?
        if let content, input.bool("regex", default: false) {
            regex = try? NSRegularExpression(pattern: content, options: caseSensitive ? [] : [.caseInsensitive])
        }
        var matches: [JSONValue] = []
        var truncated = false, scanned = 0
        try walk(root, maxDepth: input.int("maxDepth", default: 24), includeHidden: input.bool("includeHidden", default: false)) { full, _, isDir in
            if let pattern, !ToolSupport.glob(pattern, matches: (full as NSString).lastPathComponent) { return true }
            guard let content else {
                if matches.count >= maxResults { truncated = true; return false }
                matches.append(["path": .string(full), "type": isDir ? "directory" : "file"])
                return true
            }
            if isDir { return true }
            var st = stat()
            guard lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Int(st.st_size) <= maxFileBytes,
                  let data = fm.contents(atPath: full) else { return true }
            if data.prefix(8_192).contains(0) { return true }  // binary
            scanned += 1
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return true }
            var lineNumber = 0
            var stop = false
            text.enumerateLines { line, halt in
                lineNumber += 1
                let hit: Bool
                if let regex { hit = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
                else { hit = line.range(of: content, options: caseSensitive ? [] : [.caseInsensitive]) != nil }
                if hit {
                    if matches.count >= maxResults { truncated = true; stop = true; halt = true; return }
                    matches.append(["path": .string(full), "line": .int(lineNumber), "text": .string(String(line.prefix(300)))])
                }
            }
            return !stop
        }
        var result = ToolResult.success(["matches": .array(matches), "count": .int(matches.count), "truncated": .bool(truncated), "filesScanned": .int(scanned)],
                                        summary: "\(ToolSupport.plural(matches.count, "match", "matches")) under \(show(root))")
        result.truncated = truncated
        return result
    }
}

// MARK: - read

public struct FilesystemReadTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.read", name: "Read file",
        summary: "Reads a file as UTF-8 text (bounded by maxBytes from an offset), or as base64 when encoding is base64.",
        family: "filesystem",
        inputSchema: Schema.input([
            "path": Schema.path, "maxBytes": .integer("Default 100000.", minimum: 1, maximum: 5_000_000),
            "offset": .integer("Byte offset to start from.", minimum: 0),
            "encoding": .string("utf8 (default) or base64 for binary content.", enum: ["utf8", "base64"]),
        ], required: ["path"]),
        outputSchema: Schema.output(["path": .string(), "content": .string(), "encoding": .string(), "bytesRead": .integer(),
                                     "totalBytes": .integer(), "offset": .integer(), "truncated": .boolean()],
                                    required: ["path", "content", "encoding", "bytesRead", "totalBytes", "truncated"]),
        sideEffect: .read, defaultTier: .readOnly, maxOutputBytes: 8_000_000, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Read \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        try ToolSupport.requireFile(path)
        let maxBytes = input.int("maxBytes", default: 100_000), offset = input.int("offset", default: 0)
        let base64 = input.optionalString("encoding") == "base64"
        let total = ToolSupport.fileSize(path)
        guard let handle = FileHandle(forReadingAtPath: path) else { throw ToolError.io("Cannot open \(show(path))") }
        defer { try? handle.close() }
        var data = try ToolSupport.io("Reading \(show(path))") { () throws -> Data in
            try handle.seek(toOffset: UInt64(min(offset, total)))
            return try handle.read(upToCount: maxBytes) ?? Data()
        }
        let content: String
        if base64 { content = data.base64EncodedString() }
        else {
            // A bounded read may stop inside a multi-byte character: drop up to three trailing bytes.
            var text = String(data: data, encoding: .utf8)
            var dropped = 0
            while text == nil, dropped < 3, !data.isEmpty { data.removeLast(); dropped += 1; text = String(data: data, encoding: .utf8) }
            guard let text else {
                throw ToolError.unsupported("\(show(path)) is not UTF-8 text; call again with encoding: \"base64\" or use a documents.* tool")
            }
            content = text
        }
        let end = min(offset, total) + data.count
        let truncated = end < total
        var result = ToolResult.success([
            "path": .string(path), "content": .string(content), "encoding": .string(base64 ? "base64" : "utf8"),
            "bytesRead": .int(data.count), "totalBytes": .int(total), "offset": .int(min(offset, total)), "truncated": .bool(truncated),
        ], summary: "Read \(data.count) of \(total) bytes from \(show(path))")
        result.truncated = truncated
        return result
    }
}

// MARK: - write

public struct FilesystemWriteTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.write", name: "Write file",
        summary: "Creates a file, appends to it, or overwrites it when overwrite is true. An overwritten or appended file is first copied to the run's artifacts so the change can be undone.",
        family: "filesystem",
        inputSchema: Schema.input([
            "path": Schema.path, "content": .string("Text, or base64 when encoding is base64."),
            "mode": .string("create (default; fails if the file exists unless overwrite) or append.", enum: ["create", "overwrite", "append"]),
            "overwrite": .boolean("Required to replace an existing file."),
            "encoding": .string(enum: ["utf8", "base64"]), "createParents": .boolean("Create missing parent directories (default true)."),
        ], required: ["path", "content"]),
        outputSchema: Schema.output(["path": .string(), "bytesWritten": .integer(), "created": .boolean(), "backupPath": .any, "sha256": .string()],
                                    required: ["path", "bytesWritten", "created"]),
        sideEffect: .write, defaultTier: .reversibleWrite, supportsDryRun: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        let mode = input.optionalString("mode") ?? "create"
        if mode == "overwrite" && !input.bool("overwrite", default: false) {
            throw ToolError.invalidInput("mode overwrite needs overwrite: true")
        }
        if input.optionalString("encoding") == "base64", Data(base64Encoded: try input.string("content")) == nil {
            throw ToolError.invalidInput("content is not valid base64")
        }
        let verb = mode == "append" ? "Append to" : (input.bool("overwrite", default: false) ? "Write (replacing) " : "Create")
        return ToolRequirements(capabilities: [.fileWrite(path: path)], tier: .reversibleWrite,
                                summary: "\(verb) \(show(path)) (\(try input.string("content").utf8.count) bytes)")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        let mode = input.optionalString("mode") ?? "create"
        let overwrite = input.bool("overwrite", default: false)
        let raw = try input.string("content")
        let data = input.optionalString("encoding") == "base64" ? (Data(base64Encoded: raw) ?? Data()) : Data(raw.utf8)
        let existing = ToolSupport.kind(of: path)
        if existing.isDirectory { throw ToolError.invalidInput("\(show(path)) is a directory") }
        if existing.exists && mode != "append" && !overwrite {
            throw ToolError.invalidInput("\(show(path)) already exists; pass overwrite: true to replace it (a backup is kept) or mode: append")
        }
        let parent = (path as NSString).deletingLastPathComponent
        let createParents = input.bool("createParents", default: true)
        if !ToolSupport.kind(of: parent).exists && !createParents { throw ToolError.notFound("Parent directory does not exist: \(show(parent))") }
        if input.dryRun {
            return .simulated(["path": .string(path), "wouldCreate": .bool(!existing.exists), "wouldBackup": .bool(existing.exists),
                               "bytes": .int(data.count), "mode": .string(mode)],
                              summary: "Would \(existing.exists ? (mode == "append" ? "append to" : "replace") : "create") \(show(path)) (\(data.count) bytes)")
        }
        try ToolSupport.io("Creating \(show(parent))") { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        var backup: String?
        if existing.exists { backup = try ToolSupport.backup(path, context: context) }
        try ToolSupport.io("Writing \(show(path))") {
            if mode == "append", existing.exists {
                guard let handle = FileHandle(forWritingAtPath: path) else { throw ToolError.io("Cannot open \(show(path)) for appending") }
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        var output: [String: JSONValue] = ["path": .string(path), "bytesWritten": .int(data.count), "created": .bool(!existing.exists),
                                           "backupPath": backup.map(JSONValue.string) ?? .null]
        output["sha256"] = .string(try ToolSupport.sha256(path: path))
        var artifacts: [Artifact] = []
        if let backup { artifacts.append(ToolSupport.artifact(backup, kind: "file", note: "Backup of \(show(path)) before it was modified")) }
        return .success(.object(output), summary: "\(existing.exists ? (mode == "append" ? "Appended to" : "Replaced") : "Created") \(show(path))", artifacts: artifacts)
    }
}

// MARK: - mkdir

public struct FilesystemMkdirTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.mkdir", name: "Create directory",
        summary: "Creates a directory (and missing parents). Succeeds when the directory already exists.",
        family: "filesystem",
        inputSchema: Schema.input(["path": Schema.path, "createParents": .boolean("Default true.")], required: ["path"]),
        outputSchema: Schema.output(["path": .string(), "created": .boolean()], required: ["path", "created"]),
        sideEffect: .write, defaultTier: .reversibleWrite, supportsDryRun: true, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        return ToolRequirements(capabilities: [.fileWrite(path: path)], tier: .reversibleWrite, summary: "Create folder \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        let k = ToolSupport.kind(of: path)
        if k.exists && !k.isDirectory { throw ToolError.invalidInput("\(show(path)) exists and is not a directory") }
        if input.dryRun { return .simulated(["path": .string(path), "wouldCreate": .bool(!k.exists)], summary: "Would create folder \(show(path))") }
        if !k.exists {
            try ToolSupport.io("Creating \(show(path))") {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: input.bool("createParents", default: true))
            }
        }
        return .success(["path": .string(path), "created": .bool(!k.exists)], summary: k.exists ? "\(show(path)) already exists" : "Created folder \(show(path))")
    }
}

// MARK: - copy / move

public struct FilesystemCopyTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.copy", name: "Copy",
        summary: "Copies a file or a directory tree to a destination path. Refuses to replace an existing destination unless overwrite is true (files only; a backup is kept).",
        family: "filesystem",
        inputSchema: Schema.input(["source": Schema.path, "destination": .string("Full path of the copy."), "overwrite": .boolean()],
                                  required: ["source", "destination"]),
        outputSchema: Schema.output(["source": .string(), "destination": .string(), "backupPath": .any], required: ["source", "destination"]),
        sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 300, supportsDryRun: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let source = try input.path("source", context), destination = try input.path("destination", context)
        guard source != destination else { throw ToolError.invalidInput("source and destination are the same path") }
        guard !destination.hasPrefix(source + "/") else { throw ToolError.invalidInput("destination is inside source") }
        return ToolRequirements(capabilities: [.fileRead(path: source), .fileWrite(path: destination)], tier: .reversibleWrite,
                                summary: "Copy \(show(source)) to \(show(destination))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let source = try input.path("source", context), destination = try input.path("destination", context)
        try ToolSupport.requireExists(source)
        let dest = ToolSupport.kind(of: destination)
        if dest.exists {
            guard input.bool("overwrite", default: false) else {
                throw ToolError.invalidInput("\(show(destination)) already exists; pass overwrite: true to replace a file, or choose another destination")
            }
            guard !dest.isDirectory, !ToolSupport.kind(of: source).isDirectory else {
                throw ToolError.unsupported("Replacing a directory by copy is not supported; copy to a new path or trash the destination first")
            }
        }
        if input.dryRun {
            return .simulated(["source": .string(source), "destination": .string(destination), "wouldReplace": .bool(dest.exists)],
                              summary: "Would copy \(show(source)) to \(show(destination))")
        }
        var backup: String?
        try ToolSupport.io("Copying to \(show(destination))") {
            try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if dest.exists {
                backup = try ToolSupport.backup(destination, context: context)
                try fm.removeItem(atPath: destination)
            }
            try fm.copyItem(atPath: source, toPath: destination)
        }
        return .success(["source": .string(source), "destination": .string(destination), "backupPath": backup.map(JSONValue.string) ?? .null],
                        summary: "Copied \(show(source)) to \(show(destination))",
                        artifacts: backup.map { [ToolSupport.artifact($0, note: "Backup of \(show(destination)) before it was replaced")] } ?? [])
    }
}

public struct FilesystemMoveTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.move", name: "Move or rename",
        summary: "Moves or renames a file or directory. Never replaces an existing destination: the call fails instead.",
        family: "filesystem",
        inputSchema: Schema.input(["source": Schema.path, "destination": .string("Full new path.")], required: ["source", "destination"]),
        outputSchema: Schema.output(["source": .string(), "destination": .string()], required: ["source", "destination"]),
        sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 300, supportsDryRun: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let source = try input.path("source", context), destination = try input.path("destination", context)
        guard source != destination else { throw ToolError.invalidInput("source and destination are the same path") }
        guard !destination.hasPrefix(source + "/") else { throw ToolError.invalidInput("destination is inside source") }
        return ToolRequirements(capabilities: [.fileRead(path: source), .fileWrite(path: source), .fileWrite(path: destination)],
                                tier: .reversibleWrite, summary: "Move \(show(source)) to \(show(destination))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let source = try input.path("source", context), destination = try input.path("destination", context)
        try ToolSupport.requireExists(source)
        guard !ToolSupport.kind(of: destination).exists else {
            throw ToolError.invalidInput("\(show(destination)) already exists; move never replaces. Choose another destination.")
        }
        if input.dryRun {
            return .simulated(["source": .string(source), "destination": .string(destination)], summary: "Would move \(show(source)) to \(show(destination))")
        }
        try ToolSupport.io("Moving to \(show(destination))") {
            try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: source, toPath: destination)
        }
        return .success(["source": .string(source), "destination": .string(destination)], summary: "Moved \(show(source)) to \(show(destination))")
    }
}

// MARK: - metadata / checksum

public struct FilesystemMetadataTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.metadata", name: "File metadata",
        summary: "Returns type, size, dates, POSIX permissions, owner and content type of a file or directory.",
        family: "filesystem",
        inputSchema: Schema.input(["path": Schema.path], required: ["path"]),
        outputSchema: Schema.output(["path": .string(), "type": .string(), "size": .integer()], required: ["path", "type", "size"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Inspect \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        try ToolSupport.requireExists(path)
        let attrs = try ToolSupport.io("Inspecting \(show(path))") { try fm.attributesOfItem(atPath: path) }
        var out = entry(path)
        out["created"] = ToolSupport.iso(attrs[.creationDate] as? Date)
        out["permissions"] = .string(String(format: "%o", (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0))
        out["owner"] = .string(attrs[.ownerAccountName] as? String ?? "")
        out["readable"] = .bool(fm.isReadableFile(atPath: path))
        out["writable"] = .bool(fm.isWritableFile(atPath: path))
        out["hidden"] = .bool((path as NSString).lastPathComponent.hasPrefix("."))
        let ext = (path as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            out["contentType"] = .string(type.identifier)
            if let mime = type.preferredMIMEType { out["mimeType"] = .string(mime) }
        }
        if out["type"]?.stringValue == "directory" { out["childCount"] = .int((try? fm.contentsOfDirectory(atPath: path).count) ?? 0) }
        return .success(.object(out), summary: "\(show(path)): \(out["type"]?.stringValue ?? "item"), \(out["size"]?.intValue ?? 0) bytes")
    }
}

public struct FilesystemChecksumTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.checksum", name: "Checksum",
        summary: "Computes the SHA-256 digest of a file.",
        family: "filesystem",
        inputSchema: Schema.input(["path": Schema.path, "algorithm": .string(enum: ["sha256"])], required: ["path"]),
        outputSchema: Schema.output(["path": .string(), "algorithm": .string(), "digest": .string(), "bytes": .integer()],
                                    required: ["path", "algorithm", "digest", "bytes"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 300, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Compute the SHA-256 of \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        try ToolSupport.requireFile(path)
        let digest = try ToolSupport.sha256(path: path)
        return .success(["path": .string(path), "algorithm": "sha256", "digest": .string(digest), "bytes": .int(ToolSupport.fileSize(path))],
                        summary: "sha256 \(digest.prefix(16))… \(show(path))")
    }
}

// MARK: - compare

public struct FilesystemCompareTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.compare", name: "Compare",
        summary: "Compares two files (identical or not) or two directory trees (entries added, removed and changed in destination relative to source).",
        family: "filesystem",
        inputSchema: Schema.input(["source": Schema.path, "destination": Schema.path, "includeHidden": .boolean(),
                                   "limit": .integer("Maximum paths per list (default 500).", minimum: 1, maximum: 10_000)],
                                  required: ["source", "destination"]),
        outputSchema: Schema.output(["kind": .string(), "identical": .boolean()], required: ["kind", "identical"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 300, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let a = try input.path("source", context), b = try input.path("destination", context)
        return ToolRequirements(capabilities: [.fileRead(path: a), .fileRead(path: b)], tier: .readOnly, summary: "Compare \(show(a)) with \(show(b))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let a = try input.path("source", context), b = try input.path("destination", context)
        try ToolSupport.requireExists(a); try ToolSupport.requireExists(b)
        let ka = ToolSupport.kind(of: a), kb = ToolSupport.kind(of: b)
        guard ka.isDirectory == kb.isDirectory else { throw ToolError.invalidInput("cannot compare a file with a directory") }
        if !ka.isDirectory {
            let sa = ToolSupport.fileSize(a), sb = ToolSupport.fileSize(b)
            let ha = try ToolSupport.sha256(path: a), hb = try ToolSupport.sha256(path: b)
            return .success(["kind": "files", "identical": .bool(ha == hb), "sourceBytes": .int(sa), "destinationBytes": .int(sb),
                             "sourceSha256": .string(ha), "destinationSha256": .string(hb)],
                            summary: ha == hb ? "Files are identical" : "Files differ")
        }
        let hidden = input.bool("includeHidden", default: false), limit = input.int("limit", default: 500)
        func index(_ root: String) throws -> [String: (isDir: Bool, size: Int)] {
            var out: [String: (Bool, Int)] = [:]
            try walk(root, maxDepth: 64, includeHidden: hidden) { full, rel, isDir in
                out[rel] = (isDir, isDir ? 0 : ToolSupport.fileSize(full)); return true
            }
            return out
        }
        let ia = try index(a), ib = try index(b)
        var added: [String] = [], removed: [String] = [], changed: [String] = []
        for (rel, eb) in ib {
            guard let ea = ia[rel] else { added.append(rel); continue }
            if ea.isDir != eb.isDir { changed.append(rel); continue }
            if ea.isDir { continue }
            if ea.size != eb.size { changed.append(rel); continue }
            if try ToolSupport.sha256(path: a + "/" + rel) != ToolSupport.sha256(path: b + "/" + rel) { changed.append(rel) }
        }
        for rel in ia.keys where ib[rel] == nil { removed.append(rel) }
        let identical = added.isEmpty && removed.isEmpty && changed.isEmpty
        let cut = added.count > limit || removed.count > limit || changed.count > limit
        func list(_ l: [String]) -> JSONValue { .array(l.sorted().prefix(limit).map(JSONValue.string)) }
        var result = ToolResult.success([
            "kind": "directories", "identical": .bool(identical), "added": list(added), "removed": list(removed), "changed": list(changed),
            "addedCount": .int(added.count), "removedCount": .int(removed.count), "changedCount": .int(changed.count), "truncated": .bool(cut),
        ], summary: identical ? "Directory trees are identical" : "\(added.count) added, \(removed.count) removed, \(changed.count) changed")
        result.truncated = cut
        return result
    }
}

// MARK: - trash / delete

/// Paths no deletion tool accepts: the root, top-level system folders, the home folder itself and its standard folders.
private func refuseBroadDeletion(_ path: String) throws {
    let home = NSHomeDirectory()
    let parts = path.split(separator: "/")
    let standard = ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music", "Applications", "Public"].map { home + "/" + $0 }
    if path == "/" || parts.count < 2 || path == home || standard.contains(path) || path == "/Users" || path.hasPrefix("/Volumes") && parts.count <= 2 {
        throw ToolError.unsupported("Deleting \(show(path)) is not supported: the location is too broad")
    }
}

public struct FilesystemTrashTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.trash", name: "Move to Trash",
        summary: "Moves a file or directory to the Trash (recoverable) and returns where it now is.",
        family: "filesystem",
        inputSchema: Schema.input(["path": Schema.path], required: ["path"]),
        outputSchema: Schema.output(["path": .string(), "trashPath": .any], required: ["path"]),
        sideEffect: .write, defaultTier: .reversibleWrite, supportsDryRun: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        try refuseBroadDeletion(path)
        return ToolRequirements(capabilities: [.fileDelete(path: path)], tier: .reversibleWrite, summary: "Move \(show(path)) to the Trash")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        try ToolSupport.requireExists(path)
        if input.dryRun { return .simulated(["path": .string(path)], summary: "Would move \(show(path)) to the Trash") }
        var resulting: NSURL?
        try ToolSupport.io("Moving \(show(path)) to the Trash") {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        }
        let trashPath = (resulting as URL?)?.path
        return .success(["path": .string(path), "trashPath": trashPath.map(JSONValue.string) ?? .null],
                        summary: "Moved \(show(path)) to the Trash")
    }
}

public struct FilesystemDeleteTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.delete", name: "Delete permanently",
        summary: "Permanently deletes a file or directory. Irreversible: prefer filesystem.trash. A non-empty directory needs recursive: true.",
        family: "filesystem",
        inputSchema: Schema.input(["path": Schema.path, "recursive": .boolean("Required to delete a non-empty directory.")], required: ["path"]),
        outputSchema: Schema.output(["path": .string(), "deleted": .boolean(), "items": .integer()], required: ["path", "deleted"]),
        sideEffect: .destructive, defaultTier: .highRisk, defaultTimeoutSeconds: 300, supportsDryRun: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        try refuseBroadDeletion(path)
        return ToolRequirements(capabilities: [.fileDelete(path: path)], tier: .highRisk, summary: "Permanently delete \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ToolError.notFound("No such file or directory: \(show(path))") }
        var items = 1
        if (st.st_mode & S_IFMT) == S_IFDIR {
            try walk(path, maxDepth: 64, includeHidden: true) { _, _, _ in items += 1; return true }
            if items > 1 && !input.bool("recursive", default: false) {
                throw ToolError.invalidInput("\(show(path)) is a non-empty directory (\(items - 1) items); pass recursive: true to delete it")
            }
        }
        if input.dryRun { return .simulated(["path": .string(path), "items": .int(items)], summary: "Would permanently delete \(show(path)) (\(items) items)") }
        try ToolSupport.io("Deleting \(show(path))") { try fm.removeItem(atPath: path) }
        return .success(["path": .string(path), "deleted": true, "items": .int(items)], summary: "Permanently deleted \(show(path)) (\(items) items)")
    }
}
