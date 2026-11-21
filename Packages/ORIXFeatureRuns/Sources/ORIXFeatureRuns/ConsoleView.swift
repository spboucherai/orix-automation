// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/ConsoleView.swift
// Description      : The run console: persisted events and live output as
//                    monospaced log lines, with level filter, search,
//                    follow-the-tail that pauses when you scroll up, copy and
//                    clear.
// Module           : ORIXFeatureRuns
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
    /// True while every line was added at the end (no late event inserted earlier): search can then be incremental.
    @ObservationIgnored private var appendOnly = true
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
        let lastTime = buffer.lines.last?.time ?? .distantPast
        let lastID = buffer.lines.last?.id ?? -1
        let inOrder = pending.allSatisfy { $0.time >= lastTime }
        buffer.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        if !inOrder { appendOnly = false }
        recompute(newerThan: appendOnly && !query.isEmpty ? lastID : nil)
    }

    /// `newerThan`: when lines were only added at the end, search just those instead of the whole buffer.
    private func recompute(newerThan lastID: Int? = nil) {
        visible = buffer.visible(levels: levels)
        let kept = currentMatchID
        if let lastID {
            let firstID = buffer.lines.first?.id ?? 0
            if let cut = matches.firstIndex(where: { $0 >= firstID }) { matches.removeFirst(cut) } else { matches.removeAll() }
            var fresh: [Int] = []
            if let matcher = ConsoleBuffer.Matcher(query) {
                for line in buffer.lines.reversed() {
                    guard line.id > lastID else { break }
                    if levels.contains(line.level), matcher.matches(line.text) { fresh.append(line.id) }
                }
            }
            matches.append(contentsOf: fresh.reversed())
        } else {
            matches = buffer.search(query, levels: levels)
        }
        matchSet = Set(matches)
        if let kept, let i = matches.firstIndex(of: kept) { currentMatch = i }
        else if matches.isEmpty { currentMatch = nil }
        else if let c = currentMatch { currentMatch = min(c, matches.count - 1) }
        version &+= 1
    }

    public func nextMatch() { guard !matches.isEmpty else { return }; currentMatch = ((currentMatch ?? -1) + 1) % matches.count; follow = false }
    public func previousMatch() { guard !matches.isEmpty else { return }; currentMatch = ((currentMatch ?? matches.count) - 1 + matches.count) % matches.count; follow = false }

    /// Empties the view only: recorded events stay in the run's timeline.
    public func clear() { pending = []; buffer.clear(); appendOnly = true; recompute() }

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
        .onAppear { searchText = console.query }
        .task(id: searchText) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !Task.isCancelled, console.query != searchText { console.query = searchText }
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

    private var lines: some View {
        ConsoleTable(console: console, version: console.version, follow: console.follow, currentMatchID: console.currentMatchID, selection: $selection) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(console.text(selection: selection), forType: .string)
        }
        .overlay {
            if console.visible.isEmpty {
                Text(console.buffer.lines.isEmpty ? "Nothing has been logged for this run yet." : "No line matches the selected kinds.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(minHeight: 120)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if console.isLive { HStack(spacing: 4) { PulseDot(color: Theme.blue, active: true); Text("Live") } }
            else { Text("Recorded events only: program output is shown while a run is in progress and is not kept afterwards.").lineLimit(1) }
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
