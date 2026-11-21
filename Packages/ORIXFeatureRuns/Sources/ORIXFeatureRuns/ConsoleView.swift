// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/ConsoleView.swift
// Description: The run console: persisted events and live output as monospaced log lines, with level filter, search, follow-the-tail that pauses when you scroll up, copy and clear.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

extension ConsoleLine.Level {
    var title: LocalizedStringKey {
        switch self {
        case .status: return "Status changes"
        case .user: return "Your messages"
        case .agent: return "Agent text"
        case .reasoning: return "Reasoning summaries"
        case .tool: return "Tool calls"
        case .stdout: return "Standard output"
        case .stderr: return "Standard error"
        case .approval: return "Approvals"
        case .verification: return "Verification"
        case .usage: return "Usage"
        case .error: return "Errors"
        case .info: return "Other notes"
        }
    }

    var tint: Color {
        switch self {
        case .stderr, .error: return Theme.danger
        case .stdout: return Theme.text
        case .agent: return Theme.violet
        case .user: return Theme.blue
        case .verification: return Theme.success
        case .approval: return Theme.warning
        default: return Theme.textSecondary
        }
    }
}

/// State of one console: the bounded buffer, what is shown after filtering, search matches and follow mode.
@MainActor
@Observable
public final class ConsoleModel {
    public private(set) var buffer: ConsoleBuffer
    public private(set) var visible: [ConsoleLine] = []
    public private(set) var matches: [Int] = []
    public private(set) var matchSet: Set<Int> = []
    /// Index into `matches` of the match the view is showing.
    public private(set) var currentMatch: Int?
    /// Increases on every change of `visible`; the view scrolls on it.
    public private(set) var version = 0
    public var follow = true
    public var levels: Set<ConsoleLine.Level> = Set(ConsoleLine.Level.allCases) { didSet { if levels != oldValue { recompute() } } }
    public var query = "" { didSet { if query != oldValue { recompute(); currentMatch = matches.isEmpty ? nil : matches.count - 1 } } }
    public private(set) var isLive = false

    @ObservationIgnored private var assembler = ConsoleAssembler()
    @ObservationIgnored private var pending: [ConsoleAssembler.Entry] = []
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var lastLiveAt = Date.distantPast
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var services: ORIXServices?
    @ObservationIgnored private var runID = ""

    public init(capacity: Int = ConsoleBuffer.defaultCapacity) { buffer = ConsoleBuffer(capacity: capacity) }

    public var currentMatchID: Int? { currentMatch.flatMap { matches.indices.contains($0) ? matches[$0] : nil } }
    public var dropped: Int { buffer.dropped }

    /// Loads the persisted events, then follows live output while the run is in flight in this process.
    public func start(runID: String, services: ORIXServices) async {
        stop()
        self.runID = runID; self.services = services
        buffer.clear(); assembler = ConsoleAssembler(); lastSeq = 0; pending = []
        let run = try? await services.store.run(id: runID)
        if run?.status.isTerminal == false {
            isLive = true
            let stream = services.runs.live.subscribe(runID: runID)
            tasks.append(Task { [weak self] in
                for await update in stream { self?.receive(update) }
                self?.liveEnded()
            })
        }
        await refreshPersisted()
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.tick()
            }
        })
    }

    public func stop() {
        for t in tasks { t.cancel() }
        tasks = []; isLive = false
    }

    /// Fetches events recorded since the last call. Cheap; called on every store change.
    public func refreshPersisted() async {
        guard let services else { return }
        while true {
            let batch = (try? await services.store.events(runID: runID, afterSeq: lastSeq, limit: 1000)) ?? []
            guard !batch.isEmpty else { break }
            lastSeq = batch.last?.seq ?? lastSeq
            for e in batch { pending.append(contentsOf: assembler.lines(for: e)) }
            if batch.count < 1000 { break }
        }
        flush()
    }

    public func receive(_ update: LiveUpdate) {
        lastLiveAt = Date()
        pending.append(contentsOf: assembler.lines(for: update))
    }

    private func liveEnded() {
        pending.append(contentsOf: assembler.flushPartials())
        isLive = false
        flush()
    }

    private func tick() {
        // A line the stream left unfinished for a moment is shown as it stands rather than held back.
        if assembler.hasPartials, Date().timeIntervalSince(lastLiveAt) > 0.4 { pending.append(contentsOf: assembler.flushPartials()) }
        flush()
    }

    /// Adds lines directly (tests and measurements use it; the app goes through events and live updates).
    public func ingest(_ entries: [ConsoleAssembler.Entry]) { pending.append(contentsOf: entries) }

    /// Moves pending lines into the buffer and updates what the view shows. At most once per tick while streaming.
    public func flush() {
        guard !pending.isEmpty else { return }
        buffer.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        recompute()
    }

    private func recompute() {
        visible = buffer.visible(levels: levels)
        let kept = currentMatchID
        matches = buffer.search(query, levels: levels)
        matchSet = Set(matches)
        if let kept, let i = matches.firstIndex(of: kept) { currentMatch = i }
        else if matches.isEmpty { currentMatch = nil }
        else if let c = currentMatch { currentMatch = min(c, matches.count - 1) }
        version &+= 1
    }

    public func nextMatch() { guard !matches.isEmpty else { return }; currentMatch = ((currentMatch ?? -1) + 1) % matches.count; follow = false }
    public func previousMatch() { guard !matches.isEmpty else { return }; currentMatch = ((currentMatch ?? matches.count) - 1 + matches.count) % matches.count; follow = false }

    /// Empties the view only: recorded events stay in the run's timeline.
    public func clear() { pending = []; buffer.clear(); recompute() }

    /// The selected lines in order, or everything shown when nothing is selected.
    public func text(selection: Set<Int>) -> String {
        (selection.isEmpty ? visible : visible.filter { selection.contains($0.id) }).map(ConsoleBuffer.render).joined(separator: "\n")
    }
}

/// Real logs of one run. Embeddable anywhere a run id is known.
public struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var console = ConsoleModel()
    let runID: String

    public init(runID: String) { self.runID = runID }

    public var body: some View {
        ConsoleSurface(console: console)
            .task(id: runID) { await console.start(runID: runID, services: model.services) }
            .task(id: model.revision) { await console.refreshPersisted() }
            .onDisappear { console.stop() }
    }
}

/// The console drawn from a model. Split from `ConsoleView` so it can be rendered from a prepared model.
struct ConsoleSurface: View {
    @Bindable var console: ConsoleModel
    @State private var selection = Set<Int>()
    @State private var searchText = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.stroke)
            if console.dropped > 0 {
                Banner(kind: .info, text: String(localized: "This view keeps the latest \(console.buffer.capacity) lines. \(console.dropped) older lines were dropped from it; the Timeline tab still has every recorded event."))
                    .padding(Theme.Space.s)
            }
            lines
            Divider().overlay(Theme.stroke)
            footer
        }
        .background(Theme.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !Task.isCancelled { console.query = searchText }
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                TextField(String(localized: "Search the log"), text: $searchText).textFieldStyle(.plain).font(Theme.Font.body)
                    .onSubmit { console.query = searchText; console.nextMatch() }
                    .accessibilityIdentifier("console.search")
                if !console.query.isEmpty {
                    Text(console.matches.isEmpty ? String(localized: "No match") : String(localized: "\((console.currentMatch ?? 0) + 1) of \(console.matches.count)"))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).monospacedDigit().fixedSize()
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.stroke))
            .frame(minWidth: 160, maxWidth: 320)
            Button { console.previousMatch() } label: { Image(systemName: "chevron.up") }
                .disabled(console.matches.isEmpty).keyboardShortcut("g", modifiers: [.command, .shift])
                .accessibilityLabel(Text("Previous match")).accessibilityIdentifier("console.previousMatch")
            Button { console.nextMatch() } label: { Image(systemName: "chevron.down") }
                .disabled(console.matches.isEmpty).keyboardShortcut("g", modifiers: .command)
                .accessibilityLabel(Text("Next match")).accessibilityIdentifier("console.nextMatch")
            Spacer(minLength: Theme.Space.s)
            Menu {
                Button("Show everything") { console.levels = Set(ConsoleLine.Level.allCases) }
                Button("Only output and errors") { console.levels = [.stdout, .stderr, .error] }
                Divider()
                ForEach(ConsoleLine.Level.allCases) { level in
                    Toggle(isOn: Binding(get: { console.levels.contains(level) },
                                         set: { on in if on { console.levels.insert(level) } else { console.levels.remove(level) } })) {
                        Text(level.title) + Text(verbatim: "  (\(level.tag))")
                    }
                }
            } label: {
                Label(console.levels.count == ConsoleLine.Level.allCases.count ? String(localized: "All kinds") : String(localized: "\(console.levels.count) kinds"),
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("console.filter")
            Button {
                console.follow.toggle()
            } label: { Label(console.follow ? String(localized: "Following") : String(localized: "Follow"), systemImage: console.follow ? "arrow.down.to.line.compact" : "pause") }
                .help(Text("Keep the newest line in view. Scrolling up pauses it."))
                .accessibilityIdentifier("console.follow")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(console.text(selection: selection), forType: .string)
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            } label: { Label(copied ? String(localized: "Copied") : (selection.isEmpty ? String(localized: "Copy all") : String(localized: "Copy selection")), systemImage: copied ? "checkmark" : "doc.on.doc") }
                .disabled(console.visible.isEmpty).accessibilityIdentifier("console.copy")
            Button { selection = []; console.clear() } label: { Label("Clear view", systemImage: "eraser") }
                .disabled(console.visible.isEmpty)
                .help(Text("Empties this view only. Recorded events stay in the timeline."))
                .accessibilityIdentifier("console.clear")
        }
        .buttonStyle(.borderless).font(Theme.Font.caption)
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .background(Theme.surfaceRaised)
    }

    private struct ScrollState: Equatable { var offset: CGFloat; var distanceToEnd: CGFloat }

    private var lines: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(console.visible) { line in
                    ConsoleRow(line: line, query: console.matchSet.contains(line.id) ? console.query : "", isCurrent: console.currentMatchID == line.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .id(line.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 17)
            .onCopyCommand { [NSItemProvider(object: console.text(selection: selection) as NSString)] }
            .onScrollGeometryChange(for: ScrollState.self) { g in
                ScrollState(offset: g.contentOffset.y, distanceToEnd: g.contentSize.height - g.contentOffset.y - g.containerSize.height)
            } action: { old, new in
                // Moving up, away from the end, is the user reading: stop following. Reaching the end resumes.
                if new.offset < old.offset - 2, new.distanceToEnd > 60, console.follow { console.follow = false }
                else if new.distanceToEnd < 4, new.offset > old.offset, !console.follow, console.currentMatch == nil || console.query.isEmpty { console.follow = true }
            }
            .onChange(of: console.version) { _, _ in
                if console.follow, let last = console.visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: console.follow) { _, on in
                if on, let last = console.visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: console.currentMatchID) { _, id in
                if let id, !console.follow { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { if let last = console.visible.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
        .overlay {
            if console.visible.isEmpty {
                Text(console.buffer.lines.isEmpty ? "Nothing has been logged for this run yet." : "No line matches the selected kinds.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(minHeight: 120)
        .accessibilityIdentifier("console.lines")
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if console.isLive { HStack(spacing: 4) { PulseDot(color: Theme.blue, active: true); Text("Live") } }
            Text("\(console.visible.count) lines shown")
            if console.visible.count != console.buffer.lines.count { Text("\(console.buffer.lines.count - console.visible.count) hidden by the filter") }
            if !selection.isEmpty { Text("\(selection.count) selected") }
            Spacer()
            Text(console.follow ? "Following the newest line" : "Paused: scroll to the end or press Follow")
        }
        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 5)
        .background(Theme.surfaceRaised)
    }
}

struct ConsoleRow: View {
    let line: ConsoleLine
    /// Non-empty when this line matches the search.
    let query: String
    let isCurrent: Bool

    private var highlighted: AttributedString {
        var a = AttributedString(line.text)
        guard !query.isEmpty else { return a }
        var from = a.startIndex
        while from < a.endIndex, let r = a[from...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            a[r].backgroundColor = Theme.warning.opacity(isCurrent ? 0.55 : 0.28)
            a[r].underlineStyle = .single
            from = r.upperBound
        }
        return a
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: ConsoleBuffer.timestamp(line.time)).foregroundStyle(Theme.textTertiary)
            Text(verbatim: line.level.tag).fontWeight(.semibold).foregroundStyle(line.level.tint).frame(width: 46, alignment: .leading)
            Text(highlighted).foregroundStyle(line.level == .stderr || line.level == .error ? Theme.danger : Theme.text)
                .lineLimit(12).frame(maxWidth: .infinity, alignment: .leading)
            if isCurrent { Image(systemName: "arrowtriangle.left.fill").font(.system(size: 8)).foregroundStyle(Theme.warning).accessibilityLabel(Text("Current match")) }
        }
        .font(Theme.Font.monoSmall)
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}
