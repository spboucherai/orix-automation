// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXPersistence/Sources/ORIXPersistence/ORIXStore+Grants.swift
// Description      : Durable permission grants (GrantStoring) and cross-process
//                    leases that keep a single scheduler active.
// Module           : ORIXPersistence
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

extension ORIXStore {
    // MARK: GrantStoring (never throws: failures are logged and read as "no grant", which denies)

    public func allGrants() async -> [PermissionGrant] {
        do { return try storedGrants() } catch {
            logger.error("grants could not be read, treating as none: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func saveGrant(_ grant: PermissionGrant) async {
        do { try writeGrant(grant); hub.publish(.grants) } catch {
            logger.error("grant \(grant.id, privacy: .public) was not stored: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func revokeGrant(id: String, at date: Date) async {
        do {
            try db.run("UPDATE grants SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL", [.date(date), .text(id)])
            hub.publish(.grants)
        } catch {
            logger.error("grant \(id, privacy: .public) was not revoked: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func revokeAllGrants(at date: Date) async {
        do {
            try db.run("UPDATE grants SET revoked_at = ? WHERE revoked_at IS NULL", [.date(date)])
            hub.publish(.grants)
        } catch {
            logger.error("revoke-all failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Throwing read used by the management UI. Oldest first. Rows with a capability kind this version does not know are skipped.
    public func storedGrants() throws -> [PermissionGrant] {
        try db.query("""
        SELECT id, capability_kind, capability_scope, scope_kind, scope_ref, max_tier, created_at, expires_at, revoked_at, source, note
        FROM grants ORDER BY created_at, id
        """) { row -> PermissionGrant? in
            guard let capability = Capability(kind: row.text(1), scope: row.text(2)),
                  let tier = ApprovalTier(rawValue: row.int(5)) else { return nil }
            let scope: GrantScope
            switch row.text(3) {
            case "once": scope = .once(callID: row.text(4))
            case "run": scope = .run(runID: row.text(4))
            case "workflow": scope = .workflow(workflowID: row.text(4))
            case "persistent": scope = .persistent
            default: return nil
            }
            return PermissionGrant(id: row.text(0), capability: capability, scope: scope, maxTier: tier, createdAt: row.date(6),
                                   expiresAt: row.optionalDate(7), revokedAt: row.optionalDate(8), source: row.text(9), note: row.text(10))
        }.compactMap { $0 }
    }

    func writeGrant(_ grant: PermissionGrant) throws {
        let (kind, ref): (String, String)
        switch grant.scope {
        case .once(let callID): (kind, ref) = ("once", callID)
        case .run(let runID): (kind, ref) = ("run", runID)
        case .workflow(let workflowID): (kind, ref) = ("workflow", workflowID)
        case .persistent: (kind, ref) = ("persistent", "")
        }
        try db.run("""
        INSERT INTO grants(id, capability_kind, capability_scope, scope_kind, scope_ref, max_tier, created_at, expires_at, revoked_at, source, note)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET capability_kind=excluded.capability_kind, capability_scope=excluded.capability_scope,
            scope_kind=excluded.scope_kind, scope_ref=excluded.scope_ref, max_tier=excluded.max_tier, created_at=excluded.created_at,
            expires_at=excluded.expires_at, revoked_at=excluded.revoked_at, source=excluded.source, note=excluded.note
        """, [.text(grant.id), .text(grant.capability.kind), .text(grant.capability.scope), .text(kind), .text(ref),
              .int(grant.maxTier.rawValue), .date(grant.createdAt), .optionalDate(grant.expiresAt), .optionalDate(grant.revokedAt),
              .text(grant.source), .text(grant.note)])
    }

    /// Permanently removes grants that were revoked, or expired, before `before`. Active grants are never removed.
    @discardableResult
    public func deleteInactiveGrants(before: Date) throws -> Int {
        let removed = try db.run("DELETE FROM grants WHERE (revoked_at IS NOT NULL AND revoked_at < ?1) OR (expires_at IS NOT NULL AND expires_at < ?1)", [.date(before)])
        if removed > 0 { hub.publish(.grants) }
        return removed
    }

    // MARK: Leases

    /// Takes or renews the named lease for `owner`. Atomic across processes: true for exactly one contender.
    /// The same owner may call again to renew; another owner succeeds only once the lease has expired or was released.
    public func acquireLease(name: String, owner: String, ttlSeconds: Double) throws -> Bool {
        guard !name.isEmpty, !owner.isEmpty, ttlSeconds > 0 else { throw StoreError.invalidArgument("lease name, owner and a positive ttl are required") }
        let now = Date()
        let changed = try db.run("""
        INSERT INTO leases(name, owner, acquired_at, expires_at) VALUES(?1, ?2, ?3, ?4)
        ON CONFLICT(name) DO UPDATE SET
            acquired_at = CASE WHEN leases.owner = excluded.owner THEN leases.acquired_at ELSE excluded.acquired_at END,
            owner = excluded.owner, expires_at = excluded.expires_at
        WHERE leases.owner = excluded.owner OR leases.expires_at <= ?3
        """, [.text(name), .text(owner), .date(now), .date(now.addingTimeInterval(ttlSeconds))])
        return changed == 1
    }

    /// Gives the lease up. Only its owner can release it; returns false otherwise.
    @discardableResult
    public func releaseLease(name: String, owner: String) throws -> Bool {
        try db.run("DELETE FROM leases WHERE name = ? AND owner = ?", [.text(name), .text(owner)]) == 1
    }

    /// Who holds an unexpired lease, if anyone.
    public func leaseOwner(name: String) throws -> String? {
        try db.query("SELECT owner FROM leases WHERE name = ? AND expires_at > ?", [.text(name), .date(Date())]) { $0.text(0) }.first
    }
}
