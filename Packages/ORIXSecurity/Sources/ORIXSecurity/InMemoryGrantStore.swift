// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXSecurity/Sources/ORIXSecurity/InMemoryGrantStore.swift
// Description      : Non-durable GrantStoring implementation for tests,
//                    previews and runs that must not persist any grant.
// Module           : ORIXSecurity
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
