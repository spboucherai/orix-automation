// ORIX OS Automation
// File: Packages/ORIXSecurity/Sources/ORIXSecurity/InMemoryGrantStore.swift
// Description: Non-durable GrantStoring implementation for tests, previews and runs that must not persist any grant.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

/// Keeps grants in memory, in insertion order. Nothing survives the process.
public actor InMemoryGrantStore: GrantStoring {
    private var grants: [String: PermissionGrant] = [:]
    private var order: [String] = []

    public init(grants: [PermissionGrant] = []) {
        for g in grants where self.grants[g.id] == nil {
            self.grants[g.id] = g
            order.append(g.id)
        }
    }

    public func allGrants() async -> [PermissionGrant] {
        order.compactMap { grants[$0] }
    }

    public func saveGrant(_ grant: PermissionGrant) async {
        if grants[grant.id] == nil { order.append(grant.id) }
        grants[grant.id] = grant
    }

    public func revokeGrant(id: String, at date: Date) async {
        guard var g = grants[id], g.revokedAt == nil else { return }
        g.revokedAt = date
        grants[id] = g
    }

    public func revokeAllGrants(at date: Date) async {
        for id in order {
            guard var g = grants[id], g.revokedAt == nil else { continue }
            g.revokedAt = date
            grants[id] = g
        }
    }
}
