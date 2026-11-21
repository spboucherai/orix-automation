// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureWorkflow/Tests/ORIXFeatureWorkflowTests/UnitTests.swift
// Description      : Unit tests of the studio's pure logic: argument form
//                    conversion, canvas geometry, viewport maths, keyboard
//                    navigation, trigger previews and parameter forms.
// Module           : ORIXFeatureWorkflowTests
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

import CoreGraphics
import Foundation
import ORIXAppUI
import Testing
@testable import ORIXFeatureWorkflow

@Suite("Unit · argument form") struct ArgumentFormTests {
    static let schema = JSONSchema.object([
        "path": .string("Where"), "limit": .integer("How many", minimum: 1, maximum: 50), "ratio": .number("Share"),
        "overwrite": .boolean("Replace"), "mode": .string("How", enum: ["create", "append"]), "tags": .array(of: .string(), "Labels"),
        "counts": .array(of: .integer()), "options": JSONSchema(raw: ["type": "object"]),
    ], required: ["path", "limit"])

    func field(_ name: String) -> SchemaField { ArgumentForm.fields(of: Self.schema).first { $0.name == name }! }

    @Test func fieldsAreTypedAndRequiredOnesComeFirst() {
        let fields = ArgumentForm.fields(of: Self.schema)
        #expect(fields.prefix(2).map(\.name) == ["limit", "path"])
        #expect(field("mode").kind == .enumeration(["create", "append"]))
        #expect(field("tags").kind == .array && field("overwrite").kind == .boolean && field("ratio").kind == .number)
    }

    @Test func textRoundTripsThroughEveryFieldKind() throws {
        let cases: [(String, String, JSONValue)] = [
            ("path", "~/Reports/out.md", .string("~/Reports/out.md")), ("limit", "12", .int(12)), ("ratio", "0.25", .number(0.25)), ("ratio", "3", .int(3)),
            ("overwrite", "true", .bool(true)), ("mode", "append", .string("append")), ("tags", "a\nb", .array(["a", "b"])), ("counts", "[1,2]", .array([1, 2])),
            ("options", "{\"k\":1}", .object(["k": 1])),
        ]
        for (name, text, expected) in cases {
            let parsed = try ArgumentForm.parse(text, field: field(name)).get()
            #expect(parsed == expected, "\(name)")
            // Text shown for the stored value parses back to the same value.
            #expect(try ArgumentForm.parse(ArgumentForm.text(for: parsed), field: field(name)).get() == expected, "\(name) round trip")
        }
    }

    @Test func expressionsAreAcceptedInEveryFieldAndKeptAsText() throws {
        for name in ["path", "limit", "ratio", "overwrite", "mode", "tags", "options"] {
            #expect(try ArgumentForm.parse("${{ params.x }}", field: field(name)).get() == .string("${{ params.x }}"))
        }
    }

    @Test func invalidLiteralsAreRefusedWithAMessage() {
        func message(_ name: String, _ text: String) -> String? { if case .failure(let e) = ArgumentForm.parse(text, field: field(name)) { return e.message }; return nil }
        #expect(message("limit", "many") != nil)
        #expect(message("limit", "99") != nil)       // above the schema maximum
        #expect(message("ratio", "x") != nil)
        #expect(message("overwrite", "maybe") != nil)
        #expect(message("mode", "delete") != nil)    // not one of the choices
        #expect(message("counts", "1, two") != nil)
        #expect(message("options", "[1]") != nil)
        #expect(message("path", "ok") == nil)
    }

    @Test func emptyTextMeansNotSet() throws {
        #expect(try ArgumentForm.parse("  ", field: field("ratio")).get() == nil)
    }

    @Test func stubsSatisfyRequiredArguments() {
        let manifest = ToolManifest(identifier: "t.x", name: "X", summary: "", family: "t", inputSchema: Self.schema, sideEffect: .read, defaultTier: .readOnly)
        let stub = ArgumentForm.stub(for: manifest)
        #expect(Set(stub.keys) == ["path", "limit"])
        #expect(stub["limit"] == .int(1))            // the schema minimum, not 0
        #expect(Self.schema.validate(.object(stub)).isEmpty)
    }

    @Test func looseValuesKeepJSONTypes() {
        #expect(ArgumentForm.parseLoose("42") == .int(42))
        #expect(ArgumentForm.parseLoose("true") == .bool(true))
        #expect(ArgumentForm.parseLoose("[1, 2]") == .array([1, 2]))
        #expect(ArgumentForm.parseLoose("hello world") == .string("hello world"))
        #expect(ArgumentForm.parseLoose("${{ 1 + 1 }}") == .string("${{ 1 + 1 }}"))
    }
}

@Suite("Unit · canvas geometry and navigation") struct CanvasGeometryTests {
    static func document() -> WorkflowDocument {
        WorkflowDocument(metadata: WorkflowMetadata(id: "g", name: "G"), spec: WorkflowSpec(triggers: [.manual], steps: [
            WorkflowStep(id: "a", kind: .set(SetStep(values: ["x": 1]))),
            WorkflowStep(id: "b", needs: ["a"], kind: .transform(TransformStep(expression: "${{ 1 }}"))),
            WorkflowStep(id: "c", needs: ["a"], kind: .transform(TransformStep(expression: "${{ 2 }}"))),
            WorkflowStep(id: "each", needs: ["b"], kind: .foreach(ForeachStep(items: .array([1, 2]), steps: [
                WorkflowStep(id: "inner", kind: .set(SetStep(values: ["y": 2]))),
            ]))),
        ]))
    }

    @Test func nestedFramesAreAbsoluteAndInsideTheirContainer() {
        let graph = WorkflowGraph(document: Self.document())
        let g = CanvasGeometry(graph: graph)
        let container = g.frames["each"]!, inner = g.frames["inner"]!
        #expect(container.contains(inner))
        #expect(g.parents["inner"] == "each")
        #expect(g.order.firstIndex(of: "each")! < g.order.firstIndex(of: "inner")!)
        #expect(g.node(at: CGPoint(x: inner.midX, y: inner.midY)) == "inner")
        #expect(g.node(at: CGPoint(x: container.minX + 4, y: container.minY + 4)) == "each")
        #expect(g.bounds.contains(container))
    }

    @Test func draggingAContainerMovesItsChildren() {
        let g = CanvasGeometry(graph: WorkflowGraph(document: Self.document()))
        let moved = g.frame("inner", dragging: ["each"], by: CGSize(width: 40, height: 20))!
        #expect(moved.minX == g.frames["inner"]!.minX + 40 && moved.minY == g.frames["inner"]!.minY + 20)
        #expect(g.frame("a", dragging: ["each"], by: CGSize(width: 40, height: 20)) == g.frames["a"])
    }

    @Test func edgesAndPortsCanBeHit() {
        let graph = WorkflowGraph(document: Self.document())
        let g = CanvasGeometry(graph: graph)
        let edge = graph.edges.first { $0.from == "a" && $0.to == "b" }!
        let curve = g.curve(for: edge)!
        #expect(g.edge(at: curve.point(0.5), in: graph, tolerance: 6)?.id == edge.id)
        #expect(g.edge(at: CGPoint(x: -5000, y: -5000), in: graph, tolerance: 6) == nil)
        let out = g.outputPoint(node: "a", port: "out", frame: g.frames["a"]!)
        #expect(g.outputPort(at: out, tolerance: 8)?.node == "a")
    }

    @Test func arrowKeysFollowConnections() {
        let graph = WorkflowGraph(document: Self.document())
        let g = CanvasGeometry(graph: graph)
        #expect(CanvasNavigation.next(from: nil, direction: .right, graph: graph, geometry: g) == "trigger:0")
        #expect(CanvasNavigation.next(from: "trigger:0", direction: .right, graph: graph, geometry: g) == "a")
        #expect(CanvasNavigation.next(from: "a", direction: .right, graph: graph, geometry: g) == "b")
        #expect(CanvasNavigation.next(from: "b", direction: .down, graph: graph, geometry: g) == "c")
        #expect(CanvasNavigation.next(from: "c", direction: .up, graph: graph, geometry: g) == "b")
        #expect(CanvasNavigation.next(from: "b", direction: .left, graph: graph, geometry: g) == "a")
        #expect(CanvasNavigation.next(from: "each", direction: .right, graph: graph, geometry: g) == "inner")
        #expect(CanvasNavigation.next(from: "inner", direction: .left, graph: graph, geometry: g) == "each")
    }

    @Test func viewportZoomKeepsTheAnchorAndFitShowsEverything() {
        var vp = CanvasViewport()
        vp.offset = CGSize(width: 30, height: -10)
        let anchor = CGPoint(x: 400, y: 300)
        let before = vp.toWorld(anchor)
        vp.zoom(by: 1.7, anchor: anchor)
        let after = vp.toWorld(anchor)
        #expect(abs(before.x - after.x) < 0.001 && abs(before.y - after.y) < 0.001)
        vp.zoom(by: 1000, anchor: anchor)
        #expect(vp.zoom == CanvasViewport.maxZoom)

        let bounds = CGRect(x: -280, y: 0, width: 3000, height: 900)
        let size = CGSize(width: 1000, height: 600)
        vp.fit(bounds, in: size)
        #expect(CGRect(origin: .zero, size: size).contains(vp.toScreen(bounds).insetBy(dx: 1, dy: 1)))
        #expect(CanvasGeometry.snap(33) == 40 && CanvasGeometry.snap(29) == 20)
    }

    @Test func stepKeysMapToStepIDsAndStatusesAggregate() {
        #expect(WorkflowStudioModel.stepID(fromKey: "each[2]/copy") == "copy")
        #expect(WorkflowStudioModel.stepID(fromKey: "par(left)/a") == "a")
        #expect(WorkflowStudioModel.stepID(fromKey: "poll#3/check") == "check")
        #expect(WorkflowStudioModel.stepID(fromKey: "write") == "write")
        let merged = WorkflowStudioModel.aggregate(["each[0]/copy": .succeeded, "each[1]/copy": .failed, "each[2]/copy": .running, "a": .simulated])
        #expect(merged["copy"]?.status == .running && merged["copy"]?.instances == 3)
        #expect(merged["a"]?.status == .simulated)
    }
}

@Suite("Unit · triggers, parameters and palette") struct FormLogicTests {
    @Test func cronTriggerGivesTheNextThreeFireTimes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        let now = calendar.date(from: DateComponents(year: 2027, month: 3, day: 1, hour: 8))!
        let dates = TriggerPreview.nextFireDates(.schedule(cron: "0 12 * * *", timezone: "America/Toronto"), after: now)
        #expect(dates.count == 3)
        #expect(dates.map { calendar.component(.hour, from: $0) } == [12, 12, 12])
        #expect(dates.map { calendar.component(.day, from: $0) } == [1, 2, 3])
        #expect(TriggerPreview.nextFireDates(.schedule(cron: "not a cron", timezone: nil), after: now).isEmpty)
        #expect(TriggerPreview.nextFireDates(.schedule(cron: "0 12 * * *", timezone: "Mars/Olympus"), after: now).isEmpty)
        let every = TriggerPreview.nextFireDates(.interval(seconds: 600), after: now)
        #expect(every.map { $0.timeIntervalSince(now) } == [600, 1200, 1800])
        #expect(TriggerPreview.nextFireDates(.login, after: now).isEmpty)
    }

    @Test func parameterFormIsTypedAndLeavesDefaultsToTheEngine() throws {
        let params = [WorkflowParameter(name: "folder", type: .path, defaultValue: "~/Out"), WorkflowParameter(name: "count", type: .integer, defaultValue: 3),
                      WorkflowParameter(name: "flag", type: .boolean), WorkflowParameter(name: "who", required: true)]
        #expect(try ParameterForm.values(params, texts: ["who": "me"]).get() == ["who": "me"])
        #expect(try ParameterForm.values(params, texts: ["who": "me", "count": "7", "flag": "true", "folder": "~/Else"]).get() == ["who": "me", "count": 7, "flag": true, "folder": "~/Else"])
        #expect(throws: FormError.self) { try ParameterForm.values(params, texts: ["who": "me", "count": "seven"]).get() }
        #expect(throws: FormError.self) { try ParameterForm.values(params, texts: [:]).get() }
    }

    @Test func freshIDsAreValidAndUnique() {
        var doc = Palette.blankDocument(existingIDs: ["new-workflow"])
        #expect(doc.metadata.id == "new-workflow-2")
        #expect(WorkflowValidator.structuralErrors(doc).isEmpty)
        #expect(Palette.freshID("start", in: doc) == "start2")
        #expect(Palette.freshID("9 lives!", in: doc) == "step9lives")
        doc.spec.steps.append(WorkflowStep(id: "start2", kind: .fail(FailStep(message: "x"))))
        #expect(Palette.freshID("start", in: doc) == "start3")
        #expect(Palette.idBase(forTool: "documents.csvRead") == "csvRead")
        #expect(Palette.matches("file list", "filesystem.list Lists FILES") && !Palette.matches("zip", "filesystem.list"))
    }
}
