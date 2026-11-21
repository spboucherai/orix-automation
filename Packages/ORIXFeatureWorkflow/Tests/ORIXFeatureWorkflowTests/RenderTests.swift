// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureWorkflow/Tests/ORIXFeatureWorkflowTests/RenderTests.swift
// Description      : Renders every studio screen off screen and measures layout
//                    and drawing time of a generated 200-step graph.
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

import AppKit
import Foundation
import ORIXAppUI
import SwiftUI
import Testing
@testable import ORIXFeatureWorkflow

@MainActor
private func render<V: View>(_ name: String, _ view: V, app: AppModel, size: CGSize, settle: Double = 0.9) async throws -> Int {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orix-workflow-tests").appendingPathComponent("\(name).png")
    try await ShotRenderer.render(view.environment(app), size: size, settle: settle, to: url)
    let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("SHOT \(url.path) \(bytes) bytes")
    return bytes
}

/// Distinct colours in a PNG, sampled: a blank or single-colour image fails this.
private func distinctColours(_ url: URL) -> Int {
    guard let rep = NSImage(contentsOf: url)?.representations.first as? NSBitmapImageRep else { return 0 }
    var seen = Set<UInt32>()
    for y in stride(from: 0, to: rep.pixelsHigh, by: 9) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 9) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            seen.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
        }
    }
    return seen.count
}

@Suite("Render · studio screens (off screen)") @MainActor struct StudioRenderTests {
    @Test func studioWithLibraryCanvasAndInspector() async throws {
        let vm = try await makeStudio()
        #expect(try await render("studio-settings", StudioContent(vm: vm), app: vm.app, size: CGSize(width: 1600, height: 1000)) > 120_000)
        #expect(vm.canvasSize.width > 600)          // the canvas was laid out and reported its size
        #expect(vm.viewport.zoom >= 0.6)            // first view is readable
        vm.selection = ["write"]
        #expect(try await render("studio-tool-inspector", StudioContent(vm: vm), app: vm.app, size: CGSize(width: 1100, height: 700)) > 100_000)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orix-workflow-tests/studio-tool-inspector.png")
        #expect(distinctColours(url) > 40)
    }

    @Test func templateGallery() async throws {
        let vm = try await makeStudio()
        #expect(try await render("template-gallery", TemplateGallery(vm: vm), app: vm.app, size: CGSize(width: 1100, height: 760)) > 100_000)
    }

    @Test func permissionReviewSheet() async throws {
        let vm = try await makeStudio()
        #expect(try await render("permission-review", PermissionReviewSheet(vm: vm, kind: .run), app: vm.app, size: CGSize(width: 620, height: 600)) > 40_000)
    }

    @Test func paletteHistoryAndGenerate() async throws {
        let vm = try await makeStudio()
        #expect(try await render("palette", PaletteView(vm: vm), app: vm.app, size: CGSize(width: 420, height: 520)) > 40_000)
        #expect(try await render("history", HistoryPopover(vm: vm), app: vm.app, size: CGSize(width: 611, height: 420)) > 15_000)
        #expect(try await render("generate", GenerateSheet(vm: vm), app: vm.app, size: CGSize(width: 720, height: 640)) > 15_000)
        vm.showLossConfirmation = true
        #expect(try await render("rewrite-warning", LossSheet(vm: vm), app: vm.app, size: CGSize(width: 560, height: 420)) > 20_000)
    }

    @Test func canvasAfterARealDryRunShowsStepStatusAndTheOutcome() async throws {
        let vm = try await makeStudio()
        _ = try #require(await vm.start(.dryRun, parameters: [:], accept: true))
        #expect(await waitUntil { vm.runRecord?.status.isTerminal == true && !vm.runIsLive })
        #expect(vm.scene().stepInfo["prepare"]?.status == .simulated)
        #expect(try await render("studio-dry-run", StudioContent(vm: vm), app: vm.app, size: CGSize(width: 1600, height: 1000)) > 150_000)
    }
}

@Suite("Performance · 200-step graph") @MainActor struct CanvasPerformanceTests {
    private func milliseconds(_ runs: Int, _ body: () -> Void) -> (median: Double, worst: Double) {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        return (samples[samples.count / 2], samples.last ?? 0)
    }

    @Test func layoutAndDrawingStayWithinAFrameBudget() throws {
        let doc = WorkflowStudioSamples.layered(count: 200, width: 8)
        #expect(doc.allSteps.count == 200 && WorkflowValidator.structuralErrors(doc).isEmpty)

        var graph = WorkflowGraph(document: doc)
        var geometry = CanvasGeometry(graph: graph)
        let layout = milliseconds(20) {
            graph = WorkflowGraph(document: doc)
            geometry = CanvasGeometry(graph: graph)
        }
        #expect(graph.nodes.count == 201 && geometry.frames.count == 201)

        let size = CGSize(width: 1200, height: 800)
        func frame(_ configure: (inout CanvasScene) -> Void) -> (median: Double, worst: Double) {
            var scene = CanvasScene(graph: graph, geometry: geometry)
            scene.selection = ["s10", "s11"]
            scene.stepInfo = Dictionary(uniqueKeysWithValues: (0..<200).map { ("s\($0)", StepRunInfo(status: $0 % 7 == 0 ? .running : .succeeded, startedAt: Date(), endedAt: Date())) })
            configure(&scene)
            let content = Canvas(rendersAsynchronously: false) { ctx, s in GraphRenderer.draw(&ctx, size: s, scene: scene) }.frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            _ = renderer.cgImage                       // warm up symbol and glyph caches
            var drawn = false
            let t = milliseconds(15) { drawn = renderer.cgImage != nil || drawn; renderer.scale = renderer.scale == 2 ? 2.0001 : 2 }
            #expect(drawn)
            return t
        }
        let fitted = frame { $0.viewport.fit(geometry.bounds, in: size) }                 // all 200 nodes visible, low detail
        let detailed = frame { $0.viewport.zoom = 1; $0.viewport.offset = CGSize(width: 40, height: 40) }   // full detail, culled to the view
        let dragging = frame { $0.viewport.fit(geometry.bounds, in: size); $0.dragging = ["s10", "s11"]; $0.translation = CGSize(width: 60, height: 40) }

        // Hit testing and navigation on every pointer move or key press.
        let hit = milliseconds(50) {
            _ = geometry.node(at: CGPoint(x: 900, y: 300))
            _ = geometry.edge(at: CGPoint(x: 905, y: 310), in: graph, tolerance: 6)
            _ = CanvasNavigation.next(from: "s50", direction: .down, graph: graph, geometry: geometry)
        }

        print(String(format: "PERF 200 steps (201 nodes, %d edges): projection+layout median %.2f ms (worst %.2f) · frame fitted %.2f ms (worst %.2f) · frame at 100%% %.2f ms (worst %.2f) · frame while dragging %.2f ms (worst %.2f) · hit test+navigation %.3f ms",
                     graph.edges.count, layout.median, layout.worst, fitted.median, fitted.worst, detailed.median, detailed.worst, dragging.median, dragging.worst, hit.median))
        // Budgets with headroom for a loaded machine: layout only runs on an edit, a frame runs on every pan/zoom tick.
        #expect(layout.median < 60)
        #expect(fitted.median < 33)
        #expect(detailed.median < 33)
        #expect(dragging.median < 33)
        #expect(hit.median < 4)
    }

    @Test func twoHundredStepsOpenInTheStudioAndEditQuickly() async throws {
        let vm = try await makeStudio()
        #expect(await vm.install(WorkflowStudioSamples.layered(count: 200, width: 8)))
        #expect(vm.graph.nodes.count == 201 && vm.errors.isEmpty)
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<20 { vm.commitMove(["s\(i)"], by: CGSize(width: 40, height: 20)) }
        let perEdit = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / 20
        print(String(format: "PERF 200 steps: one drag commit (edit + projection + layout + undo snapshot) %.2f ms", perEdit))
        #expect(perEdit < 60)
        #expect(vm.undoStack.count == 20)
        #expect(try await render("studio-200-steps", StudioContent(vm: vm), app: vm.app, size: CGSize(width: 1600, height: 1000)) > 100_000)
    }
}
