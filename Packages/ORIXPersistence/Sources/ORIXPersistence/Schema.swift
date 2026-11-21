// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXPersistence/Sources/ORIXPersistence/Schema.swift
// Description      : Ordered, explicit schema migrations keyed by SQLite
//                    user_version. Never edit a shipped migration: append a new
//                    one.
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

enum Schema {
    /// All timestamps are REAL seconds since 2001-01-01 UTC (the exact `Date` value), so they round-trip bit for bit.
    static let migrations: [Migration] = [
        Migration(version: 1, sql: """
        CREATE TABLE runs(
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL,
            session_id TEXT,
            workflow_id TEXT,
            workflow_version INTEGER,
            trigger_kind TEXT NOT NULL,
            mode TEXT NOT NULL,
            status TEXT NOT NULL,
            queued_at REAL NOT NULL,
            started_at REAL,
            ended_at REAL,
            tokens INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0,
            error_summary TEXT,
            parent_run_id TEXT,
            updated_at REAL NOT NULL,
            json TEXT NOT NULL
        );
        CREATE INDEX runs_by_queue ON runs(queued_at DESC);
        CREATE INDEX runs_by_status ON runs(status);
        CREATE INDEX runs_by_workflow ON runs(workflow_id, queued_at DESC);

        -- No foreign key to runs: events may be emitted before the run row is first saved. deleteRun removes them.
        CREATE TABLE events(
            run_id TEXT NOT NULL,
            seq INTEGER NOT NULL,
            id TEXT NOT NULL,
            ts REAL NOT NULL,
            kind TEXT NOT NULL,
            step_id TEXT,
            text TEXT NOT NULL,
            data TEXT NOT NULL,
            PRIMARY KEY(run_id, seq)
        ) WITHOUT ROWID;

        CREATE TABLE receipts(
            run_id TEXT PRIMARY KEY NOT NULL,
            saved_at REAL NOT NULL,
            json TEXT NOT NULL
        );

        CREATE TABLE documents(
            collection TEXT NOT NULL,
            id TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            json TEXT NOT NULL,
            PRIMARY KEY(collection, id)
        );
        CREATE INDEX documents_by_update ON documents(collection, updated_at DESC);

        CREATE TABLE workflows(
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            current_version INTEGER NOT NULL,
            published_version INTEGER,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE workflow_versions(
            workflow_id TEXT NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
            version INTEGER NOT NULL,
            source TEXT NOT NULL,
            format TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            PRIMARY KEY(workflow_id, version)
        );

        CREATE TABLE grants(
            id TEXT PRIMARY KEY NOT NULL,
            capability_kind TEXT NOT NULL,
            capability_scope TEXT NOT NULL,
            scope_kind TEXT NOT NULL,
            scope_ref TEXT NOT NULL DEFAULT '',
            max_tier INTEGER NOT NULL,
            created_at REAL NOT NULL,
            expires_at REAL,
            revoked_at REAL,
            source TEXT NOT NULL,
            note TEXT NOT NULL
        );
        """),
        // 2: cross-process leases (single scheduler) and the index used by pruning and the usage dashboard.
        Migration(version: 2, sql: """
        CREATE TABLE leases(
            name TEXT PRIMARY KEY NOT NULL,
            owner TEXT NOT NULL,
            acquired_at REAL NOT NULL,
            expires_at REAL NOT NULL
        );
        CREATE INDEX runs_by_end ON runs(ended_at);
        CREATE INDEX grants_by_scope ON grants(scope_kind, scope_ref);
        """),
    ]

    static var latestVersion: Int { migrations.map(\.version).max() ?? 0 }
}
