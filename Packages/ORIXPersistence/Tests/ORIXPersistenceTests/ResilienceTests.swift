// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXPersistence/Tests/ORIXPersistenceTests/ResilienceTests.swift
// Description      : Integration tests on real files: migrations from an older
//                    schema, lease contention between two connections,
//                    corrupt-file quarantine, backup, export/import.
// Module           : ORIXPersistenceTests
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
@testable import ORIXPersistence

@Suite("ORIXStore migrations and recovery (integration, real SQLite files)")
struct MigrationTests {
    @Test func migratesFromAnOlderUserVersionKeepingData() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("orix.sqlite")
        let run = makeRun("legacy", title: "From version 1", status: .succeeded)
        do {
            // A database as version 1 of the schema left it: no leases table.
            let old = try Database(path: url.path)
            try old.configure()
            try old.migrate(Schema.migrations, upTo: 1)
            #expect(try old.userVersion() == 1)
            #expect(try old.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name = 'leases'") == 0)
            let json = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
            try old.run("""
            INSERT INTO runs(id, kind, title, trigger_kind, mode, status, queued_at, updated_at, json) VALUES(?,?,?,?,?,?,?,?,?)
            """, [.text(run.id), .text(run.kind), .text(run.title), .text(run.trigger), .text(run.mode.rawValue), .text(run.status.rawValue),
                  .date(run.queuedAt), .date(Date()), .text(json)])
            try old.run("INSERT INTO workflows(id, name, current_version, created_at, updated_at) VALUES('wf','Old',1,0,0)")
            try old.run("INSERT INTO workflow_versions(workflow_id, version, source, format, created_at) VALUES('wf',1,'old source','yaml',0)")
            old.close()
        }
        let store = try ORIXStore(url: url)
        #expect(store.recoveryNote == nil)
        #expect(try await store.run(id: "legacy") == run)
        #expect(try await store.workflowSource(workflowID: "wf", version: nil) == "old source")
        // The table added by migration 2 works.
        #expect(try await store.acquireLease(name: "scheduler", owner: "me", ttlSeconds: 10))
        let check = try Database(path: url.path)
        #expect(try check.userVersion() == Schema.latestVersion)
        #expect(Schema.latestVersion >= 2)
        check.close()
    }

    @Test func freshDatabaseIsAtLatestVersionWithWALAndForeignKeys() throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let db = try Database(path: tmp.file("fresh.sqlite").path)
        try db.configure()
        try db.migrate(Schema.migrations)
        try db.migrate(Schema.migrations)
        #expect(try db.userVersion() == Schema.latestVersion)
        #expect(try db.query("PRAGMA journal_mode") { $0.text(0) } == ["wal"])
        #expect(try db.scalarInt("PRAGMA foreign_keys") == 1)
        #expect(try db.scalarInt("PRAGMA busy_timeout") == 5000)
        #expect(try db.quickCheck() == nil)
        // Foreign keys are enforced: a version without its workflow is refused.
        #expect(throws: SQLiteError.self) {
            try db.run("INSERT INTO workflow_versions(workflow_id, version, source, format, created_at) VALUES('ghost',1,'s','yaml',0)")
        }
        // A failing transaction leaves nothing behind.
        #expect(throws: SQLiteError.self) {
            try db.transaction {
                try db.run("INSERT INTO leases(name, owner, acquired_at, expires_at) VALUES('a','o',0,0)")
                try db.run("INSERT INTO no_such_table VALUES(1)")
            }
        }
        #expect(try db.scalarInt("SELECT COUNT(*) FROM leases") == 0)
    }

    @Test func aNewerSchemaIsRefusedAndLeftUntouched() throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("future.sqlite")
        do {
            let db = try Database(path: url.path)
            try db.configure()
            try db.migrate(Schema.migrations)
            try db.exec("PRAGMA user_version = 999")
            db.close()
        }
        #expect(throws: StoreError.newerSchema(found: 999, supported: Schema.latestVersion)) { _ = try ORIXStore(url: url) }
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        #expect(!names.contains { $0.contains(".corrupt-") })
    }

    @Test func corruptFileIsQuarantinedAndAWorkingStoreIsCreated() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("orix.sqlite")
        let garbage = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try garbage.write(to: url)

        let store = try ORIXStore(url: url)
        let note = try #require(store.recoveryNote)
        #expect(note.contains("damaged") && note.contains(".corrupt-"))
        let aside = try #require(store.quarantinedFile)
        #expect(aside.lastPathComponent.hasPrefix("orix.sqlite.corrupt-"))
        // The damaged file is kept byte for byte.
        #expect(try Data(contentsOf: aside) == garbage)
        // The new store works.
        try await store.saveRun(makeRun("after", status: .running))
        await store.emit(RunEvent(runID: "after", kind: .log, text: "alive"))
        #expect(try await store.run(id: "after")?.id == "after")
        #expect(try await store.eventCount(runID: "after") == 1)
        // Opening again is a normal open: no second quarantine.
        let again = try ORIXStore(url: url)
        #expect(again.recoveryNote == nil)
        #expect(try await again.run(id: "after") != nil)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).filter { $0.contains(".corrupt-") }
        #expect(quarantined.count == 1)
    }

    @Test func damagedPagesInsideARealDatabaseAreQuarantined() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("orix.sqlite")
        do {
            let store = try ORIXStore(url: url)
            for i in 0..<400 { try await store.saveRun(makeRun("run-\(i)", title: String(repeating: "x", count: 500), status: .succeeded)) }
            try await store.backup(to: tmp.file("compact.sqlite"))
        }
        // Use the compacted copy (no WAL) and overwrite pages in the middle of it.
        let damaged = tmp.file("damaged.sqlite")
        try FileManager.default.copyItem(at: tmp.file("compact.sqlite"), to: damaged)
        let handle = try FileHandle(forWritingTo: damaged)
        try handle.seek(toOffset: 4096 * 3)
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 4096 * 20))
        try handle.close()

        let store = try ORIXStore(url: damaged)
        #expect(store.recoveryNote != nil)
        #expect(store.quarantinedFile != nil)
        #expect(try await store.runs().isEmpty)
        try await store.saveRun(makeRun("new"))
        #expect(try await store.runs().count == 1)
    }
}

@Suite("ORIXStore leases across two connections (integration, same SQLite file)")
struct LeaseTests {
    @Test func onlyOneContenderWinsAndTheLeaseCanBeRenewedReleasedAndStolen() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("orix.sqlite")
        let app = try ORIXStore(url: url)
        let agent = try ORIXStore(url: url)

        // Many rounds of simultaneous attempts from both connections: exactly one winner each time.
        for round in 0..<25 {
            let name = "scheduler-\(round)"
            let winners = await withTaskGroup(of: String?.self) { group -> [String] in
                for i in 0..<8 {
                    let owner = "owner-\(i)"
                    let store = i % 2 == 0 ? app : agent
                    group.addTask { (try? await store.acquireLease(name: name, owner: owner, ttlSeconds: 30)) == true ? owner : nil }
                }
                var out: [String] = []
                for await w in group { if let w { out.append(w) } }
                return out
            }
            #expect(winners.count == 1, "round \(round): \(winners)")
            #expect(try await agent.leaseOwner(name: name) == winners.first)
        }

        #expect(try await app.acquireLease(name: "scheduler", owner: "app", ttlSeconds: 0.4))
        #expect(try await !agent.acquireLease(name: "scheduler", owner: "agent", ttlSeconds: 0.4))
        // Renewal by the owner, seen by the other connection.
        #expect(try await app.acquireLease(name: "scheduler", owner: "app", ttlSeconds: 0.4))
        #expect(try await agent.leaseOwner(name: "scheduler") == "app")
        // Only the owner can release.
        #expect(try await !agent.releaseLease(name: "scheduler", owner: "agent"))
        #expect(try await !agent.acquireLease(name: "scheduler", owner: "agent", ttlSeconds: 0.4))
        // After expiry the other process takes over, and the former owner is refused.
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await agent.leaseOwner(name: "scheduler") == nil)
        #expect(try await agent.acquireLease(name: "scheduler", owner: "agent", ttlSeconds: 30))
        #expect(try await !app.acquireLease(name: "scheduler", owner: "app", ttlSeconds: 30))
        // Release hands it over immediately.
        #expect(try await agent.releaseLease(name: "scheduler", owner: "agent"))
        #expect(try await app.acquireLease(name: "scheduler", owner: "app", ttlSeconds: 30))
        await #expect(throws: StoreError.self) { _ = try await app.acquireLease(name: "", owner: "app", ttlSeconds: 1) }
    }

    @Test func twoConnectionsSeeEachOthersWrites() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("orix.sqlite")
        let app = try ORIXStore(url: url)
        let agent = try ORIXStore(url: url)
        try await agent.saveRun(makeRun("bg", status: .running))
        #expect(try await app.run(id: "bg")?.status == .running)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<60 {
                group.addTask { try? await (i % 2 == 0 ? app : agent).saveRun(makeRun("run-\(i)", status: .succeeded)) }
                group.addTask { try? await (i % 2 == 0 ? agent : app).put(Note(title: "n\(i)", body: "", count: i, when: Date()), collection: "notes", id: "\(i)") }
            }
        }
        #expect(try await app.runs(limit: 500).count == 61)
        #expect(try await agent.count(collection: "notes") == 60)
    }
}

@Suite("ORIXStore backup and export/import (integration, real files)")
struct BundleTests {
    @Test func backupIsAConsistentOpenableCopy() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let store = try ORIXStore(url: tmp.file("orix.sqlite"))
        try await store.saveRun(makeRun("r", status: .succeeded))
        await store.emit(RunEvent(runID: "r", kind: .log, text: "x"))
        try await store.saveWorkflowVersion(workflowID: "wf", name: "W", source: "s")
        #expect(try await store.databaseSizeBytes() > 0)
        let target = tmp.file("backups/copy.sqlite")
        try await store.backup(to: target)
        await #expect(throws: StoreError.fileExists(target.path)) { try await store.backup(to: target) }
        let copy = try ORIXStore(url: target)
        #expect(copy.recoveryNote == nil)
        #expect(try await copy.run(id: "r") != nil)
        #expect(try await copy.eventCount(runID: "r") == 1)
        #expect(try await copy.workflowSource(workflowID: "wf") == "s")
        #expect(try await ORIXStore.inMemory().databaseSizeBytes() > 0)
    }

    @Test func exportImportRoundTripExcludesGrantsRunsAndSecrets() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let source = try ORIXStore(url: tmp.file("source.sqlite"))
        let literal = "orix-bundle-literal-\(UUID().uuidString)"
        Redactor.shared.register(secret: literal)
        defer { Redactor.shared.unregister(secret: literal) }

        try await source.saveWorkflowVersion(workflowID: "wf", name: "Report", source: "steps: [one]", note: "v1")
        try await source.saveWorkflowVersion(workflowID: "wf", name: "Report", source: "steps: [one, two]\nauth: \"{{ secrets.github }}\"\ntoken: ${GITHUB_TOKEN_REFERENCE}", note: "v2")
        try await source.saveWorkflowVersion(workflowID: "wf", name: "Report", source: "steps: [one, two, three]", note: "v3")
        try await source.publish(workflowID: "wf", version: 2)
        try await source.saveWorkflowVersion(workflowID: "leaky", name: "Leaky", source: "run: curl -H 'x: \(literal)' https://example.com")

        let profile = AgentProfile(id: "agent-1", name: "Worker", instructions: "Be careful.", model: ModelRef(provider: .anthropic, model: "m"),
                                   budget: Budget(maxTotalTokens: 123_456))
        let when = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
        try await source.put(profile, collection: "agents", id: profile.id)
        try await source.put(Note(title: "Plain", body: "nothing special", count: 7, when: when), collection: "notes", id: "plain")
        try await source.put(Note(title: "Leak", body: "key sk-ant-REDACTME0123456789abcdefghij and \(literal)", count: 1, when: when), collection: "notes", id: "leak")
        try await source.put(Note(title: "s", body: "vault content", count: 0, when: when), collection: "secrets", id: "1")
        try await source.put(Note(title: "c", body: "cache", count: 0, when: when), collection: "cache", id: "1")
        await source.saveGrant(PermissionGrant(id: "grant-1", capability: .fileWrite(path: "/Users/x/GRANTED-PATH"), scope: .persistent, maxTier: .consequential))
        try await source.saveRun(makeRun("run-in-source", title: "RUN-TITLE-MARKER", status: .succeeded))
        await source.emit(RunEvent(runID: "run-in-source", kind: .log, text: "EVENT-TEXT-MARKER"))

        let file = tmp.file("export/bundle.json")
        let exported = try await source.exportBundle(to: file, excludingCollections: ["cache"])
        #expect(exported.workflows == 2 && exported.workflowVersions == 4 && exported.documents == 3)
        #expect(exported.excludedCollections == ["cache", "secrets"])
        #expect(exported.redactedValues == 2)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("GRANTED-PATH") && !text.contains("grant-1"))
        #expect(!text.contains("RUN-TITLE-MARKER") && !text.contains("EVENT-TEXT-MARKER"))
        #expect(!text.contains("vault content") && !text.contains("\"cache\""))
        #expect(!text.contains(literal) && !text.contains("REDACTME"))
        #expect(text.contains("{{ secrets.github }}") && text.contains("${GITHUB_TOKEN_REFERENCE}"))
        #expect(try JSONValue.parse(text)["format"]?.stringValue == StoreBundle.formatIdentifier)

        // Import into an empty store.
        let target = try ORIXStore(url: tmp.file("target.sqlite"))
        let imported = try await target.importBundle(from: file)
        #expect(imported.workflows == 2 && imported.workflowVersions == 4 && imported.documents == 3)
        let row = try #require(try await target.workflow(id: "wf"))
        #expect(row.name == "Report" && row.currentVersion == 3 && row.publishedVersion == 2)
        let sourceHistory = try await source.workflowVersions(workflowID: "wf")
        let history = try await target.workflowVersions(workflowID: "wf")
        #expect(history.map(\.version) == [3, 2, 1])
        #expect(history.map(\.source) == sourceHistory.map(\.source))
        #expect(history.map(\.note) == ["v3", "v2", "v1"])
        #expect(try await target.workflowSource(workflowID: "leaky")?.contains(Redactor.placeholder) == true)
        #expect(try await target.get(AgentProfile.self, collection: "agents", id: "agent-1") == profile)
        #expect(try await target.get(Note.self, collection: "notes", id: "plain") == Note(title: "Plain", body: "nothing special", count: 7, when: when))
        #expect(try await target.get(Note.self, collection: "notes", id: "leak")?.body == "key \(Redactor.placeholder) and \(Redactor.placeholder)")
        #expect(try await target.count(collection: "secrets") == 0)
        #expect(try await target.count(collection: "cache") == 0)
        #expect(await target.allGrants().isEmpty)
        #expect(try await target.runs().isEmpty)

        // Importing the same bundle again changes nothing.
        let again = try await target.importBundle(from: file)
        #expect(again.workflowVersions == 0)
        #expect(try await target.workflowVersions(workflowID: "wf").count == 3)
        #expect(try await target.count(collection: "notes") == 2)
    }

    @Test func importMergesWithoutDestroyingLocalHistory() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let source = try ORIXStore.inMemory()
        try await source.saveWorkflowVersion(workflowID: "wf", name: "Remote name", source: "remote v1")
        try await source.saveWorkflowVersion(workflowID: "wf", name: "Remote name", source: "remote v2")
        try await source.put(Note(title: "remote", body: "", count: 1, when: Date()), collection: "notes", id: "shared")
        let file = tmp.file("bundle.json")
        try await source.exportBundle(to: file)

        let local = try ORIXStore.inMemory()
        try await local.saveWorkflowVersion(workflowID: "wf", name: "Local name", source: "local v1")
        try await local.publish(workflowID: "wf", version: 1)
        try await local.put(Note(title: "local", body: "", count: 2, when: Date()), collection: "notes", id: "shared")

        let kept = try await local.importBundle(from: file, overwriteDocuments: false)
        #expect(kept.documents == 0 && kept.workflowVersions == 1)
        #expect(try await local.get(Note.self, collection: "notes", id: "shared")?.title == "local")
        #expect(try await local.workflowVersions(workflowID: "wf").map(\.source) == ["remote v2", "local v1"])
        #expect(try await local.workflow(id: "wf")?.publishedVersion == 1)
        #expect(try await local.workflow(id: "wf")?.name == "Remote name")
        _ = try await local.importBundle(from: file)
        #expect(try await local.get(Note.self, collection: "notes", id: "shared")?.title == "remote")
    }

    @Test func invalidBundlesAreRefusedWithoutSideEffects() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let store = try ORIXStore.inMemory()
        try tmp.write("garbage.json", "this is not json")
        try tmp.write("other.json", #"{"format":"something.else","version":1,"exportedAt":0,"workflows":[],"documents":[]}"#)
        try tmp.write("future.json", #"{"format":"ai.spboucher.orix.automation.bundle","version":99,"exportedAt":0,"workflows":[],"documents":[]}"#)
        try tmp.write("sneaky.json", """
        {"format":"ai.spboucher.orix.automation.bundle","version":1,"exportedAt":0,"workflows":[],
         "documents":[{"collection":"grants","id":"g","createdAt":0,"updatedAt":0,"value":{"x":1}},
                      {"collection":"notes","id":"ok","createdAt":0,"updatedAt":0,"value":{"x":1}}]}
        """)
        for name in ["garbage.json", "other.json", "future.json", "missing.json"] {
            await #expect(throws: StoreError.self) { try await store.importBundle(from: tmp.file(name)) }
        }
        #expect(try await store.collections().isEmpty)
        let sneaky = try await store.importBundle(from: tmp.file("sneaky.json"))
        #expect(sneaky.documents == 1 && sneaky.excludedCollections == ["grants"])
        #expect(try await store.collections() == ["notes"])
        #expect(await store.allGrants().isEmpty)
    }
}
