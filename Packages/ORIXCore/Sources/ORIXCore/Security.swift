// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXCore/Sources/ORIXCore/Security.swift
// Description      : Capability, grant, approval and audit contracts. The
//                    policy engine (ORIXSecurity) and the tool executor
//                    (ORIXToolRegistry) both speak these types.
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

/// Side-effect classification of a tool, ordered from least to most dangerous.
public enum SideEffect: String, Codable, Sendable, CaseIterable, Comparable {
    case read, write, external, destructive, privileged
    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: SideEffect, b: SideEffect) -> Bool { a.rank < b.rank }
}

/// Approval tiers from the security model. Tier 0 read-only … Tier 3 high-risk/irreversible.
public enum ApprovalTier: Int, Codable, Sendable, CaseIterable, Comparable {
    case readOnly = 0, reversibleWrite = 1, consequential = 2, highRisk = 3
    public static func < (a: ApprovalTier, b: ApprovalTier) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self {
        case .readOnly: return "Tier 0 · Read-only"
        case .reversibleWrite: return "Tier 1 · Reversible write"
        case .consequential: return "Tier 2 · Consequential"
        case .highRisk: return "Tier 3 · High-risk"
        }
    }
}

/// How a run was started; drives how much the policy engine may decide without asking.
public enum ExecutionMode: String, Codable, Sendable, CaseIterable {
    /// One-off task, asks for anything not already granted.
    case quick
    /// Plan preview, approvals, execution, verification.
    case guided
    /// May act without asking inside pre-approved grants; still asks above tier 1 unless a grant covers the tier.
    case autonomous
    /// Started by a trigger with no user present: anything not pre-granted waits (WAITING_APPROVAL), never auto-approved.
    case scheduled
    /// Read-only: every call above tier 0 is refused or dry-run.
    case review
}

/// macOS privacy permissions a tool may depend on. ORIX never grants these itself; the user does, in System Settings.
public enum MacPermission: String, Codable, Sendable, CaseIterable {
    case accessibility, screenRecording, appleEvents, fullDiskAccess, notifications
}

/// One specific authority. Paths are absolute and canonical (see `PathResolver`); hosts are lowercase.
public enum Capability: Codable, Hashable, Sendable {
    case fileRead(path: String)
    case fileWrite(path: String)
    /// Moving to the Trash or permanent deletion below this path.
    case fileDelete(path: String)
    /// Executable by absolute path, or bare name resolved by the executor (for example `git`).
    case processExec(executable: String)
    /// Script runtime: `bash`, `python`, `swift`, `javascript`, `applescript`, `jxa`.
    case scriptRuntime(name: String)
    /// Apple Events to a named application (bundle identifier).
    case appAutomation(bundleID: String)
    /// Accessibility inspection/control of a named application (bundle identifier).
    case accessibility(bundleID: String)
    /// Screen capture: `display`, `window:<bundleID>`, or `region`.
    case screenCapture(scope: String)
    /// Outbound network to a host. `*.example.com` covers subdomains.
    case network(host: String)
    /// Browser automation on a host (navigation and DOM interaction).
    case browser(host: String)
    /// Use of a Keychain secret by reference name. The value never reaches the model.
    case secret(reference: String)
    case clipboardRead
    case clipboardWrite
    case notify
    /// External communication channel such as `mail`, `messages`, `git-push`.
    case externalSend(channel: String)
    /// Launch or quit a named application.
    case appControl(bundleID: String)
    /// Running an installed skill.
    case skill(id: String)

    /// Stable kind name, used for grouping in the UI and in storage.
    public var kind: String {
        switch self {
        case .fileRead: return "file.read"
        case .fileWrite: return "file.write"
        case .fileDelete: return "file.delete"
        case .processExec: return "process.exec"
        case .scriptRuntime: return "script.runtime"
        case .appAutomation: return "app.automation"
        case .accessibility: return "accessibility"
        case .screenCapture: return "screen.capture"
        case .network: return "network"
        case .browser: return "browser"
        case .secret: return "secret"
        case .clipboardRead: return "clipboard.read"
        case .clipboardWrite: return "clipboard.write"
        case .notify: return "notify"
        case .externalSend: return "external.send"
        case .appControl: return "app.control"
        case .skill: return "skill"
        }
    }

    /// The scoped value (path, host, bundle id …), empty for unscoped capabilities.
    public var scope: String {
        switch self {
        case .fileRead(let p), .fileWrite(let p), .fileDelete(let p): return p
        case .processExec(let e): return e
        case .scriptRuntime(let n): return n
        case .appAutomation(let b), .accessibility(let b), .appControl(let b): return b
        case .screenCapture(let s): return s
        case .network(let h), .browser(let h): return h
        case .secret(let r): return r
        case .externalSend(let c): return c
        case .skill(let i): return i
        case .clipboardRead, .clipboardWrite, .notify: return ""
        }
    }

    public var displayString: String { scope.isEmpty ? kind : "\(kind) → \(scope)" }

    /// Rebuilds a capability from its stored `kind` and `scope`.
    public init?(kind: String, scope: String) {
        switch kind {
        case "file.read": self = .fileRead(path: scope)
        case "file.write": self = .fileWrite(path: scope)
        case "file.delete": self = .fileDelete(path: scope)
        case "process.exec": self = .processExec(executable: scope)
        case "script.runtime": self = .scriptRuntime(name: scope)
        case "app.automation": self = .appAutomation(bundleID: scope)
        case "accessibility": self = .accessibility(bundleID: scope)
        case "screen.capture": self = .screenCapture(scope: scope)
        case "network": self = .network(host: scope)
        case "browser": self = .browser(host: scope)
        case "secret": self = .secret(reference: scope)
        case "clipboard.read": self = .clipboardRead
        case "clipboard.write": self = .clipboardWrite
        case "notify": self = .notify
        case "external.send": self = .externalSend(channel: scope)
        case "app.control": self = .appControl(bundleID: scope)
        case "skill": self = .skill(id: scope)
        default: return nil
        }
    }

    /// True when a grant of `self` authorises `requested`. Never widens: write does not imply read or delete,
    /// a path grant covers only that path and its descendants, a host grant only that host (or subdomains for `*.`).
    public func covers(_ requested: Capability) -> Bool {
        guard kind == requested.kind else { return false }
        switch self {
        case .fileRead(let g), .fileWrite(let g), .fileDelete(let g):
            return Self.path(g, contains: requested.scope)
        case .network(let g), .browser(let g):
            return Self.host(g, covers: requested.scope)
        case .clipboardRead, .clipboardWrite, .notify:
            return true
        default:
            return scope == requested.scope
        }
    }

    static func path(_ root: String, contains child: String) -> Bool {
        guard root.hasPrefix("/"), child.hasPrefix("/") else { return false }
        if root == "/" { return true }
        let r = root.hasSuffix("/") ? String(root.dropLast()) : root
        return child == r || child.hasPrefix(r + "/")
    }

    static func host(_ pattern: String, covers host: String) -> Bool {
        let p = pattern.lowercased(), h = host.lowercased()
        if p == h { return true }
        if p.hasPrefix("*.") {
            let suffix = String(p.dropFirst(1))
            return h.hasSuffix(suffix) && h.count > suffix.count
        }
        return false
    }
}

/// How long a grant lives.
public enum GrantScope: Codable, Hashable, Sendable {
    /// Consumed by exactly one tool call.
    case once(callID: String)
    /// Valid for one run.
    case run(runID: String)
    /// Valid for every run of one workflow (declared in its manifest and accepted by the user).
    case workflow(workflowID: String)
    /// Valid until revoked. Opt-in only.
    case persistent
}

public struct PermissionGrant: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var capability: Capability
    public var scope: GrantScope
    /// Highest tier this grant authorises without a new approval.
    public var maxTier: ApprovalTier
    public var createdAt: Date
    public var expiresAt: Date?
    public var revokedAt: Date?
    /// `user`, `workflow:<id>`, `skill:<id>` … who asked for it. Informational.
    public var source: String
    public var note: String

    public init(id: String = UUID().uuidString, capability: Capability, scope: GrantScope, maxTier: ApprovalTier,
                createdAt: Date = Date(), expiresAt: Date? = nil, revokedAt: Date? = nil, source: String = "user", note: String = "") {
        self.id = id; self.capability = capability; self.scope = scope; self.maxTier = maxTier
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.revokedAt = revokedAt; self.source = source; self.note = note
    }

    public func isActive(at date: Date = Date()) -> Bool {
        revokedAt == nil && (expiresAt.map { $0 > date } ?? true)
    }
}

/// What a tool call is about to do, as presented to the policy engine.
public struct AccessRequest: Codable, Sendable, Hashable {
    public var runID: String
    public var callID: String
    public var workflowID: String?
    public var toolID: String
    public var capabilities: [Capability]
    public var tier: ApprovalTier
    public var sideEffect: SideEffect
    public var mode: ExecutionMode
    /// One sentence a person can judge, written by the tool from the validated arguments (not by the model).
    public var summary: String
    /// Redacted arguments shown in the approval sheet.
    public var argumentsPreview: JSONValue
    public var dryRun: Bool

    public init(runID: String, callID: String, workflowID: String? = nil, toolID: String, capabilities: [Capability],
                tier: ApprovalTier, sideEffect: SideEffect, mode: ExecutionMode, summary: String,
                argumentsPreview: JSONValue = .null, dryRun: Bool = false) {
        self.runID = runID; self.callID = callID; self.workflowID = workflowID; self.toolID = toolID
        self.capabilities = capabilities; self.tier = tier; self.sideEffect = sideEffect; self.mode = mode
        self.summary = summary; self.argumentsPreview = argumentsPreview; self.dryRun = dryRun
    }
}

public struct ApprovalRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var access: AccessRequest
    /// Capabilities not covered by any active grant.
    public var missing: [Capability]
    /// Why approval is needed (missing grant, tier above grant, mode).
    public var reason: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, access: AccessRequest, missing: [Capability], reason: String, createdAt: Date = Date()) {
        self.id = id; self.access = access; self.missing = missing; self.reason = reason; self.createdAt = createdAt
    }
}

public enum ApprovalResponse: Codable, Sendable, Hashable {
    case approveOnce
    case approveForRun
    /// Only offered below tier 3.
    case approvePersistent
    case deny(reason: String)
    /// Nobody answered (scheduled run, app closed, timeout). The call does not execute.
    case unanswered

    public var isApproval: Bool {
        switch self {
        case .approveOnce, .approveForRun, .approvePersistent: return true
        case .deny, .unanswered: return false
        }
    }
}

public enum PolicyDecision: Sendable, Hashable {
    case allow(grantIDs: [String])
    case needsApproval(ApprovalRequest)
    case deny(reason: String)
}

/// Deny-by-default decision point. Implemented by `PolicyEngine` in ORIXSecurity.
public protocol PolicyDeciding: Sendable {
    func evaluate(_ request: AccessRequest) async -> PolicyDecision
    /// Records the grants created by an approval and returns their identifiers.
    func recordApproval(_ response: ApprovalResponse, for request: ApprovalRequest) async -> [String]
    /// Marks single-use grants as consumed after the call ran.
    func consume(grantIDs: [String], callID: String) async
    /// File roots and hosts currently granted to a run, used to confine subprocesses.
    func confinement(runID: String, workflowID: String?) async -> Confinement
}

/// Asks a person. The app implements it with a sheet/notification; headless runs answer `.unanswered`.
public protocol ApprovalBroker: Sendable {
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalResponse
}

/// The filesystem and network envelope a subprocess is allowed, derived from active grants.
public struct Confinement: Codable, Sendable, Hashable {
    public var readRoots: [String]
    public var writeRoots: [String]
    public var networkHosts: [String]
    /// Hosts the browser tools may navigate to.
    public var browserHosts: [String]
    public init(readRoots: [String] = [], writeRoots: [String] = [], networkHosts: [String] = [], browserHosts: [String] = []) {
        self.readRoots = readRoots; self.writeRoots = writeRoots; self.networkHosts = networkHosts; self.browserHosts = browserHosts
    }
    public var allowsNetwork: Bool { !networkHosts.isEmpty }
}

public struct AuditEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case toolAllowed, toolDenied, approvalRequested, approvalGranted, approvalDenied, grantCreated, grantRevoked,
             toolExecuted, toolFailed, secretUsed, emergencyStop, skillInstalled, skillRemoved, policyViolation
    }
    public var id: String
    public var timestamp: Date
    public var kind: Kind
    public var runID: String?
    public var toolID: String?
    public var tier: ApprovalTier?
    /// Redacted, human-readable.
    public var detail: String
    public var data: JSONValue

    public init(id: String = UUID().uuidString, timestamp: Date = Date(), kind: Kind, runID: String? = nil, toolID: String? = nil,
                tier: ApprovalTier? = nil, detail: String, data: JSONValue = .null) {
        self.id = id; self.timestamp = timestamp; self.kind = kind; self.runID = runID; self.toolID = toolID
        self.tier = tier; self.detail = detail; self.data = data
    }
}

public protocol AuditSink: Sendable {
    func record(_ entry: AuditEntry) async
}

/// Resolves secret references to values at the last moment, inside the execution layer. Values never enter prompts.
public protocol SecretResolving: Sendable {
    func secret(reference: String) async throws -> String
}

/// Durable storage for grants. ORIXPersistence implements it on SQLite; tests use an in-memory store.
public protocol GrantStoring: Sendable {
    func allGrants() async -> [PermissionGrant]
    func saveGrant(_ grant: PermissionGrant) async
    func revokeGrant(id: String, at date: Date) async
    func revokeAllGrants(at date: Date) async
}
