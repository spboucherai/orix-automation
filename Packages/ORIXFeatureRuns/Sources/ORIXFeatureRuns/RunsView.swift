// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/RunsView.swift
// Description: The Runs section: searchable, filterable, paginated execution history on the left and the selected run's detail on the right.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

public struct RunsView: View {
    @Environment(AppModel.self) private var model
    @State private var list: RunsListModel?
    @State private var searchText = ""
    @State private var showFilters = false
    @State private var pruneDays: Int?
    @State private var pruning = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                listHeader
                Divider().overlay(Theme.stroke)
                if let list { listBody(list) } else { Spacer() }
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
            .background(Theme.surface)

            Group {
                if let id = model.selectedRunID {
                    RunDetailView(runID: id).id(id)
                } else {
                    EmptyState(symbol: "list.bullet.rectangle", title: "Select a run",
                               message: "Choose a run on the left to see its timeline, receipt, usage and console.")
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
        }
        .task {
            if list == nil { let l = RunsListModel(store: model.services.store); list = l; await l.reload() }
        }
        .task(id: model.revision) { await list?.refresh() }
        .task(id: searchText) {
            // Debounce: search once typing pauses.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let list, list.filter.search != searchText else { return }
            list.filter.search = searchText
            await list.reload()
        }
        .confirmationDialog(Text("Delete runs older than \(pruneDays ?? 0) days?"), isPresented: Binding(get: { pruneDays != nil }, set: { if !$0 { pruneDays = nil } }), titleVisibility: .visible) {
            Button(role: .destructive) {
                guard let days = pruneDays else { return }
                pruning = true
                Task {
                    do {
                        let n = try await model.services.store.pruneRuns(olderThanDays: days)
                        model.notice(n == 0 ? String(localized: "No finished run is older than \(days) days.") : String(localized: "\(n) runs were deleted with their events and receipts."), kind: .success)
                        if let id = model.selectedRunID, (try? await model.services.store.run(id: id)) == nil { model.selectedRunID = nil }
                        await list?.reload()
                    } catch { model.report(error) }
                    pruning = false
                }
            } label: { Text("Delete them") }
            Button(role: .cancel) {} label: { Text("Cancel") }
        } message: {
            Text("Finished runs that ended more than \(pruneDays ?? 0) days ago are removed for good, with their events and receipts. Files they produced stay on disk. Runs still in flight are kept.")
        }
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Runs").font(Theme.Font.title).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
                Spacer()
                if pruning || list?.isLoading == true { ProgressView().controlSize(.small) }
                Menu {
                    Section("Delete runs older than…") {
                        ForEach([7, 30, 90, 365], id: \.self) { d in Button { pruneDays = d } label: { Text("\(d) days") } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel(Text("History maintenance")).accessibilityIdentifier("runs.maintenance")
            }
            HStack(spacing: Theme.Space.s) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                    TextField(String(localized: "Search titles and errors"), text: $searchText).textFieldStyle(.plain).font(Theme.Font.body)
                        .accessibilityIdentifier("runs.search")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(Theme.textTertiary)
                            .accessibilityLabel(Text("Clear search"))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                Button { showFilters.toggle() } label: {
                    Label((list?.filter.activeCount ?? 0) > 0 ? String(localized: "Filters (\(list?.filter.activeCount ?? 0))") : String(localized: "Filters"),
                          systemImage: "line.3.horizontal.decrease.circle" + ((list?.filter.isActive ?? false) ? ".fill" : ""))
                }
                .buttonStyle(.borderless).font(Theme.Font.caption)
                .popover(isPresented: $showFilters, arrowEdge: .bottom) { if let list { RunFilterPanel(list: list) } }
                .accessibilityIdentifier("runs.filters")
            }
        }
        .padding(Theme.Space.m)
    }

    @ViewBuilder private func listBody(_ list: RunsListModel) -> some View {
        @Bindable var model = model
        if let error = list.loadError { Banner(kind: .error, text: error).padding(Theme.Space.s) }
        if list.rows.isEmpty && !list.isLoading {
            if list.filter.isActive || !list.filter.search.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No run matches", message: "Nothing in the history fits this search and these filters.",
                           actionTitle: "Clear search and filters") {
                    searchText = ""
                    let sort = list.filter.newestFirst
                    list.filter = RunFilter(); list.filter.newestFirst = sort
                    Task { await list.reload() }
                }
            } else {
                EmptyState(symbol: "tray", title: "No run yet", message: "Runs appear here as soon as the agent or a workflow starts one.",
                           actionTitle: "Ask the agent") { model.open(.section(.chat)) }
            }
        } else {
            List(selection: $model.selectedRunID) {
                ForEach(list.rows) { run in
                    RunLine(run: run).padding(.vertical, 3).tag(Optional(run.id))
                        .listRowSeparatorTint(Theme.stroke)
                        .accessibilityIdentifier("runs.row")
                }
                if list.hasMore && list.filter.newestFirst {
                    HStack { Spacer(); ProgressView().controlSize(.small); Text("Loading older runs").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary); Spacer() }
                        .listRowSeparator(.hidden)
                        .onAppear { Task { await list.loadMore() } }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("runs.list")
            HStack {
                Text(list.hasMore && list.filter.newestFirst ? "\(list.rows.count) runs loaded" : "\(list.rows.count) runs")
                Spacer()
                Text(list.filter.newestFirst ? "Newest first" : "Oldest first")
            }
            .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 5)
        }
    }
}

/// Status, kind, trigger, date range and sort order. Changes apply at once.
struct RunFilterPanel: View {
    @Bindable var list: RunsListModel
    @State private var useFrom = false
    @State private var useTo = false
    @State private var from = Calendar.current.startOfDay(for: Date().addingTimeInterval(-7 * 86_400))
    @State private var to = Date()

    private static let statuses: [RunStatus] = [.running, .waitingApproval, .paused, .succeeded, .partiallySucceeded, .failed, .canceled, .timedOut,
                                                .blockedPermission, .budgetExceeded, .recoveryRequired, .queued, .recovering]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            group("Status") {
                FlowLayout(spacing: 6) {
                    ForEach(Self.statuses, id: \.self) { s in
                        chip(isOn: list.filter.statuses.contains(s)) { toggle(&list.filter.statuses, s) } label: { Text(StatusStyle.of(s).label) }
                    }
                }
            }
            group("Kind") {
                HStack(spacing: 6) {
                    ForEach(RunKind.known, id: \.self) { k in
                        chip(isOn: list.filter.kinds.contains(k)) { toggle(&list.filter.kinds, k) } label: { Text(RunKind.title(k)) }
                    }
                }
            }
            group("Started by") {
                FlowLayout(spacing: 6) {
                    ForEach(TriggerGroup.allCases) { t in
                        chip(isOn: list.filter.triggers.contains(t)) { toggle(&list.filter.triggers, t) } label: { Text(t.title) }
                    }
                }
            }
            group("Started between") {
                HStack {
                    Toggle(isOn: $useFrom) { Text("From") }.toggleStyle(.checkbox)
                    DatePicker(selection: $from, displayedComponents: [.date, .hourAndMinute]) { Text("From") }.labelsHidden().disabled(!useFrom)
                }
                HStack {
                    Toggle(isOn: $useTo) { Text("Until") }.toggleStyle(.checkbox)
                    DatePicker(selection: $to, displayedComponents: [.date, .hourAndMinute]) { Text("Until") }.labelsHidden().disabled(!useTo)
                }
            }
            group("Order") {
                Picker(selection: $list.filter.newestFirst) { Text("Newest first").tag(true); Text("Oldest first").tag(false) } label: { Text("Order by start time") }
                    .pickerStyle(.segmented).labelsHidden()
                    .accessibilityIdentifier("runs.sort")
            }
            HStack {
                Spacer()
                Button {
                    let search = list.filter.search
                    list.filter = RunFilter(); list.filter.search = search
                    useFrom = false; useTo = false
                } label: { Text("Clear filters") }.buttonStyle(SecondaryButtonStyle()).disabled(!list.filter.isActive && list.filter.newestFirst)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 420)
        .onAppear {
            if let f = list.filter.from { from = f; useFrom = true }
            if let t = list.filter.to { to = t; useTo = true }
        }
        .onChange(of: useFrom) { _, on in list.filter.from = on ? from : nil }
        .onChange(of: useTo) { _, on in list.filter.to = on ? to : nil }
        .onChange(of: from) { _, v in if useFrom { list.filter.from = v } }
        .onChange(of: to) { _, v in if useTo { list.filter.to = v } }
        .onChange(of: list.filter) { _, _ in Task { await list.reload() } }
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) { if set.contains(value) { set.remove(value) } else { set.insert(value) } }

    private func group<C: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private func chip<L: View>(isOn: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle").font(.system(size: 10))
                label().font(Theme.Font.caption).lineLimit(1)
            }
            .foregroundStyle(isOn ? Theme.violet : Theme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isOn ? Theme.accentSoft : Theme.surfaceSunken, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Theme.violet.opacity(0.5) : Theme.stroke))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Wraps its children onto as many rows as the width needs.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(Row(y: row.y + row.height + spacing))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
