// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/EngineTests.swift
// Description      : Workflow engine tests with a closure-backed tool invoker
//                    and a fake agent runner (mocked tools), plus real-file
//                    verification in temp directories.
// Module           : ORIXWorkflowEngineTests
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
@testable import ORIXWorkflowEngine

// MARK: - Test doubles

/// Wraps the shared closure invoker and marks chosen tools as supporting dry runs (the shared double cannot).
struct DryRunAwareInvoker: ToolInvoking {
    let base: ClosureToolInvoker
    let dryRunTools: Set<String>
    func manifests() async -> [ToolManifest] {
        await base.manifests().map { m in var m = m; m.supportsDryRun = dryRunTools.contains(m.identifier); return m }
    }
    func invoke(_ call: ToolCall, context: InvocationContext) async -> ToolResult { await base.invoke(call, context: context) }
}

actor FakeAgentRunner: AgentRunning {
    private(set) var tasks: [AgentTask] = []
    private(set) var profiles: [AgentProfile] = []
    private let reply: @Sendable (AgentTask) -> AgentOutcome
    init(reply: @escaping @Sendable (AgentTask) -> AgentOutcome) { self.reply = reply }
    func run(task: AgentTask, profile: AgentProfile, runID: String, workflowID: String?, stepID: String?) async -> AgentOutcome {
        tasks.append(task); profiles.append(profile)
        return reply(task)
    }
}

/// Records when each call ran, to prove overlap (or its absence) with timestamps.
actor Timeline {
    private(set) var spans: [String: (start: Date, end: Date)] = [:]
    private var active = 0
    private(set) var maxActive = 0
    private(set) var canceled: [String] = []
    func enter() -> Date { active += 1; maxActive = max(maxActive, active); return Date() }
    func leave(_ id: String, _ start: Date) { active -= 1; spans[id] = (start, Date()) }
    func markCanceled(_ id: String) { canceled.append(id) }
    func overlap(_ a: String, _ b: String) -> Bool {
        guard let x = spans[a], let y = spans[b] else { return false }
        return x.start < y.end && y.start < x.end
    }
}

actor Counter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

struct Harness {
    let tmp: TempDirectory
    let tools = ClosureToolInvoker()
    let sink = CollectingEventSink()
    let store = InMemoryCheckpointStore(keepHistory: true)

    init() throws { tmp = try TempDirectory(prefix: "orix-wf") }

    func engine(invoker: (any ToolInvoking)? = nil, agents: (any AgentRunning)? = nil, loader: (any SubworkflowLoading)? = nil,
                approval: WorkflowApprovalHandler? = nil, profiles: AgentProfileResolver? = nil, clock: any WorkflowClock = SystemWorkflowClock(),
                configuration: WorkflowEngineConfiguration = .init()) -> WorkflowEngine {
        WorkflowEngine(tools: invoker ?? tools, agents: agents, events: sink, checkpoints: store, loader: loader, approval: approval,
                       agentProfiles: profiles, clock: clock, configuration: configuration)
    }

    func options(_ parameters: [String: JSONValue] = [:], dryRun: Bool = false, breakpoints: Set<String> = [], startPaused: Bool = false,
                 resolutions: [String: InFlightResolution] = [:]) -> WorkflowRunOptions {
        WorkflowRunOptions(runID: "run-1", parameters: parameters, dryRun: dryRun, workingDirectory: tmp.url,
                           artifactsDirectory: tmp.url.appendingPathComponent("artifacts"), breakpoints: breakpoints, startPaused: startPaused,
                           inFlightResolutions: resolutions)
    }

    /// Registers `test.echo` (returns its arguments), `test.fail` and `test.effect` (not idempotent).
    func registerBasics() async {
        await tools.register("test.echo") { call, _ in .success(call.arguments, summary: "echo") }
        await tools.register("test.fail") { _, _ in .failure(.failed, ToolFailure(code: "io", message: "disk on fire")) }
        await tools.register("test.effect", sideEffect: .write, tier: .reversibleWrite, idempotent: false) { call, _ in .success(call.arguments, summary: "effect") }
        await tools.register("notifications.post", sideEffect: .write, tier: .reversibleWrite, idempotent: false) { call, _ in .success(call.arguments, summary: "posted") }
    }

    func calls(_ toolID: String) async -> [ToolCall] { await tools.calls.filter { $0.toolID == toolID } }
}

func workflow(_ steps: String, spec: String = "") throws -> WorkflowDocument {
    try WorkflowCodec.parse("apiVersion: orix.ai/v1\nkind: Automation\nmetadata:\n  id: t\n  name: Test\nspec:\n" + spec + "  steps:\n" + steps)
}

func waitUntil(timeout: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

func sleepingTool(_ timeline: Timeline, seconds: Double) -> ClosureToolInvoker.Handler {
    { call, _ in
        let id = call.arguments["id"]?.stringValue ?? call.id
        let start = await timeline.enter()
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        catch {
            await timeline.leave(id, start)
            await timeline.markCanceled(id)
            return .failure(.canceled, ToolFailure(code: "canceled", message: "Canceled"))
        }
        await timeline.leave(id, start)
        return .success(["id": .string(id)], summary: "slept")
    }
}

// MARK: - Scheduling

@Suite("Engine scheduling (mocked tools)") struct EngineSchedulingTests {
    @Test func stepsRunInDependencyOrderAndPassOutputs() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: c
              needs: [b]
              tool: test.echo
              with: {text: "${{ steps.b.output.text }}-c", status: "${{ steps.a.status }}"}
            - id: a
              tool: test.echo
              with: {text: a}
            - id: b
              needs: [a]
              tool: test.echo
              with: {text: "${{ steps.a.output.text }}-b"}
            - id: out
              needs: [c]
              output: {final: "${{ steps.c.output.text }}", count: "${{ len(steps.c.output.text) }}"}

        """)
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .succeeded)
        #expect(outcome.steps.map(\.stepID) == ["a", "b", "c", "out"])
        #expect(outcome.outputs == ["final": "a-b-c", "count": 5])
        #expect(outcome.step("c")?.output["status"] == "succeeded")
        #expect(outcome.usage.toolCalls == 3)
        let started = await h.sink.events(of: .stepStarted).map(\.stepID)
        #expect(started == ["a", "b", "c", "out"])
        let finished = await h.sink.events(of: .stepFinished)
        #expect(finished.count == 4 && finished.allSatisfy { $0.data["status"] == "succeeded" })
        #expect(await h.sink.events(of: .checkpoint).count == 4)
        #expect(outcome.steps.allSatisfy { $0.attempts == 1 && $0.startedAt != nil && $0.endedAt != nil })
    }

    @Test func independentStepsOverlapInTime() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let timeline = Timeline()
        await h.tools.register("test.sleep", handler: sleepingTool(timeline, seconds: 0.25))
        let doc = try workflow("""
            - id: left
              tool: test.sleep
              with: {id: left}
            - id: right
              tool: test.sleep
              with: {id: right}
            - id: join
              needs: [left, right]
              tool: test.sleep
              with: {id: join}

        """)
        let began = Date()
        let outcome = await h.engine().run(doc, options: h.options())
        let elapsed = Date().timeIntervalSince(began)
        #expect(outcome.status == .succeeded)
        #expect(await timeline.overlap("left", "right"), "independent steps must run at the same time")
        let leftJoin = await timeline.overlap("left", "join"), rightJoin = await timeline.overlap("right", "join")
        #expect(!leftJoin && !rightJoin)
        #expect(await timeline.maxActive == 2)
        #expect(elapsed < 0.74, "three 0.25 s steps took \(elapsed) s; two of them must have overlapped")
    }

    @Test func maxConcurrentStepsBoundsParallelism() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let timeline = Timeline()
        await h.tools.register("test.sleep", handler: sleepingTool(timeline, seconds: 0.05))
        let doc = try workflow((1...5).map { "    - id: s\($0)\n      tool: test.sleep\n      with: {id: s\($0)}\n" }.joined())
        let outcome = await h.engine(configuration: .init(maxConcurrentSteps: 2)).run(doc, options: h.options())
        #expect(outcome.status == .succeeded)
        #expect(await timeline.maxActive == 2)
        let serial = Timeline()
        let h2 = try Harness(); defer { h2.tmp.remove() }
        await h2.tools.register("test.sleep", handler: sleepingTool(serial, seconds: 0.03))
        _ = await h2.engine(configuration: .init(maxConcurrentSteps: 1)).run(doc, options: h2.options())
        #expect(await serial.maxActive == 1)
    }

    @Test func conditionRoutesBranchesAndSkipsPropagate() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: check
              if: ${{ params.n > 2 }}
              then: [big]
              else: [small]
            - id: big
              tool: test.echo
              with: {size: big}
            - id: small
              tool: test.echo
              with: {size: small}
            - id: afterSmall
              needs: [small]
              tool: test.echo
            - id: gated
              when: ${{ params.n == 0 }}
              tool: test.echo
            - id: always
              needs: [check]
              tool: test.echo

        """, spec: "  parameters:\n    - {name: n, type: integer, default: 1}\n")
        let big = await h.engine().run(doc, options: h.options(["n": 5]))
        #expect(big.status == .succeeded)
        #expect(big.step("check")?.output == ["result": true, "branch": "then"])
        #expect(big.step("big")?.status == .succeeded)
        #expect(big.step("small")?.status == .skipped && big.step("small")?.note?.contains("'then' branch") == true)
        #expect(big.step("afterSmall")?.status == .skipped && big.step("afterSmall")?.note?.contains("'small' was skipped") == true)
        #expect(big.step("gated")?.status == .skipped && big.step("gated")?.note?.contains("when") == true)
        #expect(big.step("always")?.status == .succeeded)
        #expect(await h.calls("test.echo").count == 2)

        let h2 = try Harness(); defer { h2.tmp.remove() }
        await h2.registerBasics()
        let small = await h2.engine().run(doc, options: h2.options())
        #expect(small.step("big")?.status == .skipped && small.step("small")?.status == .succeeded && small.step("afterSmall")?.status == .succeeded)
    }

    @Test func switchSelectsCaseOrDefault() async throws {
        let doc = try workflow("""
            - id: pick
              switch: ${{ params.mode }}
              cases:
                - value: fast
                  steps: [quick]
                - value: 2
                  steps: [two]
              default: [fallback]
            - id: quick
              tool: test.echo
            - id: two
              tool: test.echo
            - id: fallback
              tool: test.echo

        """, spec: "  parameters:\n    - {name: mode, type: string, default: fast}\n")
        for (mode, expected) in [("fast", "quick"), ("other", "fallback")] {
            let h = try Harness(); defer { h.tmp.remove() }
            await h.registerBasics()
            let outcome = await h.engine().run(doc, options: h.options(["mode": .string(mode)]))
            #expect(outcome.status == .succeeded)
            for id in ["quick", "two", "fallback"] { #expect(outcome.step(id)?.status == (id == expected ? .succeeded : .skipped), "\(mode): \(id)") }
        }
    }

    @Test func foreachFansOutInOrderWithBoundedConcurrency() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let timeline = Timeline()
        await h.tools.register("test.sleep", handler: sleepingTool(timeline, seconds: 0.03))
        await h.registerBasics()
        let doc = try workflow("""
            - id: each
              foreach: ${{ params.names }}
              as: name
              concurrency: 3
              collect: shout
              steps:
                - id: nap
                  tool: test.sleep
                  with: {id: "${{ name }}"}
                - id: shout
                  needs: [nap]
                  transform: ${{ upper(name) + string(index) }}
            - id: all
              needs: [each]
              output: {names: "${{ steps.each.output.results }}", count: "${{ steps.each.output.count }}"}

        """, spec: "  parameters:\n    - {name: names, type: array, default: [a, b, c, d, e, f, g]}\n")
        let outcome = await h.engine(configuration: .init(maxConcurrentSteps: 8)).run(doc, options: h.options())
        #expect(outcome.status == .succeeded)
        #expect(outcome.outputs["names"] == ["A0", "B1", "C2", "D3", "E4", "F5", "G6"])
        #expect(outcome.outputs["count"] == 7)
        #expect(await timeline.maxActive == 3, "foreach concurrency bounds the fan-out")
        #expect(outcome.results(for: "shout").map(\.key).sorted().first == "each[0]/shout")
        #expect(outcome.results(for: "nap").count == 7)
    }

    @Test func parallelBranchesRunTogetherAndJoin() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let timeline = Timeline()
        await h.tools.register("test.sleep", handler: sleepingTool(timeline, seconds: 0.15))
        let doc = try workflow("""
            - id: both
              parallel:
                - name: left
                  steps:
                    - id: l
                      tool: test.sleep
                      with: {id: l}
                - name: right
                  steps:
                    - id: r
                      tool: test.sleep
                      with: {id: r}
            - id: after
              needs: [both]
              output: {left: "${{ steps.both.output.left.l.id }}", right: "${{ steps.both.output.right.r.id }}"}

        """)
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .succeeded && outcome.outputs == ["left": "l", "right": "r"])
        #expect(await timeline.overlap("l", "r"))
    }

    @Test func loopRunsUntilConditionIsFalseAndStopsAtItsBound() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: poll
              while: ${{ vars.n < params.target }}
              maxIterations: 5
              steps:
                - id: bump
                  set: {n: "${{ vars.n + 1 }}", seen: "${{ loop.index }}"}
            - id: done
              needs: [poll]
              output: {n: "${{ vars.n }}", iterations: "${{ steps.poll.output.iterations }}"}

        """, spec: "  parameters:\n    - {name: target, type: integer, default: 3}\n  variables:\n    n: 0\n")
        let ok = await h.engine().run(doc, options: h.options())
        #expect(ok.status == .succeeded && ok.outputs == ["n": 3, "iterations": 3])
        #expect(ok.results(for: "bump").map(\.key) == ["poll#0/bump", "poll#1/bump", "poll#2/bump"])

        let h2 = try Harness(); defer { h2.tmp.remove() }
        let bounded = await h2.engine().run(doc, options: h2.options(["target": 99]))
        #expect(bounded.status == .failed)
        #expect(bounded.step("poll")?.errorCode == "loop_bound" && bounded.results(for: "bump").count == 5)
        #expect(bounded.step("done") == nil, "nothing runs after an unhandled failure")
    }

    @Test func foreachRefusesNonLists() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let doc = try workflow("    - id: each\n      foreach: ${{ 42 }}\n      steps:\n        - id: x\n          delay: 0\n")
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .failed && outcome.step("each")?.error?.contains("needs a list") == true)
    }
}

// MARK: - Failure handling

@Suite("Engine retries, timeouts and error routing (mocked tools)") struct EngineFailureTests {
    static let flakyDoc = """
        - id: flaky
          tool: TOOL
          retry: {maxAttempts: 4, backoffSeconds: 1, backoffMultiplier: 2FORCE}

    """

    func runFlaky(tool: String, idempotent: Bool, force: Bool) async throws -> (WorkflowOutcome, [Double], [RunEvent], Int) {
        let h = try Harness(); defer { h.tmp.remove() }
        let counter = Counter()
        await h.tools.register(tool, sideEffect: idempotent ? .read : .write, tier: idempotent ? .readOnly : .reversibleWrite, idempotent: idempotent) { _, _ in
            let n = await counter.next()
            return n < 3 ? .failure(.failed, ToolFailure(code: "network", message: "attempt \(n) failed", retryable: true)) : .success(["attempt": .int(n)], summary: "ok")
        }
        let clock = VirtualWorkflowClock()
        let doc = try workflow(Self.flakyDoc.replacingOccurrences(of: "TOOL", with: tool).replacingOccurrences(of: "FORCE", with: force ? ", force: true" : ""))
        let outcome = await h.engine(clock: clock).run(doc, options: h.options())
        return (outcome, clock.sleeps, await h.sink.events(of: .retry), await counter.value)
    }

    @Test func idempotentToolIsRetriedWithBackoff() async throws {
        let (outcome, sleeps, events, calls) = try await runFlaky(tool: "test.flakyRead", idempotent: true, force: false)
        #expect(outcome.status == .succeeded)
        #expect(outcome.step("flaky")?.attempts == 3 && calls == 3)
        #expect(sleeps == [1, 2], "exponential backoff through the injected clock")
        #expect(events.count == 2 && events.allSatisfy { $0.data["retried"] == true && $0.stepID == "flaky" })
    }

    @Test func nonIdempotentToolIsNotBlindlyRetriedAndTheEventSaysWhy() async throws {
        let (outcome, sleeps, events, calls) = try await runFlaky(tool: "test.flakyWrite", idempotent: false, force: false)
        #expect(outcome.status == .failed)
        #expect(outcome.step("flaky")?.attempts == 1 && calls == 1 && sleeps.isEmpty)
        #expect(events.count == 1 && events[0].data["retried"] == false)
        #expect(events[0].text.contains("not idempotent") && events[0].text.contains("retry.force"))
    }

    @Test func forceRetriesANonIdempotentTool() async throws {
        let (outcome, _, events, calls) = try await runFlaky(tool: "test.flakyWrite", idempotent: false, force: true)
        #expect(outcome.status == .succeeded && calls == 3)
        #expect(events.count == 2 && events.allSatisfy { $0.data["forced"] == true })
    }

    @Test func retriesStopAtMaxAttempts() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("    - id: f\n      tool: test.fail\n      retry: {maxAttempts: 3}\n")
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .failed && outcome.step("f")?.attempts == 3)
        #expect(await h.calls("test.fail").count == 3)
        #expect(outcome.errors.contains { $0.contains("disk on fire") })
    }

    @Test func stepTimeoutCancelsTheToolAndMapsToTimedOut() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let timeline = Timeline()
        await h.tools.register("test.sleep", handler: sleepingTool(timeline, seconds: 10))
        await h.registerBasics()
        let doc = try workflow("""
            - id: slow
              tool: test.sleep
              with: {id: slow}
              timeoutSeconds: 0.1
            - id: after
              needs: [slow]
              tool: test.echo

        """)
        let began = Date()
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(outcome.status == .timedOut)
        #expect(outcome.step("slow")?.status == .timedOut && outcome.step("slow")?.errorCode == "timeout")
        #expect(await timeline.canceled == ["slow"], "the timeout must cancel the running tool")
        #expect(outcome.step("after") == nil)

        let h2 = try Harness(); defer { h2.tmp.remove() }
        await h2.tools.register("test.sleep", handler: sleepingTool(Timeline(), seconds: 10))
        await h2.registerBasics()
        var tolerant = doc
        tolerant.spec.steps[0].continueOnError = true
        let partial = await h2.engine().run(tolerant, options: h2.options())
        #expect(partial.status == .partiallySucceeded && partial.step("after")?.status == .succeeded)
    }

    @Test func continueOnErrorYieldsPartialSuccess() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: bad
              tool: test.fail
              continueOnError: true
            - id: next
              needs: [bad]
              tool: test.echo
              with: {saw: "${{ steps.bad.status }}", why: "${{ steps.bad.error }}"}

        """)
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .partiallySucceeded)
        #expect(outcome.step("bad")?.status == .failed && outcome.step("bad")?.continued == true)
        #expect(outcome.step("next")?.output == ["saw": "failed", "why": "disk on fire"])
    }

    @Test func onErrorRoutesToACompensationStep() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: write
              tool: test.fail
              onError: undo
            - id: undo
              tool: test.echo
              with: {compensating: "${{ error.stepID }}", because: "${{ error.message }}", status: "${{ steps.write.status }}"}
            - id: next
              needs: [write]
              tool: test.echo
              with: {handled: yes}

        """)
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .partiallySucceeded)
        #expect(outcome.step("write")?.handledBy == "undo" && outcome.step("write")?.continued == true)
        #expect(outcome.step("undo")?.output == ["compensating": "write", "because": "disk on fire", "status": "failed"])
        #expect(outcome.step("next")?.status == .succeeded)
        #expect(outcome.steps.map(\.stepID) == ["undo", "write", "next"])
    }

    @Test func handlerOnlyRunsOnFailureAndAFailingHandlerFailsTheRun() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let fine = try workflow("    - id: ok\n      tool: test.echo\n      onError: undo\n    - id: undo\n      tool: test.echo\n")
        let clean = await h.engine().run(fine, options: h.options())
        #expect(clean.status == .succeeded && clean.step("undo") == nil, "a handler step never runs in the normal flow")

        let h2 = try Harness(); defer { h2.tmp.remove() }
        await h2.registerBasics()
        let broken = try workflow("    - id: bad\n      tool: test.fail\n      onError: undo\n    - id: undo\n      fail: cannot undo\n")
        let failed = await h2.engine().run(broken, options: h2.options())
        #expect(failed.status == .failed && failed.step("bad")?.handledBy == nil && failed.step("undo")?.status == .failed)
    }

    @Test func workflowLevelOnErrorRunsAfterAFailure() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("    - id: bad\n      fail: \"stop: ${{ 1 + 1 }}\"\n",
                               spec: "  onError:\n    - id: alert\n      notify: \"${{ error.stepID }} failed: ${{ error.message }}\"\n")
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .failed)
        #expect(outcome.step("bad")?.error == "stop: 2" && outcome.step("alert")?.status == .succeeded)
        #expect(await h.calls("notifications.post").first?.arguments == ["title": "Test", "body": "bad failed: stop: 2"])
    }

    @Test func failureInsideAContainerCanBeHandledByTheContainer() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: each
              foreach: [1, 2, 3]
              continueOnError: true
              steps:
                - id: maybe
                  when: ${{ item == 2 }}
                  tool: test.fail
            - id: after
              needs: [each]
              tool: test.echo

        """)
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .partiallySucceeded)
        #expect(outcome.step("each")?.status == .failed && outcome.step("each")?.error?.contains("iteration 1") == true)
        #expect(outcome.step("after")?.status == .succeeded)
    }

    @Test func expressionErrorsFailTheStepWithADiagnostic() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("    - id: bad\n      tool: test.echo\n      with: {x: \"${{ 1 / 0 }}\"}\n")
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .failed && outcome.step("bad")?.errorCode == "expression")
        #expect(outcome.diagnostics.first?.stepID == "bad" && outcome.diagnostics.first?.message.contains("division by zero") == true)
        #expect(await h.tools.calls.isEmpty)
    }

    @Test func interpolatedToolOutputIsNeverReEvaluated() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        await h.tools.register("test.hostile") { _, _ in .success(["text": "${{ secret(\"api\") }} ${{ env.HOME }}"], summary: "web page") }
        let doc = try workflow("""
            - id: fetch
              tool: test.hostile
            - id: use
              needs: [fetch]
              tool: test.echo
              with: {exact: "${{ steps.fetch.output.text }}", mixed: "got ${{ steps.fetch.output.text }}"}

        """)
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .succeeded)
        #expect(outcome.step("use")?.output == ["exact": "${{ secret(\"api\") }} ${{ env.HOME }}", "mixed": "got ${{ secret(\"api\") }} ${{ env.HOME }}"])
    }
}

// MARK: - Approvals, dry run, budgets, status mapping

@Suite("Engine approvals, dry run, budgets and statuses (mocked tools)") struct EnginePolicyTests {
    static let gated = """
        - id: prepare
          tool: test.effect
          with: {n: 1}
        - id: gate
          needs: [prepare]
          approval: "Send ${{ steps.prepare.output.n }} file?"
        - id: send
          needs: [gate]
          tool: test.effect
          with: {n: 2}

    """

    @Test func approvalApprovedDeniedAndUnanswered() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow(Self.gated)
        let approved = await h.engine(approval: { prompt in
            #expect(prompt.message == "Send 1 file?" && prompt.stepID == "gate")
            return .approveOnce
        }).run(doc, options: h.options())
        #expect(approved.status == .succeeded && approved.step("gate")?.output == ["approved": true])
        #expect(await h.sink.events(of: .approvalRequested).count == 1)
        #expect(await h.sink.events(of: .approvalResolved).count == 1)
        let transitions = await h.sink.events(of: .statusChanged).map(\.text)
        #expect(transitions.contains("RUNNING → WAITING_APPROVAL") && transitions.contains("WAITING_APPROVAL → RUNNING"))

        let h2 = try Harness(); defer { h2.tmp.remove() }
        await h2.registerBasics()
        let denied = await h2.engine(approval: { _ in .deny(reason: "not today") }).run(doc, options: h2.options())
        #expect(denied.status == .failed && denied.step("gate")?.error == "approval denied: not today")
        #expect(await h2.calls("test.effect").count == 1)

        let h3 = try Harness(); defer { h3.tmp.remove() }
        await h3.registerBasics()
        let unanswered = await h3.engine().run(doc, options: h3.options())
        #expect(unanswered.status == .waitingApproval && unanswered.step("gate")?.status == .notApproved)
        #expect(await h3.calls("test.effect").count == 1, "nothing after the gate may run")

        // The run can be resumed from its checkpoint once somebody answers: the completed step is not run again.
        let checkpoint = try #require(unanswered.checkpoint)
        let resumed = await h3.engine(approval: { _ in .approveForRun }).resume(from: checkpoint, options: h3.options()).outcome()
        #expect(resumed.status == .succeeded)
        #expect(await h3.calls("test.effect").map { $0.arguments["n"] } == [1, 2])
    }

    @Test func dryRunExecutesNothingAndSaysExactlyWhatWasSimulated() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        await h.tools.register("test.plan", sideEffect: .write, tier: .reversibleWrite, idempotent: false) { call, _ in
            call.dryRun ? .simulated(["wouldMove": 3], summary: "would move 3 files") : .success(["moved": 3], summary: "moved 3 files")
        }
        let agent = FakeAgentRunner { _ in AgentOutcome(status: .succeeded) }
        let invoker = DryRunAwareInvoker(base: h.tools, dryRunTools: ["test.plan"])
        let doc = try workflow("""
            - id: plan
              tool: test.plan
              with: {path: /tmp/x}
            - id: effect
              needs: [plan]
              tool: test.effect
            - id: think
              needs: [effect]
              agent: {instructions: Think, model: anthropic/test}
              objective: Decide
            - id: gate
              needs: [think]
              approval: Go?
            - id: wait
              needs: [gate]
              delay: 3600
            - id: check
              needs: [wait]
              verify:
                - truthy: ${{ steps.effect.output.done }}
            - id: tell
              needs: [check]
              notify: Finished
            - id: out
              needs: [tell]
              output: {planned: "${{ steps.plan.output.wouldMove }}"}

        """)
        let began = Date()
        let outcome = await h.engine(invoker: invoker, agents: agent, approval: { _ in Issue.record("no approval in a dry run"); return .approveOnce })
            .run(doc, options: h.options(dryRun: true))
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(outcome.status == .succeeded && outcome.dryRun)
        let calls = await h.tools.calls
        #expect(calls.map(\.toolID) == ["test.plan"], "only dry-run capable tools are invoked")
        #expect(calls.allSatisfy { $0.dryRun }, "every invocation carries dryRun: true")
        #expect(await agent.tasks.isEmpty)
        #expect(outcome.steps.filter { $0.stepID != "out" }.allSatisfy { $0.status == .simulated })
        #expect(outcome.step("plan")?.note == "simulated: test.plan was invoked with dryRun: true — would move 3 files")
        #expect(outcome.step("effect")?.note == "simulated: not executed (test.effect: the tool has no dry-run mode)")
        #expect(outcome.step("think")?.note?.contains("agent was not run") == true)
        #expect(outcome.step("tell")?.note?.hasPrefix("simulated: not executed (notifications.post") == true)
        #expect(outcome.simulations.count == 7 && outcome.simulations[0].hasPrefix("plan: simulated:"))
        #expect(outcome.outputs == ["planned": 3])
        #expect(outcome.verifications.isEmpty)
    }

    @Test func toolCallBudgetStopsTheRun() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: a
              tool: test.echo
            - id: b
              needs: [a]
              tool: test.echo
            - id: c
              needs: [b]
              tool: test.echo

        """, spec: "  budget:\n    maxToolCalls: 2\n")
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .budgetExceeded)
        #expect(outcome.step("c")?.status == .budgetExceeded && outcome.usage.toolCalls == 2)
        #expect(await h.tools.calls.count == 2)
        #expect(outcome.errors.contains { $0.contains("maxToolCalls") })
    }

    @Test func agentCostBudgetStopsTheRunAndUsageIsAggregated() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let agent = FakeAgentRunner { task in
            var usage = RunUsage()
            usage.turns = 2; usage.toolCalls = 1; usage.costUSD = 0.75
            usage.tokens = TokenUsage(inputTokens: 100, outputTokens: 50)
            return AgentOutcome(status: .succeeded, finalText: "done: \(task.objective)", result: ["n": 1], usage: usage)
        }
        let doc = try workflow("""
            - id: first
              agent: writer
              objective: Draft ${{ params.topic }}
              inputs: {topic: "${{ params.topic }}"}
              expect:
                - fileNonEmpty: ~/out/${{ params.topic }}.md
            - id: second
              needs: [first]
              agent: writer
              objective: Refine ${{ steps.first.output.text }}
            - id: third
              needs: [second]
              tool: test.echo

        """, spec: "  parameters:\n    - {name: topic, type: string, default: cats}\n  budget:\n    maxProviderCostUSD: 1\n")
        let profile = AgentProfile(name: "writer", instructions: "Write.", model: ModelRef(provider: .anthropic, model: "test"))
        let outcome = await h.engine(agents: agent, profiles: { $0 == "writer" ? profile : nil }).run(doc, options: h.options())
        #expect(outcome.status == .budgetExceeded)
        #expect(outcome.usage.costUSD == 1.5 && outcome.usage.turns == 4 && outcome.usage.tokens.totalTokens == 300 && outcome.usage.toolCalls == 2)
        #expect(outcome.step("second")?.status == .succeeded && outcome.step("third") == nil)
        let tasks = await agent.tasks
        #expect(tasks.count == 2)
        #expect(tasks[0].objective == "Draft cats" && tasks[0].inputs == ["topic": "cats"])
        #expect(tasks[0].expectations == [Expectation(kind: "file_nonempty", path: "~/out/cats.md")])
        #expect(tasks[0].budget.maxCostUSD == 1 && tasks[1].budget.maxCostUSD == 0.25, "the agent only gets what is left of the workflow budget")
        #expect(tasks[1].objective == "Refine done: Draft cats")
    }

    @Test func agentStepNeedsARuntimeAndAModel() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let doc = try workflow("    - id: a\n      agent: {instructions: Hi}\n      objective: Go\n")
        let noRuntime = await h.engine().run(doc, options: h.options())
        #expect(noRuntime.status == .failed && noRuntime.step("a")?.error?.contains("no agent runtime") == true)
        let agent = FakeAgentRunner { _ in AgentOutcome(status: .succeeded) }
        let h2 = try Harness(); defer { h2.tmp.remove() }
        let noModel = await h2.engine(agents: agent).run(doc, options: h2.options())
        #expect(noModel.status == .failed && noModel.step("a")?.error?.contains("no default model") == true)
        let h3 = try Harness(); defer { h3.tmp.remove() }
        let ok = await h3.engine(agents: agent, configuration: .init(defaultModel: ModelRef(provider: .openai, model: "m"))).run(doc, options: h3.options())
        #expect(ok.status == .succeeded)
        let inline = await agent.profiles.first
        #expect(inline?.model == ModelRef(provider: .openai, model: "m") && inline?.toolPatterns == [])
    }

    @Test func durationBudgetMapsToTimedOut() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: wait
              delay: 120
            - id: late
              needs: [wait]
              tool: test.echo

        """, spec: "  budget:\n    maxDurationSeconds: 60\n")
        let clock = VirtualWorkflowClock()
        let outcome = await h.engine(clock: clock).run(doc, options: h.options())
        #expect(outcome.status == .timedOut && clock.sleeps == [120])
        #expect(outcome.step("late") == nil && outcome.errors.contains { $0.contains("maxDurationSeconds") })

        // Real time: the watchdog cancels a running step.
        let h2 = try Harness(); defer { h2.tmp.remove() }
        let timeline = Timeline()
        await h2.tools.register("test.sleep", handler: sleepingTool(timeline, seconds: 10))
        let slow = try workflow("    - id: slow\n      tool: test.sleep\n      with: {id: slow}\n", spec: "  budget:\n    maxDurationSeconds: 0.15\n")
        let real = await h2.engine().run(slow, options: h2.options())
        #expect(real.status == .timedOut && real.step("slow")?.status == .canceled)
        #expect(await timeline.canceled == ["slow"])
    }

    @Test(arguments: [
        (ToolStatus.succeeded, RunStatus.succeeded), (.failed, .failed), (.denied, .failed), (.invalidInput, .failed), (.unsupported, .failed),
        (.notApproved, .waitingApproval), (.blockedPermission, .blockedPermission), (.timedOut, .timedOut), (.canceled, .canceled),
    ])
    func toolStatusMapsToRunStatus(tool: ToolStatus, expected: RunStatus) async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        await h.tools.register("test.status") { _, _ in
            tool == .succeeded ? .success(.null, summary: "ok") : .failure(tool, ToolFailure(code: tool.rawValue, message: "tool said \(tool.rawValue)"))
        }
        let doc = try workflow("    - id: s\n      tool: test.status\n    - id: after\n      needs: [s]\n      tool: test.echo\n")
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == expected)
        #expect(outcome.step("s")?.status == WorkflowEngine.stepStatus(for: tool))
        #expect((outcome.step("after") != nil) == (tool == .succeeded))
        // Every transition the run announced is legal for the Core state machine.
        var current = RunStatus.queued
        for e in await h.sink.events(of: .statusChanged) {
            let next = try #require(RunStatus(rawValue: e.data["to"]?.stringValue ?? ""))
            #expect(current.canTransition(to: next), "\(current.rawValue) → \(next.rawValue)")
            current = next
        }
        #expect(current == expected)
    }

    @Test func unhandledStepStatusTable() {
        let expected: [StepStatus: RunStatus] = [
            .failed: .failed, .timedOut: .timedOut, .canceled: .canceled, .notApproved: .waitingApproval,
            .blockedPermission: .blockedPermission, .budgetExceeded: .budgetExceeded, .recoveryRequired: .recoveryRequired,
        ]
        for (step, run) in expected { #expect(WorkflowEngine.runStatus(forUnhandled: step) == run) }
        #expect(StepStatus.simulated.isSuccess && StepStatus.succeeded.isSuccess && !StepStatus.skipped.isSuccess)
    }

    @Test func invalidDocumentsAndParametersAreRefusedBeforeAnythingRuns() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let cyclic = try workflow("    - id: a\n      needs: [b]\n      tool: test.echo\n    - id: b\n      needs: [a]\n      tool: test.echo\n")
        let refused = await h.engine().run(cyclic, options: h.options())
        #expect(refused.status == .failed && refused.errors.contains { $0.contains("dependency cycle") })
        let needsParam = try workflow("    - id: a\n      tool: test.echo\n", spec: "  parameters:\n    - {name: folder, type: path, required: true}\n    - {name: n, type: integer, default: 1}\n")
        let missing = await h.engine().run(needsParam, options: h.options())
        #expect(missing.status == .failed && missing.errors == ["missing required parameter 'folder'"])
        let wrongType = await h.engine().run(needsParam, options: h.options(["folder": "/x", "n": "many"]))
        #expect(wrongType.errors == ["parameter 'n' must be of type integer"])
        let unknown = await h.engine().run(needsParam, options: h.options(["folder": "/x", "typo": 1]))
        #expect(unknown.errors == ["unknown parameter 'typo'"])
        #expect(await h.tools.calls.isEmpty)
    }
}

// MARK: - Control: cancellation, debugger

@Suite("Engine control handle (mocked tools)") struct EngineControlTests {
    @Test func cancellationReachesRunningSteps() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let timeline = Timeline()
        await h.tools.register("test.sleep", handler: sleepingTool(timeline, seconds: 10))
        await h.registerBasics()
        let doc = try workflow("""
            - id: one
              tool: test.sleep
              with: {id: one}
            - id: two
              tool: test.sleep
              with: {id: two}
            - id: after
              needs: [one, two]
              tool: test.echo

        """)
        let engine = h.engine()
        let run = await engine.start(doc, options: h.options())
        #expect(await waitUntil { await run.state.running.count == 2 })
        #expect(await engine.activeRunIDs == ["run-1"])
        let began = Date()
        await run.cancel()
        let outcome = await run.outcome()
        #expect(Date().timeIntervalSince(began) < 5, "cancel must not wait for the 10 s tools")
        #expect(outcome.status == .canceled)
        #expect(await timeline.canceled.sorted() == ["one", "two"], "task cancellation reached both running tools")
        #expect(outcome.step("one")?.status == .canceled && outcome.step("after") == nil)
        #expect(await h.calls("test.echo").isEmpty)
        #expect(await waitUntil { await engine.activeRunIDs.isEmpty })
    }

    @Test func pauseStepOverAndResume() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: a
              tool: test.echo
            - id: b
              needs: [a]
              tool: test.echo
            - id: c
              needs: [b]
              tool: test.echo

        """)
        let run = await h.engine().start(doc, options: h.options(startPaused: true))
        #expect(await waitUntil { let s = await run.state; return s.status == .paused && s.pausedAt == ["a"] })
        #expect(await h.tools.calls.isEmpty, "nothing runs while paused")
        await run.stepOver()
        #expect(await waitUntil { await run.state.pausedAt == ["b"] })
        #expect(await h.tools.calls.count == 1)
        #expect(await run.inspect("a")?.status == .succeeded)
        #expect(await run.state.steps["a"] == .succeeded)
        await run.stepOver()
        #expect(await waitUntil { await run.state.pausedAt == ["c"] })
        #expect(await h.tools.calls.count == 2)
        await run.resume()
        let outcome = await run.outcome()
        #expect(outcome.status == .succeeded && outcome.steps.count == 3)
        let transitions = await h.sink.events(of: .statusChanged).map(\.text)
        #expect(transitions.contains("RUNNING → PAUSED") && transitions.contains("PAUSED → RUNNING"))
    }

    @Test func breakpointsPauseAndVariablesCanBeModified() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: init
              set: {greeting: hello}
            - id: say
              needs: [init]
              tool: test.echo
              with: {text: "${{ vars.greeting }} ${{ vars.who }}"}
            - id: end
              needs: [say]
              tool: test.echo

        """, spec: "  variables:\n    who: world\n")
        let run = await h.engine().start(doc, options: h.options(breakpoints: ["say"]))
        var seen: [RunStatus] = []
        let watcher = Task { () -> [RunStatus] in
            var out: [RunStatus] = []
            for await s in await run.states() { if out.last != s.status { out.append(s.status) } }
            return out
        }
        #expect(await waitUntil { let s = await run.state; return s.pausedAt == ["say"] && s.status == .paused })
        #expect(await run.variables() == ["greeting": "hello", "who": "world"])
        #expect(await run.inspect("init")?.output == ["greeting": "hello"])
        await run.setVariable("who", to: "debugger")
        await run.removeBreakpoint("say")
        await run.addBreakpoint("end")
        await run.resume()
        #expect(await waitUntil { await run.state.pausedAt == ["end"] })
        #expect(await run.inspect("say")?.output == ["text": "hello debugger"])
        await run.resume()
        let outcome = await run.outcome()
        seen = await watcher.value
        #expect(outcome.status == .succeeded)
        #expect(seen.contains(.paused) && seen.last == .succeeded, "the state stream ends with the final status: \(seen)")
        #expect(await h.sink.events(of: .log).contains { $0.text.contains("breakpoint hit at 'say'") })
    }

    @Test func pauseDuringARunHoldsTheNextStep() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let timeline = Timeline()
        await h.tools.register("test.sleep", handler: sleepingTool(timeline, seconds: 0.2))
        await h.registerBasics()
        let doc = try workflow("    - id: slow\n      tool: test.sleep\n      with: {id: slow}\n    - id: next\n      needs: [slow]\n      tool: test.echo\n")
        let run = await h.engine().start(doc, options: h.options())
        #expect(await waitUntil { await run.state.running == ["slow"] })
        await run.pause()
        #expect(await waitUntil { let s = await run.state; return s.status == .paused && s.pausedAt == ["next"] })
        #expect(await run.inspect("slow")?.status == .succeeded, "a running step finishes; the next one waits")
        #expect(await h.calls("test.echo").isEmpty)
        await run.cancel()
        #expect(await run.outcome().status == .canceled)
    }
}

// MARK: - Checkpoints

@Suite("Engine checkpoints and recovery (mocked tools)") struct EngineCheckpointTests {
    static let pipeline = """
        - id: a
          tool: test.echo
          with: {v: 1}
        - id: b
          needs: [a]
          tool: TOOL
          with: {v: "${{ steps.a.output.v + 1 }}"}
        - id: c
          needs: [b]
          tool: test.effect
          with: {v: "${{ steps.b.output.v + 1 }}"}
        - id: out
          needs: [c]
          output: {v: "${{ steps.c.output.v }}"}

    """

    /// Runs the pipeline once and returns the checkpoint saved while `b` was mid-flight (a simulated crash point).
    func crashedDuringB(_ h: Harness, tool: String) async throws -> (WorkflowDocument, WorkflowCheckpoint) {
        await h.registerBasics()
        let doc = try workflow(Self.pipeline.replacingOccurrences(of: "TOOL", with: tool), spec: "  variables:\n    seed: 7\n")
        let first = await h.engine().run(doc, options: h.options())
        #expect(first.status == .succeeded && first.outputs == ["v": 3])
        let history = await h.store.history
        let crash = try #require(history.first { $0.inFlight.map(\.stepID) == ["b"] && $0.results["a"]?.status == .succeeded })
        #expect(crash.results["b"] == nil)
        return (doc, crash)
    }

    @Test func checkpointsAreSavedAfterEveryStepAndRemovedOnSuccess() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let (_, crash) = try await crashedDuringB(h, tool: "test.echo")
        let history = await h.store.history
        #expect(history.map(\.sequence) == Array(1...history.count), "sequence increases with every save")
        #expect(history.count >= 8, "one save when a step starts and one when it finishes")
        #expect(crash.variables[""] == ["seed": 7] && crash.document.spec.steps.count == 4)
        #expect(await h.store.latest(runID: "run-1") == nil, "a finished successful run leaves no checkpoint behind")
        let data = try JSONEncoder().encode(crash)
        #expect(try JSONDecoder().decode(WorkflowCheckpoint.self, from: data) == crash, "checkpoints are Codable for durable stores")
    }

    @Test func resumeDoesNotReRunCompletedStepsAndReRunsAnIdempotentInFlightStep() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let (_, crash) = try await crashedDuringB(h, tool: "test.echo")
        let before = await h.tools.calls.count
        let resumed = await h.engine().resume(from: crash, options: h.options()).outcome()
        #expect(resumed.status == .succeeded && resumed.outputs == ["v": 3])
        let after = await h.tools.calls.dropFirst(before)
        #expect(after.map(\.toolID) == ["test.echo", "test.effect"], "a is not run again; b (idempotent, mid-flight) and c run")
        #expect(after.first?.arguments == ["v": 2])
        #expect(await h.sink.events(of: .statusChanged).map(\.text).contains("RECOVERING → RUNNING"))
        #expect(await h.sink.events(of: .log).contains { $0.text.contains("1 completed step(s) will not run again") })
    }

    @Test func nonIdempotentInFlightStepLeadsToRecoveryRequired() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let (_, crash) = try await crashedDuringB(h, tool: "test.effect")
        #expect(crash.inFlight == [InFlightStep(key: "b", stepID: "b", kind: "tool", idempotent: false, isContainer: false)])
        let before = await h.tools.calls.count
        let blocked = await h.engine().resume(from: crash, options: h.options()).outcome()
        #expect(blocked.status == .recoveryRequired)
        #expect(await h.tools.calls.count == before, "nothing is executed, least of all the interrupted step")
        #expect(blocked.step("b")?.status == .recoveryRequired && blocked.errors.first?.contains("not idempotent") == true)
        #expect(blocked.checkpoint == crash, "the interrupted checkpoint stays the one to resume from")
        var legal = RunStatus.queued
        for e in await h.sink.events(of: .statusChanged).suffix(1) {
            legal = RunStatus(rawValue: e.data["from"]?.stringValue ?? "") ?? .queued
            #expect(legal == .recovering && e.data["to"] == "RECOVERY_REQUIRED")
        }

        // The operator confirms the effect happened: the run continues without repeating it.
        let marked = await h.engine().resume(from: crash, options: h.options(resolutions: ["b": .markSucceeded(output: ["v": 2])])).outcome()
        #expect(marked.status == .succeeded && marked.outputs == ["v": 3])
        #expect(await h.tools.calls.dropFirst(before).map { $0.arguments["v"] } == [3], "only c ran")

        // Or decides a re-run is safe.
        let count = await h.tools.calls.count
        let rerun = await h.engine().resume(from: crash, options: h.options(resolutions: ["b": .rerun])).outcome()
        #expect(rerun.status == .succeeded)
        #expect(await h.tools.calls.dropFirst(count).map { $0.arguments["v"] } == [2, 3])
    }

    @Test func resumeContinuesInsideContainers() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: each
              foreach: [10, 20, 30]
              steps:
                - id: work
                  tool: test.echo
                  with: {n: "${{ item }}"}
            - id: poll
              needs: [each]
              while: ${{ vars.n < 3 }}
              maxIterations: 9
              steps:
                - id: bump
                  set: {n: "${{ vars.n + 1 }}"}
                - id: ping
                  needs: [bump]
                  tool: test.echo
                  with: {n: "${{ vars.n }}"}
            - id: out
              needs: [poll]
              output: {n: "${{ vars.n }}", items: "${{ map(steps.each.output.results, r => r.work.n) }}"}

        """, spec: "  variables:\n    n: 0\n")
        let first = await h.engine().run(doc, options: h.options())
        #expect(first.status == .succeeded && first.outputs == ["n": 3, "items": [10, 20, 30]])
        let history = await h.store.history
        // Crash while the second foreach iteration was running.
        let mid = try #require(history.first { $0.inFlight.map(\.key) == ["each", "each[1]/work"] })
        var count = await h.tools.calls.count
        let resumed = await h.engine().resume(from: mid, options: h.options()).outcome()
        #expect(resumed.status == .succeeded && resumed.outputs == ["n": 3, "items": [10, 20, 30]])
        #expect(await h.tools.calls.dropFirst(count).map { $0.arguments["n"] } == [20, 30, 1, 2, 3], "iteration 0 is not repeated")
        // Crash in the middle of loop iteration 1, after its `set` step: the counter must not be bumped twice.
        let loopMid = try #require(history.first { $0.inFlight.map(\.key) == ["poll", "poll#1/ping"] })
        #expect(loopMid.variables[""] == ["n": 2] && loopMid.containerState["poll"] == 1)
        count = await h.tools.calls.count
        let again = await h.engine().resume(from: loopMid, options: h.options()).outcome()
        #expect(again.status == .succeeded && again.outputs["n"] == 3)
        #expect(await h.tools.calls.dropFirst(count).map { $0.arguments["n"] } == [2, 3])
    }
}

// MARK: - Verification with real files, subworkflows, misc

@Suite("Engine verification (integration: real files in a temp directory)") struct EngineVerificationTests {
    @Test func verifyChecksRealStateAndGatesSuccess() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let root = h.tmp.url.path
        await h.tools.register("test.write", sideEffect: .write, tier: .reversibleWrite, idempotent: false) { call, _ in
            let path = call.arguments["path"]?.stringValue ?? ""
            do {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try (call.arguments["content"]?.stringValue ?? "").write(toFile: path, atomically: true, encoding: .utf8)
                return .success(["path": .string(path)], summary: "wrote")
            } catch { return .failure(.failed, ToolFailure(code: "io", message: "\(error)")) }
        }
        let doc = try workflow("""
            - id: write
              tool: test.write
              with: {path: "${{ params.dir }}/out/report.md", content: "# Weekly report\\nAll good.\\n"}
            - id: empty
              tool: test.write
              with: {path: "${{ params.dir }}/out/empty.txt", content: ""}
            - id: check
              needs: [write, empty]
              verify:
                - fileExists: ${{ params.dir }}/out/report.md
                - fileNonEmpty: ${{ steps.write.output.path }}
                - fileContains: ${{ params.dir }}/out/report.md
                  text: Weekly report
                - dirNonEmpty: ${{ params.dir }}/out
                - equals: ["${{ basename(steps.write.output.path) }}", report.md]
                - truthy: ${{ endsWith(steps.write.output.path, ".md") }}
                - stepSucceeded: write
            - id: out
              needs: [check]
              output: {ok: true}
              artifacts: ["${{ params.dir }}/out/report.md"]

        """, spec: "  parameters:\n    - {name: dir, type: path, required: true}\n  permissions:\n    filesystem:\n      read: [\"${{ params.dir }}\"]\n")
        let outcome = await h.engine().run(doc, options: h.options(["dir": .string(root)]))
        #expect(outcome.status == .succeeded)
        #expect(outcome.verifications.count == 7 && outcome.verifications.allSatisfy(\.passed))
        #expect(outcome.verifications.map(\.kind) == ["file_exists", "file_nonempty", "file_contains", "dir_nonempty", "custom", "custom", "tool_succeeded"])
        #expect(outcome.artifacts.count == 1 && outcome.artifacts[0].bytes == 26 && outcome.artifacts[0].path.hasSuffix("/out/report.md"))
        #expect(await h.sink.events(of: .verification).count == 7)

        var failing = doc
        failing.spec.steps[2].kind = .verify(VerifyStep(assertions: [
            .fileNonEmpty(path: "${{ params.dir }}/out/empty.txt"), .fileExists(path: "${{ params.dir }}/out/missing.md"),
            .fileContains(path: "${{ params.dir }}/out/report.md", text: "Monthly"), .fileExists(path: "/etc/hosts"),
            .fileExists(path: "~/.ssh/id_ed25519"), .stepSucceeded("nope"),
        ]))
        let h2 = try Harness(); defer { h2.tmp.remove() }
        await h2.tools.register("test.write") { call, ctx in .success(call.arguments, summary: "pretend") }
        let bad = await h.engine().run(failing, options: h.options(["dir": .string(root)]))
        #expect(bad.status == .failed, "SUCCEEDED requires every executed verify to pass")
        #expect(bad.verifications.map(\.passed) == [false, false, false, false, false, false])
        #expect(bad.verifications[0].evidence == "0 bytes")
        #expect(bad.verifications[3].evidence.contains("outside the workflow's declared filesystem permissions"))
        #expect(bad.verifications[4].evidence.contains("outside") || bad.verifications[4].evidence.contains("protected"))
        #expect(bad.step("check")?.errorCode == "verification_failed" && bad.step("out") == nil)
    }
}

@Suite("Engine subworkflows and steps (mocked tools)") struct EngineCompositionTests {
    @Test func subworkflowReceivesInputsAndReturnsOutputs() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let child = try WorkflowCodec.parse("""
        apiVersion: orix.ai/v1
        kind: Automation
        metadata: {id: child, name: Child}
        spec:
          parameters:
            - {name: text, type: string, required: true}
            - {name: times, type: integer, default: 2}
          variables:
            prefix: "${{ params.text }}:"
          steps:
            - id: echo
              tool: test.echo
              with: {text: "${{ vars.prefix }}${{ params.times }}"}
            - id: result
              needs: [echo]
              output: {shout: "${{ upper(steps.echo.output.text) }}"}
        """)
        let parent = try workflow("""
            - id: echo
              tool: test.echo
              with: {text: parent}
            - id: call
              needs: [echo]
              subworkflow: child
              inputs: {text: "${{ steps.echo.output.text }}"}
            - id: out
              needs: [call]
              output: {fromChild: "${{ steps.call.output.shout }}", mine: "${{ steps.echo.output.text }}"}

        """)
        let outcome = await h.engine(loader: DictionarySubworkflowLoader([child])).run(parent, options: h.options())
        #expect(outcome.status == .succeeded && outcome.outputs == ["fromChild": "PARENT:2", "mine": "parent"])
        #expect(outcome.results(for: "echo").map(\.key) == ["echo", "call>/echo"], "same step ids live in separate namespaces")

        let h2 = try Harness(); defer { h2.tmp.remove() }
        let missing = await h2.engine(loader: DictionarySubworkflowLoader([])).run(parent, options: h2.options())
        #expect(missing.status == .failed)
        await h2.registerBasics()
        let h3 = try Harness(); defer { h3.tmp.remove() }
        await h3.registerBasics()
        let noLoader = await h3.engine().run(parent, options: h3.options())
        #expect(noLoader.step("call")?.error?.contains("no subworkflow loader") == true)
    }

    @Test func recursionIsStoppedByTheDepthLimit() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        let recursive = try WorkflowCodec.parse("""
        apiVersion: orix.ai/v1
        kind: Automation
        metadata: {id: narcissus, name: Narcissus}
        spec:
          steps:
            - id: again
              subworkflow: narcissus
        """)
        let outcome = await h.engine(loader: DictionarySubworkflowLoader([recursive]), configuration: .init(maxSubworkflowDepth: 4))
            .run(recursive, options: h.options())
        #expect(outcome.status == .failed)
        #expect(outcome.results(for: "again").count == 5, "four nested calls, the fifth is refused")
        #expect(outcome.errors.joined().contains("nested deeper than 4 levels"))
    }

    @Test func notifySetTransformAndSecretPlaceholders() async throws {
        let h = try Harness(); defer { h.tmp.remove() }
        await h.registerBasics()
        let doc = try workflow("""
            - id: compute
              transform: ${{ sum(map(params.items, x => x.size)) }}
              into: total
            - id: login
              needs: [compute]
              tool: test.echo
              with: {password: "${{ secret(\\"smtp\\") }}", total: "${{ vars.total }}"}
            - id: tell
              needs: [login]
              notify: Total is ${{ vars.total }}
              title: Sizes

        """, spec: "  parameters:\n    - name: items\n      type: array\n      default: [{size: 2}, {size: 40}]\n")
        let outcome = await h.engine().run(doc, options: h.options())
        #expect(outcome.status == .succeeded)
        #expect(outcome.step("compute")?.output == 42)
        #expect(outcome.step("login")?.output == ["password": ["$secret": "smtp"], "total": 42], "a secret is a reference placeholder, never a value")
        #expect(await h.calls("notifications.post").first?.arguments == ["title": "Sizes", "body": "Total is 42"])
        let call = try #require(await h.calls("test.echo").first)
        #expect(call.idempotencyKey == "run-1/login" && !call.dryRun)
    }
}
