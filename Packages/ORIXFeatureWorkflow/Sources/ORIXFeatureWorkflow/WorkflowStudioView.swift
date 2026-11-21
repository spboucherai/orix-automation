// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/WorkflowStudioView.swift
// Description      : Root of the Workflow Studio: library, toolbar, canvas,
//                    validation strip, run drawer and inspector, plus the
//                    version history, the rewrite warning and "create from
//                    description".
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

import AppKit
import ORIXAppUI
import SwiftUI

/// Picks one of two localized strings (a bare `cond ? "a" : "b"` would be read as plain, untranslated text).
/// "just now" for the first minute, a short relative time afterwards.
func relativeOrNow(_ date: Date) -> String {
    abs(date.timeIntervalSinceNow) < 60 ? String(localized: "just now") : Format.relative(date)
}

func loc(_ condition: Bool, _ yes: LocalizedStringKey, _ no: LocalizedStringKey) -> LocalizedStringKey { condition ? yes : no }

/// The visual view of the workflow model. Reads the app model from the environment.
public struct WorkflowStudioView: View {
    @Environment(AppModel.self) private var model
    @State private var vm: WorkflowStudioModel?

    public init() {}

    public var body: some View {
        Group {
            if let vm { StudioContent(vm: vm) } else { Color.clear }
        }
        .task {
            if vm == nil { vm = WorkflowStudioModel(app: model) }
        }
    }
}

/// The studio around an existing view model (also used by the screenshot harness and the tests).
struct StudioContent: View {
    @Bindable var vm: WorkflowStudioModel
    @State private var showLibrary = true
    @State private var showInspector = true

    var body: some View {
        HStack(spacing: 0) {
            if showLibrary {
                LibraryPane(vm: vm).frame(width: 228)
                Divider()
            }
            centre.frame(maxWidth: .infinity, maxHeight: .infinity)
            if showInspector, vm.document != nil {
                Divider()
                InspectorPane(vm: vm).frame(width: 304)
            }
        }
        .background(Theme.canvas)
        .task(id: vm.app.revision) { await vm.reload(selected: vm.app.selectedWorkflowID) }
        .onChange(of: vm.app.selectedWorkflowID) { _, new in
            if let new, new != vm.workflowID { Task { await vm.open(new) } }
        }
        .onChange(of: vm.app.selectedRunID) { _, new in
            if let new, new != vm.activeRunID { Task { if let r = try? await vm.services.store.run(id: new), r.workflowID == vm.workflowID { await vm.attach(runID: new) } } }
        }
        .sheet(isPresented: $vm.showTemplates) { TemplateGallery(vm: vm) }
        .sheet(isPresented: $vm.showGenerate) { GenerateSheet(vm: vm) }
        .sheet(isPresented: $vm.showLossConfirmation) { LossSheet(vm: vm) }
        .sheet(isPresented: Binding(get: { vm.runRequest != nil }, set: { if !$0 { vm.runRequest = nil } })) {
            if let kind = vm.runRequest { PermissionReviewSheet(vm: vm, kind: kind) }
        }
    }

    @ViewBuilder private var centre: some View {
        if let error = vm.loadError {
            VStack(spacing: Theme.Space.m) {
                EmptyState(symbol: "exclamationmark.triangle", title: "This workflow cannot be shown as a graph", message: "Its stored source has errors. Open it in Code Studio to fix them.",
                           actionTitle: "Open in Code Studio") { if let id = vm.workflowID { vm.app.open(.workflowCode(id)) } }
                Banner(kind: .error, text: error).frame(maxWidth: 560).padding(.bottom, Theme.Space.xl)
            }
        } else if vm.document == nil {
            if vm.libraryLoaded {
                EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "Build an automation as a graph",
                           message: "Pick a template, start blank, or describe what you want and review the draft.",
                           actionTitle: "Browse templates") { vm.showTemplates = true }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                StudioToolbar(vm: vm, showLibrary: $showLibrary, showInspector: $showInspector)
                Divider()
                if vm.newerVersionAvailable {
                    Banner(kind: .warning, text: String(localized: "A newer version of this workflow was saved elsewhere (Code Studio or another window). Saving here would put your edits on top of it."),
                           actionTitle: "Discard my edits and reload") { Task { await vm.revert() } }
                        .padding(Theme.Space.s)
                }
                WorkflowCanvasView(vm: vm)
                Divider()
                ValidationStrip(vm: vm)
                if vm.showDrawer, let runID = vm.activeRunID {
                    Divider()
                    RunDrawer(vm: vm, runID: runID).frame(height: 230).id(runID)
                }
            }
        }
    }
}

// MARK: - Toolbar

struct StudioToolbar: View {
    @Bindable var vm: WorkflowStudioModel
    @Binding var showLibrary: Bool
    @Binding var showInspector: Bool

    /// ⌘Z, ⌘A and ⌘D belong to the text field while one is being edited.
    private func unlessEditingText(_ selector: Selector?, _ action: () -> Void) {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            if let selector { text.doCommand(by: selector) }
            return
        }
        action()
    }

    private var compact: Bool { vm.canvasSize.width > 0 && vm.canvasSize.width < 760 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                icon("sidebar.left", "Show or hide the library") { showLibrary.toggle() }
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: vm.document?.metadata.name ?? "").font(Theme.Font.heading).foregroundStyle(Theme.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Text("Version \(vm.loadedVersion)").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        if vm.isDirty {
                            Label("Unsaved changes", systemImage: "circle.fill").labelStyle(DotLabelStyle()).font(Theme.Font.captionStrong).foregroundStyle(Theme.warning)
                                .accessibilityIdentifier("workflow.unsaved")
                        }
                    }
                }
                .layoutPriority(-1)
                Spacer(minLength: Theme.Space.s)
                if vm.isSaving { ProgressView().controlSize(.small) }
                Button { Task { await vm.save() } } label: { Label("Save", systemImage: "square.and.arrow.down").lineLimit(1).fixedSize() }
                    .buttonStyle(SecondaryButtonStyle()).disabled(!vm.canSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .help(Text(loc(vm.errors.isEmpty, "Save a new version", "Fix the errors before saving")))
                    .accessibilityIdentifier("workflow.save")
                Button { vm.showHistory.toggle() } label: { Label("History", systemImage: "clock.arrow.circlepath").lineLimit(1).fixedSize() }
                    .buttonStyle(SecondaryButtonStyle())
                    .popover(isPresented: $vm.showHistory, arrowEdge: .bottom) { HistoryPopover(vm: vm) }
                    .accessibilityIdentifier("workflow.history")
                Menu {
                    Button { if let id = vm.workflowID { vm.app.open(.workflowCode(id)) } } label: { Label("Open in Code Studio", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Button { vm.app.open(.section(.scheduler)) } label: { Label("Schedule…", systemImage: "calendar.badge.clock") }
                    Divider()
                    Button { vm.showGenerate = true } label: { Label("Create from description…", systemImage: "sparkles") }
                    if vm.isDirty { Button(role: .destructive) { Task { await vm.revert() } } label: { Label("Discard unsaved changes", systemImage: "arrow.uturn.backward") } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(Text("More actions")).accessibilityIdentifier("workflow.more")
                icon("sidebar.right", "Show or hide the inspector") { showInspector.toggle() }
            }
            HStack(spacing: 4) {
                icon("arrow.uturn.backward", "Undo") { unlessEditingText(Selector(("undo:"))) { vm.undo() } }.disabled(!vm.canUndo)
                    .keyboardShortcut("z", modifiers: .command).accessibilityIdentifier("workflow.undo")
                icon("arrow.uturn.forward", "Redo") { unlessEditingText(Selector(("redo:"))) { vm.redo() } }.disabled(!vm.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift]).accessibilityIdentifier("workflow.redo")
                Divider().frame(height: 16)
                Button { vm.showPalette.toggle() } label: { Label("Add", systemImage: "plus").lineLimit(1).fixedSize() }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.violet))
                    .popover(isPresented: $vm.showPalette, arrowEdge: .bottom) { PaletteView(vm: vm) }
                    .help(Text("Add a step, a tool or an agent")).accessibilityIdentifier("workflow.add")
                icon("plus.square.on.square", "Duplicate the selected steps") { unlessEditingText(nil) { vm.duplicateSelection() } }.disabled(vm.selectedStepIDs.isEmpty)
                    .keyboardShortcut("d", modifiers: .command).accessibilityIdentifier("workflow.duplicate")
                icon("trash", "Delete the selection") { vm.removeSelection() }.disabled(vm.selection.isEmpty && vm.selectedEdgeID == nil)
                    .accessibilityIdentifier("workflow.delete")
                Menu {
                    Button("Group into parallel") { vm.groupSelectionIntoParallel() }
                    Button("Wrap in for each") { vm.wrapSelectionInForeach() }
                } label: { Image(systemName: "square.on.square.dashed") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(vm.selectedStepIDs.isEmpty)
                .help(Text("Group the selected steps")).accessibilityLabel(Text("Group the selected steps")).accessibilityIdentifier("workflow.group")
                icon("wand.and.stars", "Tidy up the layout") { vm.autoLayout() }.accessibilityIdentifier("workflow.autolayout")
                // ⌘A is offered here so it works without clicking the canvas first.
                Button { unlessEditingText(#selector(NSText.selectAll(_:))) { vm.selectAll() } } label: { EmptyView() }
                    .keyboardShortcut("a", modifiers: .command).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Spacer(minLength: Theme.Space.s)
                RunControls(vm: vm, compact: compact)
                if vm.activeRunID != nil {
                    icon(vm.showDrawer ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomthird.inset.filled", "Show or hide the run panel") { vm.showDrawer.toggle() }
                        .foregroundStyle(vm.showDrawer ? Theme.violet : Theme.textSecondary).accessibilityIdentifier("workflow.drawer.toggle")
                }
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .background(Theme.surface)
    }

    private func icon(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 26, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            .help(Text(label)).accessibilityLabel(Text(label))
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.font(.system(size: 6)); configuration.title }
    }
}

// MARK: - Inspector container

struct InspectorPane: View {
    @Bindable var vm: WorkflowStudioModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Theme.Font.heading).foregroundStyle(Theme.text)
                Spacer()
                if vm.inspectedStep != nil {
                    Button { vm.clearSelection() } label: { Text("Workflow settings") }.buttonStyle(.link).font(Theme.Font.caption)
                        .accessibilityIdentifier("workflow.inspector.showSettings")
                }
            }
            .padding(Theme.Space.m)
            Divider()
            ScrollView {
                Group {
                    if let loc = vm.inspectedStep {
                        StepInspector(vm: vm, location: loc).id(loc.step.id)
                    } else if vm.selection.count > 1 {
                        multi
                    } else if let edge = vm.graph.edges.first(where: { $0.id == vm.selectedEdgeID }) {
                        edgeInfo(edge)
                    } else if let doc = vm.document {
                        WorkflowSettingsPane(vm: vm, document: doc).id(doc.metadata.id)
                    }
                }
                .padding(Theme.Space.m)
            }
        }
        .background(Theme.surfaceRaised)
        .accessibilityIdentifier("workflow.inspector")
    }

    private var title: LocalizedStringKey {
        if vm.inspectedStep != nil { return "Step" }
        if vm.selection.count > 1 { return "Selection" }
        if vm.selectedEdgeID != nil { return "Connection" }
        return "Workflow settings"
    }

    private var multi: some View {
        InspectorSection(title: "Selection") {
            Text("\(vm.selection.count) nodes selected").font(Theme.Font.body).foregroundStyle(Theme.text)
            Button { vm.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.buttonStyle(.borderless).disabled(vm.selectedStepIDs.isEmpty)
            Button { vm.groupSelectionIntoParallel() } label: { Label("Group into parallel", systemImage: "rectangle.split.3x1") }.buttonStyle(.borderless).disabled(vm.selectedStepIDs.isEmpty)
            Button { vm.wrapSelectionInForeach() } label: { Label("Wrap in for each", systemImage: "repeat") }.buttonStyle(.borderless).disabled(vm.selectedStepIDs.isEmpty)
            Button(role: .destructive) { vm.removeSelection() } label: { Label("Delete", systemImage: "trash") }.buttonStyle(.borderless)
        }
    }

    private func edgeInfo(_ e: WorkflowGraph.Edge) -> some View {
        InspectorSection(title: "Connection") {
            KeyValueRow(key: "From", value: e.from, mono: true)
            KeyValueRow(key: "To", value: e.to, mono: true)
            Text(kindText(e)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if e.kind != .trigger {
                Button(role: .destructive) { vm.deleteEdge(e) } label: { Label("Remove connection", systemImage: "trash") }.buttonStyle(.borderless)
                    .accessibilityIdentifier("workflow.inspector.removeEdge")
            }
        }
    }

    private func kindText(_ e: WorkflowGraph.Edge) -> LocalizedStringKey {
        switch e.kind {
        case .dependency: return "The second step waits for the first one to finish."
        case .branch: return "The second step runs only on the “\(e.label)” branch."
        case .error: return "The second step runs only when the first one fails."
        case .trigger: return "A trigger starts every step that needs nothing."
        }
    }
}

// MARK: - Validation strip

struct ValidationStrip: View {
    @Bindable var vm: WorkflowStudioModel
    @State private var expanded = false

    var body: some View {
        let errors = vm.errors, warnings = vm.warnings
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: Theme.Space.m) {
                        if errors.isEmpty && warnings.isEmpty {
                            Label("No problem found", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        } else {
                            Label("\(errors.count) errors", systemImage: "xmark.octagon.fill").foregroundStyle(errors.isEmpty ? Theme.textTertiary : Theme.danger)
                            Label("\(warnings.count) warnings", systemImage: "exclamationmark.triangle.fill").foregroundStyle(warnings.isEmpty ? Theme.textTertiary : Theme.warning)
                        }
                        if !(errors.isEmpty && warnings.isEmpty) { Image(systemName: expanded ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary) }
                    }
                    .font(Theme.Font.captionStrong)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(errors.isEmpty && warnings.isEmpty)
                .accessibilityIdentifier("workflow.validation.summary")
                if let m = vm.editMessage {
                    Label { Text(verbatim: m).lineLimit(2) } icon: { Image(systemName: "hand.raised.fill") }
                        .font(Theme.Font.caption).foregroundStyle(Theme.warning)
                        .accessibilityIdentifier("workflow.validation.refused")
                    Button { vm.editMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary).accessibilityLabel(Text("Dismiss"))
                } else if let first = errors.first ?? warnings.first, !expanded {
                    Button { if let id = first.stepID { vm.focus(step: id) } } label: {
                        Text(verbatim: (first.stepID.map { "\($0): " } ?? "") + first.message).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Text("\(vm.graph.nodes.count) nodes · \(vm.graph.edges.count) connections").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
            if expanded, !(errors.isEmpty && warnings.isEmpty) {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array((errors + warnings).enumerated()), id: \.offset) { _, d in
                            Button { if let id = d.stepID { vm.focus(step: id) } } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: d.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill").foregroundStyle(d.severity == .error ? Theme.danger : Theme.warning)
                                    if let id = d.stepID { Text(verbatim: id).font(Theme.Font.monoSmall).foregroundStyle(Theme.violet) }
                                    Text(verbatim: d.message).font(Theme.Font.caption).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Theme.Space.m).padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text(loc(d.stepID == nil, "", "Selects the step")))
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
        .background(Theme.surface)
    }
}

// MARK: - Rewrite warning

/// Shown before the first visual save of a workflow whose stored text holds things the model does not keep.
struct LossSheet: View {
    @Bindable var vm: WorkflowStudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label("Saving from the graph rewrites the code", systemImage: "exclamationmark.triangle.fill").font(Theme.Font.title).foregroundStyle(Theme.text)
            Text("The workflow keeps working the same way, but the stored text is written again from the model. This is what will be dropped or changed:")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(vm.lossNotes.enumerated()), id: \.offset) { _, note in
                    Label { Text(verbatim: note).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) } icon: { Image(systemName: "minus.circle.fill").foregroundStyle(Theme.warning) }
                }
            }
            .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .accessibilityIdentifier("workflow.loss.notes")
            Text("The current text stays in the version history, so you can restore it.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            HStack {
                Button("Cancel") { vm.showLossConfirmation = false }.keyboardShortcut(.cancelAction)
                Button { vm.showLossConfirmation = false; if let id = vm.workflowID { vm.app.open(.workflowCode(id)) } } label: { Text("Edit in Code Studio instead") }
                Spacer()
                Button { vm.showLossConfirmation = false; Task { await vm.save(confirmedLoss: true) } } label: { Text("Rewrite and save") }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).accessibilityIdentifier("workflow.loss.confirm")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .background(Theme.canvas)
    }
}

// MARK: - Version history

struct HistoryPopover: View {
    @Bindable var vm: WorkflowStudioModel
    @State private var versions: [WorkflowVersionRow] = []
    @State private var selected: WorkflowVersionRow?
    @State private var confirmRestore: WorkflowVersionRow?
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Versions").font(Theme.Font.heading).padding(Theme.Space.m)
                Divider()
                if !loaded { SkeletonLine(width: 160).padding(Theme.Space.m); Spacer() }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(versions) { v in
                                Button { selected = v } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text("Version \(v.version)").font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                                            if v.version == vm.loadedVersion { Pill(text: String(localized: "current"), color: Theme.violet) }
                                        }
                                        Text(verbatim: Format.dateTime(v.createdAt)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                                        if !v.note.isEmpty { Text(verbatim: v.note).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2).multilineTextAlignment(.leading) }
                                    }
                                    .padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected?.id == v.id ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("workflow.history.version.\(v.version)")
                            }
                        }
                        .padding(Theme.Space.s)
                    }
                }
            }
            .frame(width: 230)
            Divider()
            detail.frame(width: 380)
        }
        .frame(height: 420)
        .background(Theme.surfaceRaised)
        .task {
            versions = await vm.versions()
            selected = versions.first { $0.version != vm.loadedVersion } ?? versions.first
            loaded = true
        }
        .confirmationDialog(Text("Restore version \(confirmRestore?.version ?? 0)?"), isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }), titleVisibility: .visible) {
            Button("Restore as a new version") {
                if let v = confirmRestore { Task { if await vm.restore(v) { vm.showHistory = false } } }
                confirmRestore = nil
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text(loc(vm.isDirty, "The chosen version is saved again as the newest one. Your unsaved changes in the editor are discarded; every saved version stays in the history.",
                     "The chosen version is saved again as the newest one. Every saved version stays in the history."))
        }
    }

    @ViewBuilder private var detail: some View {
        if let v = selected {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("From version \(v.version) to what is open now").font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                switch vm.changes(since: v) {
                case .failure(let e): Banner(kind: .error, text: e.message)
                case .success(let changes):
                    if changes.isEmpty {
                        Text("No difference.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(changes.enumerated()), id: \.offset) { _, c in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: c.isSecurityRelevant ? "lock.trianglebadge.exclamationmark.fill" : "circle.fill")
                                            .font(.system(size: c.isSecurityRelevant ? 11 : 5)).foregroundStyle(c.isSecurityRelevant ? Theme.warning : Theme.textTertiary).frame(width: 14)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(verbatim: c.summary).font(Theme.Font.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                            if c.isSecurityRelevant { Text("Changes what the workflow is allowed to do").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.warning) }
                                        }
                                    }
                                    .padding(c.isSecurityRelevant ? 6 : 0)
                                    .background(c.isSecurityRelevant ? Theme.warning.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    if vm.isBusy { ProgressView().controlSize(.small) }
                    Button { confirmRestore = v } label: { Text("Restore this version…") }
                        .buttonStyle(SecondaryButtonStyle()).disabled(vm.isBusy || (v.version == vm.loadedVersion && !vm.isDirty))
                        .accessibilityIdentifier("workflow.history.restore")
                }
            }
            .padding(Theme.Space.m)
        } else {
            Text("Choose a version to compare.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Create from description

struct GenerateSheet: View {
    @Bindable var vm: WorkflowStudioModel
    @State private var objective = ""
    @State private var working = false
    @State private var failure: String?
    @State private var needsModel = false
    @State private var draft: (source: String, document: WorkflowDocument?, diagnostics: [WorkflowDiagnostic], usage: TokenUsage)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create from description").font(Theme.Font.title).foregroundStyle(Theme.text)
                Text("A model writes a draft. Nothing is saved or run until you accept it.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Space.l)
            Divider()
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                TextField(String(localized: "For example: every weekday at 9, list the PDFs added to ~/Documents/Inbox and write a summary to ~/Documents/Reports"), text: $objective, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.Font.body).lineLimit(3...5).disabled(working)
                    .padding(8).background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.strokeStrong))
                    .accessibilityIdentifier("workflow.generate.prompt")
                HStack {
                    if working { ProgressView().controlSize(.small); Text("Writing the draft…").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                    Spacer()
                    Button { generate() } label: { Label(loc(draft == nil, "Write a draft", "Write another draft"), systemImage: "sparkles") }
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.violet)).disabled(working || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("workflow.generate.go")
                }
                if let failure {
                    if needsModel {
                        Banner(kind: .error, text: failure, actionTitle: "Open Settings") { vm.showGenerate = false; vm.app.open(.section(.settings)) }
                            .accessibilityIdentifier("workflow.generate.noModel")
                    } else {
                        Banner(kind: .error, text: failure)
                    }
                }
                if let draft { preview(draft) } else if failure == nil && !working {
                    Text("The draft's graph, what the validator says about it and the tokens it cost appear here.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.l)
            Divider()
            HStack {
                Button("Cancel") { vm.showGenerate = false }.keyboardShortcut(.cancelAction)
                Spacer()
                let hasErrors = draft?.diagnostics.contains { $0.severity == .error } ?? true
                Button { accept() } label: { Text("Save as a workflow") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(draft == nil || hasErrors || working || vm.isBusy)
                    .help(Text(loc(hasErrors && draft != nil, "The draft has errors and cannot be saved. Write another draft or adjust the description.", "Save the draft and open it")))
                    .accessibilityIdentifier("workflow.generate.accept")
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 720, height: 640)
        .background(Theme.canvas)
    }

    @ViewBuilder private func preview(_ d: (source: String, document: WorkflowDocument?, diagnostics: [WorkflowDiagnostic], usage: TokenUsage)) -> some View {
        let errors = d.diagnostics.filter { $0.severity == .error }, warnings = d.diagnostics.filter { $0.severity == .warning }
        HStack(spacing: Theme.Space.s) {
            if let doc = d.document { Text(verbatim: doc.metadata.name).font(Theme.Font.heading).foregroundStyle(Theme.text).lineLimit(1) }
            Spacer()
            Pill(text: String(localized: "\(errors.count) errors"), symbol: "xmark.octagon", color: errors.isEmpty ? Theme.textTertiary : Theme.danger)
            Pill(text: String(localized: "\(warnings.count) warnings"), symbol: "exclamationmark.triangle", color: warnings.isEmpty ? Theme.textTertiary : Theme.warning)
            Pill(text: String(localized: "\(Format.tokens(d.usage.inputTokens)) in · \(Format.tokens(d.usage.outputTokens)) out tokens"), symbol: "gauge.with.dots.needle.50percent")
        }
        if let doc = d.document {
            GraphPreview(document: doc).frame(maxWidth: .infinity).frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
        } else {
            Banner(kind: .error, text: String(localized: "The draft is not a valid workflow, so there is no graph to show."))
        }
        if !d.diagnostics.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array((errors + warnings).enumerated()), id: \.offset) { _, x in
                        Label { Text(verbatim: (x.stepID.map { "\($0): " } ?? "") + x.message).font(Theme.Font.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true) } icon: {
                            Image(systemName: x.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill").foregroundStyle(x.severity == .error ? Theme.danger : Theme.warning)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
        }
    }

    private func generate() {
        working = true; failure = nil; needsModel = false
        let text = objective
        Task {
            do {
                let r = try await vm.services.workflows.generate(objective: text)
                let doc = try? WorkflowCodec.parse(r.source, format: WorkflowCodec.detectFormat(r.source))
                draft = (r.source, doc, r.diagnostics, r.usage)
            } catch {
                if case RunError.noModel = error { needsModel = true }
                failure = Redactor.shared.redact(WorkflowStudioModel.message(error))
            }
            working = false
        }
    }

    private func accept() {
        guard let draft else { return }
        Task { if await vm.saveNew(draft.source, note: "Created from a description") { vm.showGenerate = false } }
    }
}
