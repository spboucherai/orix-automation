// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureWorkflow/Tests/ORIXFeatureWorkflowTests/StudioModelTests.swift
// Description      : Integration tests of the studio view model against real
//                    services in a temporary folder: edits with undo/redo,
//                    inspector validation, saving, versions, palette insertion
//                    for every tool, and real dry and debug runs.
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

import Foundation
import ORIXAppUI
import Testing
@testable import ORIXFeatureWorkflow

@MainActor
func makeStudio(open id: String? = "system-health-report", seed: Bool = true) async throws -> WorkflowStudioModel {
    let app = try await PreviewEnvironment.make(seed: seed)
    let vm = WorkflowStudioModel(app: app)
    app.selectedWorkflowID = id
    await vm.reload(selected: id)
    return vm
}

@MainActor
func waitUntil(_ seconds: Double = 30, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

@Suite("Integration · studio edits (real services, temp folder)") @MainActor struct StudioEditTests {
    @Test func opensTheSelectedWorkflowAndFollowsTheAppSelectionBothWays() async throws {
        let vm = try await makeStudio()
        #expect(vm.workflowID == "system-health-report")
        #expect(vm.rows.count == 3 && vm.document != nil && !vm.isDirty)
        #expect(vm.graph.nodes.contains { $0.id == "write" && $0.category == .tool })
        #expect(vm.errors.isEmpty)
        await vm.open("folder-backup-and-verify")
        #expect(vm.app.selectedWorkflowID == "folder-backup-and-verify")
        vm.app.selectedWorkflowID = "smart-downloads-organizer"
        await vm.reload(selected: vm.app.selectedWorkflowID)
        #expect(vm.workflowID == "smart-downloads-organizer")
        vm.search = "health"
        #expect(vm.filteredRows.map(\.id) == ["system-health-report"])
    }

    @Test func everyCanvasEditIsUndoableAndRedoable() async throws {
        let vm = try await makeStudio()
        let original = try #require(vm.document)
        let tool = try #require(vm.manifestByID["filesystem.list"])

        // Add after the selected step: wired with `needs`, required arguments stubbed.
        vm.selection = ["write"]
        let added = try #require(vm.add(.tool(tool)))
        var step = try #require(vm.document?.step(id: added))
        #expect(step.needs == ["write"])
        if case .tool(let t) = step.kind { #expect(t.tool == "filesystem.list" && t.arguments["path"] != nil) } else { Issue.record("not a tool step") }
        #expect(vm.selection == [added] && vm.isDirty && vm.canUndo)

        // Connect, then disconnect by deleting the edge.
        vm.connect(from: "paths", port: "out", to: added)
        #expect(vm.document?.step(id: added)?.needs == ["write", "paths"])
        let edge = try #require(vm.graph.edges.first { $0.from == "paths" && $0.to == added })
        vm.selectedEdgeID = edge.id
        vm.removeSelection()
        #expect(vm.document?.step(id: added)?.needs == ["write"])

        // A cycle is refused and reported; the document does not change.
        let before = vm.document
        vm.connect(from: added, port: "out", to: "write")
        #expect(vm.document == before && vm.editMessage != nil)

        // Rename rewrites references.
        #expect(vm.rename("freeFraction", to: "share") == nil)
        let renamed = try #require(vm.document)
        #expect(renamed.step(id: "freeFraction") == nil && renamed.step(id: "write")?.needs.contains("share") == true)
        #expect(WorkflowCodec.emit(renamed).contains("steps.share.output") && !WorkflowCodec.emit(renamed).contains("steps.freeFraction"))
        #expect(vm.rename("share", to: "write") != nil)      // duplicate id refused inline

        // Duplicate, move with snapping, group, wrap, auto-layout, delete.
        vm.selection = [added]
        vm.duplicateSelection()
        let copy = try #require(vm.selection.first)
        #expect(copy != added && vm.document?.step(id: copy) != nil)
        vm.commitMove([copy], by: CGSize(width: 33, height: 47))
        let position = try #require(vm.document?.spec.layout[copy])
        #expect(position.x.truncatingRemainder(dividingBy: 20) == 0 && position.y.truncatingRemainder(dividingBy: 20) == 0)
        #expect(vm.geometry.frames[copy]?.origin == CGPoint(x: position.x, y: position.y))
        vm.selection = [added, copy]
        vm.groupSelectionIntoParallel()
        let group = try #require(vm.selection.first)
        if case .parallel(let p) = vm.document?.step(id: group)?.kind { #expect(p.branches.flatMap(\.steps).map(\.id).sorted() == [added, copy].sorted()) } else { Issue.record("not grouped") }
        vm.selection = [group]
        vm.wrapSelectionInForeach()
        let loop = try #require(vm.selection.first)
        #expect(vm.document?.location(of: group)?.containerID == loop)
        vm.autoLayout()
        #expect(vm.document?.spec.layout.isEmpty == false)
        vm.selection = [loop]
        vm.removeSelection()
        #expect(vm.document?.step(id: loop) == nil && vm.document?.step(id: added) == nil)
        step = try #require(vm.document?.step(id: "write"))

        // Undo everything, then redo everything.
        let final = vm.document
        var undos = 0
        while vm.canUndo { vm.undo(); undos += 1 }
        #expect(undos == 10)
        #expect(vm.document == original && !vm.isDirty)
        while vm.canRedo { vm.redo() }
        #expect(vm.document == final)
        // Every state along the way is a valid, round-trippable document.
        #expect(try WorkflowCodec.parse(WorkflowCodec.emit(#require(final))) == final)
    }

    @Test func branchAndErrorPortsCreateAndRemoveRoutes() async throws {
        let vm = try await makeStudio()
        vm.selection = []
        let note = try #require(vm.add(.template(.notify)))
        vm.connect(from: "lowDisk", port: "else", to: note)
        if case .condition(let c) = vm.document?.step(id: "lowDisk")?.kind { #expect(c.otherwise == [note]) } else { Issue.record("no condition") }
        let branch = try #require(vm.graph.edges.first { $0.kind == .branch && $0.to == note })
        #expect(branch.label == "else")
        vm.deleteEdge(branch)
        if case .condition(let c) = vm.document?.step(id: "lowDisk")?.kind { #expect(c.otherwise.isEmpty) }
        vm.connect(from: "check", port: "error", to: note)
        #expect(vm.document?.step(id: "check")?.onError == note)
        #expect(vm.graph.node(note)?.category == .error)
        let route = try #require(vm.graph.edges.first { $0.kind == .error })
        vm.deleteEdge(route)
        #expect(vm.document?.step(id: "check")?.onError == nil)
        // Trigger links are derived and cannot be removed.
        let trigger = try #require(vm.graph.edges.first { $0.kind == .trigger })
        let before = vm.document
        vm.deleteEdge(trigger)
        #expect(vm.document == before && vm.editMessage != nil)
    }

    @Test func selectionAndKeyboardNavigationModel() async throws {
        let vm = try await makeStudio()
        vm.selectAll()
        #expect(vm.selection.count == vm.graph.nodes.count)
        vm.clearSelection()
        #expect(vm.selection.isEmpty && vm.inspectedStep == nil)
        vm.select("write", extend: false)
        vm.select("check", extend: true)
        #expect(vm.selection == ["write", "check"] && vm.inspectedStep == nil)
        vm.select("check", extend: true)
        #expect(vm.selection == ["write"] && vm.inspectedStep?.step.id == "write")
        vm.moveSelection(.right)
        #expect(vm.selection == ["check"])
        vm.moveSelection(.left)
        #expect(vm.selection == ["write"])
        let frame = try #require(vm.geometry.frames["collect"])
        vm.select(in: frame.insetBy(dx: -4, dy: -4), extend: false)
        #expect(vm.selection.isSuperset(of: ["collect", "info", "disk"]))
        vm.selection = ["trigger:1"]
        vm.removeSelection()
        #expect(vm.document?.spec.triggers == [.manual])
        vm.undo()
        #expect(vm.document?.spec.triggers.count == 2)
    }

    @Test func inspectorEditsAreValidatedAndRefusedInline() async throws {
        let vm = try await makeStudio()
        let manifest = try #require(vm.manifestByID["filesystem.write"])
        let fields = ArgumentForm.fields(of: manifest.inputSchema)
        let overwrite = try #require(fields.first { $0.name == "overwrite" })
        let path = try #require(fields.first { $0.name == "path" })
        let start = vm.document

        // Argument form ↔ document round trip.
        #expect(vm.setArgument("write", field: path, text: "~/ORIX Samples/x.md") == nil)
        #expect(vm.setArgument("write", field: overwrite, text: "false") == nil)
        guard case .tool(let t) = vm.document?.step(id: "write")?.kind else { Issue.record("no tool"); return }
        #expect(t.arguments["path"] == .string("~/ORIX Samples/x.md") && t.arguments["overwrite"] == .bool(false))
        #expect(ArgumentForm.text(for: t.arguments["overwrite"]) == "false")
        #expect(vm.setArgument("write", field: overwrite, text: "${{ params.minFreeFraction > 0 }}") == nil)
        #expect(vm.setArgument("write", field: overwrite, text: "") == nil)       // optional argument removed
        if case .tool(let t2) = vm.document?.step(id: "write")?.kind { #expect(t2.arguments["overwrite"] == nil) }

        // Refused: wrong type, unknown names in expressions, required argument cleared, non-upstream step.
        let valid = vm.document
        #expect(vm.setArgument("write", field: overwrite, text: "perhaps") != nil)
        #expect(vm.setArgument("write", field: path, text: "${{ params.missing }}") != nil)
        #expect(vm.setArgument("write", field: path, text: "${{ steps.result.output }}") != nil)
        #expect(vm.setField("write", .when("${{ nonsense( }}")) != nil)
        #expect(vm.setField("write", .onError("info")) != nil)                     // another list
        #expect(vm.update("write") { $0.needs.append("ghost") } != nil)
        #expect(vm.document == valid)

        // Accepted flow fields.
        #expect(vm.setField("write", .when("${{ params.minFreeFraction > 0 }}")) == nil)
        #expect(vm.setField("write", .retry(WorkflowRetryPolicy(maxAttempts: 3, backoffSeconds: 1))) == nil)
        #expect(vm.setField("write", .timeoutSeconds(20)) == nil)
        #expect(vm.setField("write", .continueOnError(true)) == nil)
        let edited = try #require(vm.document?.step(id: "write"))
        #expect(edited.when != nil && edited.retry?.maxAttempts == 3 && edited.timeoutSeconds == 20 && edited.continueOnError)

        // Changing the tool keeps compatible arguments and stubs the required ones.
        #expect(vm.setTool("write", to: "filesystem.mkdir") == nil)
        if case .tool(let t3) = vm.document?.step(id: "write")?.kind { #expect(t3.tool == "filesystem.mkdir" && t3.arguments["path"] == .string("~/ORIX Samples/x.md") && t3.arguments["content"] == nil) }
        #expect(vm.setTool("write", to: "no.such.tool") != nil)

        // Workflow settings.
        #expect(vm.updateDocument { $0.metadata.name = "Health" } == nil)
        #expect(vm.updateDocument { $0.spec.budget.maxToolCalls = 0 } != nil)
        #expect(vm.updateDocument { $0.spec.triggers.append(.schedule(cron: "61 * * * *", timezone: nil)) } != nil)
        #expect(vm.updateDocument { $0.spec.parameters.removeAll { $0.name == "outputFolder" } } != nil)   // still used
        #expect(vm.updateDocument { $0.spec.permissions.network.append("api.example.com") } == nil)
        #expect(vm.document?.metadata.name == "Health")
        while vm.canUndo { vm.undo() }
        #expect(vm.document == start)
    }

    @Test func paletteInsertionIsValidForEveryToolKindAndAgent() async throws {
        let vm = try await makeStudio()
        #expect(vm.manifests.count > 20)
        await vm.createBlank()
        let blank = try #require(vm.document)
        var failures: [String] = []
        let items = vm.manifests.map(PaletteItem.tool) + StepTemplate.allCases.map(PaletteItem.template) + vm.agents.map(PaletteItem.agent)
        for item in items {
            vm.selection = []
            guard let id = vm.add(item), let doc = vm.document else { failures.append("\(item.id): refused (\(vm.editMessage ?? "?"))"); continue }
            let result = await vm.services.workflows.diagnose(WorkflowCodec.emit(doc))
            let errors = result.diagnostics.filter { $0.severity == .error }
            if !errors.isEmpty { failures.append("\(item.id): " + errors.map(\.message).joined(separator: "; ")) }
            if result.document != doc { failures.append("\(item.id): does not round-trip") }
            if doc.step(id: id) == nil { failures.append("\(item.id): step missing") }
            vm.undo()
            #expect(vm.document == blank)
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        if failures.isEmpty { print("PALETTE inserted \(items.count) entries (\(vm.manifests.count) tools, \(StepTemplate.allCases.count) step kinds, \(vm.agents.count) agents) without validation errors") }
        // Inside a selected container.
        let each = try #require(vm.add(.template(.foreach)))
        vm.selection = [each]
        let inner = try #require(vm.add(.template(.delay)))
        #expect(vm.document?.location(of: inner)?.containerID == each)
    }
}

@Suite("Integration · studio saving and versions (real services, temp folder)") @MainActor struct StudioSaveTests {
    @Test func firstVisualSaveShowsWhatTheRewriteDropsThenSavesAndReloadsEqual() async throws {
        let vm = try await makeStudio()
        #expect(!vm.lossNotes.isEmpty)                       // the template has comments
        #expect(vm.lossNotes.contains { $0.contains("comment") })
        #expect(vm.setField("write", .timeoutSeconds(45)) == nil)
        #expect(vm.canSave)
        #expect(await vm.save() == false)
        #expect(vm.showLossConfirmation && vm.loadedVersion == 1 && vm.isDirty)
        vm.showLossConfirmation = false
        #expect(await vm.save(confirmedLoss: true))
        #expect(!vm.isDirty && vm.loadedVersion == 2 && vm.lossNotes.isEmpty)
        let edited = try #require(vm.document)

        // The stored text is exactly the canonical emission, so the code view sees the same model.
        let stored = try await vm.services.workflows.source(workflowID: "system-health-report")
        #expect(stored == WorkflowCodec.emit(edited, format: .yaml))
        #expect(WorkflowCodec.roundTripLoss(source: stored).isEmpty)

        // A fresh model reads back an equal document; later saves need no confirmation.
        let second = WorkflowStudioModel(app: vm.app)
        await second.reload(selected: "system-health-report")
        #expect(second.document == edited && second.document?.step(id: "write")?.timeoutSeconds == 45)
        #expect(second.setField("write", .timeoutSeconds(50)) == nil)
        #expect(await second.save())
        #expect(second.loadedVersion == 3)

        // The first model notices the newer version: it reloads when clean.
        await vm.reload(selected: "system-health-report")
        #expect(vm.loadedVersion == 3 && vm.document?.step(id: "write")?.timeoutSeconds == 50)
        // …and warns instead of overwriting when it has unsaved edits.
        #expect(vm.setField("write", .timeoutSeconds(60)) == nil)
        _ = try await vm.services.workflows.save(source: stored, note: "Saved from the code view")
        await vm.reload(selected: "system-health-report")
        #expect(vm.newerVersionAvailable && vm.document?.step(id: "write")?.timeoutSeconds == 60)
        await vm.revert()
        #expect(!vm.newerVersionAvailable && vm.loadedVersion == 4 && vm.document?.step(id: "write")?.timeoutSeconds == 45)
    }

    @Test func saveIsDisabledWhileThereAreErrors() async throws {
        let vm = try await makeStudio()
        // Removing a step that expressions still read is allowed on the canvas and reported by the validator.
        vm.selection = ["freeFraction"]
        vm.removeSelection()
        await vm.refreshDiagnostics()
        #expect(!vm.errors.isEmpty && vm.errors.contains { $0.stepID != nil })
        #expect(!vm.canSave)
        #expect(await vm.save(confirmedLoss: true) == false)
        #expect(vm.loadedVersion == 1)
        vm.undo()
        await vm.refreshDiagnostics()
        #expect(vm.errors.isEmpty)
    }

    @Test func newDuplicateTemplateAndDelete() async throws {
        let vm = try await makeStudio()
        await vm.createBlank()
        #expect(vm.workflowID == "new-workflow" && vm.rows.count == 4)
        let blank = try #require(vm.document)
        #expect(blank.spec.triggers == [.manual] && blank.spec.steps.count == 1 && vm.errors.isEmpty && !vm.isDirty)
        await vm.createBlank()
        #expect(vm.workflowID == "new-workflow-2")
        let row = try #require(vm.rows.first { $0.id == "new-workflow" })
        await vm.duplicate(row)
        #expect(vm.workflowID == "new-workflow-copy" && vm.document?.spec.steps == blank.spec.steps)
        let template = try #require(BuiltInWorkflows.all().first { $0.slug == "batch-image-conversion" } ?? BuiltInWorkflows.all().last)
        #expect(await vm.installTemplate(template))
        #expect(vm.document?.metadata.name == template.title)
        let count = vm.rows.count
        await vm.delete(try #require(vm.currentRow))
        #expect(vm.rows.count == count - 1 && vm.workflowID != nil && vm.workflowID == vm.app.selectedWorkflowID)
        #expect(BuiltInWorkflows.all().count >= 10)
    }

    @Test func unsavedEditsSurviveSwitchingWorkflows() async throws {
        let vm = try await makeStudio()
        #expect(vm.setField("write", .timeoutSeconds(12)) == nil)
        await vm.open("folder-backup-and-verify")
        #expect(vm.hasDraft("system-health-report") && !vm.isDirty)
        await vm.open("system-health-report")
        #expect(vm.isDirty && vm.document?.step(id: "write")?.timeoutSeconds == 12 && vm.canUndo)
    }

    @Test func versionHistoryDiffsFlagPermissionChangesAndRestoreSavesANewVersion() async throws {
        let vm = try await makeStudio()
        let first = try #require(vm.document)
        #expect(vm.updateDocument { $0.spec.permissions.network.append("api.example.com") } == nil)
        #expect(vm.setField("write", .timeoutSeconds(30)) == nil)
        #expect(await vm.save(confirmedLoss: true))
        let versions = await vm.versions()
        #expect(versions.map(\.version) == [2, 1])
        #expect(versions[0].note.contains("Workflow Studio"))
        let changes = try vm.changes(since: versions[1]).get()
        #expect(changes.contains { $0.isSecurityRelevant && $0.summary.contains("api.example.com") })
        #expect(changes.contains { if case .stepModified(let id, _) = $0 { return id == "write" }; return false })
        #expect(try vm.changes(since: versions[0]).get().isEmpty)
        #expect(await vm.restore(versions[1]))
        #expect(vm.loadedVersion == 3 && vm.document == first)
        #expect(await vm.versions().first?.note == "Restored from version 1")
    }

    @Test func generateWithoutAModelReportsItAndSavesNothing() async throws {
        let vm = try await makeStudio(open: nil, seed: false)
        #expect(vm.rows.isEmpty && vm.document == nil)
        do {
            _ = try await vm.services.workflows.generate(objective: "List my downloads")
            Issue.record("generation should need a model")
        } catch {
            guard case RunError.noModel = error else { Issue.record("unexpected error \(error)"); return }
        }
        #expect(await vm.services.workflows.list().isEmpty)
    }
}

@Suite("Integration · studio runs (real engine, temp folder)") @MainActor struct StudioRunTests {
    @Test func dryRunGoesThroughPermissionReviewAndShowsSimulatedSteps() async throws {
        let vm = try await makeStudio()
        let folder = NSHomeDirectory() + "/ORIX Samples/system-health-report/Reports"
        let existedBefore = FileManager.default.fileExists(atPath: folder)
        let filesBefore = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let review = try await vm.services.workflows.permissionReview(workflowID: "system-health-report")
        #expect(!review.accepted && !review.proposed.isEmpty)
        await vm.requestRun(.dryRun)
        #expect(vm.runRequest == .dryRun && vm.activeRunID == nil)     // not accepted yet: the sheet is shown
        vm.runRequest = nil
        let runID = try #require(await vm.start(.dryRun, parameters: [:], accept: true))
        #expect(try await vm.services.workflows.permissionReview(workflowID: "system-health-report").accepted)
        #expect(await waitUntil { vm.runRecord?.status.isTerminal == true && !vm.runIsLive && vm.runReceipt != nil })
        #expect(vm.activeRunID == runID && vm.runIsDry && vm.showDrawer)
        // What was simulated is reported, from the live outcome or (when the run ended before it could be followed) the receipt.
        let simulated = vm.runOutcome?.simulations ?? vm.runReceipt?.limitations ?? []
        #expect(simulated.contains { $0.contains("prepare") && $0.contains("simulated") })
        #expect(vm.stepInfo["prepare"]?.status == .simulated)
        #expect(vm.stepInfo["info"]?.status == .simulated && vm.stepInfo["collect"] != nil)
        #expect(vm.stepInfo["paths"]?.status == .succeeded && vm.stepInfo["paths"]?.output != nil)
        #expect(vm.stepInfo["paths"]?.durationSeconds != nil)
        #expect(vm.runRecord?.status.isTerminal == true && vm.runReceipt != nil)
        // The dry run wrote nothing.
        #expect(FileManager.default.fileExists(atPath: folder) == existedBefore)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []) == filesBefore)
        // Already accepted: the next request starts directly.
        await vm.requestRun(.dryRun)
        #expect(vm.runRequest == nil && vm.activeRunID != runID)
        #expect(await waitUntil { vm.runRecord?.status.isTerminal == true && !vm.runIsLive })

        // A fresh model shows the last run's data from the store.
        let later = WorkflowStudioModel(app: vm.app)
        await later.reload(selected: "system-health-report")
        #expect(later.activeRunID == vm.activeRunID && later.runHandle == nil)
        #expect(later.stepInfo["prepare"]?.status == .simulated && later.stepInfo["paths"]?.status == .succeeded)
    }

    @Test func debugRunPausesStepsOverEditsVariablesAndStopsAtBreakpoints() async throws {
        let vm = try await makeStudio()
        var doc = Palette.blankDocument(existingIDs: [])
        doc.metadata.id = "debug-me"
        doc.spec.steps = [
            WorkflowStep(id: "one", kind: .set(SetStep(values: ["n": 1]))),
            WorkflowStep(id: "two", needs: ["one"], kind: .transform(TransformStep(expression: "${{ vars.n + 1 }}", into: "m"))),
            WorkflowStep(id: "three", needs: ["two"], kind: .output(OutputStep(values: ["m": "${{ vars.m }}"]))),
        ]
        #expect(await vm.install(doc))
        vm.toggleBreakpoint("three")
        #expect(vm.breakpoints == ["three"])
        await vm.requestRun(.debug)                 // no declared permission → nothing to accept, but the sheet still asks once
        if vm.runRequest != nil { vm.runRequest = nil; _ = await vm.start(.debug, parameters: [:], accept: false) }
        #expect(await waitUntil { vm.runIsPaused })
        #expect(vm.stepInfo["one"] == nil || vm.stepInfo["one"]?.status != .succeeded)
        vm.stepOver()
        #expect(await waitUntil { vm.stepInfo["one"]?.status == .succeeded && vm.runVariables["n"] == .int(1) })
        #expect(vm.runIsPaused && vm.runIsLive)
        #expect(await vm.setVariable("n", text: "41") == nil)
        #expect(vm.runVariables["n"] == .int(41))
        vm.resumeRun()                              // runs "two", then holds at the breakpoint on "three"
        #expect(await waitUntil { vm.stepInfo["two"]?.status == .succeeded && vm.runState?.pausedAt == ["three"] })
        #expect(vm.stepInfo["two"]?.output == .int(42))
        vm.toggleBreakpoint("three")
        vm.resumeRun()
        #expect(await waitUntil { vm.runOutcome != nil })
        #expect(vm.runOutcome?.status == .succeeded && vm.runOutcome?.outputs["m"] == .int(42))
        #expect(vm.stepInfo["three"]?.status == .succeeded && !vm.runIsLive)
    }

    @Test func stopCancelsARunningWorkflow() async throws {
        let vm = try await makeStudio()
        var doc = Palette.blankDocument(existingIDs: [])
        doc.metadata.id = "slow"
        doc.spec.steps = [WorkflowStep(id: "wait", kind: .delay(DelayStep(seconds: 30)))]
        #expect(await vm.install(doc))
        _ = try #require(await vm.start(.run, parameters: [:], accept: false))
        #expect(await waitUntil { vm.stepInfo["wait"]?.status == .running })
        vm.stopRun()
        #expect(await waitUntil { vm.runOutcome != nil })
        #expect(vm.runOutcome?.status == .canceled && !vm.runIsLive)
    }
}
