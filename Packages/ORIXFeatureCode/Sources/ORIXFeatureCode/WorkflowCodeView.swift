// ORIX OS Automation
// File: Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/WorkflowCodeView.swift
// Description: The workflow code tab: the list of stored workflows, the editor with its toolbar and status line, the problems list and the console.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

struct WorkflowCodeView: View {
    @Environment(AppModel.self) private var model
    let studio: CodeStudioModel
    /// What the user asked to open while the buffer has unsaved changes.
    @State private var pendingOpen: PendingOpen?
    @State private var showGoToLine = false
    @State private var goToLineText = ""
    @State private var showCompare = false
    @State private var compareFrom = 0
    @State private var compareTo = 0

    enum PendingOpen: Equatable { case workflow(String), new(String), reload }

    private var workflow: WorkflowCodeModel { studio.workflow }

    // MARK: Opening

    private func request(_ target: PendingOpen) {
        if case .workflow(let id) = target, id == workflow.openID { return }
        if workflow.isDirty { pendingOpen = target } else { perform(target) }
    }

    private func perform(_ target: PendingOpen) {
        switch target {
        case .workflow(let id):
            model.selectedWorkflowID = id
            Task { await workflow.open(id, services: model.services) }
        case .new(let source):
            model.selectedWorkflowID = nil
            workflow.startNew(source: source)
            Task { await workflow.validateNow() }
        case .reload:
            if let id = workflow.openID { Task { await workflow.open(id, services: model.services) } }
        }
    }

    private func followSelection() {
        guard workflow.hasLoaded, let id = model.selectedWorkflowID, id != workflow.openID, pendingOpen == nil else { return }
        guard workflow.workflows.contains(where: { $0.id == id }) else { return }
        request(.workflow(id))
    }

    private func save() {
        Task {
            if let saved = await workflow.save() {
                model.selectedWorkflowID = saved.id
                studio.console.note("Saved \(saved.id) as version \(saved.version)" + (saved.permissionsReset ? " — declared permissions changed, acceptance withdrawn" : ""))
            } else {
                studio.bottomTab = .problems
            }
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            sidebar.frame(width: 210)
            VStack(spacing: Theme.Space.m) {
                if workflow.openID == nil && workflow.text.isEmpty {
                    Panel {
                        EmptyState(symbol: "chevron.left.forwardslash.chevron.right", title: "No workflow is open",
                                   message: workflow.workflows.isEmpty ? "Start a workflow here: it is saved with a version history and opens in the Workflow Studio too."
                                                                       : "Choose a workflow on the left, or start a new one.",
                                   actionTitle: "New workflow") { request(.new(WorkflowSnippets.starter)) }
                    }
                } else {
                    editorPanel
                    bottomPanel.frame(height: 190)
                }
            }
        }
        .onChange(of: model.selectedWorkflowID) { _, _ in followSelection() }
        .onChange(of: workflow.hasLoaded) { _, _ in followSelection() }
        .onChange(of: workflow.workflows) { _, _ in followSelection() }
        .onAppear {
            workflow.editor.onGoToLineRequest = { showGoToLine = true }
            followSelection()
        }
        .confirmationDialog(Text("Discard the unsaved changes to \(workflow.title)?"), isPresented: Binding(get: { pendingOpen != nil }, set: { if !$0 { cancelPending() } }),
                            titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { if let p = pendingOpen { pendingOpen = nil; perform(p) } }
            Button("Keep editing", role: .cancel) { cancelPending() }
        } message: {
            Text("The text in the editor was not saved. Discarding it cannot be undone.")
        }
    }

    private func cancelPending() {
        pendingOpen = nil
        // The editor keeps its workflow: put the shared selection back on it.
        if model.selectedWorkflowID != workflow.openID { model.selectedWorkflowID = workflow.openID }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Workflows").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Menu {
                        Button("Blank workflow") { request(.new(WorkflowSnippets.starter)) }
                        Section("From a built-in example") {
                            ForEach(BuiltInWorkflows.all()) { b in Button(b.title) { request(.new(b.yaml)) } }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(Text("New workflow")).accessibilityLabel(Text("New workflow")).accessibilityIdentifier("code.workflow.new")
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                Divider()
                if workflow.workflows.isEmpty {
                    Text(workflow.hasLoaded ? "No workflow is saved yet." : "Loading…").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        .padding(Theme.Space.m).frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(workflow.workflows) { row in
                                let selected = row.id == workflow.openID
                                Button { request(.workflow(row.id)) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(verbatim: row.name).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                                            if selected && workflow.isDirty {
                                                Circle().fill(Theme.warning).frame(width: 6, height: 6).accessibilityLabel(Text("Unsaved changes"))
                                            }
                                        }
                                        HStack(spacing: 5) {
                                            Text(verbatim: row.id).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 0)
                                            Text(verbatim: "v\(row.currentVersion)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected ? .isSelected : [])
                                .accessibilityIdentifier("code.workflow.row.\(row.id)")
                            }
                        }
                        .padding(6)
                    }
                }
            }
        }
    }

    // MARK: Editor

    private var editorPanel: some View {
        @Bindable var workflow = studio.workflow
        return Panel {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let notice = workflow.notice {
                    Banner(kind: notice.kind, text: notice.text, actionTitle: "Dismiss") { studio.workflow.notice = nil }
                        .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.s)
                }
                if let newer = workflow.staleNotice {
                    Banner(kind: .warning, text: String(localized: "Version \(newer) of this workflow was saved elsewhere while you were editing. Saving here creates a newer version on top of it."),
                           actionTitle: "Load version \(newer)") { pendingOpen = .reload }
                        .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.s)
                }
                CodeEditor(text: $workflow.text, language: workflow.format == .json ? .json : .yaml, diagnostics: workflow.diagnostics,
                           hovers: workflow.hovers, controller: workflow.editor)
                    .padding(Theme.Space.s)
                    .overlay(alignment: .topTrailing) {
                        if let doc = studio.toolDoc { ToolDocCard(manifest: doc) { studio.toolDoc = nil }.padding(Theme.Space.l) }
                    }
                Divider()
                statusLine
            }
        }
    }

    private var toolbar: some View {
        @Bindable var studio = studio
        return HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: workflow.title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                    if workflow.isDirty { Pill(text: String(localized: "Unsaved"), symbol: "circle.fill", color: Theme.warning).accessibilityIdentifier("code.workflow.unsaved") }
                }
                Text(verbatim: workflow.openID.map { "\($0) · v\(workflow.storedVersion)" } ?? String(localized: "Not saved yet"))
                    .font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: 0) {
                IconButton(symbol: "arrow.uturn.backward", label: "Undo", identifier: "code.workflow.undo") { workflow.editor.undo() }
                IconButton(symbol: "arrow.uturn.forward", label: "Redo", identifier: "code.workflow.redo") { workflow.editor.redo() }
                IconButton(symbol: "magnifyingglass", label: "Find and replace", identifier: "code.workflow.find") { workflow.editor.showFind(replace: true) }
                Button { showGoToLine = true } label: { Image(systemName: "arrow.right.to.line").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22) }
                    .buttonStyle(.borderless).keyboardShortcut("l", modifiers: .command).help(Text("Go to line")).accessibilityLabel(Text("Go to line"))
                    .accessibilityIdentifier("code.workflow.gotoline")
                    .popover(isPresented: $showGoToLine, arrowEdge: .bottom) { goToLinePopover }
                Button { workflow.editor.toggleComment() } label: { Image(systemName: "number").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22) }
                    .buttonStyle(.borderless).keyboardShortcut("/", modifiers: .command).help(Text("Comment or uncomment the selected lines"))
                    .accessibilityLabel(Text("Comment or uncomment the selected lines")).disabled(workflow.format == .json)
                Button { studio.requestFormat() } label: { Image(systemName: "text.alignleft").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22) }
                    .buttonStyle(.borderless).keyboardShortcut("f", modifiers: [.command, .shift]).help(Text("Format the source"))
                    .accessibilityLabel(Text("Format the source")).accessibilityIdentifier("code.workflow.format")
                snippetMenu
                compareMenu
                if let id = workflow.openID {
                    IconButton(symbol: "point.3.connected.trianglepath.dotted", label: "Open in Workflow Studio", identifier: "code.workflow.openVisual") { model.open(.workflow(id)) }
                }
            }
            .fixedSize().layoutPriority(2)
            Picker("Format", selection: Binding(get: { workflow.format }, set: { new in if new != workflow.format { studio.requestFormat(as: new) } })) {
                Text(verbatim: "YAML").tag(WorkflowFormat.yaml)
                Text(verbatim: "JSON").tag(WorkflowFormat.json)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().layoutPriority(2).accessibilityIdentifier("code.workflow.formatPicker")
            Button(action: save) {
                HStack(spacing: 5) {
                    if workflow.isSaving { ProgressView().controlSize(.small) }
                    Text("Save").lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(PrimaryButtonStyle()).fixedSize().layoutPriority(2).keyboardShortcut("s", modifiers: .command)
            .disabled(!workflow.isDirty || workflow.isSaving)
            .accessibilityIdentifier("code.workflow.save")
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
    }

    private var goToLinePopover: some View {
        HStack(spacing: Theme.Space.s) {
            TextField(String(localized: "Line number"), text: $goToLineText).textFieldStyle(.roundedBorder).frame(width: 110)
                .onSubmit(goToLine).accessibilityIdentifier("code.workflow.gotoline.field")
            Button("Go", action: goToLine).keyboardShortcut(.defaultAction).disabled(Int(goToLineText.trimmingCharacters(in: .whitespaces)) == nil)
        }
        .padding(Theme.Space.m)
    }

    private func goToLine() {
        guard let line = Int(goToLineText.trimmingCharacters(in: .whitespaces)) else { return }
        showGoToLine = false
        workflow.editor.goTo(line: line)
    }

    private var snippetMenu: some View {
        Menu {
            Section("Steps") { ForEach(WorkflowSnippets.stepKinds) { s in Button(s.title) { workflow.editor.insertSnippet(s.body + "\n") } } }
            Section("Patterns") { ForEach(WorkflowSnippets.patterns) { s in Button(s.title) { workflow.editor.insertSnippet(s.body + "\n") } } }
        } label: { Image(systemName: "curlybraces.square").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(workflow.format == .json)
        .help(Text(workflow.format == .json ? "Snippets are written in YAML: switch the format to insert them" : "Insert a snippet at the cursor"))
        .accessibilityLabel(Text("Insert a snippet at the cursor")).accessibilityIdentifier("code.workflow.snippets")
    }

    private var compareMenu: some View {
        Menu {
            Button("Unsaved changes with the stored version") { studio.diff = workflow.unsavedDiff() }.disabled(!workflow.isDirty)
            Button("Two stored versions…") {
                let all = workflow.versions.map(\.version).sorted()
                compareTo = all.last ?? 0
                compareFrom = all.dropLast().last ?? compareTo
                showCompare = true
            }
            .disabled(workflow.versions.count < 2)
        } label: { Image(systemName: "plus.forwardslash.minus").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(Text("Compare")).accessibilityLabel(Text("Compare")).accessibilityIdentifier("code.workflow.compare")
        .popover(isPresented: $showCompare, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Compare two versions").font(Theme.Font.heading)
                let all = workflow.versions.sorted { $0.version > $1.version }
                Picker("From", selection: $compareFrom) { ForEach(all) { v in Text(versionLabel(v)).tag(v.version) } }
                Picker("To", selection: $compareTo) { ForEach(all) { v in Text(versionLabel(v)).tag(v.version) } }
                HStack {
                    Spacer()
                    Button("Show differences") {
                        showCompare = false
                        studio.diff = workflow.versionDiff(from: compareFrom, to: compareTo)
                    }
                    .keyboardShortcut(.defaultAction).disabled(compareFrom == compareTo)
                }
            }
            .padding(Theme.Space.l).frame(width: 340)
        }
    }

    private func versionLabel(_ v: WorkflowVersionRow) -> String {
        "v\(v.version) · \(Format.dateTime(v.createdAt))" + (v.note.isEmpty ? "" : " · \(v.note)")
    }

    private var statusLine: some View {
        HStack(spacing: Theme.Space.m) {
            Text("Line \(workflow.editor.cursorLine), column \(workflow.editor.cursorColumn)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
            if workflow.editor.selectionLength > 0 {
                Text("\(workflow.editor.selectionLength) selected").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).monospacedDigit()
            }
            Spacer()
            if workflow.isValidating { Text("Checking…").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            if workflow.errorCount > 0 {
                Label("Errors: \(workflow.errorCount)", systemImage: "xmark.octagon.fill").font(Theme.Font.caption).foregroundStyle(Theme.danger)
            }
            if workflow.warningCount > 0 {
                Label("Warnings: \(workflow.warningCount)", systemImage: "exclamationmark.triangle.fill").font(Theme.Font.caption).foregroundStyle(Theme.warning)
            }
            if workflow.errorCount == 0 && workflow.warningCount == 0 && !workflow.isValidating {
                Label("No problems", systemImage: "checkmark.circle.fill").font(Theme.Font.caption).foregroundStyle(Theme.success)
            }
            ViewThatFits(in: .horizontal) {
                Text("⌃Space completes · ⌥-click a tool for its documentation").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
                Text("⌃Space completes").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 5)
    }

    // MARK: Problems and console

    private var bottomPanel: some View {
        @Bindable var studio = studio
        return Panel {
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    Picker("Panel", selection: $studio.bottomTab) {
                        Text("Problems (\(workflow.diagnostics.count))").tag(CodeStudioModel.BottomTab.problems)
                        Text("Console").tag(CodeStudioModel.BottomTab.console)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityIdentifier("code.bottom.tab")
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
                Divider()
                switch studio.bottomTab {
                case .problems: ProblemsList(diagnostics: workflow.diagnostics, isEmptyDocument: workflow.text.isEmpty) { d in
                    workflow.editor.goTo(line: max(1, d.line), column: max(1, d.column))
                }
                case .console: ConsoleView(buffer: studio.console, showsPolicyNote: false)
                }
            }
        }
    }
}

/// The problems of the open document. Clicking one moves the cursor to it.
struct ProblemsList: View {
    let diagnostics: [EditorDiagnostic]
    let isEmptyDocument: Bool
    let onSelect: (EditorDiagnostic) -> Void

    private func style(_ s: EditorDiagnostic.Severity) -> (String, Color, LocalizedStringKey) {
        switch s {
        case .error: return ("xmark.octagon.fill", Theme.danger, "Error")
        case .warning: return ("exclamationmark.triangle.fill", Theme.warning, "Warning")
        case .info: return ("info.circle.fill", Theme.blue, "Note")
        }
    }

    var body: some View {
        if diagnostics.isEmpty {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.success)
                Text(isEmptyDocument ? "Nothing to check yet." : "No problems found.").font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diagnostics) { d in
                        let (symbol, color, label) = style(d.severity)
                        Button { onSelect(d) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Label(label, systemImage: symbol).font(Theme.Font.captionStrong).foregroundStyle(color).frame(width: 78, alignment: .leading)
                                Text(verbatim: d.message).font(Theme.Font.body).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                if !d.code.isEmpty { Text(verbatim: d.code).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                                Text(verbatim: d.line > 0 ? "\(d.line):\(d.column)" : "—").font(Theme.Font.monoSmall).foregroundStyle(Theme.textSecondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                            .padding(.horizontal, Theme.Space.m).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Moves the cursor to the problem"))
                    }
                }
            }
            .accessibilityIdentifier("code.problems")
        }
    }
}
