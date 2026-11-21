// ORIX OS Automation
// File: Packages/ORIXSecurity/Sources/ORIXSecurity/PolicyEngine.swift
// Description: Deny-by-default policy decision point: matches each requested capability against active, scoped grants; tier 3 always needs contemporaneous approval.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

/// The single place where "may this call run?" is decided. Nothing is allowed implicitly: every capability of a request
/// must be covered by an active grant whose scope matches the call, the run, the workflow, or which is persistent.
public actor PolicyEngine: PolicyDeciding {
    /// Single-use grants that are never consumed (the call was abandoned) stop matching after this long.
    public static let onceGrantLifetime: TimeInterval = 3600

    private let store: any GrantStoring
    private let audit: (any AuditSink)?
    private let now: @Sendable () -> Date

    public init(store: any GrantStoring, audit: (any AuditSink)? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.audit = audit
        self.now = now
    }

    // MARK: PolicyDeciding

    public func evaluate(_ request: AccessRequest) async -> PolicyDecision {
        // 1. Protected locations: no grant can cover them.
        if let protected = request.capabilities.first(where: Self.isProtectedFile) {
            let reason = "\(PathResolver.display(protected.scope)) is a protected location (credentials or system security state); no grant can cover it."
            await record(.policyViolation, runID: request.runID, toolID: request.toolID, tier: request.tier,
                         detail: "Refused \(request.toolID): \(protected.displayString) is protected",
                         data: ["callID": .string(request.callID), "capability": .string(protected.displayString)])
            return .deny(reason: reason)
        }
        // 2. Review mode never changes anything.
        if request.mode == .review && request.tier > .readOnly && !request.dryRun {
            return .deny(reason: "review mode is read-only: \(request.toolID) is \(request.tier.label) and was not a dry run.")
        }

        let date = now()
        let active = await store.allGrants().filter { $0.isActive(at: date) }

        // A call that names no capability has nothing a grant could cover: reads pass, anything else is asked every time.
        if request.capabilities.isEmpty {
            if request.tier == .readOnly { return .allow(grantIDs: []) }
            return .needsApproval(ApprovalRequest(access: request, missing: [],
                reason: "\(request.toolID) declares no specific capability, so each \(request.tier.label) call needs explicit approval.",
                createdAt: date))
        }

        var used: [String] = []
        var missing: [Capability] = []
        var tierTooLow = false
        for capability in request.capabilities {
            if let grant = Self.bestGrant(in: active, for: capability, request: request) {
                if !used.contains(grant.id) { used.append(grant.id) }
            } else {
                if !missing.contains(capability) { missing.append(capability) }
                if active.contains(where: { Self.scopeMatches($0.scope, request: request) && $0.capability.covers(capability) && $0.maxTier < request.tier }) {
                    tierTooLow = true
                }
            }
        }
        if missing.isEmpty { return .allow(grantIDs: used) }

        let list = missing.map(\.displayString).joined(separator: ", ")
        let reason: String
        if request.tier == .highRisk {
            reason = "\(ApprovalTier.highRisk.label) actions need your approval every time; standing grants never apply. Needed: \(list)."
        } else if tierTooLow {
            reason = "An existing grant covers this scope only up to a lower tier than \(request.tier.label). Needed: \(list)."
        } else if request.mode == .scheduled {
            reason = "No active grant covers: \(list). Scheduled runs wait for approval; nothing is approved automatically."
        } else {
            reason = "No active grant covers: \(list)."
        }
        return .needsApproval(ApprovalRequest(access: request, missing: missing, reason: reason, createdAt: date))
    }

    public func recordApproval(_ response: ApprovalResponse, for request: ApprovalRequest) async -> [String] {
        let access = request.access
        let baseData: [String: JSONValue] = ["callID": .string(access.callID), "approvalID": .string(request.id)]
        switch response {
        case .deny(let why):
            await record(.approvalDenied, runID: access.runID, toolID: access.toolID, tier: access.tier,
                         detail: "Denied \(access.toolID): \(why)", data: .object(baseData))
            return []
        case .unanswered:
            await record(.approvalDenied, runID: access.runID, toolID: access.toolID, tier: access.tier,
                         detail: "Approval for \(access.toolID) was not answered; the call does not run", data: .object(baseData))
            return []
        case .approveOnce, .approveForRun, .approvePersistent:
            break
        }

        let date = now()
        var scope: GrantScope
        var scopeLabel: String
        switch response {
        case .approveForRun: scope = .run(runID: access.runID); scopeLabel = "this run"
        case .approvePersistent: scope = .persistent; scopeLabel = "until revoked"
        default: scope = .once(callID: access.callID); scopeLabel = "this call only"
        }
        var downgraded = false
        if access.tier == .highRisk, scope != .once(callID: access.callID) {
            // Tier 3 is contemporaneous by definition: a broader answer is narrowed to this one call.
            scope = .once(callID: access.callID); scopeLabel = "this call only"; downgraded = true
        }
        let expiry: Date? = { if case .once = scope { return date.addingTimeInterval(Self.onceGrantLifetime) }; return nil }()
        let note = Redactor.shared.redact("Approved for \(access.toolID): \(access.summary)")

        var ids: [String] = []
        for capability in request.missing where !Self.isProtectedFile(capability) {
            let grant = PermissionGrant(capability: capability, scope: scope, maxTier: access.tier, createdAt: date,
                                        expiresAt: expiry, source: "user", note: note)
            await store.saveGrant(grant)
            ids.append(grant.id)
            await record(.grantCreated, runID: access.runID, toolID: access.toolID, tier: access.tier,
                         detail: "Grant \(capability.displayString) (\(scopeLabel), up to \(access.tier.label))",
                         data: ["grantID": .string(grant.id), "callID": .string(access.callID), "scope": .string(Self.scopeName(scope))])
        }
        var data = baseData
        data["grantIDs"] = .array(ids.map(JSONValue.string))
        data["scope"] = .string(Self.scopeName(scope))
        if downgraded { data["downgradedToOnce"] = true }
        await record(.approvalGranted, runID: access.runID, toolID: access.toolID, tier: access.tier,
                     detail: "Approved \(access.toolID) for \(scopeLabel)" + (downgraded ? " (narrowed: tier 3 is never standing)" : ""),
                     data: .object(data))
        return ids
    }

    public func consume(grantIDs: [String], callID: String) async {
        let date = now()
        let listed = Set(grantIDs)
        for grant in await store.allGrants() where grant.revokedAt == nil {
            guard case .once(let owner) = grant.scope else { continue }
            // Every single-use grant of this call is spent, whether or not the caller listed it.
            if owner == callID || listed.contains(grant.id) {
                await store.revokeGrant(id: grant.id, at: date)
            }
        }
    }

    public func confinement(runID: String, workflowID: String?) async -> Confinement {
        let date = now()
        var read: Set<String> = [], write: Set<String> = [], network: Set<String> = [], browser: Set<String> = []
        for grant in await store.allGrants() where grant.isActive(at: date) {
            switch grant.scope {
            case .run(let id): guard id == runID else { continue }
            case .workflow(let id): guard let workflowID, id == workflowID else { continue }
            case .persistent: break
            case .once: continue
            }
            switch grant.capability {
            case .fileRead(let p): if !PathResolver.isProtected(p) { read.insert(p) }
            case .fileWrite(let p): if !PathResolver.isProtected(p) { write.insert(p) }
            case .network(let h): network.insert(h.lowercased())
            case .browser(let h): browser.insert(h.lowercased())
            default: break
            }
        }
        return Confinement(readRoots: read.sorted(), writeRoots: write.sorted(), networkHosts: network.sorted(), browserHosts: browser.sorted())
    }

    // MARK: Management (Permissions UI)

    /// Every stored grant, newest first, including revoked and expired ones (the UI shows history).
    public func grants() async -> [PermissionGrant] {
        await store.allGrants().sorted { $0.createdAt > $1.createdAt }
    }

    /// Grants that currently match requests.
    public func activeGrants() async -> [PermissionGrant] {
        let date = now()
        return await grants().filter { $0.isActive(at: date) }
    }

    /// Stores a grant created by the user (or accepted from a workflow manifest). Returns false, storing nothing,
    /// when the grant targets a protected location.
    @discardableResult
    public func add(_ grant: PermissionGrant) async -> Bool {
        if Self.isProtectedFile(grant.capability) {
            await record(.policyViolation, detail: "Refused to store a grant on protected location \(grant.capability.displayString)",
                         data: ["grantID": .string(grant.id)])
            return false
        }
        await store.saveGrant(grant)
        await record(.grantCreated, tier: grant.maxTier,
                     detail: "Grant \(grant.capability.displayString) (\(Self.scopeName(grant.scope)), up to \(grant.maxTier.label)) added by \(grant.source)",
                     data: ["grantID": .string(grant.id), "scope": .string(Self.scopeName(grant.scope))])
        return true
    }

    public func revoke(id: String) async {
        let existing = await store.allGrants().first { $0.id == id }
        guard let existing, existing.revokedAt == nil else { return }
        await store.revokeGrant(id: id, at: now())
        await record(.grantRevoked, detail: "Revoked grant \(existing.capability.displayString)", data: ["grantID": .string(id)])
    }

    /// Emergency: every grant stops matching immediately.
    public func revokeAll() async {
        let date = now()
        let count = await store.allGrants().filter { $0.revokedAt == nil }.count
        await store.revokeAllGrants(at: date)
        await record(.emergencyStop, detail: "Revoked all grants (\(count))", data: ["revoked": .int(count)])
    }

    /// Revokes the grants scoped to one run (call when the run ends or is cancelled). Returns how many were revoked.
    @discardableResult
    public func revokeRun(runID: String) async -> Int {
        let date = now()
        var count = 0
        for grant in await store.allGrants() where grant.revokedAt == nil && grant.scope == .run(runID: runID) {
            await store.revokeGrant(id: grant.id, at: date)
            count += 1
        }
        if count > 0 {
            await record(.grantRevoked, runID: runID, detail: "Revoked \(count) run-scoped grant(s)", data: ["revoked": .int(count)])
        }
        return count
    }

    /// Grants declared for one workflow, newest first (active or not).
    public func grantsForWorkflow(_ workflowID: String) async -> [PermissionGrant] {
        await grants().filter { $0.scope == .workflow(workflowID: workflowID) }
    }

    /// Marks grants whose expiry has passed as revoked so they stop appearing as live. Expired grants never match
    /// even before this runs. Returns how many were marked.
    @discardableResult
    public func purgeExpired() async -> Int {
        let date = now()
        var count = 0
        for grant in await store.allGrants() where grant.revokedAt == nil {
            guard let expiry = grant.expiresAt, expiry <= date else { continue }
            await store.revokeGrant(id: grant.id, at: date)
            count += 1
        }
        return count
    }

    // MARK: Matching

    private static func isProtectedFile(_ capability: Capability) -> Bool {
        switch capability {
        case .fileRead(let p), .fileWrite(let p), .fileDelete(let p): return PathResolver.isProtected(p)
        default: return false
        }
    }

    private static func scopeMatches(_ scope: GrantScope, request: AccessRequest) -> Bool {
        switch scope {
        case .once(let callID): return callID == request.callID
        case .run(let runID): return runID == request.runID
        case .workflow(let workflowID): return request.workflowID == workflowID
        case .persistent: return true
        }
    }

    private static func satisfies(_ grant: PermissionGrant, _ capability: Capability, request: AccessRequest) -> Bool {
        if request.tier == .highRisk {
            // Only an approval given for this exact call counts.
            guard case .once(let callID) = grant.scope, callID == request.callID else { return false }
        } else if !scopeMatches(grant.scope, request: request) {
            return false
        }
        return grant.maxTier >= request.tier && grant.capability.covers(capability)
    }

    /// Prefers the longest-lived matching grant so single-use approvals are not spent needlessly.
    private static func bestGrant(in grants: [PermissionGrant], for capability: Capability, request: AccessRequest) -> PermissionGrant? {
        func rank(_ scope: GrantScope) -> Int {
            switch scope {
            case .persistent: return 0
            case .workflow: return 1
            case .run: return 2
            case .once: return 3
            }
        }
        return grants.filter { satisfies($0, capability, request: request) }.min { rank($0.scope) < rank($1.scope) }
    }

    private static func scopeName(_ scope: GrantScope) -> String {
        switch scope {
        case .once: return "once"
        case .run: return "run"
        case .workflow: return "workflow"
        case .persistent: return "persistent"
        }
    }

    private func record(_ kind: AuditEntry.Kind, runID: String? = nil, toolID: String? = nil, tier: ApprovalTier? = nil,
                        detail: String, data: JSONValue = .null) async {
        guard let audit else { return }
        await audit.record(AuditEntry(timestamp: now(), kind: kind, runID: runID, toolID: toolID, tier: tier,
                                      detail: Redactor.shared.redact(detail), data: data))
    }
}
