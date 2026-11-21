// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/ArchiveAndWatchTools.swift
// Description      : filesystem.archive (zip through ditto),
//                    filesystem.unarchive (zip-slip safe, staged extraction)
//                    and filesystem.waitForChange (FSEvents / vnode source with
//                    a timeout).
// Module           : ORIXToolRegistry
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
import CoreServices
import ORIXCore

private var fm: FileManager { FileManager.default }
private func show(_ path: String) -> String { PathResolver.display(path) }

// MARK: - archive

public struct FilesystemArchiveTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.archive", name: "Create zip archive",
        summary: "Compresses a file or a directory into a .zip archive. Refuses to replace an existing archive unless overwrite is true.",
        family: "filesystem",
        inputSchema: Schema.input(["source": Schema.path, "destination": .string("Path of the .zip to create."),
                                   "keepParent": .boolean("For a directory: store it as the top-level folder of the archive (default true)."),
                                   "overwrite": .boolean()], required: ["source", "destination"]),
        outputSchema: Schema.output(["destination": .string(), "bytes": .integer(), "sha256": .string()], required: ["destination", "bytes"]),
        sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 600, supportsDryRun: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let source = try input.path("source", context), destination = try input.path("destination", context)
        guard destination.lowercased().hasSuffix(".zip") else { throw ToolError.invalidInput("destination must end with .zip") }
        guard destination != source, !destination.hasPrefix(source + "/") else { throw ToolError.invalidInput("destination must be outside source") }
        return ToolRequirements(capabilities: [.fileRead(path: source), .fileWrite(path: destination)], tier: .reversibleWrite,
                                summary: "Archive \(show(source)) into \(show(destination))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let source = try input.path("source", context), destination = try input.path("destination", context)
        try ToolSupport.requireExists(source)
        let existing = ToolSupport.kind(of: destination)
        if existing.exists && !input.bool("overwrite", default: false) {
            throw ToolError.invalidInput("\(show(destination)) already exists; pass overwrite: true (a backup is kept) or choose another name")
        }
        if existing.isDirectory { throw ToolError.invalidInput("\(show(destination)) is a directory") }
        if input.dryRun {
            return .simulated(["source": .string(source), "destination": .string(destination), "wouldReplace": .bool(existing.exists)],
                              summary: "Would archive \(show(source)) into \(show(destination))")
        }
        let parent = (destination as NSString).deletingLastPathComponent
        try ToolSupport.io("Creating \(show(parent))") { try fm.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        var backup: String?
        if existing.exists { backup = try ToolSupport.backup(destination, context: context) }
        // Build next to the destination, then rename: a failed run never leaves a half-written archive in place.
        let staging = parent + "/.orix-archive-" + UUID().uuidString.prefix(8) + ".zip"
        defer { try? fm.removeItem(atPath: staging) }
        var args = ["-c", "-k", "--sequesterRsrc"]
        if ToolSupport.kind(of: source).isDirectory && input.bool("keepParent", default: true) { args.append("--keepParent") }
        args += [source, staging]
        let out = try await ToolSupport.run(ProcessSpec(executable: "/usr/bin/ditto", arguments: args, environment: ["LC_ALL": "C"],
                                                        workingDirectory: parent, timeoutSeconds: context.timeoutSeconds,
                                                        confinement: ToolSupport.profile(context, extraWrite: [parent], network: false)), context: context)
        try out.requireSuccess(timeoutSeconds: context.timeoutSeconds)
        try ToolSupport.io("Finishing \(show(destination))") {
            if existing.exists { try fm.removeItem(atPath: destination) }
            try fm.moveItem(atPath: staging, toPath: destination)
        }
        return .success(["destination": .string(destination), "bytes": .int(ToolSupport.fileSize(destination)),
                         "sha256": .string(try ToolSupport.sha256(path: destination)), "backupPath": backup.map(JSONValue.string) ?? .null],
                        summary: "Archived \(show(source)) into \(show(destination))")
    }
}

// MARK: - unarchive

public struct FilesystemUnarchiveTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.unarchive", name: "Extract zip archive",
        summary: "Extracts a .zip archive into a directory. Archives whose entries would land outside the destination (zip-slip) are refused, and existing files are never replaced.",
        family: "filesystem",
        inputSchema: Schema.input(["source": Schema.path, "destination": .string("Directory to extract into (created if missing).")],
                                  required: ["source", "destination"]),
        outputSchema: Schema.output(["destination": .string(), "entries": .array(of: .string()), "count": .integer()], required: ["destination", "count"]),
        sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 600, supportsDryRun: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let source = try input.path("source", context), destination = try input.path("destination", context)
        return ToolRequirements(capabilities: [.fileRead(path: source), .fileWrite(path: destination)], tier: .reversibleWrite,
                                summary: "Extract \(show(source)) into \(show(destination))")
    }

    /// Entry names as stored in the archive.
    static func listEntries(_ archive: String, context: ToolExecutionContext) async throws -> [String] {
        let out = try await ToolSupport.run(ProcessSpec(executable: "/usr/bin/zipinfo", arguments: ["-1", archive], environment: ["LC_ALL": "C"],
                                                        workingDirectory: (archive as NSString).deletingLastPathComponent,
                                                        timeoutSeconds: context.timeoutSeconds, maxOutputBytes: 16_000_000,
                                                        confinement: ToolSupport.profile(context, network: false)), context: context)
        // zipinfo exits 1 for an empty archive and >1 for unreadable ones.
        guard out.exitCode == 0 || (out.exitCode == 1 && out.stdout.isEmpty) else {
            throw ToolError.unsupported("\(show(archive)) is not a readable zip archive")
        }
        if out.stdoutTruncated { throw ToolError.unsupported("The archive lists too many entries to verify safely") }
        return out.stdoutText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// True when a stored entry name would leave the extraction root.
    static func escapes(_ name: String) -> Bool {
        if name.hasPrefix("/") || name.hasPrefix("~") || name.contains("\\") { return true }
        var depth = 0
        for part in name.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." { depth -= 1; if depth < 0 { return true } }
            else if part != "." { depth += 1 }
        }
        return name.split(separator: "/").contains("..")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let source = try input.path("source", context), destination = try input.path("destination", context)
        try ToolSupport.requireFile(source)
        let destKind = ToolSupport.kind(of: destination)
        if destKind.exists && !destKind.isDirectory { throw ToolError.invalidInput("\(show(destination)) is not a directory") }

        // 1. Refuse on the stored names before anything is extracted.
        let names = try await Self.listEntries(source, context: context)
        if let bad = names.first(where: Self.escapes) {
            throw ToolError.permissionDenied("The archive contains an entry that escapes the destination (\(bad.prefix(120))); nothing was extracted")
        }
        if input.dryRun {
            return .simulated(["destination": .string(destination), "entries": .array(names.prefix(500).map(JSONValue.string)), "count": .int(names.count)],
                              summary: "Would extract \(ToolSupport.plural(names.count, "entry", "entries")) into \(show(destination))")
        }

        // 2. Extract into a private staging directory, confined so that even a parser disagreement cannot write elsewhere.
        let staging = PathResolver.resolveSymlinks(NSTemporaryDirectory()) + "/orix-unarchive-" + UUID().uuidString.prefix(12)
        try ToolSupport.io("Creating the staging directory") { try fm.createDirectory(atPath: staging, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(atPath: staging) }
        let out = try await ToolSupport.run(ProcessSpec(executable: "/usr/bin/ditto", arguments: ["-x", "-k", source, staging], environment: ["LC_ALL": "C"],
                                                        workingDirectory: staging, timeoutSeconds: context.timeoutSeconds,
                                                        confinement: SeatbeltProfile(writeRoots: [staging], allowsNetwork: false)), context: context)
        try out.requireSuccess(timeoutSeconds: context.timeoutSeconds)

        // 3. Verify what actually landed: every entry, and every symlink target, stays inside the staging root.
        var extracted: [String] = []
        guard let walker = fm.enumerator(atPath: staging) else { throw ToolError.io("Cannot read the extracted files") }
        while let rel = walker.nextObject() as? String {
            try Task.checkCancellation()
            let full = staging + "/" + rel
            if let target = try? fm.destinationOfSymbolicLink(atPath: full) {
                let base = (full as NSString).deletingLastPathComponent
                let lexical = ToolSupport.lexical(target.hasPrefix("/") ? target : base + "/" + target)
                guard lexical == staging || lexical.hasPrefix(staging + "/") else {
                    throw ToolError.permissionDenied("The archive contains a symbolic link pointing outside the destination (\(rel.prefix(120))); nothing was extracted")
                }
            }
            let real = PathResolver.resolveSymlinks(full)
            guard real == staging || real.hasPrefix(staging + "/") else {
                throw ToolError.permissionDenied("The archive contains an entry that resolves outside the destination (\(rel.prefix(120))); nothing was extracted")
            }
            extracted.append(rel)
        }

        // 4. Move the top-level items in; never replace anything.
        let top = try ToolSupport.io("Reading the extracted files") { try fm.contentsOfDirectory(atPath: staging) }.filter { $0 != "__MACOSX" }
        let conflicts = top.filter { fm.fileExists(atPath: destination + "/" + $0) }
        guard conflicts.isEmpty else {
            throw ToolError.invalidInput("Extraction would replace existing items in \(show(destination)): \(conflicts.prefix(10).joined(separator: ", ")). Choose an empty destination.")
        }
        try ToolSupport.io("Moving extracted files into \(show(destination))") {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
            for name in top { try fm.moveItem(atPath: staging + "/" + name, toPath: destination + "/" + name) }
        }
        let listed = extracted.filter { !$0.hasPrefix("__MACOSX") }
        return .success(["destination": .string(destination), "entries": .array(listed.prefix(1_000).map(JSONValue.string)), "count": .int(listed.count)],
                        summary: "Extracted \(ToolSupport.plural(listed.count, "entry", "entries")) into \(show(destination))")
    }
}

// MARK: - waitForChange

public struct FilesystemWaitForChangeTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "filesystem.waitForChange", name: "Wait for a file change",
        summary: "Waits until a file or anything inside a directory changes, or until the timeout. Returns the changed paths; a timeout is a normal result with changed: false.",
        family: "filesystem",
        inputSchema: Schema.input(["path": Schema.path, "timeoutSeconds": JSONSchema(raw: ["type": "number", "minimum": 0.1, "maximum": 3_000])],
                                  required: ["path"]),
        outputSchema: Schema.output(["changed": .boolean(), "timedOut": .boolean(), "events": .array(of: .any)], required: ["changed", "timedOut", "events"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 3_060, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Watch \(show(path)) for changes")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        try ToolSupport.requireExists(path)
        // Stop shortly before the executor's own deadline so a quiet period is a result, not a failure.
        let margin = min(1, context.timeoutSeconds * 0.2)
        let wait = min(input.double("timeoutSeconds", default: 30), max(0.05, context.timeoutSeconds - margin))
        let watcher = ChangeWatcher()
        let events: [ChangeWatcher.Event] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                watcher.start(path: path, isDirectory: ToolSupport.kind(of: path).isDirectory, timeout: wait, continuation: cont)
            }
        } onCancel: { watcher.cancel() }
        let changed = !events.isEmpty
        return .success(["changed": .bool(changed), "timedOut": .bool(!changed),
                         "events": .array(events.prefix(200).map { ["path": .string($0.path), "change": .string($0.change)] })],
                        summary: changed ? "\(ToolSupport.plural(events.count, "change")) in \(show(path))" : "No change in \(show(path)) within \(Int(wait)) s")
    }
}

/// One-shot watcher: FSEvents (recursive, per-file) for directories, a vnode dispatch source for single files.
final class ChangeWatcher: @unchecked Sendable {
    struct Event: Sendable { let path: String; let change: String }

    private let queue = DispatchQueue(label: "ai.orix.tools.watch")
    private var continuation: CheckedContinuation<[Event], Error>?
    private var stream: FSEventStreamRef?
    private var source: DispatchSourceFileSystemObject?
    private var collected: [Event] = []
    private var settle: DispatchWorkItem?

    func start(path: String, isDirectory: Bool, timeout: Double, continuation: CheckedContinuation<[Event], Error>) {
        queue.async { [self] in
            self.continuation = continuation
            if isDirectory { startStream(path) } else { startSource(path) }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(.success(collected)) }
        }
    }

    func cancel() { queue.async { [self] in finish(.failure(ToolError.canceled)) } }

    private func finish(_ result: Result<[Event], Error>) {
        guard let c = continuation else { return }
        continuation = nil
        settle?.cancel()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        source?.cancel(); source = nil
        c.resume(with: result)
    }

    /// Collects the events of one burst (200 ms of quiet) before answering.
    private func record(_ events: [Event]) {
        guard continuation != nil else { return }
        collected.append(contentsOf: events)
        settle?.cancel()
        let item = DispatchWorkItem { [self] in finish(.success(collected)) }
        settle = item
        queue.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func startSource(_ path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { finish(.failure(ToolError.io("Cannot watch \(path): \(String(cString: strerror(errno)))"))); return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke], queue: queue)
        s.setEventHandler { [self] in
            let flags = s.data
            var names: [String] = []
            if flags.contains(.delete) { names.append("deleted") }
            if flags.contains(.rename) { names.append("renamed") }
            if flags.contains(.write) || flags.contains(.extend) { names.append("modified") }
            if flags.contains(.attrib) { names.append("attributes") }
            record([Event(path: path, change: names.isEmpty ? "changed" : names.joined(separator: ","))])
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    private func startStream(_ path: String) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var events: [Event] = []
            for i in 0..<min(count, list.count) {
                let f = Int(flags[i])
                var names: [String] = []
                if f & kFSEventStreamEventFlagItemCreated != 0 { names.append("created") }
                if f & kFSEventStreamEventFlagItemRemoved != 0 { names.append("removed") }
                if f & kFSEventStreamEventFlagItemRenamed != 0 { names.append("renamed") }
                if f & kFSEventStreamEventFlagItemModified != 0 { names.append("modified") }
                if f & (kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemChangeOwner) != 0 { names.append("attributes") }
                events.append(Event(path: list[i], change: names.isEmpty ? "changed" : names.joined(separator: ",")))
            }
            watcher.record(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else {
            finish(.failure(ToolError.io("Cannot watch \(path)"))); return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            finish(.failure(ToolError.io("Cannot start watching \(path)"))); return
        }
        stream = s
    }
}
