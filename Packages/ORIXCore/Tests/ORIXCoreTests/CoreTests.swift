// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXCore/Tests/ORIXCoreTests/CoreTests.swift
// Description      : Unit tests for JSON values, schema validation, capability
//                    coverage, path resolution, redaction, manifests and
//                    run-state transitions.
// Module           : ORIXCoreTests
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
import Testing
@testable import ORIXCore
import ORIXTestingSupport

@Suite struct JSONValueTests {
    @Test func roundTripKeepsIntegersAndDoubles() throws {
        let v = try JSONValue.parse(#"{"a":1,"b":1.5,"c":[true,null,"x"],"d":{"e":-3}}"#)
        #expect(v["a"] == .int(1))
        #expect(v["b"] == .number(1.5))
        #expect(v.value(atPath: "c.2") == .string("x"))
        #expect(v.value(atPath: "d.e")?.intValue == -3)
        #expect(try JSONValue.parse(v.serialized()) == v)
    }

    @Test func truthiness() {
        #expect(!JSONValue.null.isTruthy)
        #expect(!JSONValue.string("").isTruthy)
        #expect(!JSONValue.array([]).isTruthy)
        #expect(JSONValue.int(2).isTruthy)
    }
}

@Suite struct SchemaTests {
    let schema = JSONSchema.object([
        "path": .string("A path"),
        "limit": .integer(minimum: 1, maximum: 100),
        "mode": .string(enum: ["a", "b"]),
        "tags": .array(of: .string()),
    ], required: ["path"])

    @Test func acceptsValidInput() {
        #expect(schema.validate(["path": "/tmp", "limit": 5, "mode": "a", "tags": ["x"]]).isEmpty)
    }

    @Test func reportsEveryViolation() {
        let v = schema.validate(["limit": 500, "mode": "z", "tags": [1], "extra": true])
        let text = v.map(\.description).joined(separator: "|")
        #expect(text.contains("path: required"))
        #expect(text.contains("limit: greater than maximum"))
        #expect(text.contains("mode: value is not one of"))
        #expect(text.contains("tags.0: expected string"))
        #expect(text.contains("extra: unexpected property"))
    }

    @Test func rejectsWrongRootType() {
        #expect(!schema.validate("not an object").isEmpty)
    }
}

@Suite struct CapabilityTests {
    @Test func pathCoverageIsPrefixOnWholeComponents() {
        let g = Capability.fileRead(path: "/Users/a/Documents")
        #expect(g.covers(.fileRead(path: "/Users/a/Documents")))
        #expect(g.covers(.fileRead(path: "/Users/a/Documents/x/y.txt")))
        #expect(!g.covers(.fileRead(path: "/Users/a/Documents-private/x")))
        #expect(!g.covers(.fileRead(path: "/Users/a")))
    }

    @Test func kindsNeverImplyEachOther() {
        #expect(!Capability.fileWrite(path: "/a").covers(.fileRead(path: "/a")))
        #expect(!Capability.fileWrite(path: "/a").covers(.fileDelete(path: "/a/b")))
        #expect(!Capability.network(host: "example.com").covers(.browser(host: "example.com")))
    }

    @Test func hostWildcards() {
        #expect(Capability.network(host: "*.example.com").covers(.network(host: "api.example.com")))
        #expect(!Capability.network(host: "*.example.com").covers(.network(host: "example.com")))
        #expect(!Capability.network(host: "*.example.com").covers(.network(host: "evilexample.com")))
        #expect(!Capability.network(host: "example.com").covers(.network(host: "example.com.evil.net")))
    }

    @Test func kindScopeRoundTrip() {
        let caps: [Capability] = [.fileRead(path: "/a"), .processExec(executable: "git"), .clipboardRead, .secret(reference: "x"), .skill(id: "s")]
        for c in caps { #expect(Capability(kind: c.kind, scope: c.scope) == c) }
    }
}

@Suite struct PathResolverTests {
    @Test func removesDotDotAndExpandsTilde() throws {
        let base = URL(fileURLWithPath: "/tmp")
        #expect(try PathResolver.canonical("~/x/../y", relativeTo: base) == PathResolver.resolveSymlinks(NSHomeDirectory()) + "/y")
        #expect(throws: ToolError.self) { try PathResolver.canonical("~root/x", relativeTo: base) }
        #expect(throws: ToolError.self) { try PathResolver.canonical("", relativeTo: base) }
    }

    @Test func symlinkEscapeResolvesToRealTarget() throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let outside = try TempDirectory(prefix: "orix-outside"); defer { outside.remove() }
        try outside.write("secret.txt", "s")
        try FileManager.default.createSymbolicLink(at: tmp.file("link"), withDestinationURL: outside.url)
        let resolved = try PathResolver.canonical("link/secret.txt", relativeTo: tmp.url)
        #expect(resolved == outside.url.path + "/secret.txt")
        #expect(!Capability.fileRead(path: tmp.url.path).covers(.fileRead(path: resolved)))
        // A not-yet-existing file below a symlinked directory still resolves through the link.
        let future = try PathResolver.canonical("link/new/file.txt", relativeTo: tmp.url)
        #expect(future == outside.url.path + "/new/file.txt")
    }

    @Test func protectedLocations() {
        #expect(PathResolver.isProtected(NSHomeDirectory() + "/.ssh/id_ed25519"))
        #expect(PathResolver.isProtected(NSHomeDirectory() + "/Library/Keychains/login.keychain-db"))
        #expect(!PathResolver.isProtected(NSHomeDirectory() + "/Documents/a.txt"))
    }
}

@Suite struct RedactionTests {
    @Test func scrubsCredentialShapes() {
        let r = Redactor()
        let fakeAnthropic = "sk-ant-" + String(repeating: "a1B2", count: 10)
        let fakeOpenRouter = "sk-or-v1-" + String(repeating: "0f", count: 20)
        let text = "key=\(fakeAnthropic) other \(fakeOpenRouter) Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345"
        let out = r.redact(text)
        #expect(!out.contains(fakeAnthropic))
        #expect(!out.contains(fakeOpenRouter))
        #expect(!out.contains("abcdefghijklmnopqrstuvwxyz012345"))
        #expect(out.contains(Redactor.placeholder))
    }

    @Test func scrubsRegisteredLiteralsAndSensitiveKeys() {
        let r = Redactor()
        r.register(secret: "correct-horse-battery")
        #expect(r.redact("the value is correct-horse-battery!") == "the value is \(Redactor.placeholder)!")
        let v = r.redact(["password": "hunter2hunter2", "note": "ok", "body": "x"], keys: ["body"])
        #expect(v["password"] == .string(Redactor.placeholder))
        #expect(v["body"] == .string(Redactor.placeholder))
        #expect(v["note"] == "ok")
    }

    @Test func leavesOrdinaryTextAlone() {
        #expect(Redactor().redact("Moved 14 files to ~/Downloads/Sorted in 0.3 s") == "Moved 14 files to ~/Downloads/Sorted in 0.3 s")
    }

    @Test func truncationIsHonest() {
        let (t, cut) = String(repeating: "é", count: 100).truncated(maxBytes: 51)
        #expect(cut)
        #expect(t.contains("output truncated"))
        #expect(!"short".truncated(maxBytes: 51).truncated)
    }
}

@Suite struct ManifestAndStateTests {
    @Test func manifestProblems() {
        let good = ToolManifest(identifier: "filesystem.list", name: "List", summary: "Lists the entries of a directory.", family: "filesystem",
                                inputSchema: .object([:]), sideEffect: .read, defaultTier: .readOnly, idempotent: true)
        #expect(good.problems().isEmpty)
        var bad = good
        bad.identifier = "List Files"; bad.sideEffect = .destructive; bad.defaultTier = .readOnly; bad.idempotent = false
        #expect(bad.problems().count >= 2)
    }

    @Test func terminalStatesAreFinal() {
        for s in RunStatus.allCases where s.isTerminal && s != .recoveryRequired {
            for n in RunStatus.allCases { #expect(!s.canTransition(to: n)) }
        }
        #expect(RunStatus.running.canTransition(to: .waitingApproval))
        #expect(RunStatus.waitingApproval.canTransition(to: .running))
        #expect(!RunStatus.running.canTransition(to: .queued))
    }

    @Test func costIsNeverInvented() {
        let u = TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        #expect(u.costUSD(model: ModelInfo(id: "m", provider: .openai)) == nil)
        #expect(u.costUSD(model: ModelInfo(id: "m", provider: .openai, inputPricePerMTok: 3, outputPricePerMTok: 15)) == 18)
        #expect(TokenUsage(reportedCostUSD: 0.002).costUSD(model: nil) == 0.002)
    }

    @Test func scriptedProviderAggregates() async throws {
        let p = ScriptedProvider(turns: [ScriptedProvider.tool("filesystem.list", ["path": "/tmp"], id: "t1", text: "Looking")])
        let r = try await p.complete(LLMRequest(model: "scripted-1", messages: [.user("hi")]))
        #expect(r.text == "Looking")
        #expect(r.toolUses.first?.name == "filesystem__list")
        #expect(r.stopReason == .toolUse)
    }
}
