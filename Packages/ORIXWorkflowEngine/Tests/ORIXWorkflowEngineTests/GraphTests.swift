// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/GraphTests.swift
// Description      : Unit and property tests of the graph projection,
//                    auto-layout, visual edit operations and document diff.
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
@testable import ORIXWorkflowEngine

private func tool(_ id: String, needs: [String] = [], _ tool: String = "filesystem.list", with args: [String: JSONValue] = [:]) -> WorkflowStep {
    WorkflowStep(id: id, needs: needs, kind: .tool(ToolStep(tool: tool, arguments: args)))
}

private func document(_ steps: [WorkflowStep], triggers: [WorkflowTrigger] = [], onError: [WorkflowStep] = []) -> WorkflowDocument {
    WorkflowDocument(metadata: WorkflowMetadata(id: "g", name: "Graph"), spec: WorkflowSpec(triggers: triggers, steps: steps, onError: onError))
}

/// A document touching every graph feature.
private func sampleDocument() -> WorkflowDocument {
    var list = tool("list")
    list.onError = "cleanup"
    list.name = "List files"
    let cond = WorkflowStep(id: "check", needs: ["list"], kind: .condition(ConditionStep(condition: "${{ len(steps.list.output.entries) > 0 }}", then: ["each"], otherwise: ["nothing"])))
    let each = WorkflowStep(id: "each", kind: .foreach(ForeachStep(items: "${{ steps.list.output.entries }}", steps: [
        tool("read", needs: [], "filesystem.read"), WorkflowStep(id: "shape", needs: ["read"], kind: .transform(TransformStep(expression: "upper(steps.read.output.text)"))),
    ], collect: "shape")))
    let nothing = WorkflowStep(id: "nothing", kind: .notify(NotifyStep(message: "Nothing to do")))
    let sw = WorkflowStep(id: "route", needs: ["each"], kind: .switch(SwitchStep(on: "params.mode", cases: [SwitchCase(value: "fast", steps: ["par"])], defaultSteps: ["loop"])))
    let par = WorkflowStep(id: "par", kind: .parallel(ParallelStep(branches: [
        ParallelBranch(name: "left", steps: [tool("l1"), tool("l2", needs: ["l1"])]), ParallelBranch(name: "right", steps: [tool("r1")]),
    ])))
    let loop = WorkflowStep(id: "loop", kind: .loop(LoopStep(condition: "vars.n < 3", maxIterations: 5, steps: [WorkflowStep(id: "inc", kind: .set(SetStep(values: ["n": "${{ vars.n + 1 }}"])))])))
    let cleanup = WorkflowStep(id: "cleanup", kind: .fail(FailStep(message: "listing failed")))
    let agent = WorkflowStep(id: "think", needs: ["route"], kind: .agent(AgentStep(agent: .profile("analyst"), objective: "x")))
    let out = WorkflowStep(id: "out", needs: ["think"], kind: .output(OutputStep(values: ["n": 1])))
    return document([list, cond, each, nothing, sw, par, loop, cleanup, agent, out],
                    triggers: [.manual, .schedule(cron: "0 9 * * MON", timezone: "America/Toronto")],
                    onError: [WorkflowStep(id: "alert", kind: .notify(NotifyStep(message: "failed")))])
}

@Suite("Graph projection (unit)") struct GraphProjectionTests {
    @Test func nodesCategoriesPortsAndMembership() {
        let g = WorkflowGraph(document: sampleDocument())
        #expect(g.nodes.map(\.id) == ["trigger:0", "trigger:1", "list", "check", "each", "nothing", "route", "par", "loop", "cleanup", "think", "out",
                                      "read", "shape", "l1", "l2", "r1", "inc", "alert"])
        func cat(_ id: String) -> WorkflowGraph.Category? { g.node(id)?.category }
        #expect(cat("trigger:0") == .trigger && cat("list") == .tool && cat("check") == .logic && cat("each") == .logic)
        #expect(cat("par") == .parallelism && cat("inc") == .data && cat("cleanup") == .error && cat("think") == .agent)
        #expect(cat("out") == .output && cat("nothing") == .output && cat("alert") == .error && cat("shape") == .logic)
        #expect(g.node("list")?.title == "List files" && g.node("list")?.subtitle == "filesystem.list" && g.node("check")?.title == "check")
        #expect(g.node("trigger:1")?.subtitle == "0 9 * * MON (America/Toronto)" && g.node("think")?.subtitle == "analyst")
        #expect(g.node("list")?.outputs.map(\.id) == ["out", "error"] && g.node("list")?.inputs.map(\.id) == ["in"])
        #expect(g.node("check")?.outputs.map(\.id) == ["out", "then", "else"])
        #expect(g.node("route")?.outputs.map(\.id) == ["out", "case:0", "default"] && g.node("route")?.outputs[1].label == "fast")
        #expect(g.node("each")?.outputs.map(\.id) == ["out", "body"] && g.node("trigger:0")?.inputs.isEmpty == true)
        #expect(g.node("read")?.parentID == "each" && g.node("read")?.branch == nil)
        #expect(g.node("l2")?.parentID == "par" && g.node("l2")?.branch == "left" && g.node("r1")?.branch == "right")
        #expect(g.node("par")?.isContainer == true && g.node("list")?.isContainer == false && g.node("alert")?.parentID == nil)
        #expect(g.children(of: "par").map(\.id) == ["l1", "l2", "r1"])
    }

    @Test func everyEdgeKind() {
        let g = WorkflowGraph(document: sampleDocument())
        func has(_ from: String, _ port: String, _ to: String, _ kind: WorkflowGraph.EdgeKind, _ label: String = "") -> Bool {
            g.edges.contains { $0.from == from && $0.fromPort == port && $0.to == to && $0.toPort == "in" && $0.kind == kind && $0.label == label }
        }
        #expect(has("list", "out", "check", .dependency) && has("read", "out", "shape", .dependency) && has("l1", "out", "l2", .dependency))
        #expect(has("check", "then", "each", .branch, "then") && has("check", "else", "nothing", .branch, "else"))
        #expect(has("route", "case:0", "par", .branch, "fast") && has("route", "default", "loop", .branch, "default"))
        #expect(has("list", "error", "cleanup", .error, "on error"))
        // Triggers reach only root steps that start on their own: not gated, not handlers, no needs.
        let triggered = g.edges.filter { $0.kind == .trigger && $0.from == "trigger:0" }.map(\.to)
        #expect(triggered == ["list"])
        #expect(g.edges.filter { $0.kind == .trigger }.count == 2)
        #expect(Set(g.edges.map(\.id)).count == g.edges.count)
    }

    @Test func danglingReferencesProduceNoEdge() {
        let g = WorkflowGraph(document: document([tool("a", needs: ["ghost"])]))
        #expect(g.edges.isEmpty && g.nodes.count == 1)
    }
}

@Suite("Graph auto-layout (unit)") struct GraphLayoutTests {
    private func overlaps(_ a: WorkflowGraph.Node, _ b: WorkflowGraph.Node) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    @Test func layoutIsDeterministicLayeredAndFreeOfOverlaps() {
        let doc = sampleDocument()
        #expect(WorkflowGraph.autoLayout(doc) == WorkflowGraph.autoLayout(doc))
        let g = WorkflowGraph(document: doc)
        #expect(g == WorkflowGraph(document: doc))
        let groups = Dictionary(grouping: g.nodes, by: { ($0.parentID ?? "") })
        for (_, nodes) in groups {
            for i in nodes.indices { for j in nodes.indices where i < j {
                #expect(!overlaps(nodes[i], nodes[j]), "\(nodes[i].id) overlaps \(nodes[j].id)")
            } }
        }
        // Layers follow dependency, branch and error edges.
        for e in g.edges where e.kind != .trigger { #expect(g.node(e.from)!.x < g.node(e.to)!.x, "\(e.id) does not go left to right") }
        #expect(g.node("trigger:0")!.x < 0 && g.node("list")!.x == 0 && g.node("list")!.y == 0)
        // Containers enclose their children (child positions are relative to the container).
        for n in g.nodes { if let p = n.parentID, let c = g.node(p) {
            #expect(n.x >= 0 && n.y >= 0 && n.x + n.width <= c.width && n.y + n.height <= c.height, "\(n.id) leaves \(p)")
        } }
        #expect(g.node("alert")!.y > g.node("out")!.y)
    }

    @Test func storedLayoutOverridesAutoPositionsAndResizesContainers() throws {
        var doc = sampleDocument()
        let auto = WorkflowGraph(document: doc)
        doc = try WorkflowEdit.moveNode("list", x: 500, y: 600, in: doc)
        doc = try WorkflowEdit.moveNode("read", x: 900, y: 30, in: doc)
        doc = try WorkflowEdit.moveNode("trigger:1", x: -10, y: -20, in: doc)
        let g = WorkflowGraph(document: doc)
        #expect(g.node("list")!.x == 500 && g.node("list")!.y == 600)
        #expect(g.node("trigger:1")!.x == -10 && g.node("trigger:1")!.y == -20)
        #expect(g.node("check")!.x == auto.node("check")!.x)
        #expect(g.node("each")!.width >= 900 + WorkflowGraph.leafSize.width && g.node("each")!.width > auto.node("each")!.width)
        let applied = doc.applyingAutoLayout()
        #expect(applied.spec.layout.count == doc.allSteps.count && applied.spec.layout["list"] == WorkflowNodePosition(x: 0, y: 0))
        #expect(WorkflowValidator.validate(applied, tools: [], agents: [], workflows: []).allSatisfy { $0.code != "stale-layout" })
    }

    @Test func cyclicDocumentsStillLayOut() {
        let g = WorkflowGraph(document: document([tool("a", needs: ["b"]), tool("b", needs: ["a"])]))
        #expect(g.nodes.count == 2)
    }
}

@Suite("Graph edits (unit)") struct GraphEditTests {
    private func threw(_ expected: WorkflowEditError, _ body: () throws -> WorkflowDocument) -> Bool {
        do { _ = try body(); return false } catch let e as WorkflowEditError { return e == expected } catch { return false }
    }
    private func throwsEdit(_ body: () throws -> WorkflowDocument) -> WorkflowEditError? {
        do { _ = try body(); return nil } catch let e as WorkflowEditError { return e } catch { return nil }
    }

    @Test func addStepToRootContainerAndBranch() throws {
        var doc = sampleDocument()
        doc = try WorkflowEdit.addStep(tool("new"), to: doc)
        #expect(doc.spec.steps.last?.id == "new")
        doc = try WorkflowEdit.addStep(tool("first"), to: doc, at: 0)
        #expect(doc.spec.steps.first?.id == "first")
        doc = try WorkflowEdit.addStep(tool("inEach"), to: doc, inContainer: "each", at: 1)
        #expect(doc.location(of: "inEach")?.containerID == "each" && doc.location(of: "inEach")?.index == 1)
        doc = try WorkflowEdit.addStep(tool("inLoop"), to: doc, inContainer: "loop")
        doc = try WorkflowEdit.addStep(tool("inRight"), to: doc, inContainer: "par", branch: "right")
        doc = try WorkflowEdit.addStep(tool("inNew"), to: doc, inContainer: "par", branch: "extra")
        #expect(doc.location(of: "inRight")?.branch == "right" && doc.location(of: "inNew")?.branch == "extra" && doc.location(of: "inLoop")?.containerID == "loop")
        #expect(threw(.duplicateID("list")) { try WorkflowEdit.addStep(tool("list"), to: doc) })
        #expect(threw(.duplicateID("l1")) { try WorkflowEdit.addStep(WorkflowStep(id: "c", kind: .loop(LoopStep(condition: "true", maxIterations: 1, steps: [tool("l1")]))), to: doc) })
        #expect(threw(.invalidID("9 bad")) { try WorkflowEdit.addStep(tool("9 bad"), to: doc) })
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.addStep(tool("x"), to: doc, inContainer: "ghost") })
        if case .invalid? = throwsEdit({ try WorkflowEdit.addStep(tool("x"), to: doc, inContainer: "list") }) {} else { Issue.record("a tool step cannot contain steps") }
        if case .invalid? = throwsEdit({ try WorkflowEdit.addStep(tool("x"), to: doc, inContainer: "par") }) {} else { Issue.record("parallel needs a branch") }
        if case .invalid? = throwsEdit({ try WorkflowEdit.addStep(tool("x", needs: ["ghost"]), to: doc) }) {} else { Issue.record("unknown need must be refused") }
    }

    @Test func removeStepDropsReferencesNestedLayoutAndIsRefusedWhenUnknown() throws {
        var doc = sampleDocument()
        doc.spec.layout = ["each": .init(x: 1, y: 2), "read": .init(x: 3, y: 4), "list": .init(x: 5, y: 6)]
        doc.spec.steps.append(WorkflowStep(id: "v", needs: ["each", "list"], kind: .verify(VerifyStep(assertions: [.stepSucceeded("each"), .stepSucceeded("list")]))))
        let out = try WorkflowEdit.removeStep("each", from: doc)
        #expect(out.step(id: "each") == nil && out.step(id: "read") == nil && out.step(id: "shape") == nil)
        #expect(out.step(id: "route")?.needs == [] && out.step(id: "v")?.needs == ["list"])
        #expect(out.step(id: "check")?.kind == .condition(ConditionStep(condition: "${{ len(steps.list.output.entries) > 0 }}", then: [], otherwise: ["nothing"])))
        #expect(out.step(id: "v")?.kind == .verify(VerifyStep(assertions: [.stepSucceeded("list")])))
        #expect(out.spec.layout == ["list": .init(x: 5, y: 6)])
        let noHandler = try WorkflowEdit.removeStep("cleanup", from: doc)
        #expect(noHandler.step(id: "list")?.onError == nil)
        let noCollect = try WorkflowEdit.removeStep("shape", from: doc)
        if case .foreach(let f)? = noCollect.step(id: "each")?.kind { #expect(f.collect == nil && f.steps.map(\.id) == ["read"]) } else { Issue.record("each lost") }
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.removeStep("ghost", from: doc) })
    }

    @Test func renameRewritesStructuralReferencesAndExpressions() throws {
        var doc = sampleDocument()
        doc.spec.layout["list"] = .init(x: 7, y: 8)
        doc.spec.steps.append(WorkflowStep(id: "v", needs: ["list"], when: "steps.list.status == 'succeeded' && steps[\"list\"] != null",
                                           kind: .verify(VerifyStep(assertions: [.stepSucceeded("list"), .truthy("steps.list.output"), .equals("${{ steps.list.output.n }} of list", "list")]))))
        let out = try WorkflowEdit.renameStep("list", to: "listing-1", in: doc)
        #expect(out.step(id: "list") == nil && out.step(id: "listing-1")?.name == "List files")
        #expect(out.step(id: "check")?.needs == ["listing-1"])
        #expect(out.step(id: "check")?.kind == .condition(ConditionStep(condition: "${{ len(steps.listing-1.output.entries) > 0 }}", then: ["each"], otherwise: ["nothing"])))
        if case .foreach(let f)? = out.step(id: "each")?.kind { #expect(f.items == "${{ steps.listing-1.output.entries }}") } else { Issue.record("each lost") }
        let v = out.step(id: "v")
        // Dotted and bracket references are rewritten; plain text is left alone.
        #expect(v?.when == "steps.listing-1.status == 'succeeded' && steps[\"listing-1\"] != null" && v?.needs == ["listing-1"])
        #expect(v?.kind == .verify(VerifyStep(assertions: [.stepSucceeded("listing-1"), .truthy("steps.listing-1.output"), .equals("${{ steps.listing-1.output.n }} of list", "list")])))
        #expect(out.spec.layout == ["listing-1": .init(x: 7, y: 8)])
        let handler = try WorkflowEdit.renameStep("cleanup", to: "recover", in: doc)
        #expect(handler.step(id: "list")?.onError == "recover")
        let collected = try WorkflowEdit.renameStep("shape", to: "shaped", in: doc)
        if case .foreach(let f)? = collected.step(id: "each")?.kind { #expect(f.collect == "shaped") } else { Issue.record("each lost") }
        #expect(try WorkflowEdit.renameStep("list", to: "list", in: doc) == doc)
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.renameStep("ghost", to: "x", in: doc) })
        #expect(threw(.duplicateID("read")) { try WorkflowEdit.renameStep("list", to: "read", in: doc) })
        #expect(threw(.invalidID("no good")) { try WorkflowEdit.renameStep("list", to: "no good", in: doc) })
        #expect(try WorkflowCodec.parse(WorkflowCodec.emit(out)) == out)
    }

    @Test func connectAndDisconnect() throws {
        let doc = document([tool("a"), tool("b", needs: ["a"]), tool("c"), WorkflowStep(id: "p", kind: .parallel(ParallelStep(branches: [ParallelBranch(name: "x", steps: [tool("in1"), tool("in2")])])))])
        let out = try WorkflowEdit.connect(from: "b", to: "c", in: doc)
        #expect(out.step(id: "c")?.needs == ["b"])
        #expect(try WorkflowEdit.connect(from: "b", to: "c", in: out) == out)
        #expect(try WorkflowEdit.connect(from: "in1", to: "in2", in: doc).step(id: "in2")?.needs == ["in1"])
        if case .wouldCreateCycle? = throwsEdit({ try WorkflowEdit.connect(from: "c", to: "a", in: out) }) {} else { Issue.record("cycle a→b→c→a must be refused") }
        if case .wouldCreateCycle? = throwsEdit({ try WorkflowEdit.connect(from: "a", to: "a", in: doc) }) {} else { Issue.record("self need must be refused") }
        #expect(threw(.differentScopes("a", "in1")) { try WorkflowEdit.connect(from: "a", to: "in1", in: doc) })
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.connect(from: "ghost", to: "a", in: doc) })
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.connect(from: "a", to: "ghost", in: doc) })
        #expect(try WorkflowEdit.disconnect(from: "b", to: "c", in: out) == doc)
        #expect(try WorkflowEdit.disconnect(from: "c", to: "a", in: doc) == doc)
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.disconnect(from: "ghost", to: "a", in: doc) })
    }

    @Test func moveNode() throws {
        let doc = sampleDocument()
        #expect(try WorkflowEdit.moveNode("read", x: 10.5, y: -3, in: doc).spec.layout == ["read": .init(x: 10.5, y: -3)])
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.moveNode("ghost", x: 0, y: 0, in: doc) })
        #expect(threw(.unknownStep("trigger:7")) { try WorkflowEdit.moveNode("trigger:7", x: 0, y: 0, in: doc) })
        if case .invalid? = throwsEdit({ try WorkflowEdit.moveNode("read", x: .nan, y: 0, in: doc) }) {} else { Issue.record("NaN position must be refused") }
    }

    @Test func setFieldAndUpdateStep() throws {
        var doc = sampleDocument()
        doc = try WorkflowEdit.setField("list", .name("Listing"), in: doc)
        doc = try WorkflowEdit.setField("list", .when("params.enabled"), in: doc)
        doc = try WorkflowEdit.setField("list", .timeoutSeconds(12), in: doc)
        doc = try WorkflowEdit.setField("list", .continueOnError(true), in: doc)
        doc = try WorkflowEdit.setField("list", .retry(WorkflowRetryPolicy(maxAttempts: 3)), in: doc)
        doc = try WorkflowEdit.setField("list", .toolArgument("path", "~/x"), in: doc)
        doc = try WorkflowEdit.setField("list", .toolArgument("recursive", true), in: doc)
        doc = try WorkflowEdit.setField("list", .toolArgument("recursive", nil), in: doc)
        doc = try WorkflowEdit.setField("list", .onError(nil), in: doc)
        let s = doc.step(id: "list")!
        #expect(s.name == "Listing" && s.when == "params.enabled" && s.timeoutSeconds == 12 && s.continueOnError && s.retry?.maxAttempts == 3 && s.onError == nil)
        #expect(s.kind == .tool(ToolStep(tool: "filesystem.list", arguments: ["path": "~/x"])))
        doc = try WorkflowEdit.setField("list", .onError("cleanup"), in: doc)
        #expect(doc.step(id: "list")?.onError == "cleanup")
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.setField("list", .onError("ghost"), in: doc) })
        #expect(threw(.differentScopes("list", "read")) { try WorkflowEdit.setField("list", .onError("read"), in: doc) })
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.setField("ghost", .name("x"), in: doc) })
        if case .invalid? = throwsEdit({ try WorkflowEdit.setField("check", .toolArgument("a", 1), in: doc) }) {} else { Issue.record("toolArgument on a condition must be refused") }
        if case .invalid? = throwsEdit({ try WorkflowEdit.setField("list", .onError("list"), in: doc) }) {} else { Issue.record("self handler must be refused") }
        // Replacing a container's kind drops its nested steps and their layout.
        doc.spec.layout["read"] = .init(x: 1, y: 1)
        let flat = try WorkflowEdit.setField("each", .kind(.delay(DelayStep(seconds: 1))), in: doc)
        #expect(flat.step(id: "read") == nil && flat.spec.layout["read"] == nil && flat.step(id: "each")?.kind.name == "delay")
        let updated = try WorkflowEdit.updateStep("out", in: doc) { $0.needs = ["list"]; $0.name = "Result" }
        #expect(updated.step(id: "out")?.needs == ["list"] && updated.step(id: "out")?.name == "Result")
        if case .invalid? = throwsEdit({ try WorkflowEdit.updateStep("out", in: doc) { $0.id = "renamed" } }) {} else { Issue.record("updateStep must not rename") }
        if case .wouldCreateCycle? = throwsEdit({ try WorkflowEdit.updateStep("list", in: doc) { $0.needs = ["check"] } }) {} else { Issue.record("cycle must be refused") }
    }

    @Test func duplicateStepGivesFreshIdsAndRemapsNestedReferences() throws {
        var doc = sampleDocument()
        doc.spec.layout = ["each": .init(x: 100, y: 200), "read": .init(x: 5, y: 6)]
        let out = try WorkflowEdit.duplicateStep("each", in: doc)
        #expect(out.spec.steps.map(\.id) == ["list", "check", "each", "each-copy", "nothing", "route", "par", "loop", "cleanup", "think", "out"])
        guard case .foreach(let f)? = out.step(id: "each-copy")?.kind else { Issue.record("copy is not a foreach"); return }
        #expect(f.steps.map(\.id) == ["read-copy", "shape-copy"] && f.collect == "shape-copy" && f.steps[1].needs == ["read-copy"])
        #expect(f.steps[1].kind == .transform(TransformStep(expression: "upper(steps.read-copy.output.text)")))
        #expect(f.items == "${{ steps.list.output.entries }}")
        #expect(out.spec.layout["each-copy"] == .init(x: 140, y: 240) && out.spec.layout["read-copy"] == .init(x: 5, y: 6))
        #expect(out.step(id: "each") == doc.step(id: "each"))
        let twice = try WorkflowEdit.duplicateStep("each", in: out)
        #expect(twice.step(id: "each-copy2") != nil && twice.step(id: "read-copy2") != nil)
        let named = try WorkflowEdit.duplicateStep("check", in: doc, newID: "check2")
        #expect(named.step(id: "check2")?.needs == ["list"] && named.location(of: "check2")?.index == 2)
        #expect(threw(.duplicateID("list")) { try WorkflowEdit.duplicateStep("check", in: doc, newID: "list") })
        #expect(threw(.invalidID("-x")) { try WorkflowEdit.duplicateStep("check", in: doc, newID: "-x") })
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.duplicateStep("ghost", in: doc) })
    }

    @Test func groupIntoParallelBuildsBranchesFromConnectedComponentsAndRewires() throws {
        var doc = document([tool("a"), tool("b", needs: ["a"]), tool("c", needs: ["b"]), tool("d", needs: ["a"]), tool("e", needs: ["c", "d"]), tool("f")])
        doc.spec.layout = ["b": .init(x: 10, y: 20), "c": .init(x: 30, y: 40)]
        let out = try WorkflowEdit.groupIntoParallel(["b", "c", "d"], containerID: "fan", in: doc)
        #expect(out.spec.steps.map(\.id) == ["a", "fan", "e", "f"])
        let fan = out.step(id: "fan")!
        #expect(fan.needs == ["a"])
        guard case .parallel(let p) = fan.kind else { Issue.record("not parallel"); return }
        #expect(p.branches.map(\.name) == ["b", "d"] && p.branches[0].steps.map(\.id) == ["b", "c"] && p.branches[1].steps.map(\.id) == ["d"])
        #expect(p.branches[0].steps[0].needs == [] && p.branches[0].steps[1].needs == ["b"] && p.branches[1].steps[0].needs == [])
        #expect(out.step(id: "e")?.needs == ["fan"])
        #expect(out.spec.layout == ["fan": .init(x: 10, y: 20)])
        #expect(WorkflowValidator.structuralErrors(out).isEmpty)
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.groupIntoParallel(["b", "ghost"], containerID: "g", in: doc) })
        #expect(threw(.duplicateID("a")) { try WorkflowEdit.groupIntoParallel(["b"], containerID: "a", in: doc) })
        #expect(threw(.differentScopes("a", "b")) { try WorkflowEdit.groupIntoParallel(["a", "b"], containerID: "g", in: out) })
        if case .invalid? = throwsEdit({ try WorkflowEdit.groupIntoParallel([], containerID: "g", in: doc) }) {} else { Issue.record("empty selection must be refused") }
        if case .invalid? = throwsEdit({ try WorkflowEdit.groupIntoParallel(["b", "b"], containerID: "g", in: doc) }) {} else { Issue.record("repeated selection must be refused") }
        // a → c (outside) → … : grouping b and its indirect dependent e around the outside step c would loop through the container.
        if case .wouldCreateCycle? = throwsEdit({ try WorkflowEdit.groupIntoParallel(["b", "e"], containerID: "g", in: doc) }) {} else { Issue.record("cycle through the container must be refused") }
        // Branch and error routes cannot cross the container boundary.
        if case .invalid? = throwsEdit({ try WorkflowEdit.groupIntoParallel(["each"], containerID: "g", in: sampleDocument()) }) {} else { Issue.record("gated member must be refused") }
        if case .invalid? = throwsEdit({ try WorkflowEdit.groupIntoParallel(["list"], containerID: "g", in: sampleDocument()) }) {} else { Issue.record("member with outside handler must be refused") }
        let together = try WorkflowEdit.groupIntoParallel(["check", "each", "nothing"], containerID: "g", in: sampleDocument())
        if case .parallel(let q)? = together.step(id: "g")?.kind { #expect(q.branches.count == 1 && q.branches[0].steps.count == 3) } else { Issue.record("not parallel") }
        #expect(together.step(id: "g")?.needs == ["list"] && together.step(id: "route")?.needs == ["g"])
    }

    @Test func wrapInForeachKeepsInternalNeeds() throws {
        let doc = document([tool("a"), tool("b", needs: ["a"]), tool("c", needs: ["b"]), tool("d", needs: ["c", "a"])])
        let out = try WorkflowEdit.wrapInForeach(["b", "c"], containerID: "each", items: "${{ steps.a.output.entries }}", itemName: "entry", in: doc)
        #expect(out.spec.steps.map(\.id) == ["a", "each", "d"] && out.step(id: "d")?.needs == ["each", "a"])
        guard case .foreach(let f)? = out.step(id: "each")?.kind else { Issue.record("not foreach"); return }
        #expect(f.items == "${{ steps.a.output.entries }}" && f.itemName == "entry" && f.concurrency == 1 && f.collect == nil)
        #expect(f.steps.map(\.id) == ["b", "c"] && f.steps[0].needs == [] && f.steps[1].needs == ["b"])
        #expect(out.step(id: "each")?.needs == ["a"])
        if case .invalid? = throwsEdit({ try WorkflowEdit.wrapInForeach(["b"], containerID: "x", items: "[]", itemName: "steps", in: doc) }) {} else { Issue.record("reserved loop variable must be refused") }
        #expect(threw(.invalidID("bad id")) { try WorkflowEdit.wrapInForeach(["b"], containerID: "bad id", items: "[]", in: doc) })
    }

    @Test func reorderWithinItsList() throws {
        let doc = sampleDocument()
        #expect(try WorkflowEdit.reorder("out", to: 0, in: doc).spec.steps.first?.id == "out")
        #expect(try WorkflowEdit.reorder("list", to: 99, in: doc).spec.steps.last?.id == "list")
        #expect(try WorkflowEdit.reorder("l2", to: 0, in: doc).location(of: "l2")?.index == 0)
        #expect(try WorkflowEdit.reorder("list", to: 0, in: doc) == doc)
        #expect(threw(.unknownStep("ghost")) { try WorkflowEdit.reorder("ghost", to: 0, in: doc) })
    }

    @Test func editsOfAStructurallyInvalidDocumentAreRefused() {
        let broken = document([tool("a", needs: ["ghost"])])
        if case .invalid? = throwsEdit({ try WorkflowEdit.addStep(tool("b"), to: broken) }) {} else { Issue.record("an invalid document cannot be edited into a valid one silently") }
    }
}

// MARK: - Property test

/// Generates structurally valid documents: unique valid ids, `needs` only to earlier steps of the same list.
private struct ValidDocumentGenerator {
    var rng: SeededRNG
    var counter = 0
    init(seed: UInt64) { rng = SeededRNG(seed: seed) }

    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &rng) }
    mutating func bool(_ p: Double = 0.5) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }
    mutating func id() -> String { counter += 1; return pick(["s", "step-", "fetch_", "n"]) + "\(counter)" }

    mutating func leaf(_ id: String, earlier: [String]) -> WorkflowStepKind {
        let ref = earlier.isEmpty ? "params.x" : "steps.\(pick(earlier)).output"
        switch int(0...6) {
        case 0: return .tool(ToolStep(tool: pick(["filesystem.list", "shell.run"]), arguments: ["path": .string("${{ \(ref) }}/x"), "n": .int(int(0...9))]))
        case 1: return .set(SetStep(values: ["v": .string("${{ \(ref) }}")]))
        case 2: return .transform(TransformStep(expression: "len(\(ref)) > 0"))
        case 3: return .delay(DelayStep(seconds: .int(int(0...3))))
        case 4: return .verify(VerifyStep(assertions: earlier.isEmpty ? [.truthy(true)] : [.stepSucceeded(pick(earlier)), .truthy(.string(ref))]))
        case 5: return .notify(NotifyStep(message: "value ${{ \(ref) }}"))
        default: return .agent(AgentStep(agent: .profile("analyst"), objective: "Use ${{ \(ref) }}"))
        }
    }

    mutating func steps(depth: Int, count: Int) -> [WorkflowStep] {
        var out: [WorkflowStep] = []
        for _ in 0..<count {
            let sid = id()
            let earlier = out.map(\.id)
            let needs = earlier.filter { _ in bool(0.3) }
            let kind: WorkflowStepKind
            if depth < 2, bool(0.25) {
                switch int(0...2) {
                case 0: kind = .foreach(ForeachStep(items: "params.items", itemName: "entry", concurrency: int(1...3), steps: steps(depth: depth + 1, count: int(0...3))))
                case 1: kind = .parallel(ParallelStep(branches: (0..<int(1...3)).map { ParallelBranch(name: "b\($0)", steps: steps(depth: depth + 1, count: int(0...2))) }))
                default: kind = .loop(LoopStep(condition: "vars.n < 3", maxIterations: int(1...9), steps: steps(depth: depth + 1, count: int(1...2))))
                }
            } else { kind = leaf(sid, earlier: earlier) }
            out.append(WorkflowStep(id: sid, name: bool(0.3) ? "Step \(sid)" : nil, needs: needs, when: bool(0.2) ? "params.enabled" : nil, kind: kind))
        }
        // A condition gating two later-defined free steps, and an error handler.
        if out.count >= 2, bool(0.5) {
            let a = WorkflowStep(id: id(), kind: .delay(DelayStep(seconds: 1))), b = WorkflowStep(id: id(), kind: .fail(FailStep(message: "no")))
            out.append(WorkflowStep(id: id(), needs: [out[0].id], kind: .condition(ConditionStep(condition: "params.enabled", then: [a.id], otherwise: [b.id]))))
            out += [a, b]
        }
        if !out.isEmpty, bool(0.4) {
            let h = WorkflowStep(id: id(), kind: .notify(NotifyStep(message: "failed")))
            out[int(0...(out.count - 1))].onError = h.id
            out.append(h)
        }
        return out
    }

    mutating func document() -> WorkflowDocument {
        var spec = WorkflowSpec(triggers: bool() ? [.manual] : [.manual, .login],
                                parameters: [WorkflowParameter(name: "x"), WorkflowParameter(name: "items", type: .array), WorkflowParameter(name: "enabled", type: .boolean)],
                                variables: ["n": 0], steps: steps(depth: 0, count: int(2...7)))
        if bool(0.3) { spec.onError = [WorkflowStep(id: id(), kind: .notify(NotifyStep(message: "workflow failed")))] }
        return WorkflowDocument(metadata: WorkflowMetadata(id: "prop", name: "Property"), spec: spec)
    }

    /// One random edit; throws `WorkflowEditError` when the edit is refused.
    mutating func edit(_ doc: WorkflowDocument) throws -> WorkflowDocument {
        let all = doc.allSteps
        guard !all.isEmpty else { return try WorkflowEdit.addStep(WorkflowStep(id: id(), kind: .delay(DelayStep(seconds: 1))), to: doc) }
        let a = pick(all), b = pick(all)
        let peers = all.filter { $0.scopeID == a.scopeID }.map(\.step.id)
        switch int(0...13) {
        case 0: return try WorkflowEdit.addStep(WorkflowStep(id: id(), needs: bool() ? [] : [pick(doc.spec.steps.map(\.id) + ["ghost"])], kind: leaf("x", earlier: [])), to: doc, at: bool() ? int(0...3) : nil)
        case 1:
            let containers = all.filter(\.step.isContainer)
            guard !containers.isEmpty else { return doc }
            return try WorkflowEdit.addStep(WorkflowStep(id: id(), kind: leaf("x", earlier: [])), to: doc, inContainer: pick(containers).step.id, branch: pick(["b0", "b1", "fresh"]))
        case 2: return try WorkflowEdit.removeStep(a.step.id, from: doc)
        case 3: return try WorkflowEdit.renameStep(a.step.id, to: bool(0.9) ? id() : b.step.id, in: doc)
        case 4: return try WorkflowEdit.connect(from: a.step.id, to: bool(0.8) ? pick(peers) : b.step.id, in: doc)
        case 5: return try WorkflowEdit.disconnect(from: a.step.needs.first ?? b.step.id, to: a.step.id, in: doc)
        case 6: return try WorkflowEdit.moveNode(bool(0.9) ? a.step.id : "trigger:\(int(0...2))", x: Double(int(-500...500)), y: Double(int(-500...500)) / 4, in: doc)
        case 7:
            let field: StepField = pick([.name(bool() ? "Renamed" : nil), .when(bool() ? "vars.n == 0" : nil), .timeoutSeconds(bool() ? 2.5 : nil), .continueOnError(bool()),
                                         .onError(bool() ? pick(peers) : nil), .retry(bool() ? WorkflowRetryPolicy(maxAttempts: 2, backoffSeconds: 0.5) : nil),
                                         .toolArgument("path", bool() ? "~/p" : nil), .kind(.delay(DelayStep(seconds: 2)))])
            return try WorkflowEdit.setField(a.step.id, field, in: doc)
        case 8: return try WorkflowEdit.duplicateStep(a.step.id, in: doc)
        case 9: return try WorkflowEdit.groupIntoParallel(Array(Set([a.step.id, pick(peers), pick(peers)])).sorted(), containerID: id(), in: doc)
        case 10: return try WorkflowEdit.wrapInForeach(Array(Set([a.step.id, pick(peers)])).sorted(), containerID: id(), items: "params.items", in: doc)
        case 11: return try WorkflowEdit.reorder(a.step.id, to: int(0...8), in: doc)
        case 12: return try WorkflowEdit.updateStep(a.step.id, in: doc) { $0.needs = Array(peers.prefix(2)) }
        default: return try WorkflowEdit.groupIntoParallel([a.step.id, b.step.id], containerID: id(), in: doc)
        }
    }
}

@Suite("Graph edits (property)") struct GraphEditPropertyTests {
    @Test func randomEditSequencesStayValidAndRoundTripThroughTheCodeView() throws {
        var generator = ValidDocumentGenerator(seed: 20261121)
        var applied = 0, refused = 0
        var kinds: Set<String> = []
        for round in 0..<60 {
            var doc = generator.document()
            #expect(WorkflowValidator.structuralErrors(doc).isEmpty, "generator produced an invalid document in round \(round)")
            for stepIndex in 0..<40 {
                let before = doc
                do { doc = try generator.edit(doc) }
                catch is WorkflowEditError { refused += 1; #expect(doc == before); continue }
                applied += 1
                let errors = WorkflowValidator.structuralErrors(doc)
                if !errors.isEmpty { Issue.record("round \(round) edit \(stepIndex): structurally invalid result: \(errors[0])\n\(WorkflowCodec.emit(doc))"); return }
                for format in WorkflowFormat.allCases {
                    let text = WorkflowCodec.emit(doc, format: format)
                    guard let back = try? WorkflowCodec.parse(text, format: format), back == doc else {
                        Issue.record("round \(round) edit \(stepIndex): \(format) round trip lost information\n\(text)"); return
                    }
                }
                for change in WorkflowDiff.diff(before, doc) { kinds.insert(String(describing: change).prefix { $0 != "(" }.description) }
                #expect(WorkflowDiff.diff(before, doc).isEmpty == (before == doc))
                _ = WorkflowGraph(document: doc)
            }
        }
        #expect(applied > 600, "only \(applied) edits were applied (\(refused) refused)")
        #expect(refused > 50, "the property test should also exercise refused edits (\(refused))")
        #expect(kinds.isSuperset(of: ["stepAdded", "stepRemoved", "stepModified", "stepMoved", "layoutChanged"]), "diff kinds seen: \(kinds.sorted())")
    }
}

// MARK: - Diff

@Suite("Workflow diff (unit)") struct WorkflowDiffTests {
    @Test func equalDocumentsHaveNoChange() {
        #expect(WorkflowDiff.diff(sampleDocument(), sampleDocument()).isEmpty)
    }

    @Test func everyDocumentLevelChangeKind() {
        let old = sampleDocument()
        var new = old
        new.metadata.name = "Renamed"; new.metadata.tags = ["x"]
        new.spec.triggers.removeLast()
        new.spec.parameters = [WorkflowParameter(name: "mode"), WorkflowParameter(name: "added")]
        new.spec.permissions.filesystem.write = ["~/Reports"]
        new.spec.permissions.notifications = true
        new.spec.budget.maxToolCalls = 5
        new.spec.variables = ["n": 1]
        new.spec.onError = []
        new.spec.layout["list"] = .init(x: 1, y: 1)
        var older = old
        older.spec.parameters = [WorkflowParameter(name: "mode", type: .integer), WorkflowParameter(name: "gone")]
        older.spec.permissions.network = ["example.com"]
        let changes = WorkflowDiff.diff(older, new)
        #expect(changes == [
            .metadataChanged(fields: ["name", "tags"]), .triggersChanged,
            .parametersChanged(added: ["added"], removed: ["gone"], modified: ["mode"]),
            .permissionsChanged(added: ["filesystem.write: ~/Reports", "notifications"], removed: ["network: example.com"]),
            .budgetChanged, .variablesChanged, .onErrorChanged, .layoutChanged,
        ])
        #expect(changes.filter(\.isSecurityRelevant) == [.permissionsChanged(added: ["filesystem.write: ~/Reports", "notifications"], removed: ["network: example.com"])])
        #expect(changes[3].summary == "Permissions changed (security-relevant): added filesystem.write: ~/Reports, notifications; removed network: example.com")
        #expect(changes.allSatisfy { !$0.summary.isEmpty })
        #expect(WorkflowDiff.permissionEntries(WorkflowPermissions(processes: ["git"], scripts: ["bash"], apps: .init(control: ["com.apple.Safari"]), browser: ["a.com"],
                                                                 secrets: ["k"], clipboard: .init(read: true, write: true), screen: ["display"]))
                == ["processes: git", "scripts: bash", "apps.control: com.apple.Safari", "browser: a.com", "secrets: k", "clipboard.read", "clipboard.write", "screen: display"])
    }

    @Test func stepChangesAreReportedByFieldWithoutBlamingContainers() throws {
        let old = sampleDocument()
        var new = try WorkflowEdit.setField("read", .toolArgument("path", "~/x"), in: old)
        new = try WorkflowEdit.updateStep("read", in: new) { s in
            s.name = "Read"; s.when = "true"; s.retry = WorkflowRetryPolicy(maxAttempts: 2); s.timeoutSeconds = 3; s.continueOnError = true
            if case .tool(var t) = s.kind { t.tool = "documents.pdfText"; s.kind = .tool(t) }
        }
        #expect(WorkflowDiff.diff(old, new) == [.stepModified(id: "read", fields: ["name", "when", "tool", "with", "retry", "timeoutSeconds", "continueOnError"])])
        let kind = try WorkflowEdit.setField("nothing", .kind(.fail(FailStep(message: "x"))), in: old)
        #expect(WorkflowDiff.diff(old, kind) == [.stepModified(id: "nothing", fields: ["kind"])])
        let each = try WorkflowEdit.updateStep("each", in: old) { s in
            if case .foreach(var f) = s.kind { f.concurrency = 4; f.itemName = "e"; s.kind = .foreach(f) }
        }
        #expect(WorkflowDiff.diff(old, each) == [.stepModified(id: "each", fields: ["as", "concurrency"])])
        let cond = try WorkflowEdit.updateStep("check", in: old) { s in s.kind = .condition(ConditionStep(condition: "false", then: [], otherwise: ["nothing", "each"])) }
        #expect(WorkflowDiff.diff(old, cond) == [.stepModified(id: "check", fields: ["if", "then", "else"])])
    }

    @Test func diffAfterEachEditOperation() throws {
        let old = sampleDocument()
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.addStep(tool("new"), to: old)) == [.stepAdded(id: "new")])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.removeStep("each", from: old))
                == [.stepRemoved(id: "each"), .stepRemoved(id: "read"), .stepRemoved(id: "shape"), .stepModified(id: "check", fields: ["then"]), .stepModified(id: "route", fields: ["needs"])])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.renameStep("think", to: "reason", in: old))
                == [.stepRemoved(id: "think"), .stepAdded(id: "reason"), .stepModified(id: "out", fields: ["needs"])])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.connect(from: "list", to: "out", in: old)) == [.stepModified(id: "out", fields: ["needs"])])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.disconnect(from: "think", to: "out", in: old)) == [.stepModified(id: "out", fields: ["needs"])])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.moveNode("list", x: 1, y: 2, in: old)) == [.layoutChanged])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.setField("list", .name("L"), in: old)) == [.stepModified(id: "list", fields: ["name"])])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.duplicateStep("par", in: old))
                == [.stepAdded(id: "par-copy"), .stepAdded(id: "l1-copy"), .stepAdded(id: "l2-copy"), .stepAdded(id: "r1-copy")])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.reorder("out", to: 0, in: old)) == [.stepMoved(id: "out")])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.groupIntoParallel(["think", "out"], containerID: "tail", in: old))
                == [.stepAdded(id: "tail"), .stepModified(id: "think", fields: ["needs"]), .stepMoved(id: "think"), .stepMoved(id: "out")])
        #expect(WorkflowDiff.diff(old, try WorkflowEdit.wrapInForeach(["out"], containerID: "wrap", items: "[1]", in: old))
                == [.stepAdded(id: "wrap"), .stepModified(id: "out", fields: ["needs"]), .stepMoved(id: "out")])
        let nested = WorkflowDiff.diff(old, try WorkflowEdit.reorder("l2", to: 0, in: old))
        #expect(nested == [.stepMoved(id: "l2")] || nested == [.stepMoved(id: "l1")])
    }
}
