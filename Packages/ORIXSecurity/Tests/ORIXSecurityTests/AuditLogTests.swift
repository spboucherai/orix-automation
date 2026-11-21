// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXSecurity/Tests/ORIXSecurityTests/AuditLogTests.swift
// Description      : Integration tests of the hash-chained audit log on real
//                    files: chain verification, tamper detection, reopening,
//                    redaction, two writers.
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

@Suite("AuditLog (integration, real files)")
struct AuditLogTests {
    private func entry(_ n: Int, kind: AuditEntry.Kind = .toolExecuted) -> AuditEntry {
        AuditEntry(id: "entry-\(n)", kind: kind, runID: "run-1", toolID: "filesystem.write", tier: .reversibleWrite,
                   detail: "Wrote file number \(n)", data: ["n": .int(n), "path": .string("/tmp/file-\(n).txt")])
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func chainVerifiesAndEntriesRoundTrip() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let log = try AuditLog(url: tmp.file("audit/audit.jsonl"))
        #expect(await log.verify() == .ok(entries: 0))
        for i in 1...25 { await log.record(entry(i)) }
        #expect(await log.verify() == .ok(entries: 25))
        #expect(await log.writeFailures == 0)
        let all = await log.entries(limit: 100)
        #expect(all.map(\.id) == (1...25).map { "entry-\($0)" })
        #expect(all[4].data == ["n": 5, "path": "/tmp/file-5.txt"])
        #expect(all[4].tier == .reversibleWrite)
        #expect(await log.entries(limit: 3).map(\.id) == ["entry-23", "entry-24", "entry-25"])
        #expect(await log.entryCount() == 25)

        // Every line is standalone JSON with the documented fields, and the first links to the genesis hash.
        let text = try lines(tmp.file("audit/audit.jsonl"))
        #expect(text.count == 25)
        let first = try JSONValue.parse(text[0])
        #expect(first["prev"]?.stringValue == AuditLog.genesisHash)
        #expect(first["hash"]?.stringValue?.count == 64)
        #expect(first["entry"]?["id"]?.stringValue == "entry-1")
        let second = try JSONValue.parse(text[1])
        #expect(second["prev"] == first["hash"])
        let mode = try FileManager.default.attributesOfItem(atPath: tmp.file("audit/audit.jsonl").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func editingAMiddleLineIsDetected() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("audit.jsonl")
        let log = try AuditLog(url: url)
        for i in 1...10 { await log.record(entry(i)) }
        var text = try lines(url)
        #expect(text[4].contains("Wrote file number 5"))
        text[4] = text[4].replacingOccurrences(of: "Wrote file number 5", with: "Wrote file number 6")
        try (text.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
        let result = await log.verify()
        #expect(!result.isValid)
        #expect(result.firstBrokenLine == 5)
        #expect(result.verifiedEntries == 4)
        #expect(result.reason?.contains("edited") == true)
        // A freshly opened log reaches the same verdict.
        #expect(try await AuditLog(url: url).verify().firstBrokenLine == 5)
    }

    @Test func deletingAMiddleLineIsDetected() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("audit.jsonl")
        let log = try AuditLog(url: url)
        for i in 1...10 { await log.record(entry(i)) }
        var text = try lines(url)
        text.remove(at: 3)
        try (text.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
        let result = try await AuditLog(url: url).verify()
        #expect(result.firstBrokenLine == 4)
        #expect(result.reason?.contains("removed") == true)
    }

    @Test func swappedAndForgedLinesAreDetected() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("audit.jsonl")
        let log = try AuditLog(url: url)
        for i in 1...6 { await log.record(entry(i)) }
        let original = try lines(url)
        var swapped = original
        swapped.swapAt(1, 2)
        try (swapped.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
        #expect(try await AuditLog(url: url).verify().firstBrokenLine == 2)
        var garbage = original
        garbage.insert("{\"not\":\"an audit line\"}", at: 2)
        try (garbage.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
        #expect(try await AuditLog(url: url).verify().firstBrokenLine == 3)
    }

    @Test func reopeningContinuesTheChain() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("audit.jsonl")
        do {
            let log = try AuditLog(url: url)
            for i in 1...4 { await log.record(entry(i)) }
        }
        let reopened = try AuditLog(url: url)
        for i in 5...8 { await reopened.record(entry(i)) }
        #expect(await reopened.verify() == .ok(entries: 8))
        let text = try lines(url)
        #expect(try JSONValue.parse(text[4])["prev"] == JSONValue.parse(text[3])["hash"])
        #expect(await reopened.entries(limit: 10).count == 8)
    }

    @Test func twoWritersShareOneChain() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("audit.jsonl")
        let a = try AuditLog(url: url)
        let b = try AuditLog(url: url)
        await withTaskGroup(of: Void.self) { group in
            for i in 1...40 {
                group.addTask { await (i % 2 == 0 ? a : b).record(self.entry(i)) }
            }
        }
        #expect(await a.verify() == .ok(entries: 40))
        #expect(Set(await b.entries(limit: 100).map(\.id)).count == 40)
    }

    @Test func detailsAreRedactedBeforeWriting() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("audit.jsonl")
        let secret = "orix-test-literal-\(UUID().uuidString)"
        Redactor.shared.register(secret: secret)
        defer { Redactor.shared.unregister(secret: secret) }
        let log = try AuditLog(url: url)
        await log.record(AuditEntry(kind: .secretUsed, detail: "Used \(secret) and sk-ant-REDACTME0123456789abcdefghij",
                                    data: ["header": .string("Bearer abcdefghijklmnopqrstuvwxyz012345"), "password": "hunter2hunter2", "note": .string(secret)]))
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains(secret))
        #expect(!raw.contains("REDACTME"))
        #expect(!raw.contains("abcdefghijklmnopqrstuvwxyz012345"))
        #expect(!raw.contains("hunter2"))
        #expect(raw.contains(Redactor.placeholder))
        #expect(await log.verify().isValid)
    }

    @Test func tornLastLineIsReportedAndDoesNotCorruptLaterEntries() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let url = tmp.file("audit.jsonl")
        do {
            let log = try AuditLog(url: url)
            for i in 1...3 { await log.record(entry(i)) }
        }
        // Simulate a crash in the middle of a write: a partial line with no newline.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"hash\":\"abc".utf8))
        try handle.close()
        let log = try AuditLog(url: url)
        await log.record(entry(4))
        let result = await log.verify()
        #expect(result.firstBrokenLine == 4)
        #expect(await log.entries(limit: 10).map(\.id) == ["entry-1", "entry-2", "entry-3", "entry-4"])
    }
}
