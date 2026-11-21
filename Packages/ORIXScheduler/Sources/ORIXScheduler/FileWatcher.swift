// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXScheduler/Sources/ORIXScheduler/FileWatcher.swift
// Description      : FSEvents-based file and directory watcher with recursion
//                    control, glob filtering and debounced, coalesced change
//                    reports.
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

import CoreServices
import Foundation

public enum FileWatcherError: Error, Sendable, Hashable, LocalizedError {
    case pathNotFound(String)
    case streamCreationFailed(String)
    case alreadyStarted

    public var errorDescription: String? {
        switch self {
        case .pathNotFound(let p): return "Cannot watch \(p): it does not exist."
        case .streamCreationFailed(let p): return "FSEvents refused to watch \(p)."
        case .alreadyStarted: return "The watcher is already running."
        }
    }
}

/// Watches a directory (or a single file) with FSEvents and reports changed paths.
///
/// - `recursive: false` reports only direct children of the watched directory.
/// - `glob` is an `fnmatch` pattern. Without a `/` it is matched against the file name (`*.pdf`); with a `/` it is
///   matched against the path relative to the watched directory (`reports/*.csv`).
/// - Changes are coalesced: the handler is called once, `debounceSeconds` after the last change of a burst (and at the
///   latest `maxLatencySeconds` after the first one), with every distinct path of the burst, sorted.
/// - Paths are canonical (symlinks resolved), as FSEvents reports them.
///
/// The watcher sees creations, modifications, renames and deletions made after `start()` returns. It does not say which
/// kind of change happened to which path: callers stat the paths.
public final class FileWatcher: @unchecked Sendable {
    public struct Event: Sendable, Hashable {
        /// Distinct changed paths, sorted.
        public var paths: [String]
        /// When the handler was called.
        public var date: Date
        public init(paths: [String], date: Date) { self.paths = paths; self.date = date }
    }

    /// The canonical watched path.
    public let path: String
    public let recursive: Bool
    public let glob: String?
    public let debounceSeconds: Double
    public let maxLatencySeconds: Double

    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "ai.orix.scheduler.filewatcher")
    private let isDirectory: Bool
    private let streamRoot: String
    // Touched on `queue` only.
    private var stream: FSEventStreamRef?
    private var retainedSelf: Unmanaged<FileWatcher>?
    private var pending: Set<String> = []
    private var firstPendingAt: Date?
    private var flushWork: DispatchWorkItem?

    public init(path: String, recursive: Bool = true, glob: String? = nil, debounceSeconds: Double = 0.5,
                maxLatencySeconds: Double? = nil, handler: @escaping @Sendable (Event) -> Void) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard let real = realpath(expanded, nil) else { throw FileWatcherError.pathNotFound(path) }
        self.path = String(cString: real)
        free(real)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: self.path, isDirectory: &isDir)
        isDirectory = isDir.boolValue
        streamRoot = isDir.boolValue ? self.path : (self.path as NSString).deletingLastPathComponent
        self.recursive = recursive
        self.glob = (glob?.isEmpty ?? true) ? nil : glob
        self.debounceSeconds = max(0, debounceSeconds)
        self.maxLatencySeconds = maxLatencySeconds ?? max(2, self.debounceSeconds * 10)
        self.handler = handler
    }

    /// Starts watching. Changes made before this returns are not reported. A started watcher keeps itself alive until
    /// `stop()` is called.
    public func start() throws {
        try queue.sync {
            guard stream == nil else { throw FileWatcherError.alreadyStarted }
            let retained = Unmanaged.passRetained(self)
            var context = FSEventStreamContext(version: 0, info: retained.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []
                var flags: [UInt32] = []
                for i in 0..<count { flags.append(eventFlags[i]) }
                watcher.received(paths: paths, flags: flags)
            }
            guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [streamRoot] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else {
                retained.release()
                throw FileWatcherError.streamCreationFailed(path)
            }
            FSEventStreamSetDispatchQueue(s, queue)
            guard FSEventStreamStart(s) else {
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                retained.release()
                throw FileWatcherError.streamCreationFailed(path)
            }
            stream = s
            retainedSelf = retained
        }
    }

    /// Stops watching. Pending, not yet reported changes are dropped. Safe to call more than once.
    public func stop() {
        queue.sync {
            guard let s = stream else { return }
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
            flushWork?.cancel()
            flushWork = nil
            pending = []
            firstPendingAt = nil
            retainedSelf?.release()
            retainedSelf = nil
        }
    }

    public var isRunning: Bool { queue.sync { stream != nil } }

    /// True when `candidate` (a canonical path) passes the recursion and glob filters. Exposed for tests.
    public func accepts(_ candidate: String) -> Bool {
        if !isDirectory { return candidate == path }
        guard candidate != path, candidate.hasPrefix(path + "/") else { return false }
        let relative = String(candidate.dropFirst(path.count + 1))
        if !recursive && relative.contains("/") { return false }
        guard let glob else { return true }
        let subject = glob.contains("/") ? relative : (relative as NSString).lastPathComponent
        return fnmatch(glob, subject, 0) == 0
    }

    // Called on `queue`.
    private func received(paths: [String], flags: [UInt32]) {
        var changed = false
        for (index, raw) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let candidate = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if accepts(candidate), pending.insert(candidate).inserted { changed = true }
            else if pending.contains(candidate) { changed = true }
        }
        guard changed else { return }
        let now = Date()
        if firstPendingAt == nil { firstPendingAt = now }
        flushWork?.cancel()
        let sinceFirst = now.timeIntervalSince(firstPendingAt ?? now)
        let delay = max(0, min(debounceSeconds, maxLatencySeconds - sinceFirst))
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Called on `queue`.
    private func flush() {
        guard stream != nil, !pending.isEmpty else { return }
        let event = Event(paths: pending.sorted(), date: Date())
        pending = []
        firstPendingAt = nil
        flushWork = nil
        handler(event)
    }
}
