// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureWorkflow/Sources/orix-preview-workflow/main.swift
// Description      : Renders the Workflow Studio screens to PNG files on a
//                    throwaway data folder: `swift run orix-preview-workflow
//                    --shot <dir>`.
// Module           : orix-preview-workflow
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
import ORIXAppUI
import ORIXFeatureWorkflow
import SwiftUI

_ = NSApplication.shared

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--shot"), arguments.count > flag + 1 else {
    FileHandle.standardError.write(Data("usage: orix-preview-workflow --shot <dir>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)

@MainActor
func shoot<V: View>(_ name: String, _ view: V, model: AppModel, size: CGSize, settle: Double = 1.4) async throws {
    for dark in [true, false] {
        let url = directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try await ShotRenderer.render(view.environment(model), size: size, dark: dark, settle: settle, to: url)
        print("SHOT \(url.path)")
    }
}

@MainActor
func run() async throws {
    let model = try await PreviewEnvironment.make()
    model.section = .workflows
    model.selectedWorkflowID = "system-health-report"
    let vm = WorkflowStudioModel(app: model)
    await vm.reload(selected: model.selectedWorkflowID)
    let compact = CGSize(width: 1100, height: 700), large = CGSize(width: 1600, height: 1000)

    try await shoot("library-canvas", vm.studioView(), model: model, size: large)
    try await shoot("library-canvas-compact", vm.studioView(), model: model, size: compact)

    vm.selectNodes(["write"])
    try await shoot("inspector-tool", vm.studioView(), model: model, size: large)
    vm.selectNodes(["lowDisk"])
    try await shoot("inspector-condition", vm.studioView(), model: model, size: compact)
    vm.selectNodes([])

    try await shoot("template-gallery", vm.templateGalleryView(), model: model, size: CGSize(width: 1100, height: 760))
    try await shoot("permission-review", vm.permissionReviewView(), model: model, size: CGSize(width: 620, height: 600))
    try await shoot("add-palette", vm.paletteView(), model: model, size: CGSize(width: 420, height: 520))
    try await shoot("version-history", vm.historyView(), model: model, size: CGSize(width: 611, height: 420))
    try await shoot("create-from-description", vm.generateView(), model: model, size: CGSize(width: 720, height: 640))

    // A real dry run of the template, started paused so the canvas can be captured while it is going.
    try await model.services.workflows.acceptPermissions(workflowID: "system-health-report")
    var request = WorkflowRunRequest(workflowID: "system-health-report")
    request.dryRun = true
    request.startPaused = true
    let runID = try await model.services.workflows.startRun(request)
    await vm.follow(runID: runID)
    for _ in 0..<3 { vm.debuggerStepOver(); try await Task.sleep(nanoseconds: 250_000_000) }
    vm.fitWhenShown()
    try await shoot("dry-run-during", vm.studioView(), model: model, size: large)
    vm.debuggerResume()
    let deadline = Date().addingTimeInterval(60)
    while vm.selectedRunIsLive, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
    print("DRY RUN status=\(vm.selectedRunStatus?.rawValue ?? "?") steps=\(vm.stepStatuses.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.rawValue)" }.joined(separator: " "))")
    vm.selectNodes(["write"])
    try await shoot("dry-run-after", vm.studioView(), model: model, size: large)
    try await shoot("dry-run-after-compact", vm.studioView(), model: model, size: compact)
    vm.showRunPanel(false)

    // A generated 40-step graph, zoomed to fit.
    guard await vm.install(WorkflowStudioSamples.layered(count: 40)) else { print("INSTALL FAILED: \(model.banner?.text ?? "?")"); throw CocoaError(.fileWriteUnknown) }
    vm.fitWhenShown(exactly: true)
    try await shoot("graph-40-nodes", vm.studioView(), model: model, size: large)

    await model.services.shutdown()
}

Task { @MainActor in
    do { try await run(); exit(0) } catch {
        FileHandle.standardError.write(Data("preview failed: \(error)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()
