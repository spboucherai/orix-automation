// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXPersistence/Tests/ORIXPersistenceTests/StoreTests.swift
// Description      : Integration tests of ORIXStore on real SQLite files: runs,
//                    events, receipts, documents, workflows, grants,
//                    aggregates, notifications.
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

func makeRun(_ id: String, title: String = "Run", status: RunStatus = .queued, workflow: String? = nil, queuedAt: Date = Date(),
             tokens: Int = 0, cost: Double = 0, error: String? = nil) -> RunRecord {
    var run = RunRecord(id: id, kind: workflow == nil ? "agent" : "workflow", title: title, workflowID: workflow, mode: .guided, status: status,
                        model: ModelRef(provider: .anthropic, model: "test-model"), queuedAt: queuedAt, errorSummary: error)
    run.usage.tokens = TokenUsage(inputTokens: tokens)
    run.usage.costUSD = cost
    if status.isTerminal { run.startedAt = queuedAt; run.endedAt = queuedAt.addingTimeInterval(5) }
    return run
}

struct Note: Codable, Sendable, Hashable {
    var title: String
    var body: String
    var count: Int
    var when: Date
}

@Suite("ORIXStore runs, events, receipts (integration, real SQLite file)")
struct StoreRunTests {
    @Test func runRoundTripUpsertAndFilters() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let store = try ORIXStore(url: tmp.file("db/orix.sqlite"))
        #expect(store.recoveryNote == nil)
        let base = Date()
        var a = makeRun("a", title: "Weekly report", workflow: "wf-1", queuedAt: base.addingTimeInterval(-30))
        let b = makeRun("b", title: "Sort downloads", status: .failed, queuedAt: base.addingTimeInterval(-20), error: "Disk 100% full")
        let c = makeRun("c", title: "Rename_files", status: .succeeded, workflow: "wf-1", queuedAt: base.addingTimeInterval(-10))
        for run in [a, b, c] { try await store.saveRun(run) }
        #expect(try await store.run(id: "a") == a)
        #expect(try await store.run(id: "missing") == nil)

        a.status = .running; a.startedAt = base; a.usage.turns = 3
        try await store.saveRun(a)
        #expect(try await store.run(id: "a") == a)
        #expect(try await store.runs().map(\.id) == ["c", "b", "a"])
        #expect(try await store.runs(limit: 1, offset: 1).map(\.id) == ["b"])
        #expect(try await store.runs(status: .failed).map(\.id) == ["b"])
        #expect(try await store.runs(workflowID: "wf-1").map(\.id) == ["c", "a"])
        #expect(try await store.runs(search: "REPORT").map(\.id) == ["a"])
        #expect(try await store.runs(search: "disk 100%").map(\.id) == ["b"])
        // LIKE wildcards in the query are literal.
        #expect(try await store.runs(search: "%").map(\.id) == ["b"])
        #expect(try await store.runs(search: "Rename_").map(\.id) == ["c"])
        #expect(try await store.runs(search: "Sort_").isEmpty)
        #expect(try await store.runs(status: .succeeded, workflowID: "wf-1", search: "rename").map(\.id) == ["c"])
        #expect(try await store.activeRuns().map(\.id) == ["a"])
    }

    @Test func eventsGetMonotonicSequencePerRun() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let store = try ORIXStore(url: tmp.file("orix.sqlite"))
        for i in 1...5 {
            await store.emit(RunEvent(runID: "r1", seq: 999, kind: .log, stepID: i == 2 ? "step-a" : nil, text: "line \(i)", data: ["i": .int(i)]))
        }
        await store.emit(RunEvent(runID: "r2", kind: .statusChanged, text: "other run"))
        let events = try await store.events(runID: "r1")
        #expect(events.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(events.map(\.text) == (1...5).map { "line \($0)" })
        #expect(events[1].stepID == "step-a")
        #expect(events[4].data == ["i": 5])
        #expect(try await store.events(runID: "r2").map(\.seq) == [1])
        #expect(try await store.events(runID: "r1", afterSeq: 3).map(\.seq) == [4, 5])
        #expect(try await store.events(runID: "r1", afterSeq: 1, limit: 2).map(\.seq) == [2, 3])
        #expect(try await store.eventCount(runID: "r1") == 5)
        let original = RunEvent(runID: "r1", kind: .toolFinished, text: "done", data: ["status": "succeeded"])
        let stored = try await store.append(original)
        #expect(stored.seq == 6)
        #expect(try await store.events(runID: "r1", afterSeq: 5) == [stored])
    }

    @Test func concurrentEmitsFromTwoConnectionsNeverCollide() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("orix.sqlite")
        let a = try ORIXStore(url: url)
        let b = try ORIXStore(url: url)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<300 {
                group.addTask { await (i % 2 == 0 ? a : b).emit(RunEvent(runID: "shared", kind: .log, text: "e\(i)")) }
                if i % 3 == 0 { group.addTask { await a.emit(RunEvent(runID: "other", kind: .log, text: "o\(i)")) } }
            }
        }
        let events = try await b.events(runID: "shared", limit: 1000)
        #expect(events.count == 300)
        #expect(events.map(\.seq) == Array(1...300))
        #expect(Set(events.map(\.text)).count == 300)
        #expect(try await a.events(runID: "other", limit: 1000).map(\.seq) == Array(1...100))
    }

    @Test func deletingARunCascadesToEventsAndReceipt() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let store = try ORIXStore(url: tmp.file("orix.sqlite"))
        for id in ["keep", "drop"] {
            try await store.saveRun(makeRun(id, status: .succeeded))
            for _ in 0..<4 { await store.emit(RunEvent(runID: id, kind: .log, text: id)) }
            try await store.saveReceipt(RunReceipt(runID: id, title: id, status: .succeeded, objective: "o", model: nil, startedAt: Date(), endedAt: Date(), usage: .init()))
        }
        #expect(try await store.deleteRun(id: "drop"))
        #expect(try await !store.deleteRun(id: "drop"))
        #expect(try await store.run(id: "drop") == nil)
        #expect(try await store.eventCount(runID: "drop") == 0)
        #expect(try await store.receipt(runID: "drop") == nil)
        #expect(try await store.eventCount(runID: "keep") == 4)
        #expect(try await store.receipt(runID: "keep") != nil)
    }

    @Test func receiptRoundTrip() async throws {
        let store = try ORIXStore.inMemory()
        var usage = RunUsage(); usage.turns = 4; usage.costUSD = 0.0123; usage.costIsComplete = false
        let receipt = RunReceipt(runID: "r", title: "T", status: .partiallySucceeded, objective: "Do it", model: ModelRef(provider: .openai, model: "m"),
                                 startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.125), endedAt: Date(timeIntervalSinceReferenceDate: 800_000_100.5),
                                 usage: usage,
                                 toolCalls: [ToolCallRecord(id: "c1", toolID: "filesystem.read", arguments: ["path": "/tmp/a"], status: .succeeded, summary: "read", durationMs: 12, tier: .readOnly)],
                                 approvals: ["approved once"], permissionsUsed: ["file.read → /tmp"],
                                 artifacts: [Artifact(path: "/tmp/out.pdf", bytes: 10, sha256: "abc")],
                                 verifications: [VerificationResult(assertion: "exists", kind: "file_exists", passed: true, evidence: "10 bytes")],
                                 agentSummary: "done", limitations: ["none"], errors: ["one"])
        try await store.saveReceipt(receipt)
        #expect(try await store.receipt(runID: "r") == receipt)
        var changed = receipt; changed.status = .succeeded
        try await store.saveReceipt(changed)
        #expect(try await store.receipt(runID: "r")?.status == .succeeded)
    }

    @Test func crashRecoveryMarksInterruptedRuns() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("orix.sqlite")
        do {
            // The "crashed" process: leaves runs in flight and never finishes them.
            let crashed = try ORIXStore(url: url)
            try await crashed.saveRun(makeRun("running", status: .running))
            try await crashed.saveRun(makeRun("queued", status: .queued))
            try await crashed.saveRun(makeRun("waiting", status: .waitingApproval, error: "needs approval"))
            try await crashed.saveRun(makeRun("done", status: .succeeded))
            try await crashed.saveRun(makeRun("failed", status: .failed))
        }
        try await Task.sleep(for: .milliseconds(20))
        let processStart = Date()
        let store = try ORIXStore(url: url)
        // A run started by the new process after it launched must not be touched.
        try await store.saveRun(makeRun("fresh", status: .running))

        let marked = try await store.markInterruptedRuns(olderThan: processStart)
        #expect(Set(marked.map(\.id)) == ["running", "queued", "waiting"])
        #expect(marked.allSatisfy { $0.status == .recoveryRequired })
        let running = try #require(try await store.run(id: "running"))
        #expect(running.status == .recoveryRequired)
        #expect(running.errorSummary?.contains("Interrupted while RUNNING") == true)
        #expect(try await store.run(id: "waiting")?.errorSummary == "needs approval")
        #expect(try await store.run(id: "done")?.status == .succeeded)
        #expect(try await store.run(id: "failed")?.status == .failed)
        #expect(try await store.run(id: "fresh")?.status == .running)
        #expect(try await store.activeRuns().map(\.id) == ["fresh"])
        #expect(try await store.runs(status: .recoveryRequired).count == 3)
        // Idempotent: nothing left to mark.
        #expect(try await store.markInterruptedRuns(olderThan: processStart).isEmpty)
    }

    @Test func usageAggregatesAndStatusCounts() async throws {
        let store = try ORIXStore.inMemory()
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
        let old = calendar.date(byAdding: .day, value: -40, to: noon)!
        try await store.saveRun(makeRun("t1", status: .succeeded, queuedAt: noon, tokens: 1000, cost: 0.25))
        try await store.saveRun(makeRun("t2", status: .failed, queuedAt: noon, tokens: 500, cost: 0.10))
        try await store.saveRun(makeRun("t3", status: .canceled, queuedAt: noon))
        try await store.saveRun(makeRun("y1", status: .timedOut, queuedAt: yesterday, tokens: 70, cost: 0.01))
        try await store.saveRun(makeRun("o1", status: .succeeded, queuedAt: old, tokens: 9999, cost: 9))

        let usage = try await store.usageByDay(days: 7)
        #expect(usage.count == 7)
        #expect(usage.map(\.date) == usage.map(\.date).sorted())
        let today = try #require(usage.last)
        #expect(today.date == calendar.startOfDay(for: Date()))
        #expect(today.runs == 3 && today.succeeded == 1 && today.failed == 1 && today.tokens == 1500)
        #expect(abs(today.costUSD - 0.35) < 1e-9)
        let previous = usage[5]
        #expect(previous.runs == 1 && previous.failed == 1 && previous.succeeded == 0 && previous.tokens == 70)
        #expect(usage.prefix(5).allSatisfy { $0.runs == 0 && $0.costUSD == 0 })
        #expect(today.day.count == 10)

        #expect(try await store.statusCounts() == [.succeeded: 2, .failed: 1, .canceled: 1, .timedOut: 1])
        #expect(try await store.statusCounts(sinceDays: 7) == [.succeeded: 1, .failed: 1, .canceled: 1, .timedOut: 1])
    }

    @Test func pruneRemovesOnlyOldFinishedRuns() async throws {
        let store = try ORIXStore.inMemory()
        let old = Date().addingTimeInterval(-40 * 86_400)
        try await store.saveRun(makeRun("old-done", status: .succeeded, queuedAt: old))
        try await store.saveRun(makeRun("old-waiting", status: .waitingApproval, queuedAt: old))
        try await store.saveRun(makeRun("new-done", status: .succeeded))
        await store.emit(RunEvent(runID: "old-done", kind: .log))
        await store.emit(RunEvent(runID: "new-done", kind: .log))
        #expect(try await store.pruneRuns(olderThanDays: 30) == 1)
        #expect(try await store.runs().map(\.id).sorted() == ["new-done", "old-waiting"])
        #expect(try await store.eventCount(runID: "old-done") == 0)
        #expect(try await store.eventCount(runID: "new-done") == 1)
        #expect(try await store.pruneRuns(olderThanDays: 30) == 0)
    }
}

@Suite("ORIXStore documents and workflows (integration, real SQLite)")
struct StoreDocumentTests {
    @Test func documentsRoundTripOrderAndRemoval() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let store = try ORIXStore(url: tmp.file("orix.sqlite"))
        let when = Date(timeIntervalSinceReferenceDate: 812_345_678.987654)
        let first = Note(title: "First", body: "héllo \"quoted\"\nline", count: 1, when: when)
        let second = Note(title: "Second", body: "", count: 2, when: when)
        try await store.put(first, collection: "notes", id: "1")
        try await Task.sleep(for: .milliseconds(5))
        try await store.put(second, collection: "notes", id: "2")
        try await store.put(AgentProfile(id: "agent-1", name: "Worker", instructions: "Work.", model: ModelRef(provider: .anthropic, model: "m")),
                            collection: "agents", id: "agent-1")
        #expect(try await store.get(Note.self, collection: "notes", id: "1") == first)
        #expect(try await store.get(Note.self, collection: "notes", id: "nope") == nil)
        #expect(try await store.get(Note.self, collection: "other", id: "1") == nil)
        #expect(try await store.all(Note.self, collection: "notes") == [second, first])
        #expect(try await store.get(AgentProfile.self, collection: "agents", id: "agent-1")?.name == "Worker")

        // Updating moves a document to the front and keeps a single copy.
        try await Task.sleep(for: .milliseconds(5))
        var edited = first; edited.count = 10
        try await store.put(edited, collection: "notes", id: "1")
        #expect(try await store.all(Note.self, collection: "notes") == [edited, second])
        #expect(try await store.count(collection: "notes") == 2)
        #expect(try await store.collections() == ["agents", "notes"])

        #expect(try await store.remove(collection: "notes", id: "2"))
        #expect(try await !store.remove(collection: "notes", id: "2"))
        #expect(try await store.count(collection: "notes") == 1)
        #expect(try await store.count(collection: "empty") == 0)
        await #expect(throws: StoreError.self) { try await store.put(first, collection: "", id: "x") }
    }

    @Test func workflowVersionHistorySemantics() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let store = try ORIXStore(url: tmp.file("orix.sqlite"))
        #expect(try await store.workflows().isEmpty)
        #expect(try await store.saveWorkflowVersion(workflowID: "wf", name: "Report", source: "steps: []", format: "yaml", note: "first") == 1)
        // Identical source: no new version; the name still follows.
        #expect(try await store.saveWorkflowVersion(workflowID: "wf", name: "Weekly report", source: "steps: []", format: "yaml", note: "ignored") == 1)
        #expect(try await store.workflowVersions(workflowID: "wf").count == 1)
        #expect(try await store.workflow(id: "wf")?.name == "Weekly report")
        #expect(try await store.saveWorkflowVersion(workflowID: "wf", name: "Weekly report", source: "steps: [a]", format: "yaml", note: "second") == 2)
        // Same text in another format is a different version; going back to an old source appends, never rewrites.
        #expect(try await store.saveWorkflowVersion(workflowID: "wf", name: "Weekly report", source: "steps: [a]", format: "json") == 3)
        #expect(try await store.saveWorkflowVersion(workflowID: "wf", name: "Weekly report", source: "steps: []", format: "yaml", note: "revert") == 4)

        let history = try await store.workflowVersions(workflowID: "wf")
        #expect(history.map(\.version) == [4, 3, 2, 1])
        #expect(history.map(\.note) == ["revert", "", "second", "first"])
        #expect(history.map(\.format) == ["yaml", "json", "yaml", "yaml"])
        #expect(try await store.workflowSource(workflowID: "wf", version: nil) == "steps: []")
        #expect(try await store.workflowSource(workflowID: "wf", version: 2) == "steps: [a]")
        #expect(try await store.workflowSource(workflowID: "wf", version: 9) == nil)
        #expect(try await store.workflowSource(workflowID: "none", version: nil) == nil)

        var row = try #require(try await store.workflow(id: "wf"))
        #expect(row.currentVersion == 4 && row.publishedVersion == nil)
        try await store.publish(workflowID: "wf", version: 2)
        row = try #require(try await store.workflow(id: "wf"))
        #expect(row.publishedVersion == 2 && row.currentVersion == 4)
        await #expect(throws: StoreError.notFound("Version 12 of workflow wf")) { try await store.publish(workflowID: "wf", version: 12) }
        await #expect(throws: StoreError.notFound("Workflow ghost")) { try await store.publish(workflowID: "ghost", version: 1) }
        await #expect(throws: StoreError.self) { try await store.saveWorkflowVersion(workflowID: "wf", name: "x", source: "s", format: "xml") }
        try await store.publish(workflowID: "wf", version: nil)
        #expect(try await store.workflow(id: "wf")?.publishedVersion == nil)

        try await Task.sleep(for: .milliseconds(5))
        try await store.saveWorkflowVersion(workflowID: "other", name: "Other", source: "{}", format: "json")
        #expect(try await store.workflows().map(\.id) == ["other", "wf"])

        // Deleting cascades to the history through the foreign key.
        #expect(try await store.deleteWorkflow(id: "wf"))
        #expect(try await !store.deleteWorkflow(id: "wf"))
        #expect(try await store.workflowVersions(workflowID: "wf").isEmpty)
        #expect(try await store.workflowVersions(workflowID: "other").count == 1)
        // A re-created workflow starts again at version 1.
        #expect(try await store.saveWorkflowVersion(workflowID: "wf", name: "Again", source: "new") == 1)
    }

    @Test func grantsPersistAcrossReopenWithExactDates() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("orix.sqlite")
        let created = Date()
        let grants = [
            PermissionGrant(id: "g1", capability: .fileRead(path: "/Users/x/Documents"), scope: .persistent, maxTier: .readOnly, createdAt: created),
            PermissionGrant(id: "g2", capability: .network(host: "*.example.com"), scope: .run(runID: "run-1"), maxTier: .consequential,
                            createdAt: created.addingTimeInterval(1), expiresAt: created.addingTimeInterval(3600.123456), source: "workflow:wf", note: "n"),
            PermissionGrant(id: "g3", capability: .clipboardWrite, scope: .once(callID: "call-9"), maxTier: .reversibleWrite, createdAt: created.addingTimeInterval(2)),
            PermissionGrant(id: "g4", capability: .skill(id: "pdf-tools"), scope: .workflow(workflowID: "wf"), maxTier: .highRisk, createdAt: created.addingTimeInterval(3)),
        ]
        do {
            let store = try ORIXStore(url: url)
            for g in grants { await store.saveGrant(g) }
            #expect(await store.allGrants() == grants)
        }
        let store = try ORIXStore(url: url)
        #expect(await store.allGrants() == grants)
        let revokedAt = Date()
        await store.revokeGrant(id: "g1", at: revokedAt)
        await store.revokeGrant(id: "g1", at: revokedAt.addingTimeInterval(50))
        #expect(await store.allGrants().first { $0.id == "g1" }?.revokedAt == revokedAt)
        #expect(await store.allGrants().filter { $0.isActive() }.map(\.id) == ["g2", "g3", "g4"])
        await store.revokeAllGrants(at: revokedAt.addingTimeInterval(60))
        #expect(await store.allGrants().allSatisfy { !$0.isActive() })
        #expect(await store.allGrants().first { $0.id == "g1" }?.revokedAt == revokedAt)
        #expect(try await store.deleteInactiveGrants(before: Date().addingTimeInterval(120)) == 4)
        #expect(await store.allGrants().isEmpty)
    }

    @Test func changeStreamReportsWrites() async throws {
        let store = try ORIXStore.inMemory()
        let stream = store.changes
        let collector = Task { () -> [StoreChange] in
            var seen: [StoreChange] = []
            for await change in stream { seen.append(change); if seen.count == 6 { break } }
            return seen
        }
        try await store.saveRun(makeRun("r"))
        await store.emit(RunEvent(runID: "r", kind: .log))
        try await store.saveWorkflowVersion(workflowID: "wf", name: "n", source: "s")
        try await store.put(Note(title: "t", body: "b", count: 0, when: Date()), collection: "notes", id: "1")
        await store.saveGrant(PermissionGrant(capability: .notify, scope: .persistent, maxTier: .reversibleWrite))
        try await store.deleteRun(id: "r")
        let seen = await collector.value
        #expect(seen == [.run("r"), .events("r"), .workflow("wf"), .collection("notes"), .grants, .run("r")])
    }

    @Test func darwinNotificationFiresAfterAWriteToAFile() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let store = try ORIXStore(url: tmp.file("orix.sqlite"))
        let stream = ORIXStore.darwinChanges()
        let got = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            try? await store.saveRun(makeRun("r"))
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(got, "no Darwin notification within 5 s of a write")
    }
}
