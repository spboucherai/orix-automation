// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/LibraryViews.swift
// Description: The workflow library pane, the built-in template gallery and the add-node palette.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

struct LibraryPane: View {
    @Bindable var vm: WorkflowStudioModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("Workflows").font(Theme.Font.heading).foregroundStyle(Theme.text)
                    Spacer()
                    Menu {
                        Button { Task { await vm.createBlank() } } label: { Label("New workflow", systemImage: "plus") }
                        Button { vm.showTemplates = true } label: { Label("From a template…", systemImage: "square.grid.2x2") }
                        Button { vm.showGenerate = true } label: { Label("Create from description…", systemImage: "sparkles") }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(Text("New workflow")).accessibilityLabel(Text("New workflow"))
                    .accessibilityIdentifier("workflow.library.new")
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    TextField(String(localized: "Search workflows"), text: $vm.search).textFieldStyle(.plain).font(Theme.Font.body)
                        .accessibilityIdentifier("workflow.library.search")
                    if !vm.search.isEmpty {
                        Button { vm.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                            .accessibilityLabel(Text("Clear search"))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            }
            .padding(Theme.Space.m)
            Divider()
            if !vm.libraryLoaded {
                VStack(alignment: .leading, spacing: Theme.Space.m) { ForEach(0..<4, id: \.self) { _ in SkeletonLine(height: 14) } }.padding(Theme.Space.m)
                Spacer()
            } else if vm.rows.isEmpty {
                EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No workflow yet", message: "Start from a template or from a blank workflow.",
                           actionTitle: "Browse templates") { vm.showTemplates = true }
            } else if vm.filteredRows.isEmpty {
                Text("No workflow matches “\(vm.search)”.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(Theme.Space.l)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(vm.filteredRows) { row in LibraryRow(vm: vm, row: row) }
                    }
                    .padding(Theme.Space.s)
                }
            }
            Divider()
            Button { vm.showTemplates = true } label: {
                Label("Template gallery", systemImage: "square.grid.2x2").font(Theme.Font.bodyStrong).frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle()).padding(Theme.Space.m)
            .accessibilityIdentifier("workflow.library.templates")
        }
        .background(Theme.surfaceRaised)
        .confirmationDialog(Text("Delete “\(vm.pendingDelete?.name ?? "")”?"), isPresented: Binding(get: { vm.pendingDelete != nil }, set: { if !$0 { vm.pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete workflow", role: .destructive) {
                if let row = vm.pendingDelete { Task { await vm.delete(row) } }
                vm.pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { vm.pendingDelete = nil }
        } message: {
            Text("Every saved version, its schedules and its accepted permissions are removed. Past runs stay in Runs. This cannot be undone.")
        }
    }
}

private struct LibraryRow: View {
    @Bindable var vm: WorkflowStudioModel
    let row: WorkflowRow
    @State private var hovering = false

    var body: some View {
        let selected = vm.workflowID == row.id
        Button { Task { await vm.open(row.id) } } label: {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(verbatim: row.name).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                        if vm.hasDraft(row.id) {
                            Circle().fill(Theme.warning).frame(width: 6, height: 6)
                                .help(Text("Unsaved changes")).accessibilityLabel(Text("Unsaved changes"))
                        }
                    }
                    Text("v\(row.currentVersion) · \(relativeOrNow(row.updatedAt))").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if hovering || selected {
                    Menu {
                        Button { Task { await vm.duplicate(row) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { vm.app.open(.workflowCode(row.id)) } label: { Label("Open in Code Studio", systemImage: "chevron.left.forwardslash.chevron.right") }
                        Divider()
                        Button(role: .destructive) { vm.pendingDelete = row } label: { Label("Delete…", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") .frame(width: 18, height: 18) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(Text("Actions for \(row.name)"))
                }
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : (hovering ? Theme.stroke : Color.clear), in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Duplicate") { Task { await vm.duplicate(row) } }
            Button("Open in Code Studio") { vm.app.open(.workflowCode(row.id)) }
            Button("Delete…", role: .destructive) { vm.pendingDelete = row }
        }
        .accessibilityIdentifier("workflow.library.row.\(row.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Template gallery

struct TemplateGallery: View {
    @Bindable var vm: WorkflowStudioModel
    @State private var templates: [BuiltInWorkflow] = []
    @State private var query = ""
    @State private var installing: String?
    @State private var replace: BuiltInWorkflow?

    private var shown: [BuiltInWorkflow] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? templates : templates.filter { Palette.matches(query, $0.title + " " + $0.summary + " " + $0.slug) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Template gallery").font(Theme.Font.title).foregroundStyle(Theme.text)
                    Text("Ready-made automations you can run as they are or change. A template becomes one of your workflows.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                TextField(String(localized: "Search templates"), text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                    .accessibilityIdentifier("workflow.templates.search")
                Button("Done") { vm.showTemplates = false }.keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Space.l)
            Divider()
            if templates.isEmpty {
                EmptyState(symbol: "square.grid.2x2", title: "No template found", message: "The built-in templates could not be read from the app.")
            } else if shown.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No template matches", message: "Try another word.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 480), spacing: Theme.Space.m, alignment: .top)], alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(shown) { t in card(t) }
                    }
                    .padding(Theme.Space.l)
                }
            }
        }
        .frame(minWidth: 680, idealWidth: 980, minHeight: 480, idealHeight: 640)
        .background(Theme.canvas)
        .task { templates = BuiltInWorkflows.all() }
        .confirmationDialog(Text("Replace your copy of “\(replace?.title ?? "")”?"), isPresented: Binding(get: { replace != nil }, set: { if !$0 { replace = nil } }), titleVisibility: .visible) {
            Button("Save the template as a new version") { if let t = replace { install(t) }; replace = nil }
            Button("Cancel", role: .cancel) { replace = nil }
        } message: {
            Text("You already have a workflow made from this template. The template is saved as its newest version; your earlier versions stay in the version history, and unsaved changes in the editor are discarded.")
        }
    }

    private func install(_ t: BuiltInWorkflow) {
        installing = t.slug
        Task {
            if await vm.installTemplate(t) { vm.showTemplates = false }
            installing = nil
        }
    }

    private func card(_ t: BuiltInWorkflow) -> some View {
        let doc = try? t.document()
        let owned = doc.map { d in vm.rows.contains { $0.id == d.metadata.id } } ?? false
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let doc {
                    GraphPreview(document: doc).frame(height: 120).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)).allowsHitTesting(false)
                }
                Text(verbatim: t.title).font(Theme.Font.heading).foregroundStyle(Theme.text).lineLimit(2)
                Text(verbatim: t.summary.isEmpty ? t.slug : t.summary).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                if let doc {
                    HStack(spacing: 6) {
                        Pill(text: String(localized: "\(doc.allSteps.count) steps"), symbol: "square.stack.3d.up")
                        ForEach(doc.spec.triggers.filter { $0 != .manual }.prefix(1), id: \.self) { tr in Pill(text: tr.typeName, symbol: "bolt") }
                        if owned { Pill(text: String(localized: "in your workflows"), symbol: "checkmark", color: Theme.success) }
                    }
                } else {
                    Banner(kind: .error, text: String(localized: "This template does not parse and cannot be used."))
                }
                HStack {
                    Spacer()
                    if installing == t.slug { ProgressView().controlSize(.small) }
                    Button { if owned { replace = t } else { install(t) } } label: { Text("Use template") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(doc == nil || installing != nil)
                        .accessibilityIdentifier("workflow.templates.use.\(t.slug)")
                }
            }
        }
    }
}

// MARK: - Add-node palette

struct PaletteView: View {
    @Bindable var vm: WorkflowStudioModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var templates: [StepTemplate] {
        StepTemplate.allCases.filter { t in
            (t != .subworkflow || vm.rows.contains { $0.id != vm.workflowID }) && (query.isEmpty || Palette.matches(query, t.searchText))
        }
    }

    private var tools: [(family: String, tools: [ToolManifest])] {
        let matching = vm.manifests.filter { query.isEmpty || Palette.matches(query, $0.identifier + " " + $0.name + " " + $0.summary + " " + $0.family) }
        return Dictionary(grouping: matching, by: \.family).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var profiles: [AgentProfile] { vm.agents.filter { query.isEmpty || Palette.matches(query, $0.name + " " + $0.role + " agent") } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField(String(localized: "Search steps, tools and agents"), text: $query).textFieldStyle(.plain).font(Theme.Font.body).focused($searchFocused)
                    .accessibilityIdentifier("workflow.palette.search")
            }
            .padding(Theme.Space.m)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    if !templates.isEmpty {
                        Section { ForEach(templates) { t in
                            row(symbol: CategoryStyle.symbol(kind: t == .switchCase ? "switch" : t.rawValue, category: t.category), color: CategoryStyle.of(t.category).color,
                                title: Text(t.title), subtitle: Text(t.summary), badges: { EmptyView() }) { add(.template(t)) }
                                .accessibilityIdentifier("workflow.palette.kind.\(t.rawValue)")
                        } } header: { header("Flow and data") }
                    }
                    if !profiles.isEmpty {
                        Section { ForEach(profiles) { p in
                            row(symbol: "sparkles", color: Theme.violet, title: Text(verbatim: p.name), subtitle: Text(verbatim: p.role + (p.model.model.isEmpty ? "" : " · " + p.model.model)), badges: { EmptyView() }) { add(.agent(p)) }
                        } } header: { header("Agents") }
                    }
                    ForEach(tools, id: \.family) { group in
                        Section { ForEach(group.tools, id: \.identifier) { m in
                            row(symbol: "wrench.and.screwdriver.fill", color: Theme.blue, title: Text(verbatim: m.identifier), subtitle: Text(verbatim: m.summary), badges: {
                                HStack(spacing: 4) {
                                    TierBadge(tier: m.defaultTier)
                                    Pill(text: SideEffectStyle.label(m.sideEffect), symbol: SideEffectStyle.symbol(m.sideEffect), color: SideEffectStyle.color(m.sideEffect))
                                }
                            }) { add(.tool(m)) }
                            .accessibilityIdentifier("workflow.palette.tool.\(m.identifier)")
                        } } header: { header(LocalizedStringKey(group.family)) }
                    }
                    if templates.isEmpty && profiles.isEmpty && tools.isEmpty {
                        Text("Nothing matches “\(query)”.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(Theme.Space.l)
                    }
                }
                .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.s)
            }
        }
        .frame(width: 420, height: 520)
        .background(Theme.surfaceRaised)
        .onAppear { searchFocused = true }
    }

    private func add(_ item: PaletteItem) {
        if vm.add(item) != nil { vm.showPalette = false }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.Space.s).padding(.vertical, 6).background(Theme.surfaceRaised)
    }

    private func row<Badges: View>(symbol: String, color: Color, title: Text, subtitle: Text, @ViewBuilder badges: () -> Badges, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 24, height: 24).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    title.font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                    subtitle.font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2).multilineTextAlignment(.leading)
                    badges()
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle").foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaletteRowStyle())
    }
}

private struct PaletteRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
    }
}
