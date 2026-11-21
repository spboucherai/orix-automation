// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/StudioModel.swift
// Description      : State of the Workflow Studio: library, the open document
//                    with undo/redo, selection, viewport, diagnostics, saving
//                    through WorkflowCodec and WorkflowService, and versions.
// Module           : ORIXFeatureWorkflow
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
import Observation
import ORIXAppUI
import SwiftUI

/// What the studio knows about one step of the selected run.
struct StepRunInfo: Hashable, Sendable {
    var status: StepStatus
    var startedAt: Date?
    var endedAt: Date?
    var attempts = 0
    var error: String?
    var note: String?
    var output: JSONValue?
    /// How many instances of the step ran (iterations of a loop count separately).
    var instances = 1

    var durationSeconds: Double? {
        guard let s = startedAt, let e = endedAt else { return nil }
        return max(0, e.timeIntervalSince(s))
    }
}

enum RunKind: String, Sendable { case run, dryRun, debug }

@MainActor
@Observable
public final class WorkflowStudioModel {
    public let app: AppModel
    var services: ORIXServices { app.services }

    // MARK: Library and catalogue
    private(set) var rows: [WorkflowRow] = []
    private(set) var libraryLoaded = false
    var search = ""
    private(set) var manifests: [ToolManifest] = []
    private(set) var agents: [AgentProfile] = []
    private(set) var manifestByID: [String: ToolManifest] = [:]

    // MARK: Open document
    private(set) var workflowID: String?
    private(set) var document: WorkflowDocument?
    private(set) var graph = WorkflowGraph(document: WorkflowDocument(metadata: WorkflowMetadata(id: "empty", name: "")))
    private(set) var geometry = CanvasGeometry()
    private(set) var savedDocument: WorkflowDocument?
    private(set) var storedSource = ""
    private(set) var storedFormat: WorkflowFormat = .yaml
    private(set) var loadedVersion = 0
    private(set) var lossNotes: [String] = []
    private(set) var newerVersionAvailable = false
    private(set) var loadError: String?
    private(set) var diagnostics: [WorkflowDiagnostic] = []
    private(set) var isSaving = false
    private(set) var isBusy = false
    /// The last edit that was refused, shown in the validation strip until the next successful edit.
    var editMessage: String?

    struct Snapshot { var document: WorkflowDocument; var selection: Set<String> }
    private(set) var undoStack: [Snapshot] = []
    private(set) var redoStack: [Snapshot] = []
    struct Draft { var document: WorkflowDocument; var undo: [Snapshot]; var redo: [Snapshot] }
    private(set) var drafts: [String: Draft] = [:]

    // MARK: Selection and viewport
    var selection: Set<String> = [] { didSet { if selection != oldValue, !selection.isEmpty { selectedEdgeID = nil } } }
    var selectedEdgeID: String?
    var viewport = CanvasViewport()
    var canvasSize: CGSize = .zero
    var draggingIDs: Set<String> = []
    var dragTranslation: CGSize = .zero
    var needsFit = true
    var fitExactly = false

    // MARK: Sheets
    var showTemplates = false
    var showPalette = false
    var showGenerate = false
    var showHistory = false
    var showLossConfirmation = false
    var pendingDelete: WorkflowRow?
    var runRequest: RunKind?

    // MARK: Run (see StudioModel+Run.swift)
    var breakpoints: Set<String> = []
    var activeRunID: String?
    var runKind: RunKind = .run
    var runRecord: RunRecord?
    var runState: WorkflowRunState?
    var stepInfo: [String: StepRunInfo] = [:]
    var runOutcome: WorkflowOutcome?
    var runReceipt: RunReceipt?
    var runVariables: [String: JSONValue] = [:]
    var runHandle: WorkflowRun?
    var runTasks: [Task<Void, Never>] = []
    var showDrawer = false
    var isStartingRun = false

    private var diagnoseTask: Task<Void, Never>?

    public init(app: AppModel) { self.app = app }

    // MARK: - Derived

    var isDirty: Bool { document != nil && document != savedDocument }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var errors: [WorkflowDiagnostic] { diagnostics.filter { $0.severity == .error } }
    var warnings: [WorkflowDiagnostic] { diagnostics.filter { $0.severity == .warning } }
    var canSave: Bool { isDirty && errors.isEmpty && !isSaving }
    var currentRow: WorkflowRow? { rows.first { $0.id == workflowID } }

    var filteredRows: [WorkflowRow] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let sorted = rows.sorted { $0.updatedAt > $1.updatedAt }
        return q.isEmpty ? sorted : sorted.filter { Palette.matches(q, $0.name + " " + $0.id) }
    }

    var selectedStepIDs: [String] {
        guard let document else { return [] }
        return document.allSteps.map(\.step.id).filter(selection.contains)
    }

    /// The step shown in the inspector: exactly one selected step.
    var inspectedStep: WorkflowStepLocation? {
        guard selection.count == 1, let id = selection.first, let document else { return nil }
        return document.location(of: id)
    }

    func hasDraft(_ id: String) -> Bool { id == workflowID ? isDirty : drafts[id] != nil }

    func diagnostics(forStep id: String) -> [WorkflowDiagnostic] { diagnostics.filter { $0.stepID == id } }

    // MARK: - Loading

    /// Reloads the library and catalogue; follows `selected` (the app's selected workflow), and notices versions saved elsewhere.
    public func reload(selected: String?) async {
        async let rowsNow = services.workflows.list()
        async let tools = services.executor.manifests()
        async let profiles = services.agents.all()
        rows = await rowsNow
        manifests = await tools.sorted { $0.identifier < $1.identifier }
        manifestByID = Dictionary(manifests.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        agents = await profiles
        libraryLoaded = true
        let target = selected.flatMap { id in rows.contains { $0.id == id } ? id : nil } ?? workflowID.flatMap { id in rows.contains { $0.id == id } ? id : nil }
            ?? filteredRows.first?.id
        if target != workflowID {
            await open(target)
        } else if let row = currentRow, row.currentVersion != loadedVersion {
            if isDirty { newerVersionAvailable = true } else { await load(row.id) }
        }
        if activeRunID != nil, runHandle == nil { await refreshRunFromStore() }
    }

    /// Opens a workflow (nil closes). Unsaved edits of the previous one are kept as a draft for this session.
    public func open(_ id: String?) async {
        if let current = workflowID, let document, isDirty { drafts[current] = Draft(document: document, undo: undoStack, redo: redoStack) }
        guard let id else {
            workflowID = nil; document = nil; savedDocument = nil; diagnostics = []; selection = []; undoStack = []; redoStack = []
            detachRun()
            return
        }
        await load(id)
        if app.selectedWorkflowID != id { app.selectedWorkflowID = id }
    }

    /// Reads the stored source, parses it and restores the session draft, if any.
    func load(_ id: String) async {
        detachRun()
        workflowID = id
        newerVersionAvailable = false
        loadError = nil
        editMessage = nil
        selection = []
        undoStack = []; redoStack = []
        breakpoints = []
        do {
            let versions = await services.workflows.versions(workflowID: id)
            guard let latest = versions.max(by: { $0.version < $1.version }) else { throw RunError.notFound("Workflow \(id)") }
            storedSource = latest.source
            storedFormat = latest.format == "json" ? .json : .yaml
            loadedVersion = latest.version
            lossNotes = WorkflowCodec.roundTripLoss(source: latest.source, format: storedFormat)
            let doc = try WorkflowCodec.parse(latest.source, format: storedFormat)
            savedDocument = doc
            if let draft = drafts.removeValue(forKey: id) {
                undoStack = draft.undo; redoStack = draft.redo
                setDocument(draft.document)
            } else {
                setDocument(doc)
            }
            needsFit = true
            await refreshDiagnostics()
            await adoptLatestRun()
        } catch {
            document = nil; savedDocument = nil; diagnostics = []
            graph = WorkflowGraph(document: WorkflowDocument(metadata: WorkflowMetadata(id: "empty", name: "")))
            geometry = CanvasGeometry()
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Discards unsaved edits and reads the stored version again.
    func revert() async {
        guard let id = workflowID else { return }
        drafts[id] = nil
        await load(id)
    }

    private func setDocument(_ doc: WorkflowDocument) {
        document = doc
        graph = WorkflowGraph(document: doc)
        geometry = CanvasGeometry(graph: graph)
        let ids = Set(graph.nodes.map(\.id))
        selection = selection.intersection(ids)
        if let e = selectedEdgeID, !graph.edges.contains(where: { $0.id == e }) { selectedEdgeID = nil }
        breakpoints = breakpoints.intersection(ids)
    }

    // MARK: - Diagnostics

    /// Validation against the tools, agents and workflows that exist now, without waiting for the service.
    func validate(_ doc: WorkflowDocument) -> [WorkflowDiagnostic] {
        WorkflowValidator.validate(doc, tools: manifests, agents: agents.map(\.name), workflows: rows.map(\.id))
    }

    /// Asks the workflow service to diagnose the canonical text of the open document.
    func refreshDiagnostics() async {
        guard let document else { diagnostics = []; return }
        let result = await services.workflows.diagnose(WorkflowCodec.emit(document, format: .yaml))
        guard self.document == document else { return }
        diagnostics = result.diagnostics
    }

    private func scheduleDiagnostics() {
        diagnoseTask?.cancel()
        diagnoseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshDiagnostics()
        }
    }

    // MARK: - Undoable edits

    /// Replaces the document as one undoable step.
    func apply(_ new: WorkflowDocument) {
        guard let old = document, new != old else { return }
        undoStack.append(Snapshot(document: old, selection: selection))
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        redoStack = []
        editMessage = nil
        setDocument(new)
        scheduleDiagnostics()
    }

    func undo() {
        guard let last = undoStack.popLast(), let current = document else { return }
        redoStack.append(Snapshot(document: current, selection: selection))
        setDocument(last.document)
        selection = last.selection.intersection(Set(graph.nodes.map(\.id)))
        editMessage = nil
        scheduleDiagnostics()
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = document else { return }
        undoStack.append(Snapshot(document: current, selection: selection))
        setDocument(next.document)
        selection = next.selection.intersection(Set(graph.nodes.map(\.id)))
        editMessage = nil
        scheduleDiagnostics()
    }

    static func message(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }

    /// Runs a graph edit. A refused edit leaves the document untouched and returns the reason (also kept in `editMessage`).
    @discardableResult
    func perform(_ edit: (WorkflowDocument) throws -> WorkflowDocument) -> String? {
        guard let document else { return nil }
        do {
            apply(try edit(document))
            return nil
        } catch {
            let m = Self.message(error)
            editMessage = m
            return m
        }
    }

    /// Runs an inspector edit: structural rules first, then the validator. An edit that introduces a new error is not
    /// applied and its message is returned for display next to the field.
    func performValidated(step stepID: String? = nil, _ edit: (WorkflowDocument) throws -> WorkflowDocument) -> String? {
        guard let document else { return nil }
        do {
            let candidate = try edit(document)
            if candidate == document { return nil }
            if let structural = WorkflowValidator.structuralErrors(candidate).first { return structural.message }
            func key(_ d: WorkflowDiagnostic) -> String { "\(d.code)|\(d.stepID ?? "")|\(d.message)" }
            let before = Set(validate(document).filter { $0.severity == .error }.map(key))
            if let fresh = validate(candidate).first(where: { $0.severity == .error && !before.contains(key($0)) }) {
                return fresh.stepID.map { id in id == stepID ? fresh.message : "\(fresh.message) (step \(id))" } ?? fresh.message
            }
            apply(candidate)
            return nil
        } catch {
            return Self.message(error)
        }
    }

    // MARK: - Saving

    /// Saves a new version from the model. Returns false when nothing was saved (errors, or the user must first confirm
    /// what the rewrite drops).
    @discardableResult
    func save(confirmedLoss: Bool = false) async -> Bool {
        guard let document, isDirty else { return true }
        await refreshDiagnostics()
        guard errors.isEmpty else { editMessage = String(localized: "Fix the errors before saving."); return false }
        if !lossNotes.isEmpty && !confirmedLoss { showLossConfirmation = true; return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let source = WorkflowCodec.emit(document, format: .yaml)
            let saved = try await services.workflows.save(source: source, format: .yaml, note: lossNotes.isEmpty ? "Edited in Workflow Studio" : "Edited in Workflow Studio (rewritten in canonical form)")
            storedSource = source; storedFormat = .yaml
            loadedVersion = saved.version
            savedDocument = document
            lossNotes = []
            newerVersionAvailable = false
            diagnostics = saved.diagnostics
            if saved.permissionsReset {
                app.notice(String(localized: "The declared permissions changed, so the earlier acceptance was withdrawn. You will be asked again before the next run."), kind: .warning)
            }
            rows = await services.workflows.list()
            return true
        } catch {
            app.report(error)
            return false
        }
    }

    // MARK: - Library actions

    func createBlank() async {
        let doc = Palette.blankDocument(existingIDs: Set(rows.map(\.id)))
        await saveNew(WorkflowCodec.emit(doc, format: .yaml), note: "Created in Workflow Studio")
    }

    func duplicate(_ row: WorkflowRow) async {
        do {
            var doc = try await services.workflows.document(workflowID: row.id)
            let taken = Set(rows.map(\.id))
            var id = row.id + "-copy"
            var n = 2
            while taken.contains(id) { id = "\(row.id)-copy\(n)"; n += 1 }
            doc.metadata.id = id
            doc.metadata.name = String(localized: "\(doc.metadata.name) copy")
            await saveNew(WorkflowCodec.emit(doc, format: .yaml), note: "Duplicated from \(row.id)")
        } catch { app.report(error) }
    }

    func installTemplate(_ template: BuiltInWorkflow) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let saved = try await services.workflows.installBuiltIn(slug: template.slug)
            rows = await services.workflows.list()
            drafts[saved.id] = nil
            if saved.id == workflowID { await load(saved.id) } else { await open(saved.id) }
            return true
        } catch { app.report(error); return false }
    }

    /// Saves source as a new workflow (or a new version of the id it names) and opens it.
    @discardableResult
    func saveNew(_ source: String, note: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let saved = try await services.workflows.save(source: source, format: WorkflowCodec.detectFormat(source), note: note)
            rows = await services.workflows.list()
            drafts[saved.id] = nil
            if saved.id == workflowID { await load(saved.id) } else { await open(saved.id) }
            return true
        } catch { app.report(error); return false }
    }

    func delete(_ row: WorkflowRow) async {
        do {
            try await services.workflows.delete(workflowID: row.id)
            drafts[row.id] = nil
            rows = await services.workflows.list()
            if row.id == workflowID {
                workflowID = nil; document = nil; savedDocument = nil
                let next = filteredRows.first?.id
                app.selectedWorkflowID = next
                await open(next)
            }
        } catch { app.report(error) }
    }

    // MARK: - Versions

    func versions() async -> [WorkflowVersionRow] {
        guard let id = workflowID else { return [] }
        return await services.workflows.versions(workflowID: id).sorted { $0.version > $1.version }
    }

    /// Changes from a stored version to what is open now.
    func changes(since version: WorkflowVersionRow) -> Result<[WorkflowChange], FormError> {
        guard let document else { return .success([]) }
        do {
            let old = try WorkflowCodec.parse(version.source, format: version.format == "json" ? .json : .yaml)
            return .success(WorkflowDiff.diff(old, document))
        } catch { return .failure(FormError(message: Self.message(error))) }
    }

    /// Saves an earlier version's source again as the newest version, and opens it.
    func restore(_ version: WorkflowVersionRow) async -> Bool {
        guard let id = workflowID else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await services.workflows.save(source: version.source, format: version.format == "json" ? .json : .yaml, note: "Restored from version \(version.version)")
            drafts[id] = nil
            rows = await services.workflows.list()
            await load(id)
            return true
        } catch { app.report(error); return false }
    }

    // MARK: - Viewport

    /// Shows the whole graph.
    func zoomToFit() {
        guard canvasSize.width > 0 else { needsFit = true; fitExactly = true; return }
        viewport.fit(geometry.bounds, in: canvasSize)
        needsFit = false; fitExactly = false
    }

    /// First view of a workflow: the whole graph when it stays readable, else its beginning at a readable size.
    func fitForReading() {
        guard canvasSize.width > 0 else { needsFit = true; return }
        if fitExactly { zoomToFit(); return }
        viewport.fit(geometry.bounds, in: canvasSize)
        let readable: CGFloat = 0.62
        if viewport.zoom < readable {
            let b = geometry.bounds
            viewport.zoom = readable
            let fitsTall = b.height * readable <= canvasSize.height - 64
            viewport.offset = CGSize(width: 32 - b.minX * readable,
                                     height: fitsTall ? (canvasSize.height - b.height * readable) / 2 - b.minY * readable : 32 - b.minY * readable)
        }
        needsFit = false
    }

    func zoom(by factor: CGFloat) { viewport.zoom(by: factor, anchor: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)) }
    func resetZoom() { viewport.setZoom(1, anchor: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)) }

    func reveal(_ id: String) {
        guard let f = geometry.frames[id], canvasSize.width > 0 else { return }
        viewport.reveal(f, in: canvasSize)
    }

    /// Selects a step from a diagnostic or a list and brings it into view.
    func focus(step id: String) {
        guard geometry.frames[id] != nil else { return }
        selection = [id]
        reveal(id)
    }
}
