// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Tests/ORIXToolRegistryTests/ExecutorPipelineTests.swift
// Description      : Unit tests of the registry and of the nine-step
//                    ToolExecutor pipeline, driven by probe tools and scripted
//                    policies/brokers.
// Module           : ORIXToolRegistryTests
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
import ORIXCore
import ORIXTestingSupport
@testable import ORIXToolRegistry

@Suite("Manifests and registry (unit)")
struct ManifestAndRegistryTests {
    @Test func everyBuiltInManifestIsValid() {
        for tool in ORIXToolRegistryTools.all() {
            #expect(tool.manifest.problems().isEmpty, "\(tool.identifier): \(tool.manifest.problems())")
            #expect(tool.identifier == tool.manifest.identifier)
            #expect(tool.manifest.family == String(tool.identifier.split(separator: ".")[0]))
            #expect(tool.manifest.outputSchema.raw["type"]?.stringValue == "object", "\(tool.identifier) must declare an object output")
        }
    }

    @Test func identifiersMatchTheCanonicalList() {
        let ids = ORIXToolRegistryTools.all().map(\.identifier)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == Set(ORIXToolRegistryTools.canonicalIdentifiers))
        #expect(ids.count == 44)
    }

    @Test func tiersFollowTheGuide() {
        let byID = Dictionary(uniqueKeysWithValues: ORIXToolRegistryTools.all().map { ($0.identifier, $0.manifest) })
        #expect(byID["filesystem.delete"]?.defaultTier == .highRisk)
        #expect(byID["filesystem.delete"]?.sideEffect == .destructive)
        #expect(byID["filesystem.trash"]?.defaultTier == .reversibleWrite)
        #expect(byID["git.commit"]?.defaultTier == .reversibleWrite)
        for id in ["shell.run", "shell.script", "python.run", "script.swift", "script.javascript", "git.push", "http.request"] {
            #expect(byID[id]?.defaultTier == .consequential, "\(id)")
        }
        for (id, m) in byID where id.hasPrefix("system.") { #expect(m.defaultTier == .readOnly && m.sideEffect == .read) }
        #expect(!byID.keys.contains { $0.contains("reset") || $0.contains("clean") || $0.contains("rebase") })
    }

    @Test func registryRejectsDuplicatesAndBadManifests() async throws {
        let registry = ToolRegistry()
        try await registry.register(FilesystemReadTool())
        await #expect(throws: ToolRegistryError.duplicateIdentifier("filesystem.read")) { try await registry.register(FilesystemReadTool()) }
        var bad = ProbeTool("test.bad") { _, _ in .success([:], summary: "") }
        bad.manifest.summary = "short"
        await #expect(throws: ToolRegistryError.self) { try await registry.register(bad) }
        // registerAll is atomic.
        await #expect(throws: ToolRegistryError.self) { try await registry.registerAll([FilesystemListTool(), bad]) }
        #expect(await registry.tool(id: "filesystem.list") == nil)
        try await registry.registerAll([FilesystemListTool(), SystemInfoTool()])
        #expect(await registry.manifests().map(\.identifier) == ["filesystem.list", "filesystem.read", "system.info"])
        #expect(await registry.manifests(family: "filesystem").count == 2)
        #expect(await registry.unregister(id: "system.info"))
        #expect(await registry.unregister(id: "system.info") == false)
        #expect(await registry.tool(id: "system.info") == nil)
    }
}

@Suite("ToolExecutor pipeline (unit, probe tools)")
struct ExecutorPipelineTests {
    static func echo(_ counter: Counter = Counter()) -> ProbeTool {
        ProbeTool("test.echo") { input, _ in counter.increment(); return .success(["text": .string(input.optionalString("text") ?? "")], summary: "echo") }
    }
    static func slow(_ counter: Counter = Counter(), id: String = "test.slow", concurrency: ToolConcurrency = .unlimited) -> ProbeTool {
        ProbeTool(id, concurrency: concurrency) { input, _ in
            counter.enter(); defer { counter.leave() }
            try await Task.sleep(for: .seconds(input.double("seconds", default: 0.15)))
            return .success([:], summary: "slept")
        }
    }
    static func writer(_ counter: Counter, id: String = "test.write") -> ProbeTool {
        ProbeTool(id, sideEffect: .write, tier: .reversibleWrite) { _, _ in counter.increment(); return .success(["n": .int(counter.value)], summary: "wrote") }
    }

    @Test func unknownToolIsNotFound() async throws {
        let h = try await Harness(builtIns: false)
        defer { h.tmp.remove() }
        let r = await h.call("nope.missing")
        #expect(r.status == .failed && r.failure?.code == "not_found")
        #expect(await h.events.events(of: .toolFinished).count == 1)
        #expect(await h.audit.entries.last?.kind == .toolFailed)
    }

    @Test func schemaViolationRunsNothing() async throws {
        let counter = Counter()
        let h = try await Harness(extra: [Self.echo(counter)], builtIns: false)
        defer { h.tmp.remove() }
        let r = await h.call("test.echo", ["text": 42])
        #expect(r.status == .invalidInput && r.failure?.code == "invalid_input")
        let extra = await h.call("test.echo", ["unexpected": true])
        #expect(extra.status == .invalidInput)
        #expect(counter.value == 0)
    }

    @Test func protectedPathIsDeniedAndAuditedAsViolation() async throws {
        let h = try await Harness(policy: AllowAllPolicy())
        defer { h.tmp.remove() }
        let r = await h.call("filesystem.read", ["path": "~/.ssh/id_ed25519"])
        #expect(r.status == .denied && r.failure?.code == "permission_denied")
        #expect(await h.audit.entries.contains { $0.kind == .policyViolation && $0.toolID == "filesystem.read" })
        let w = await h.call("filesystem.write", ["path": "~/Library/Keychains/x", "content": "x"])
        #expect(w.status == .denied)
        #expect(!FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Keychains/x"))
    }

    @Test func denyAllPolicyDenies() async throws {
        let counter = Counter()
        let h = try await Harness(policy: DenyAllPolicy(), extra: [Self.echo(counter)], builtIns: false)
        defer { h.tmp.remove() }
        let r = await h.call("test.echo", ["text": "a"])
        #expect(r.status == .denied && counter.value == 0)
        #expect(await h.audit.entries.last?.kind == .toolDenied)
    }

    @Test func approvalOnceExecutesAndConsumesTheGrant() async throws {
        let counter = Counter()
        let policy = ApprovalPolicy()
        let broker = ScriptedApprovalBroker(answers: [.approveOnce])
        let h = try await Harness(policy: policy, approvals: broker, extra: [Self.writer(counter)], builtIns: false)
        defer { h.tmp.remove() }
        let r = await h.call("test.write", [:], id: "call-1")
        #expect(r.status == .succeeded && counter.value == 1)
        #expect(await broker.requests.count == 1)
        #expect(await policy.approvals == [.approveOnce])
        #expect(await policy.consumed == ["grant-call-1"])
        #expect(await h.events.events(of: .approvalRequested).count == 1)
        #expect(await h.events.events(of: .approvalResolved).first?.data["approved"] == .bool(true))
        let kinds = await h.audit.entries.map(\.kind)
        #expect(kinds.contains(.approvalRequested) && kinds.contains(.approvalGranted) && kinds.last == .toolExecuted)
        // The scripted list is exhausted: the next call falls back to deny.
        let again = await h.call("test.write")
        #expect(again.status == .notApproved && counter.value == 1)
    }

    @Test func refusedOrUnansweredApprovalIsNotApproved() async throws {
        let counter = Counter()
        let broker = ScriptedApprovalBroker(answers: [.deny(reason: "not now"), .unanswered])
        let h = try await Harness(policy: ApprovalPolicy(), approvals: broker, extra: [Self.writer(counter)], builtIns: false)
        defer { h.tmp.remove() }
        for _ in 0..<2 {
            let r = await h.call("test.write")
            #expect(r.status == .notApproved && r.failure?.code == "not_approved")
        }
        #expect(counter.value == 0)
        #expect(await h.audit.entries.filter { $0.kind == .approvalDenied }.count == 2)
        #expect(await h.audit.entries.last?.kind == .toolDenied)
    }

    @Test func approvalWaitDoesNotBlockOtherCalls() async throws {
        let counter = Counter(), broker = GatedBroker()
        let h = try await Harness(policy: ApprovalPolicy(), approvals: broker, extra: [Self.writer(counter), Self.echo()], builtIns: false)
        defer { h.tmp.remove() }
        async let pending = h.call("test.write")
        while await broker.asked == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let other = await h.call("test.echo", ["text": "meanwhile"], runID: "run-other")
        #expect(other.status == .succeeded)
        #expect(await h.executor.inFlightCount == 1)
        await broker.release(.approveOnce)
        #expect(await pending.status == .succeeded)
        #expect(await h.executor.inFlightCount == 0)
    }

    @Test func idempotencyKeyReplaysWithoutExecuting() async throws {
        let counter = Counter()
        let h = try await Harness(policy: AllowAllPolicy(), extra: [Self.writer(counter)], builtIns: false)
        defer { h.tmp.remove() }
        let first = await h.call("test.write", [:], key: "k1")
        let second = await h.call("test.write", [:], key: "k1")
        #expect(first.output == second.output && counter.value == 1)
        #expect(await h.events.events(of: .toolFinished).last?.data["replayed"] == .bool(true))
        _ = await h.call("test.write", [:], key: "k1", runID: "another-run")
        #expect(counter.value == 2)
        _ = await h.call("test.write")
        _ = await h.call("test.write")
        #expect(counter.value == 4)
    }

    @Test func concurrentCallsWithTheSameKeyExecuteOnce() async throws {
        let counter = Counter()
        let tool = ProbeTool("test.slowwrite", sideEffect: .write, tier: .reversibleWrite) { _, _ in
            counter.increment(); try await Task.sleep(for: .milliseconds(150)); return .success(["n": 1], summary: "ok")
        }
        let h = try await Harness(policy: AllowAllPolicy(), extra: [tool], builtIns: false)
        defer { h.tmp.remove() }
        async let a = h.call("test.slowwrite", [:], key: "same")
        async let b = h.call("test.slowwrite", [:], key: "same")
        let (ra, rb) = await (a, b)
        #expect(ra.status == .succeeded && rb.status == .succeeded && counter.value == 1)
    }

    @Test func failedCallsAreNotStoredForReplay() async throws {
        let counter = Counter()
        let tool = ProbeTool("test.flaky", sideEffect: .write, tier: .reversibleWrite) { _, _ in
            counter.increment()
            if counter.value == 1 { throw ToolError.io("disk hiccup") }
            return .success([:], summary: "ok")
        }
        let h = try await Harness(policy: AllowAllPolicy(), extra: [tool], builtIns: false)
        defer { h.tmp.remove() }
        #expect(await h.call("test.flaky", [:], key: "k").status == .failed)
        #expect(await h.call("test.flaky", [:], key: "k").status == .succeeded)
        #expect(counter.value == 2)
    }

    @Test func timeoutFromArgumentAndFromRunBound() async throws {
        let h = try await Harness(policy: AllowAllPolicy(), extra: [Self.slow()], builtIns: false)
        defer { h.tmp.remove() }
        let clock = ContinuousClock()
        let started = clock.now
        let r = await h.call("test.slow", ["seconds": 20, "timeoutSeconds": 0.3])
        #expect(r.status == .timedOut && r.failure?.code == "timeout")
        let bounded = await h.call("test.slow", ["seconds": 20], maxToolSeconds: 0.3)
        #expect(bounded.status == .timedOut)
        #expect(clock.now - started < .seconds(5))
        #expect(await h.audit.entries.last?.kind == .toolFailed)
    }

    @Test func cancelAllAndCancelRun() async throws {
        let h = try await Harness(policy: AllowAllPolicy(), extra: [Self.slow()], builtIns: false)
        defer { h.tmp.remove() }
        async let a = h.call("test.slow", ["seconds": 30], runID: "run-a")
        async let b = h.call("test.slow", ["seconds": 30], runID: "run-b")
        while await h.executor.inFlightCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        await h.executor.cancel(runID: "run-a")
        #expect(await a.status == .canceled)
        #expect(await h.executor.inFlightCount == 1)
        await h.executor.cancelAll()
        let rb = await b
        #expect(rb.status == .canceled && rb.failure?.code == "canceled")
        #expect(await h.executor.inFlightCount == 0)
    }

    @Test func cancellingTheCallingTaskCancelsTheTool() async throws {
        let h = try await Harness(policy: AllowAllPolicy(), extra: [Self.slow()], builtIns: false)
        defer { h.tmp.remove() }
        let task = Task { await h.call("test.slow", ["seconds": 30]) }
        while await h.executor.inFlightCount < 1 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value.status == .canceled)
    }

    @Test func outputAndEventsAreRedacted() async throws {
        let secret = "correct-horse-battery-staple-9431"
        let shaped = "sk-ant-api03-" + String(repeating: "Ab3xY9", count: 8)
        let tool = ProbeTool("test.leak", redactedKeys: ["apiKey"]) { _, ctx in
            ctx.progress(ToolProgress(stream: .stdout, text: "progress \(secret)"))
            return .success(["line": .string("value=\(secret) and \(shaped)"), "nested": ["items": [.string(shaped)]]], summary: "leaked \(secret)")
        }
        let h = try await Harness(policy: AllowAllPolicy(), extra: [tool], builtIns: false)
        defer { h.tmp.remove() }
        h.redactor.register(secret: secret)
        let seen = Counter()
        var context = h.tmp.invocation()
        final class Box: @unchecked Sendable { var text = "" }
        let box = Box()
        context.progress = { _, p in box.text += p.text; seen.increment() }
        let r = await h.executor.invoke(ToolCall(toolID: "test.leak", arguments: ["apiKey": "hunter2-hunter2", "text": .string("see \(shaped)")]), context: context)
        let whole = r.output.serialized() + r.summary
        #expect(r.status == .succeeded)
        #expect(!whole.contains(secret) && !whole.contains(shaped) && whole.contains(Redactor.placeholder))
        #expect(seen.value == 1 && !box.text.contains(secret))
        let events = await h.events.events
        let dump = events.map { $0.text + $0.data.serialized() }.joined() + (await h.audit.entries.map { $0.detail + $0.data.serialized() }.joined())
        #expect(!dump.contains(secret) && !dump.contains(shaped) && !dump.contains("hunter2-hunter2"))
        #expect(events.first?.data["arguments"]?["apiKey"] == .string(Redactor.placeholder))
    }

    @Test func invalidOutputAndThrownErrorsAreTyped() async throws {
        let schema = JSONSchema.object(["n": .integer()], required: ["n"], additional: true)
        let badOutput = ProbeTool("test.badout", outputSchema: schema) { _, _ in .success(["n": "not a number"], summary: "x") }
        let tcc = ProbeTool("test.tcc") { _, _ in throw ToolError.tccBlocked(.accessibility, "Accessibility is off") }
        let unsupported = ProbeTool("test.unsupported") { _, _ in throw ToolError.unsupported("not on this Mac") }
        struct Odd: Error {}
        let odd = ProbeTool("test.odd") { _, _ in throw Odd() }
        let h = try await Harness(policy: AllowAllPolicy(), extra: [badOutput, tcc, unsupported, odd], builtIns: false)
        defer { h.tmp.remove() }
        let r1 = await h.call("test.badout")
        #expect(r1.status == .failed && r1.failure?.code == "output_invalid")
        let r2 = await h.call("test.tcc")
        #expect(r2.status == .blockedPermission && r2.failure?.code == "tcc_blocked")
        #expect(await h.call("test.unsupported").status == .unsupported)
        let r4 = await h.call("test.odd")
        #expect(r4.status == .failed && r4.failure?.code == "internal")
    }

    @Test func oversizedOutputIsTruncated() async throws {
        let tool = ProbeTool("test.big", maxOutputBytes: 10_000) { _, _ in .success(["text": .string(String(repeating: "x", count: 500_000)), "n": 7], summary: "big") }
        let h = try await Harness(policy: AllowAllPolicy(), extra: [tool], builtIns: false)
        defer { h.tmp.remove() }
        let r = await h.call("test.big")
        #expect(r.status == .succeeded && r.truncated)
        #expect(r.output.serialized().utf8.count <= 10_000)
        #expect(r.output["n"] == 7)
        let (preview, cut) = ToolExecutor.bounded(.array((0..<5_000).map { .string("item-\($0)") }), maxBytes: 2_000)
        #expect(cut && preview["truncated"] == true && preview.serialized().utf8.count <= 2_000)
    }

    @Test func eventsAndAuditDescribeTheCall() async throws {
        let h = try await Harness(policy: AllowAllPolicy(), extra: [Self.echo(), ProbeTool("test.web", untrusted: true) { _, _ in .success([:], summary: "page") }], builtIns: false)
        defer { h.tmp.remove() }
        let r = await h.call("test.echo", ["text": "hi"], id: "call-42")
        #expect(r.durationMs >= 0 && !r.untrusted)
        let requested = await h.events.events(of: .toolRequested), finished = await h.events.events(of: .toolFinished)
        #expect(requested.count == 1 && finished.count == 1)
        #expect(requested[0].data["callID"] == "call-42" && requested[0].data["toolID"] == "test.echo")
        let data = finished[0].data
        #expect(data["status"] == "succeeded" && data["tier"] == 0 && data["summary"] == "echo" && data["durationMs"]?.intValue != nil)
        #expect(data["arguments"]?["text"] == "hi")
        let entry = await h.audit.entries.last
        #expect(entry?.kind == .toolExecuted && entry?.toolID == "test.echo" && entry?.runID == "run-test" && entry?.tier == .readOnly)
        #expect(await h.call("test.web").untrusted)
    }

    @Test func serialToolsRunOneAtATime() async throws {
        let serial = Counter(), free = Counter()
        let h = try await Harness(policy: AllowAllPolicy(),
                                  extra: [Self.slow(serial, id: "test.serial", concurrency: .serial), Self.slow(free, id: "test.free")], builtIns: false)
        defer { h.tmp.remove() }
        await withTaskGroup(of: ToolResult.self) { group in
            for i in 0..<5 {
                group.addTask { await h.call("test.serial", ["seconds": 0.05], runID: "run-\(i)") }
                group.addTask { await h.call("test.free", ["seconds": 0.2], runID: "run-\(i)") }
            }
            for await r in group { #expect(r.status == .succeeded) }
        }
        #expect(serial.value == 5 && serial.maxConcurrent == 1)
        #expect(free.value == 5 && free.maxConcurrent > 1)
    }

    @Test func exclusiveToolsExcludeEachOther() async throws {
        let shared = Counter()
        let h = try await Harness(policy: AllowAllPolicy(), extra: [Self.slow(shared, id: "test.pointer", concurrency: .exclusive),
                                                                    Self.slow(shared, id: "test.keyboard", concurrency: .exclusive)], builtIns: false)
        defer { h.tmp.remove() }
        await withTaskGroup(of: ToolResult.self) { group in
            for i in 0..<6 { group.addTask { await h.call(i % 2 == 0 ? "test.pointer" : "test.keyboard", ["seconds": 0.04]) } }
            for await r in group { #expect(r.status == .succeeded) }
        }
        #expect(shared.value == 6 && shared.maxConcurrent == 1)
    }

    @Test func toolIgnoringCancellationIsAbandonedAfterTheGracePeriod() async throws {
        let finished = Counter()
        let stubborn = ProbeTool("test.stubborn") { _, _ in
            // Deliberately not cancellable.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.global().asyncAfter(deadline: .now() + 8) { c.resume() } }
            finished.increment()
            return .success([:], summary: "late")
        }
        let h = try await Harness(policy: AllowAllPolicy(), extra: [stubborn], builtIns: false)
        defer { h.tmp.remove() }
        await h.executor.setUnwindGrace(0.3)
        let clock = ContinuousClock(); let start = clock.now
        let r = await h.call("test.stubborn", ["timeoutSeconds": 0.2])
        #expect(r.status == .timedOut && finished.value == 0 && clock.now - start < .seconds(5), "the caller is answered even though the tool is still running")
        let task = Task { await h.call("test.stubborn") }
        while await h.executor.inFlightCount < 1 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        await h.executor.cancelAll()
        #expect(await task.value.status == .canceled && finished.value == 0 && clock.now - start < .seconds(7))
    }

    @Test func dryRunIsRefusedWhenUnsupported() async throws {
        let counter = Counter()
        let h = try await Harness(policy: AllowAllPolicy(), extra: [Self.writer(counter)], builtIns: false)
        defer { h.tmp.remove() }
        let r = await h.call("test.write", [:], dryRun: true)
        #expect(r.status == .unsupported && counter.value == 0)
    }

    @Test func artifactsDirectoryIsImplicitlyGranted() async throws {
        let policy = ApprovalPolicy()
        let h = try await Harness(policy: policy, approvals: ScriptedApprovalBroker(answers: [.approveOnce, .approveOnce]))
        defer { h.tmp.remove() }
        let inside = await h.call("filesystem.write", ["path": "artifacts/note.txt", "content": "x"])
        #expect(inside.status == .succeeded)
        #expect(await policy.requests.last?.capabilities.isEmpty == true)
        let outside = await h.call("filesystem.write", ["path": "note.txt", "content": "x"])
        #expect(outside.status == .succeeded)
        #expect(await policy.requests.last?.capabilities == [.fileWrite(path: h.path("note.txt"))])
        #expect(await policy.requests.last?.summary.contains("note.txt") == true)
    }

    @Test func secretsAreScopedToDeclaredReferences() async throws {
        var declared = ProbeTool("test.secret") { _, ctx in
            let v = try await ctx.secrets?.secret(reference: "api-token") ?? "none"
            return .success(["echo": .string("the value is \(v)")], summary: "used")
        }
        declared.capabilities = { _, _ in [.secret(reference: "api-token")] }
        let sneaky = ProbeTool("test.sneaky") { _, ctx in
            _ = try await ctx.secrets?.secret(reference: "api-token")
            return .success([:], summary: "stole")
        }
        let h = try await Harness(policy: AllowAllPolicy(), extra: [declared, sneaky], secrets: MapSecrets(values: ["api-token": "tok-7Qm2-very-secret-value"]), builtIns: false)
        defer { h.tmp.remove() }
        let ok = await h.call("test.secret")
        #expect(ok.status == .succeeded && !ok.output.serialized().contains("tok-7Qm2") && ok.output.serialized().contains(Redactor.placeholder))
        #expect(await h.audit.entries.contains { $0.kind == .secretUsed && $0.data["reference"] == "api-token" })
        #expect(await h.call("test.sneaky").status == .denied)
    }

    @Test func requirementErrorsStopBeforePolicy() async throws {
        let policy = ApprovalPolicy()
        let h = try await Harness(policy: policy)
        defer { h.tmp.remove() }
        let r = await h.call("filesystem.read", ["path": "~root/secret"])
        #expect(r.status == .invalidInput)
        let sudo = await h.call("shell.run", ["executable": "sudo", "args": ["ls"]])
        #expect(sudo.status == .unsupported)
        #expect(await policy.requests.isEmpty)
    }
}
