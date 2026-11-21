// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/StudioModel+Edits.swift
// Description      : Canvas and inspector edits of the Workflow Studio, each
//                    expressed with WorkflowEdit so the result is always a
//                    structurally valid document.
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
import ORIXAppUI

extension WorkflowStudioModel {
    // MARK: Selection

    func select(_ id: String, extend: Bool) {
        if extend {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    func selectAll() { selection = Set(graph.nodes.map(\.id)) }
    func clearSelection() { selection = []; selectedEdgeID = nil }

    /// Selects every node whose frame intersects a world rectangle.
    func select(in rect: CGRect, extend: Bool) {
        let hit = Set(geometry.frames.filter { id, f in isContainer(id) ? rect.contains(f) : f.intersects(rect) }.map(\.key))
        selection = extend ? selection.union(hit) : hit
    }

    private func isContainer(_ id: String) -> Bool { graph.node(id)?.isContainer ?? false }

    func moveSelection(_ direction: CanvasDirection) {
        let current = selection.count == 1 ? selection.first : nil
        guard let next = CanvasNavigation.next(from: current, direction: direction, graph: graph, geometry: geometry) else { return }
        selection = [next]
        reveal(next)
    }

    // MARK: Add

    /// The container a new step goes into: the selected foreach/loop/parallel, else the root list.
    private func insertionTarget() -> (container: String?, branch: String?) {
        guard let loc = inspectedStep else { return (nil, nil) }
        switch loc.step.kind {
        case .foreach, .loop: return (loc.step.id, nil)
        case .parallel(let p): return (loc.step.id, p.branches.first?.name ?? "branch1")
        default: return (nil, nil)
        }
    }

    /// Inserts a new step for a palette entry. With one step selected in the root list the new step is wired after it;
    /// with a container selected it goes inside. Returns the new id, or nil when the edit was refused.
    @discardableResult
    func add(_ item: PaletteItem) -> String? {
        guard let document else { return nil }
        let step = Palette.makeStep(item, in: document, otherWorkflows: rows.map(\.id).filter { $0 != workflowID })
        let target = insertionTarget()
        let anchor = target.container == nil ? inspectedStep.flatMap { $0.scopeKind == .root ? $0.step : nil } : nil
        let handlerIDs = Set(document.spec.steps.compactMap(\.onError))
        let refused = perform { doc in
            var out = try WorkflowEdit.addStep(step, to: doc, inContainer: target.container, branch: target.branch)
            if let anchor, !handlerIDs.contains(anchor.id) { out = try WorkflowEdit.connect(from: anchor.id, to: step.id, in: out) }
            if !doc.spec.layout.isEmpty, target.container == nil {
                // Hand-placed graphs keep their layout: put the new node next to its anchor, or in the middle of the view.
                var p = viewport.toWorld(CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
                if let anchor, let f = geometry.frames[anchor.id] { p = CGPoint(x: f.maxX + WorkflowGraph.columnGap, y: f.minY) }
                out = try WorkflowEdit.moveNode(step.id, x: Double(CanvasGeometry.snap(p.x)), y: Double(CanvasGeometry.snap(p.y)), in: out)
            }
            return out
        }
        guard refused == nil else { return nil }
        selection = [step.id]
        reveal(step.id)
        return step.id
    }

    // MARK: Remove, duplicate, rename

    func removeSelection() {
        if let edgeID = selectedEdgeID, let edge = graph.edges.first(where: { $0.id == edgeID }) { deleteEdge(edge); return }
        guard !selection.isEmpty else { return }
        let stepIDs = selectedStepIDs
        let triggers = selection.compactMap { id -> Int? in id.hasPrefix("trigger:") ? Int(id.dropFirst("trigger:".count)) : nil }.sorted(by: >)
        let refused = perform { doc in
            var out = doc
            for id in stepIDs where out.step(id: id) != nil { out = try WorkflowEdit.removeStep(id, from: out) }
            if !triggers.isEmpty {
                for i in triggers where out.spec.triggers.indices.contains(i) { out.spec.triggers.remove(at: i) }
                // Trigger positions are keyed by index: stored ones no longer match.
                out.spec.layout = out.spec.layout.filter { !$0.key.hasPrefix("trigger:") }
            }
            return out
        }
        if refused == nil { selection = [] }
    }

    func duplicateSelection() {
        let ids = selectedStepIDs
        guard !ids.isEmpty, document != nil else { return }
        var created: [String] = []
        let refused = perform { doc in
            var out = doc
            for id in ids where doc.location(of: id).map({ loc in !loc.ancestors.contains(where: ids.contains) }) ?? false {
                let before = Set(out.allSteps.map(\.step.id))
                out = try WorkflowEdit.duplicateStep(id, in: out)
                let fresh = out.allSteps.map(\.step.id).filter { !before.contains($0) }
                if let top = fresh.first(where: { out.location(of: $0)?.scopeID == doc.location(of: id)?.scopeID }) {
                    created.append(top)
                    // Auto-placed originals have no stored position: offset the copy from where the original is drawn.
                    if doc.spec.layout[id] == nil, !doc.spec.layout.isEmpty, let n = graph.node(id) {
                        out = try WorkflowEdit.moveNode(top, x: n.x + 40, y: n.y + 40, in: out)
                    }
                }
            }
            return out
        }
        if refused == nil, !created.isEmpty { selection = Set(created) }
    }

    /// Renames a step id everywhere it is referenced. Returns the reason when refused.
    func rename(_ old: String, to new: String) -> String? {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard trimmed != old else { return nil }
        let wasSelected = selection.contains(old)
        let hadBreakpoint = breakpoints.contains(old)
        let refused = performValidated(step: trimmed) { try WorkflowEdit.renameStep(old, to: trimmed, in: $0) }
        if refused == nil {
            if wasSelected { selection.remove(old); selection.insert(trimmed) }
            if hadBreakpoint { breakpoints.insert(trimmed) }
        }
        return refused
    }

    // MARK: Connections

    /// Connects an output port to a node: `out` adds a dependency, branch ports add the target to that branch, `error`
    /// makes the target the error handler.
    func connect(from: String, port: String, to: String) {
        guard from != to else { return }
        if from.hasPrefix("trigger:") || to.hasPrefix("trigger:") {
            editMessage = String(localized: "Triggers start every step that needs nothing. Connect steps to each other instead.")
            return
        }
        perform { doc in
            switch port {
            case "out": return try WorkflowEdit.connect(from: from, to: to, in: doc)
            case "error": return try WorkflowEdit.setField(from, .onError(to), in: doc)
            default:
                guard let a = doc.location(of: from), let b = doc.location(of: to) else { throw WorkflowEditError.unknownStep(to) }
                guard a.scopeID == b.scopeID else { throw WorkflowEditError.differentScopes(from, to) }
                return try WorkflowEdit.updateStep(from, in: doc) { s in
                    switch s.kind {
                    case .condition(var c):
                        c.then.removeAll { $0 == to }; c.otherwise.removeAll { $0 == to }
                        if port == "then" { c.then.append(to) } else { c.otherwise.append(to) }
                        s.kind = .condition(c)
                    case .switch(var sw):
                        for i in sw.cases.indices { sw.cases[i].steps.removeAll { $0 == to } }
                        sw.defaultSteps.removeAll { $0 == to }
                        if port == "default" { sw.defaultSteps.append(to) }
                        else if let i = Int(port.dropFirst("case:".count)), sw.cases.indices.contains(i) { sw.cases[i].steps.append(to) }
                        s.kind = .switch(sw)
                    default: throw WorkflowEditError.invalid("Step '\(from)' has no '\(port)' output.")
                    }
                }
            }
        }
    }

    func deleteEdge(_ edge: WorkflowGraph.Edge) {
        switch edge.kind {
        case .trigger:
            editMessage = String(localized: "A trigger starts every step that needs nothing; this link cannot be removed. Give the step a dependency instead.")
        case .dependency:
            perform { try WorkflowEdit.disconnect(from: edge.from, to: edge.to, in: $0) }
        case .error:
            perform { try WorkflowEdit.setField(edge.from, .onError(nil), in: $0) }
        case .branch:
            perform { doc in
                try WorkflowEdit.updateStep(edge.from, in: doc) { s in
                    switch s.kind {
                    case .condition(var c):
                        if edge.fromPort == "then" { c.then.removeAll { $0 == edge.to } } else { c.otherwise.removeAll { $0 == edge.to } }
                        s.kind = .condition(c)
                    case .switch(var sw):
                        if edge.fromPort == "default" { sw.defaultSteps.removeAll { $0 == edge.to } }
                        else if let i = Int(edge.fromPort.dropFirst("case:".count)), sw.cases.indices.contains(i) { sw.cases[i].steps.removeAll { $0 == edge.to } }
                        s.kind = .switch(sw)
                    default: break
                    }
                }
            }
        }
        if editMessage == nil { selectedEdgeID = nil }
    }

    // MARK: Layout

    /// Stores the snapped positions of the dragged nodes as one undoable edit. Nested steps stay inside their container.
    func commitMove(_ ids: Set<String>, by translation: CGSize) {
        guard translation != .zero else { return }
        // A node whose container moves too follows it; storing both would move it twice.
        let movers = ids.filter { id in !geometry.ancestors(of: id).contains(where: ids.contains) }
        perform { doc in
            var out = doc
            for id in movers {
                guard let node = graph.node(id) else { continue }
                var x = CanvasGeometry.snap(CGFloat(node.x) + translation.width)
                var y = CanvasGeometry.snap(CGFloat(node.y) + translation.height)
                if node.parentID != nil { x = max(CanvasGeometry.grid, x); y = max(44, y) }
                out = try WorkflowEdit.moveNode(id, x: Double(x), y: Double(y), in: out)
            }
            return out
        }
    }

    /// Moves the selection by one grid step (Option + arrow keys).
    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard !selection.isEmpty else { return }
        commitMove(selection, by: CGSize(width: dx * CanvasGeometry.grid, height: dy * CanvasGeometry.grid))
    }

    func autoLayout() {
        perform { $0.applyingAutoLayout() }
        needsFit = true
        fitExactly = true
        if canvasSize.width > 0 { zoomToFit() }
    }

    // MARK: Grouping

    func groupSelectionIntoParallel() {
        let ids = selectedStepIDs
        guard let document, !ids.isEmpty else { return }
        let id = Palette.freshID("parallel", in: document)
        if perform({ try WorkflowEdit.groupIntoParallel(ids, containerID: id, in: $0) }) == nil { selection = [id] }
    }

    func wrapSelectionInForeach() {
        let ids = selectedStepIDs
        guard let document, !ids.isEmpty else { return }
        let id = Palette.freshID("each", in: document)
        if perform({ try WorkflowEdit.wrapInForeach(ids, containerID: id, items: "${{ [] }}", in: $0) }) == nil { selection = [id] }
    }

    // MARK: Inspector edits

    func setField(_ id: String, _ field: StepField) -> String? {
        performValidated(step: id) { try WorkflowEdit.setField(id, field, in: $0) }
    }

    func update(_ id: String, _ body: @escaping (inout WorkflowStep) throws -> Void) -> String? {
        performValidated(step: id) { try WorkflowEdit.updateStep(id, in: $0, body) }
    }

    /// Edits metadata, triggers, parameters, permissions or budget.
    func updateDocument(_ body: (inout WorkflowDocument) -> Void) -> String? {
        performValidated { doc in var out = doc; body(&out); return out }
    }

    /// Changes the tool of a tool step: arguments the new tool also accepts are kept, its required ones are stubbed.
    func setTool(_ id: String, to identifier: String) -> String? {
        guard let manifest = manifestByID[identifier] else { return String(localized: "This tool is not installed.") }
        return update(id) { s in
            guard case .tool(let t) = s.kind else { return }
            let allowed = Set(ArgumentForm.fields(of: manifest.inputSchema).map(\.name))
            var args = ArgumentForm.stub(for: manifest)
            for (k, v) in t.arguments where allowed.contains(k) {
                if let field = ArgumentForm.fields(of: manifest.inputSchema).first(where: { $0.name == k }), ArgumentForm.violation(v, field: field) == nil { args[k] = v }
            }
            s.kind = .tool(ToolStep(tool: identifier, arguments: args))
        }
    }

    /// Sets one tool argument from field text. Empty text removes an optional argument.
    func setArgument(_ id: String, field: SchemaField, text: String) -> String? {
        switch ArgumentForm.parse(text, field: field) {
        case .failure(let e): return e.message
        case .success(let value):
            if value == nil && field.required {
                if case .string = field.kind { return setField(id, .toolArgument(field.name, .string(""))) }
                return String(localized: "This argument is required.")
            }
            return setField(id, .toolArgument(field.name, value))
        }
    }

    /// Steps of the same list as `id`, for `needs`, branch lists and `onError` pickers.
    func siblings(of id: String) -> [String] {
        guard let document, let loc = document.location(of: id) else { return [] }
        return document.allSteps.filter { $0.scopeID == loc.scopeID && $0.step.id != id }.map(\.step.id)
    }

    func toggleBreakpoint(_ id: String) {
        guard !id.hasPrefix("trigger:") else { return }
        if breakpoints.contains(id) { breakpoints.remove(id) } else { breakpoints.insert(id) }
        let on = breakpoints.contains(id)
        if let handle = runHandle { Task { if on { await handle.addBreakpoint(id) } else { await handle.removeBreakpoint(id) } } }
    }
}
