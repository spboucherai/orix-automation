// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/Support.swift
// Description      : Shared helpers: typed failures, blocking-work bridge,
//                    bounded subprocess launcher (osascript, sdef), application
//                    resolution, schema and regex shortcuts.
// Module           : ORIXAppleAutomation
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

import AppKit
import Foundation
import ORIXCore

// MARK: Typed failures

/// A failure with a code outside `ToolError`'s fixed set (`focus_changed`, `syntax_error`, `app_not_running` …).
/// Tools convert it into a structured `ToolResult` instead of throwing it to the executor.
struct TypedFailure: Error {
    var status: ToolStatus = .failed
    var code: String
    var message: String
    var recovery: String?
    var retryable = false
    var output: JSONValue = .null

    var result: ToolResult {
        ToolResult(status: status, output: output, summary: message,
                   failure: ToolFailure(code: code, message: message, recovery: recovery, retryable: retryable))
    }
}

/// Runs `body`, turning a `TypedFailure` into its `ToolResult`. `ToolError` keeps propagating to the executor.
func catchingTypedFailures(_ body: () async throws -> ToolResult) async throws -> ToolResult {
    do { return try await body() } catch let f as TypedFailure { return f.result }
}

/// Runs synchronous, possibly slow work (Accessibility IPC, Vision, pixel loops) off the cooperative pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

// MARK: Schema / argument shortcuts

func outputObject(_ properties: [String: JSONSchema], required: [String] = []) -> JSONSchema {
    .object(properties, required: required, additional: true)
}

let bundleIDSchema = JSONSchema.string("Application bundle identifier, for example com.apple.finder.")

extension ToolInput {
    /// The call's own timeout bounded by what the executor allows.
    func timeout(default d: Double, context: ToolExecutionContext) -> Double {
        max(0.1, min(double("timeoutSeconds", default: d), context.timeoutSeconds))
    }

    func nonEmptyString(_ key: String) throws -> String {
        let s = try string(key)
        guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.invalidInput("\(key) is empty") }
        return s
    }

    /// A validated, canonical bundle identifier from `key`.
    func bundleID(_ key: String = "bundleID") throws -> String {
        try AppResolver.validatedBundleID(try string(key))
    }
}

func rectJSON(_ r: CGRect) -> JSONValue {
    ["x": .number(Double(r.origin.x)), "y": .number(Double(r.origin.y)),
     "width": .number(Double(r.size.width)), "height": .number(Double(r.size.height))]
}

func regexGroups(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [[String?]] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }
}

func regexFound(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
    !regexGroups(pattern, in: text, options: options).isEmpty
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func mutate<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

// MARK: Application resolution

/// Resolves application names, paths and bundle identifiers without launching anything.
public enum AppResolver {
    static let searchDirectories: [String] = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
        NSHomeDirectory() + "/Applications", "/System/Library/CoreServices", "/System/Library/CoreServices/Applications",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
    ]

    public static func isValidBundleID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._\-]{0,254}$"#, options: .regularExpression) != nil
    }

    /// Checks the syntax and returns the identifier spelled as the installed bundle declares it (case matters for grants).
    public static func validatedBundleID(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidBundleID(id) else { throw ToolError.invalidInput("\"\(raw)\" is not a valid bundle identifier") }
        return canonicalBundleID(id)
    }

    public static func canonicalBundleID(_ id: String) -> String {
        if let url = url(forBundleID: id), let real = Bundle(url: url)?.bundleIdentifier, real.lowercased() == id.lowercased() { return real }
        if let running = running(id).first?.bundleIdentifier { return running }
        return id
    }

    public static func url(forBundleID id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    public static func bundleID(forAppAt path: String) -> String? {
        Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
    }

    /// Application bundle on disk for a name such as `Finder`, `System Events` or `Safari.app`.
    public static func url(forName name: String) -> URL? {
        let base = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        guard !base.isEmpty, !base.contains("/") else { return nil }
        let fm = FileManager.default
        for dir in searchDirectories {
            let candidate = dir + "/" + base + ".app"
            if fm.fileExists(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        // Case-insensitive pass, then running applications (apps living elsewhere).
        for dir in searchDirectories {
            if let hit = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.lowercased() == base.lowercased() + ".app" }) {
                return URL(fileURLWithPath: dir + "/" + hit)
            }
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.lowercased() == base.lowercased()
                || $0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == base.lowercased()
        }?.bundleURL
    }

    public static func bundleID(forName name: String) -> String? {
        url(forName: name).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Resolves what a script may pass to `application "…"` / `Application("…")`: a path, a bundle identifier or a name.
    public static func bundleID(forReference reference: String) -> String? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return nil }
        if ref.hasPrefix("/") || ref.hasPrefix("~") {
            let path = ref.hasPrefix("~") ? NSHomeDirectory() + ref.dropFirst(1) : ref
            return bundleID(forAppAt: path)
        }
        if let byName = bundleID(forName: ref) { return byName }
        if isValidBundleID(ref), ref.contains("."), url(forBundleID: ref) != nil { return canonicalBundleID(ref) }
        return nil
    }

    /// Running instances of an application. The Launch Services lookup occasionally answers "none" for a running
    /// application while another one is launching or quitting (observed on macOS 27), so an empty answer is
    /// cross-checked against the workspace list and retried briefly before it is believed.
    static func running(_ bundleID: String) -> [NSRunningApplication] {
        for attempt in 0..<3 {
            var apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
            if apps.isEmpty {
                apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.lowercased() == bundleID.lowercased() && !$0.isTerminated }
            }
            if !apps.isEmpty { return apps }
            if attempt < 2 { usleep(25_000) }
        }
        return []
    }

    static func displayName(_ bundleID: String) -> String {
        if let n = running(bundleID).first?.localizedName { return n }
        if let u = url(forBundleID: bundleID) { return u.deletingPathExtension().lastPathComponent }
        return bundleID
    }
}

// MARK: Subprocess

struct SubprocessOutput: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
    var truncated: Bool
}

/// Minimal launcher for the two system binaries this package needs. Explicit argv (no shell), minimal environment,
/// bounded capture, timeout, SIGTERM then SIGKILL on timeout or task cancellation.
enum Subprocess {
    static let environment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": NSHomeDirectory(),
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "TMPDIR": NSTemporaryDirectory(),
    ]

    private final class Handle: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var launched = false
        private(set) var canceled = false
        private(set) var timedOut = false
        private var out = Data(), err = Data()
        private var truncated = false

        func markLaunched() -> Bool { lock.lock(); defer { lock.unlock() }; launched = true; return !canceled }
        func snapshot() -> (Data, Data, Bool, Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (out, err, truncated, canceled, timedOut) }

        func append(_ data: Data, toStdout: Bool, limit: Int) {
            lock.lock(); defer { lock.unlock() }
            if toStdout {
                let room = limit - out.count
                if data.count > room { truncated = true }
                if room > 0 { out.append(data.prefix(room)) }
            } else {
                let room = 65_536 - err.count
                if room > 0 { err.append(data.prefix(room)) }
            }
        }

        func stop(timeout: Bool) {
            lock.lock()
            if timeout { timedOut = true } else { canceled = true }
            let running = launched && process.isRunning
            lock.unlock()
            guard running else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil, timeout: Double,
                    maxOutputBytes: Int = 1_048_576) async throws -> SubprocessOutput {
        let handle = Handle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SubprocessOutput, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runSync(handle, executable, arguments, stdin: stdin, timeout: timeout, maxOutputBytes: maxOutputBytes)
                    })
                }
            }
        } onCancel: {
            handle.stop(timeout: false)
        }
    }

    private static func runSync(_ handle: Handle, _ executable: String, _ arguments: [String], stdin: Data?, timeout: Double,
                                maxOutputBytes: Int) throws -> SubprocessOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw ToolError.unsupported("\(executable) is not available on this Mac") }
        let process = handle.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        let eof = DispatchSemaphore(value: 0)
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            pipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    eof.signal()
                } else {
                    handle.append(data, toStdout: isOut, limit: maxOutputBytes)
                }
            }
        }

        do { try process.run() } catch { throw ToolError.io("Could not start \(executable): \(error.localizedDescription)") }
        if !handle.markLaunched() { handle.stop(timeout: false) }

        let timer = DispatchWorkItem { handle.stop(timeout: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        let writer = inPipe.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global().async {
            if let stdin, !stdin.isEmpty { try? writer.write(contentsOf: stdin) }
            try? writer.close()
        }

        process.waitUntilExit()
        timer.cancel()
        // A grandchild may still hold the pipes open: do not wait for EOF forever.
        let deadline = DispatchTime.now() + 2
        if eof.wait(timeout: deadline) == .timedOut || eof.wait(timeout: deadline) == .timedOut {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }
        let (out, err, truncated, canceled, timedOut) = handle.snapshot()
        if canceled { throw ToolError.canceled }
        return SubprocessOutput(exitCode: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut, truncated: truncated)
    }
}
