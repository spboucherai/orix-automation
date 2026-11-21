// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXCore/Sources/ORIXCore/Tools.swift
// Description      : The tool contract: manifest, input, execution context,
//                    result, typed errors, and the invoker protocol the agent
//                    and workflow engines call.
// Module           : ORIXCore
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

public enum ToolConcurrency: String, Codable, Sendable {
    /// Any number of calls at once.
    case unlimited
    /// One call of this tool at a time.
    case serial
    /// Nothing else that is `exclusive` runs at the same time (GUI control: one pointer, one focus).
    case exclusive
}

public struct ToolManifest: Codable, Sendable, Hashable {
    public var identifier: String
    public var name: String
    public var version: String
    /// Shown to the model and in the UI.
    public var summary: String
    /// `filesystem`, `shell`, `applescript`, `accessibility`, `screen`, `browser`, `python`, `script`, `documents`, `git`, `system`, `http`, `notifications`, `skill`.
    public var family: String
    public var inputSchema: JSONSchema
    public var outputSchema: JSONSchema
    public var sideEffect: SideEffect
    /// Tier when the call's own requirements do not say otherwise.
    public var defaultTier: ApprovalTier
    public var macPermissions: [MacPermission]
    public var defaultTimeoutSeconds: Double
    public var maxOutputBytes: Int
    public var concurrency: ToolConcurrency
    public var supportsDryRun: Bool
    /// True when repeating the call with the same input cannot cause additional effects.
    public var idempotent: Bool
    /// Top-level input keys whose values are replaced by `«redacted»` in logs, events and approval previews.
    public var redactedInputKeys: [String]
    /// True when the output carries content from outside the user's authority (web pages, files, app text): data, never instructions.
    public var outputIsUntrusted: Bool
    public var examples: [JSONValue]

    public init(identifier: String, name: String, version: String = "1.0.0", summary: String, family: String,
                inputSchema: JSONSchema, outputSchema: JSONSchema = .any, sideEffect: SideEffect, defaultTier: ApprovalTier,
                macPermissions: [MacPermission] = [], defaultTimeoutSeconds: Double = 30, maxOutputBytes: Int = 262_144,
                concurrency: ToolConcurrency = .unlimited, supportsDryRun: Bool = false, idempotent: Bool = false,
                redactedInputKeys: [String] = [], outputIsUntrusted: Bool = false, examples: [JSONValue] = []) {
        self.identifier = identifier; self.name = name; self.version = version; self.summary = summary; self.family = family
        self.inputSchema = inputSchema; self.outputSchema = outputSchema; self.sideEffect = sideEffect; self.defaultTier = defaultTier
        self.macPermissions = macPermissions; self.defaultTimeoutSeconds = defaultTimeoutSeconds; self.maxOutputBytes = maxOutputBytes
        self.concurrency = concurrency; self.supportsDryRun = supportsDryRun; self.idempotent = idempotent
        self.redactedInputKeys = redactedInputKeys; self.outputIsUntrusted = outputIsUntrusted; self.examples = examples
    }

    /// Structural problems that make a manifest unusable. Empty means valid.
    public func problems() -> [String] {
        var out: [String] = []
        let idOK = identifier.range(of: #"^[a-z][a-z0-9]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$"#, options: .regularExpression) != nil
        if !idOK { out.append("identifier must look like family.action (got \(identifier))") }
        if name.isEmpty { out.append("name is empty") }
        if summary.count < 10 { out.append("summary is too short to guide a model") }
        if inputSchema.raw["type"]?.stringValue != "object" { out.append("inputSchema must be an object schema") }
        if defaultTimeoutSeconds <= 0 || defaultTimeoutSeconds > 3600 { out.append("defaultTimeoutSeconds must be in (0, 3600]") }
        if maxOutputBytes <= 0 { out.append("maxOutputBytes must be positive") }
        if sideEffect == .read && defaultTier > .readOnly { out.append("a read tool cannot default above tier 0") }
        if sideEffect >= .destructive && defaultTier < .consequential { out.append("destructive/privileged tools must default to tier 2 or 3") }
        if sideEffect != .read && idempotent == false && supportsDryRun == false && defaultTier == .readOnly {
            out.append("a side-effecting tool cannot be tier 0")
        }
        return out
    }
}

public struct ToolInput: Sendable, Hashable {
    public var arguments: JSONValue
    public var dryRun: Bool
    public var idempotencyKey: String?

    public init(arguments: JSONValue, dryRun: Bool = false, idempotencyKey: String? = nil) {
        self.arguments = arguments; self.dryRun = dryRun; self.idempotencyKey = idempotencyKey
    }

    public func string(_ key: String) throws -> String {
        guard let s = arguments[key]?.stringValue else { throw ToolError.invalidInput("\(key) must be a string") }
        return s
    }
    public func optionalString(_ key: String) -> String? { arguments[key]?.stringValue }
    public func int(_ key: String, default d: Int) -> Int { arguments[key]?.intValue ?? d }
    public func double(_ key: String, default d: Double) -> Double { arguments[key]?.doubleValue ?? d }
    public func bool(_ key: String, default d: Bool) -> Bool { arguments[key]?.boolValue ?? d }
    public func strings(_ key: String) -> [String] { arguments[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
}

/// What one concrete call needs, computed by the tool from validated arguments before anything runs.
public struct ToolRequirements: Sendable, Hashable {
    public var capabilities: [Capability]
    public var tier: ApprovalTier
    /// One sentence for the approval sheet, for example `Move 14 files from ~/Downloads to ~/Downloads/Sorted`.
    public var summary: String

    public init(capabilities: [Capability], tier: ApprovalTier, summary: String) {
        self.capabilities = capabilities; self.tier = tier; self.summary = summary
    }
}

public struct ToolProgress: Sendable, Hashable {
    public enum Stream: String, Sendable, Codable { case stdout, stderr, status }
    public var stream: Stream
    public var text: String
    public init(stream: Stream, text: String) { self.stream = stream; self.text = text }
}

public struct ToolExecutionContext: Sendable {
    public var runID: String
    public var callID: String
    public var workflowID: String?
    public var mode: ExecutionMode
    /// Default directory for relative paths. Tools must not assume the process working directory.
    public var workingDirectory: URL
    /// Where a tool may write artifacts for this run without a file grant.
    public var artifactsDirectory: URL
    public var timeoutSeconds: Double
    /// File and network envelope from active grants, for confining subprocesses.
    public var confinement: Confinement
    public var secrets: (any SecretResolving)?
    public var progress: @Sendable (ToolProgress) -> Void

    public init(runID: String, callID: String = UUID().uuidString, workflowID: String? = nil, mode: ExecutionMode = .guided,
                workingDirectory: URL, artifactsDirectory: URL, timeoutSeconds: Double = 30, confinement: Confinement = .init(),
                secrets: (any SecretResolving)? = nil, progress: @escaping @Sendable (ToolProgress) -> Void = { _ in }) {
        self.runID = runID; self.callID = callID; self.workflowID = workflowID; self.mode = mode
        self.workingDirectory = workingDirectory; self.artifactsDirectory = artifactsDirectory
        self.timeoutSeconds = timeoutSeconds; self.confinement = confinement; self.secrets = secrets; self.progress = progress
    }
}

public struct Artifact: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var path: String
    /// `file`, `report`, `screenshot`, `patch`, `data`, `log`.
    public var kind: String
    public var bytes: Int
    public var sha256: String?
    public var createdAt: Date
    public var note: String

    public init(id: String = UUID().uuidString, path: String, kind: String = "file", bytes: Int = 0, sha256: String? = nil,
                createdAt: Date = Date(), note: String = "") {
        self.id = id; self.path = path; self.kind = kind; self.bytes = bytes; self.sha256 = sha256; self.createdAt = createdAt; self.note = note
    }
}

public enum ToolStatus: String, Codable, Sendable {
    case succeeded
    case failed
    /// Policy refused the call.
    case denied
    /// The user refused, or nobody answered an approval request.
    case notApproved
    /// A macOS permission (TCC) is missing; the user must grant it in System Settings.
    case blockedPermission
    case timedOut
    case canceled
    /// Arguments failed schema validation; nothing ran.
    case invalidInput
    /// The tool exists but cannot do this on this Mac / app / version.
    case unsupported
    /// Dry run: nothing was changed, the output describes what would happen.
    case simulated
}

public struct ToolFailure: Codable, Sendable, Hashable {
    /// `invalid_input`, `permission_denied`, `not_approved`, `tcc_blocked`, `not_found`, `timeout`, `canceled`, `io`, `network`, `process_failed`, `unsupported`, `output_invalid`, `internal`.
    public var code: String
    public var message: String
    /// What the person (or the agent) can do about it.
    public var recovery: String?
    /// True when retrying the same call may succeed (transient).
    public var retryable: Bool
    public init(code: String, message: String, recovery: String? = nil, retryable: Bool = false) {
        self.code = code; self.message = message; self.recovery = recovery; self.retryable = retryable
    }
}

public struct ToolResult: Codable, Sendable, Hashable {
    public var status: ToolStatus
    public var output: JSONValue
    /// One line for timelines.
    public var summary: String
    public var artifacts: [Artifact]
    public var failure: ToolFailure?
    public var durationMs: Int
    public var truncated: Bool
    /// Output carries outside content; the runtime wraps it as data when it goes back to a model.
    public var untrusted: Bool

    public init(status: ToolStatus = .succeeded, output: JSONValue = .null, summary: String = "", artifacts: [Artifact] = [],
                failure: ToolFailure? = nil, durationMs: Int = 0, truncated: Bool = false, untrusted: Bool = false) {
        self.status = status; self.output = output; self.summary = summary; self.artifacts = artifacts; self.failure = failure
        self.durationMs = durationMs; self.truncated = truncated; self.untrusted = untrusted
    }

    public static func success(_ output: JSONValue, summary: String, artifacts: [Artifact] = []) -> ToolResult {
        ToolResult(status: .succeeded, output: output, summary: summary, artifacts: artifacts)
    }
    public static func simulated(_ output: JSONValue, summary: String) -> ToolResult {
        ToolResult(status: .simulated, output: output, summary: summary)
    }
    public static func failure(_ status: ToolStatus, _ failure: ToolFailure) -> ToolResult {
        ToolResult(status: status, summary: failure.message, failure: failure)
    }
    public var isSuccess: Bool { status == .succeeded || status == .simulated }
}

/// Errors a tool throws. The executor converts each into a structured `ToolResult`; nothing is swallowed.
public enum ToolError: Error, Sendable, Hashable, LocalizedError {
    case invalidInput(String)
    case notFound(String)
    case permissionDenied(String)
    /// A macOS privacy permission is missing.
    case tccBlocked(MacPermission, String)
    case unsupported(String)
    case io(String)
    case network(String, retryable: Bool)
    case processFailed(exitCode: Int32, stderr: String)
    case timeout(seconds: Double)
    case canceled
    case internalError(String)

    public var errorDescription: String? { failure.message }

    public var status: ToolStatus {
        switch self {
        case .invalidInput: return .invalidInput
        case .permissionDenied: return .denied
        case .tccBlocked: return .blockedPermission
        case .unsupported: return .unsupported
        case .timeout: return .timedOut
        case .canceled: return .canceled
        case .notFound, .io, .network, .processFailed, .internalError: return .failed
        }
    }

    public var failure: ToolFailure {
        switch self {
        case .invalidInput(let m): return .init(code: "invalid_input", message: m, recovery: "Correct the arguments and call again.")
        case .notFound(let m): return .init(code: "not_found", message: m)
        case .permissionDenied(let m): return .init(code: "permission_denied", message: m, recovery: "Ask the user to grant the capability; do not look for another route.")
        case .tccBlocked(let p, let m):
            return .init(code: "tcc_blocked", message: m, recovery: "The user must enable \(p.rawValue) for ORIX OS Automation in System Settings › Privacy & Security.")
        case .unsupported(let m): return .init(code: "unsupported", message: m)
        case .io(let m): return .init(code: "io", message: m)
        case .network(let m, let r): return .init(code: "network", message: m, retryable: r)
        case .processFailed(let code, let stderr):
            return .init(code: "process_failed", message: "Process exited with code \(code)" + (stderr.isEmpty ? "" : ": \(stderr.prefix(2000))"))
        case .timeout(let s): return .init(code: "timeout", message: "Timed out after \(Int(s)) s", retryable: true)
        case .canceled: return .init(code: "canceled", message: "Canceled")
        case .internalError(let m): return .init(code: "internal", message: m)
        }
    }
}

/// A tool. `requirements` must be pure: it inspects arguments and resolves paths, it does not act.
public protocol ORIXTool: Sendable {
    var identifier: String { get }
    var manifest: ToolManifest { get }
    func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements
    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult
}

public extension ORIXTool {
    var identifier: String { manifest.identifier }
}

/// A requested tool call, from a model or a workflow step.
public struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var toolID: String
    public var arguments: JSONValue
    public var dryRun: Bool
    public var idempotencyKey: String?
    public init(id: String = UUID().uuidString, toolID: String, arguments: JSONValue, dryRun: Bool = false, idempotencyKey: String? = nil) {
        self.id = id; self.toolID = toolID; self.arguments = arguments; self.dryRun = dryRun; self.idempotencyKey = idempotencyKey
    }
}

/// Per-run settings the invoker needs to enforce policy.
public struct InvocationContext: Sendable {
    public var runID: String
    public var workflowID: String?
    public var mode: ExecutionMode
    public var workingDirectory: URL
    public var artifactsDirectory: URL
    /// Upper bound applied on top of each tool's own timeout.
    public var maxToolSeconds: Double
    public var progress: @Sendable (String, ToolProgress) -> Void

    public init(runID: String, workflowID: String? = nil, mode: ExecutionMode, workingDirectory: URL, artifactsDirectory: URL,
                maxToolSeconds: Double = 600, progress: @escaping @Sendable (String, ToolProgress) -> Void = { _, _ in }) {
        self.runID = runID; self.workflowID = workflowID; self.mode = mode; self.workingDirectory = workingDirectory
        self.artifactsDirectory = artifactsDirectory; self.maxToolSeconds = maxToolSeconds; self.progress = progress
    }
}

/// The only door to side effects. Validates, checks policy, asks for approval, runs with a timeout, redacts, audits.
/// Never throws: every outcome is a `ToolResult`.
public protocol ToolInvoking: Sendable {
    func manifests() async -> [ToolManifest]
    func invoke(_ call: ToolCall, context: InvocationContext) async -> ToolResult
}
