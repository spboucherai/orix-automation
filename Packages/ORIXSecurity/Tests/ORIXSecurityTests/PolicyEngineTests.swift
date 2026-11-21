// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXSecurity/Tests/ORIXSecurityTests/PolicyEngineTests.swift
// Description      : Unit tests of the policy engine against an in-memory grant
//                    store: deny by default, scopes, tiers, expiry, revocation,
//                    confinement.
// Module           : ORIXSecurityTests
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
import ORIXCore
import ORIXTestingSupport
import Testing
@testable import ORIXSecurity

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

private func makeEngine(grants: [PermissionGrant] = []) -> (PolicyEngine, InMemoryGrantStore, CollectingAuditSink, TestClock) {
    let clock = TestClock()
    let store = InMemoryGrantStore(grants: grants)
    let audit = CollectingAuditSink()
    return (PolicyEngine(store: store, audit: audit, now: { clock.now }), store, audit, clock)
}

private func request(_ capabilities: [Capability], tier: ApprovalTier = .readOnly, run: String = "run-1", call: String = "call-1",
                     workflow: String? = nil, mode: ExecutionMode = .guided, dryRun: Bool = false) -> AccessRequest {
    AccessRequest(runID: run, callID: call, workflowID: workflow, toolID: "filesystem.test", capabilities: capabilities, tier: tier,
                  sideEffect: tier == .readOnly ? .read : .write, mode: mode, summary: "Test call", dryRun: dryRun)
}

private func approval(_ decision: PolicyDecision) -> ApprovalRequest? {
    if case .needsApproval(let r) = decision { return r }
    return nil
}

private func allowedIDs(_ decision: PolicyDecision) -> [String]? {
    if case .allow(let ids) = decision { return ids }
    return nil
}

private func isDeny(_ decision: PolicyDecision) -> Bool {
    if case .deny = decision { return true }
    return false
}

@Suite("PolicyEngine (unit, in-memory grant store)")
struct PolicyEngineTests {
    @Test func readsAreNotImplicitlyAllowed() async {
        let (engine, _, _, _) = makeEngine()
        let decision = await engine.evaluate(request([.fileRead(path: "/Users/x/Documents/a.txt")]))
        let ask = approval(decision)
        #expect(ask?.missing == [.fileRead(path: "/Users/x/Documents/a.txt")])
        #expect(ask?.reason.contains("No active grant") == true)
    }

    @Test func protectedPathsAreDeniedEvenWithARootGrant() async {
        let root = PermissionGrant(capability: .fileRead(path: "/"), scope: .persistent, maxTier: .highRisk)
        let (engine, _, audit, _) = makeEngine(grants: [root])
        let ssh = NSHomeDirectory() + "/.ssh/id_ed25519"
        #expect(isDeny(await engine.evaluate(request([.fileRead(path: ssh)]))))
        #expect(isDeny(await engine.evaluate(request([.fileWrite(path: "/System/Library/x")], tier: .reversibleWrite))))
        #expect(isDeny(await engine.evaluate(request([.fileDelete(path: NSHomeDirectory() + "/Library/Keychains/login.keychain-db")], tier: .highRisk))))
        // The same grant does cover an ordinary path.
        #expect(allowedIDs(await engine.evaluate(request([.fileRead(path: "/tmp/a")]))) == [root.id])
        #expect(await audit.entries.filter { $0.kind == .policyViolation }.count == 3)
    }

    @Test func protectedGrantsCannotBeAddedOrApproved() async {
        let (engine, store, _, _) = makeEngine()
        let added = await engine.add(PermissionGrant(capability: .fileRead(path: NSHomeDirectory() + "/.ssh"), scope: .persistent, maxTier: .readOnly))
        #expect(!added)
        let forged = ApprovalRequest(access: request([.fileRead(path: NSHomeDirectory() + "/.aws/credentials")]),
                                     missing: [.fileRead(path: NSHomeDirectory() + "/.aws/credentials")], reason: "forged")
        #expect(await engine.recordApproval(.approvePersistent, for: forged).isEmpty)
        #expect(await store.allGrants().isEmpty)
    }

    @Test func reviewModeIsReadOnly() async {
        let grant = PermissionGrant(capability: .fileWrite(path: "/tmp/work"), scope: .persistent, maxTier: .consequential)
        let read = PermissionGrant(capability: .fileRead(path: "/tmp/work"), scope: .persistent, maxTier: .readOnly)
        let (engine, _, _, _) = makeEngine(grants: [grant, read])
        let write = await engine.evaluate(request([.fileWrite(path: "/tmp/work/a")], tier: .reversibleWrite, mode: .review))
        if case .deny(let reason) = write { #expect(reason.contains("review mode is read-only")) } else { Issue.record("expected deny") }
        // A dry run is not refused by the mode, and a tier-0 read with a grant is allowed.
        #expect(allowedIDs(await engine.evaluate(request([.fileWrite(path: "/tmp/work/a")], tier: .reversibleWrite, mode: .review, dryRun: true))) == [grant.id])
        #expect(allowedIDs(await engine.evaluate(request([.fileRead(path: "/tmp/work/a")], mode: .review))) == [read.id])
    }

    @Test func highRiskIgnoresStandingGrants() async {
        let cap = Capability.fileDelete(path: "/tmp/work")
        let grants = [
            PermissionGrant(capability: cap, scope: .persistent, maxTier: .highRisk),
            PermissionGrant(capability: cap, scope: .run(runID: "run-1"), maxTier: .highRisk),
            PermissionGrant(capability: cap, scope: .workflow(workflowID: "wf"), maxTier: .highRisk),
            PermissionGrant(capability: cap, scope: .once(callID: "another-call"), maxTier: .highRisk),
        ]
        let (engine, _, _, _) = makeEngine(grants: grants)
        let ask = approval(await engine.evaluate(request([.fileDelete(path: "/tmp/work/a")], tier: .highRisk, workflow: "wf")))
        #expect(ask?.missing == [.fileDelete(path: "/tmp/work/a")])
        #expect(ask?.reason.contains("every time") == true)
    }

    @Test func highRiskApprovalIsAlwaysSingleUse() async throws {
        let (engine, store, audit, _) = makeEngine()
        let req = request([.fileDelete(path: "/tmp/work/a")], tier: .highRisk)
        for response in [ApprovalResponse.approvePersistent, .approveForRun, .approveOnce] {
            let ask = try #require(approval(await engine.evaluate(req)))
            let ids = await engine.recordApproval(response, for: ask)
            #expect(ids.count == 1)
            let stored = try #require(await store.allGrants().first { $0.id == ids[0] })
            #expect(stored.scope == .once(callID: "call-1"))
            #expect(stored.maxTier == .highRisk)
            #expect(allowedIDs(await engine.evaluate(req)) == ids)
            // Another call in the same run is not covered.
            #expect(approval(await engine.evaluate(request([.fileDelete(path: "/tmp/work/a")], tier: .highRisk, call: "call-2"))) != nil)
            await engine.consume(grantIDs: ids, callID: "call-1")
            #expect(approval(await engine.evaluate(req)) != nil)
        }
        #expect(await audit.entries.filter { $0.kind == .approvalGranted }.count == 3)
        #expect(await audit.entries.filter { $0.kind == .approvalGranted && $0.data["downgradedToOnce"] == true }.count == 2)
    }

    @Test func approveOnceCoversOneCallAndIsConsumed() async throws {
        let (engine, store, audit, _) = makeEngine()
        let req = request([.fileWrite(path: "/tmp/work/a"), .fileRead(path: "/tmp/work/a")], tier: .reversibleWrite)
        let ask = try #require(approval(await engine.evaluate(req)))
        #expect(ask.missing.count == 2)
        let ids = await engine.recordApproval(.approveOnce, for: ask)
        #expect(ids.count == 2)
        #expect(Set(allowedIDs(await engine.evaluate(req)) ?? []) == Set(ids))
        #expect(approval(await engine.evaluate(request([.fileWrite(path: "/tmp/work/a")], tier: .reversibleWrite, call: "call-2"))) != nil)
        await engine.consume(grantIDs: ids, callID: "call-1")
        #expect(approval(await engine.evaluate(req))?.missing.count == 2)
        #expect(await store.allGrants().allSatisfy { $0.revokedAt != nil })
        #expect(await audit.entries.filter { $0.kind == .grantCreated }.count == 2)
    }

    @Test func approveForRunCoversTheRunOnly() async throws {
        let (engine, _, _, _) = makeEngine()
        let ask = try #require(approval(await engine.evaluate(request([.network(host: "api.example.com")], tier: .consequential))))
        let ids = await engine.recordApproval(.approveForRun, for: ask)
        #expect(allowedIDs(await engine.evaluate(request([.network(host: "api.example.com")], tier: .consequential, call: "call-9"))) == ids)
        #expect(approval(await engine.evaluate(request([.network(host: "api.example.com")], tier: .consequential, run: "run-2"))) != nil)
        // Consuming does not spend a run grant.
        await engine.consume(grantIDs: ids, callID: "call-9")
        #expect(allowedIDs(await engine.evaluate(request([.network(host: "api.example.com")], tier: .consequential, call: "call-10"))) == ids)
        #expect(await engine.revokeRun(runID: "run-1") == 1)
        #expect(approval(await engine.evaluate(request([.network(host: "api.example.com")], tier: .consequential, call: "call-11"))) != nil)
    }

    @Test func approvePersistentCoversLaterRuns() async throws {
        let (engine, _, _, _) = makeEngine()
        let ask = try #require(approval(await engine.evaluate(request([.clipboardWrite], tier: .reversibleWrite))))
        let ids = await engine.recordApproval(.approvePersistent, for: ask)
        #expect(allowedIDs(await engine.evaluate(request([.clipboardWrite], tier: .reversibleWrite, run: "run-77", call: "c"))) == ids)
    }

    @Test func denialAndSilenceCreateNoGrant() async throws {
        let (engine, store, audit, _) = makeEngine()
        let ask = try #require(approval(await engine.evaluate(request([.notify], tier: .reversibleWrite))))
        #expect(await engine.recordApproval(.deny(reason: "no"), for: ask).isEmpty)
        #expect(await engine.recordApproval(.unanswered, for: ask).isEmpty)
        #expect(await store.allGrants().isEmpty)
        #expect(await audit.entries.map(\.kind) == [.approvalDenied, .approvalDenied])
    }

    @Test func workflowGrantsMatchOnlyTheirWorkflow() async {
        let grant = PermissionGrant(capability: .fileRead(path: "/tmp/reports"), scope: .workflow(workflowID: "wf-a"), maxTier: .readOnly, source: "workflow:wf-a")
        let (engine, _, _, _) = makeEngine(grants: [grant])
        #expect(allowedIDs(await engine.evaluate(request([.fileRead(path: "/tmp/reports/x.pdf")], workflow: "wf-a"))) == [grant.id])
        #expect(approval(await engine.evaluate(request([.fileRead(path: "/tmp/reports/x.pdf")], workflow: "wf-b"))) != nil)
        #expect(approval(await engine.evaluate(request([.fileRead(path: "/tmp/reports/x.pdf")]))) != nil)
        #expect(await engine.grantsForWorkflow("wf-a").map(\.id) == [grant.id])
        #expect(await engine.grantsForWorkflow("wf-b").isEmpty)
    }

    @Test func grantTierIsACeiling() async {
        let grant = PermissionGrant(capability: .fileWrite(path: "/tmp/work"), scope: .persistent, maxTier: .reversibleWrite)
        let (engine, _, _, _) = makeEngine(grants: [grant])
        #expect(allowedIDs(await engine.evaluate(request([.fileWrite(path: "/tmp/work/a")], tier: .reversibleWrite))) == [grant.id])
        let ask = approval(await engine.evaluate(request([.fileWrite(path: "/tmp/work/a")], tier: .consequential, mode: .autonomous)))
        #expect(ask?.reason.contains("lower tier") == true)
    }

    @Test func coverageNeverWidens() async {
        let grants = [
            PermissionGrant(capability: .fileWrite(path: "/tmp/work"), scope: .persistent, maxTier: .consequential),
            PermissionGrant(capability: .network(host: "*.example.com"), scope: .persistent, maxTier: .consequential),
        ]
        let (engine, _, _, _) = makeEngine(grants: grants)
        // Write does not imply read or delete; a sibling folder with the same prefix is not inside the root.
        #expect(approval(await engine.evaluate(request([.fileRead(path: "/tmp/work/a")]))) != nil)
        #expect(approval(await engine.evaluate(request([.fileDelete(path: "/tmp/work/a")], tier: .reversibleWrite))) != nil)
        #expect(approval(await engine.evaluate(request([.fileWrite(path: "/tmp/workspace/a")], tier: .reversibleWrite))) != nil)
        #expect(allowedIDs(await engine.evaluate(request([.network(host: "api.example.com")], tier: .consequential))) != nil)
        #expect(approval(await engine.evaluate(request([.network(host: "example.org")], tier: .consequential))) != nil)
        #expect(approval(await engine.evaluate(request([.browser(host: "api.example.com")], tier: .consequential))) != nil)
        // Partially covered request: only the uncovered capability is asked for.
        let partial = approval(await engine.evaluate(request([.fileWrite(path: "/tmp/work/a"), .processExec(executable: "git")], tier: .consequential)))
        #expect(partial?.missing == [.processExec(executable: "git")])
    }

    @Test func expiredAndRevokedGrantsNeverMatch() async {
        let clock = TestClock()
        let expiring = PermissionGrant(capability: .fileRead(path: "/tmp/a"), scope: .persistent, maxTier: .readOnly,
                                       createdAt: clock.now, expiresAt: clock.now.addingTimeInterval(60))
        let revoked = PermissionGrant(capability: .fileRead(path: "/tmp/b"), scope: .persistent, maxTier: .readOnly,
                                      createdAt: clock.now, revokedAt: clock.now)
        let store = InMemoryGrantStore(grants: [expiring, revoked])
        let engine = PolicyEngine(store: store, now: { clock.now })
        #expect(allowedIDs(await engine.evaluate(request([.fileRead(path: "/tmp/a")]))) == [expiring.id])
        #expect(approval(await engine.evaluate(request([.fileRead(path: "/tmp/b")]))) != nil)
        clock.advance(61)
        #expect(approval(await engine.evaluate(request([.fileRead(path: "/tmp/a")]))) != nil)
        #expect(await engine.activeGrants().isEmpty)
        #expect(await engine.confinement(runID: "run-1", workflowID: nil).readRoots.isEmpty)
        #expect(await engine.purgeExpired() == 1)
        #expect(await engine.purgeExpired() == 0)
        #expect(await engine.grants().count == 2)
    }

    @Test func unconsumedSingleUseGrantsGoStale() async throws {
        let (engine, _, _, clock) = makeEngine()
        let req = request([.fileWrite(path: "/tmp/work/a")], tier: .reversibleWrite)
        let ask = try #require(approval(await engine.evaluate(req)))
        _ = await engine.recordApproval(.approveOnce, for: ask)
        clock.advance(PolicyEngine.onceGrantLifetime + 1)
        #expect(approval(await engine.evaluate(req)) != nil)
    }

    @Test func revokeAndRevokeAll() async {
        let a = PermissionGrant(capability: .fileRead(path: "/tmp/a"), scope: .persistent, maxTier: .readOnly)
        let b = PermissionGrant(capability: .fileRead(path: "/tmp/b"), scope: .run(runID: "run-1"), maxTier: .readOnly)
        let (engine, _, audit, _) = makeEngine()
        #expect(await engine.add(a))
        #expect(await engine.add(b))
        await engine.revoke(id: a.id)
        #expect(approval(await engine.evaluate(request([.fileRead(path: "/tmp/a")]))) != nil)
        #expect(allowedIDs(await engine.evaluate(request([.fileRead(path: "/tmp/b")]))) == [b.id])
        await engine.revokeAll()
        #expect(approval(await engine.evaluate(request([.fileRead(path: "/tmp/b")]))) != nil)
        #expect(await engine.activeGrants().isEmpty)
        let kinds = await audit.entries.map(\.kind)
        #expect(kinds == [.grantCreated, .grantCreated, .grantRevoked, .emergencyStop])
    }

    @Test func confinementAggregatesMatchingScopes() async {
        let grants = [
            PermissionGrant(capability: .fileRead(path: "/tmp/in"), scope: .persistent, maxTier: .readOnly),
            PermissionGrant(capability: .fileWrite(path: "/tmp/out"), scope: .run(runID: "run-1"), maxTier: .reversibleWrite),
            PermissionGrant(capability: .fileWrite(path: "/tmp/other-run"), scope: .run(runID: "run-2"), maxTier: .reversibleWrite),
            PermissionGrant(capability: .network(host: "API.example.com"), scope: .workflow(workflowID: "wf"), maxTier: .consequential),
            PermissionGrant(capability: .browser(host: "example.com"), scope: .workflow(workflowID: "other"), maxTier: .consequential),
            PermissionGrant(capability: .browser(host: "docs.example.com"), scope: .persistent, maxTier: .consequential),
            PermissionGrant(capability: .fileWrite(path: "/tmp/once"), scope: .once(callID: "call-1"), maxTier: .reversibleWrite),
            PermissionGrant(capability: .fileDelete(path: "/tmp/del"), scope: .persistent, maxTier: .consequential),
        ]
        let (engine, _, _, _) = makeEngine(grants: grants)
        let c = await engine.confinement(runID: "run-1", workflowID: "wf")
        #expect(c == Confinement(readRoots: ["/tmp/in"], writeRoots: ["/tmp/out"], networkHosts: ["api.example.com"], browserHosts: ["docs.example.com"]))
        let noWorkflow = await engine.confinement(runID: "run-9", workflowID: nil)
        #expect(noWorkflow == Confinement(readRoots: ["/tmp/in"], browserHosts: ["docs.example.com"]))
        #expect(!noWorkflow.allowsNetwork)
    }

    @Test func callsWithoutCapabilities() async {
        let (engine, _, _, _) = makeEngine()
        #expect(allowedIDs(await engine.evaluate(request([]))) == [])
        let ask = approval(await engine.evaluate(request([], tier: .consequential)))
        #expect(ask?.missing == [])
        #expect(ask?.reason.contains("no specific capability") == true)
    }

    @Test func scheduledRunsWaitForApproval() async {
        let (engine, _, _, _) = makeEngine()
        let ask = approval(await engine.evaluate(request([.externalSend(channel: "mail")], tier: .consequential, mode: .scheduled)))
        #expect(ask?.reason.contains("Scheduled runs wait") == true)
    }

    @Test func inMemoryStoreKeepsOrderAndRevocationDate() async {
        let store = InMemoryGrantStore()
        let a = PermissionGrant(id: "a", capability: .notify, scope: .persistent, maxTier: .reversibleWrite)
        let b = PermissionGrant(id: "b", capability: .clipboardRead, scope: .persistent, maxTier: .readOnly)
        await store.saveGrant(a); await store.saveGrant(b); await store.saveGrant(a)
        #expect(await store.allGrants().map(\.id) == ["a", "b"])
        let first = Date(timeIntervalSince1970: 10)
        await store.revokeGrant(id: "a", at: first)
        await store.revokeAllGrants(at: Date(timeIntervalSince1970: 20))
        let all = await store.allGrants()
        #expect(all[0].revokedAt == first)
        #expect(all[1].revokedAt == Date(timeIntervalSince1970: 20))
    }
}
