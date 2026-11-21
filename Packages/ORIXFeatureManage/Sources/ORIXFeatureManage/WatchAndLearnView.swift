// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/WatchAndLearnView.swift
// Description      : Watch & Learn: opt-in recording of chosen apps with a
//                    persistent indicator, review with delete, redact and
//                    variable labelling, and a proposed workflow saved only
//                    after approval.
// Module           : ORIXFeatureManage
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
import Observation
import ORIXAppUI
import SwiftUI

/// Whether a Watch & Learn recording is running, for an app-wide indicator in the shell.
@MainActor
@Observable
public final class RecordingStatus {
    public static let shared = RecordingStatus()
    public fileprivate(set) var isRecording = false
    public fileprivate(set) var isPaused = false
    public fileprivate(set) var applicationNames: [String] = []
}

@MainActor
@Observable
final class WatchModel {
    enum Phase: Sendable { case idle, recording, paused, review, proposal }

    let services: ORIXServices
    private(set) var phase: Phase = .idle
    private(set) var apps: [RunningAppInfo] = []
    var selected: Set<String> = []
    private(set) var actions: [RecordedAction] = []
    private(set) var limitations: [String] = []
    var items: [ReviewedAction] = []
    var workflowName = ""
    private(set) var proposal: WorkflowProposal?
    private(set) var diagnostics: [WorkflowDiagnostic] = []
    private(set) var savedWorkflowID: String?
    private(set) var isSample = false
    private(set) var accessibilityGranted = false
    private(set) var saving = false
    var error: String?
    private var recorder: InputRecorder?

    init(services: ORIXServices) { self.services = services }

    static let reviewable: Set<RecordedAction.Kind> = [.appActivated, .appLaunched, .appTerminated, .focusChanged, .valueChanged, .selectionChanged, .menuItemSelected, .windowCreated, .windowFocused]

    func refreshApps() {
        apps = RunningAppInfo.current()
        selected = selected.intersection(Set(apps.map(\.bundleID)))
        accessibilityGranted = MacPermissions.status(.accessibility) == .granted
    }

    func start() {
        error = nil
        let r = InputRecorder()
        r.onAction = { [weak self] a in self?.received(a) }
        do {
            actions = []
            limitations = try r.start(targetBundleIDs: selected.sorted())
            actions = r.actions
            recorder = r; phase = .recording; isSample = false
            publishStatus()
        } catch { self.error = ManageText.describe(error) }
    }

    private func received(_ a: RecordedAction) {
        if let i = actions.lastIndex(where: { $0.id == a.id }) { actions[i] = a } else { actions.append(a) }
        if let r = recorder { limitations = r.limitations }
    }

    func pause() { recorder?.pause(); phase = .paused; publishStatus() }
    func resume() { recorder?.resume(); phase = .recording; publishStatus() }

    func stop() {
        let final = recorder?.stop() ?? actions
        limitations = recorder?.limitations ?? limitations
        recorder = nil
        beginReview(final)
        publishStatus()
    }

    /// Loads actions for review. `sample` marks a synthetic recording that was never captured from this Mac.
    func beginReview(_ recorded: [RecordedAction], sample: Bool = false) {
        actions = recorded
        items = recorded.filter { Self.reviewable.contains($0.kind) }.map { ReviewedAction(action: $0) }
        isSample = sample
        proposal = nil; savedWorkflowID = nil; diagnostics = []
        phase = .review
    }

    private func publishStatus() {
        let s = RecordingStatus.shared
        s.isRecording = phase == .recording || phase == .paused
        s.isPaused = phase == .paused
        s.applicationNames = s.isRecording ? apps.filter { selected.contains($0.bundleID) }.map(\.name) : []
    }

    func remove(_ id: String) { items.removeAll { $0.id == id } }

    /// Builds the workflow from what is left after review and validates it against the tools that exist now.
    func propose() async {
        let p = RecordingToWorkflow.convert(items, name: workflowName)
        proposal = p
        diagnostics = await services.workflows.diagnose(p.yaml).diagnostics
        phase = .proposal
    }

    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    /// Saves the proposed workflow. Called only from the explicit approval button.
    func save() async {
        guard let p = proposal, !hasErrors, !p.document.spec.steps.isEmpty else { return }
        saving = true; defer { saving = false }
        do {
            let saved = try await services.workflows.save(source: p.yaml, note: "Proposed from a Watch & Learn recording")
            savedWorkflowID = saved.id
            error = nil
        } catch { self.error = ManageText.describe(error) }
    }

    /// Forgets the recording. Nothing was written unless a workflow was saved.
    func discard() {
        _ = recorder?.stop(); recorder = nil
        actions = []; items = []; limitations = []; proposal = nil; diagnostics = []; savedWorkflowID = nil; workflowName = ""; isSample = false; error = nil
        phase = .idle
        publishStatus()
    }

    static func symbol(_ kind: RecordedAction.Kind) -> String {
        switch kind {
        case .appActivated, .appLaunched: return "macwindow.badge.plus"
        case .appTerminated: return "xmark.rectangle"
        case .focusChanged: return "scope"
        case .valueChanged: return "character.cursor.ibeam"
        case .selectionChanged: return "checklist"
        case .menuItemSelected: return "filemenu.and.selection"
        case .windowCreated, .windowFocused: return "macwindow"
        case .limitation: return "exclamationmark.triangle"
        default: return "record.circle"
        }
    }
}

public struct WatchAndLearnView: View {
    @Environment(AppModel.self) private var model
    @State private var watch: WatchModel?
    private let sample: [RecordedAction]?
    private let sampleProposal: Bool

    public init() { sample = nil; sampleProposal = false }

    /// Opens directly on the review of a synthetic recording, labelled as a sample on screen. Used only by the preview harness.
    public init(sampleRecording: [RecordedAction], showProposal: Bool = false) { sample = sampleRecording; sampleProposal = showProposal }

    public var body: some View {
        ManagePage {
            PageHeader("Watch & Learn", subtitle: "Show ORIX a repetitive task once; it proposes a workflow you review before anything is saved.")
            if let watch {
                if let e = watch.error { Banner(kind: .error, text: e) }
                switch watch.phase {
                case .idle: idle(watch)
                case .recording, .paused: recording(watch)
                case .review: review(watch)
                case .proposal: proposal(watch)
                }
            }
        }
        .task {
            guard watch == nil else { return }
            let w = WatchModel(services: model.services)
            w.refreshApps()
            if let sample {
                w.workflowName = "Sample · Rename a note"
                w.beginReview(sample, sample: true)
                if sampleProposal { await w.propose() }
            }
            watch = w
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if watch?.phase == .idle { watch?.refreshApps() }
        }
    }

    // MARK: Idle

    @ViewBuilder
    private func idle(_ w: WatchModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("What a recording contains")
                consent("checkmark.circle.fill", Theme.success, String(localized: "Recorded, only in the applications you select: which app comes to the front, launches or quits; which control gets the focus (its role and title); that a value changed; which menu item was chosen; which window opened."))
                consent("xmark.circle.fill", Theme.danger, String(localized: "Never recorded: keystrokes, pointer positions, the screen, the content of secure fields, and anything in applications you did not select. Typed text is kept only as its length."))
                consent("internaldrive", Theme.violet, String(localized: "The recording stays in memory. It is written nowhere unless you approve the workflow proposed from it; discarding it leaves no trace."))
            }
        }
        if !w.accessibilityGranted {
            Banner(kind: .warning, text: String(localized: "Accessibility is not granted, so a recording would contain only app switches, launches and quits. Grant it in Permissions to record focus, values, menus and windows."),
                   actionTitle: "Open Permissions") { model.open(.section(.permissions)) }
        }
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader("Applications to watch", subtitle: "Nothing is selected for you.") {
                    Button { w.refreshApps() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.link).accessibilityIdentifier("watch.refreshApps")
                }
                if w.apps.isEmpty {
                    Text("No other application is running.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: Theme.Space.s)], alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(w.apps) { app in appChoice(app, w) }
                    }
                }
            }
        }
        HStack(spacing: Theme.Space.m) {
            Button { w.start() } label: { Label("Start recording", systemImage: "record.circle") }
                .buttonStyle(PrimaryButtonStyle()).disabled(w.selected.isEmpty).accessibilityIdentifier("watch.start")
            Text(w.selected.isEmpty ? LocalizedStringKey("Select at least one application.") : LocalizedStringKey("By starting, you agree to record the events described above in the selected applications until you press Stop."))
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func consent(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 20)
            Text(text).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func appChoice(_ app: RunningAppInfo, _ w: WatchModel) -> some View {
        let on = w.selected.contains(app.bundleID)
        return Button {
            if on { w.selected.remove(app.bundleID) } else { w.selected.insert(app.bundleID) }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Theme.violet : Theme.textTertiary)
                if let icon = RunningAppInfo.icon(app.bundleID) { Image(nsImage: icon).resizable().frame(width: 22, height: 22).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                    Text(app.bundleID).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.s)
            .background(on ? Theme.accentSoft : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? [.isSelected] : []).accessibilityIdentifier("watch.app.\(app.bundleID)")
    }

    // MARK: Recording

    @ViewBuilder
    private func recording(_ w: WatchModel) -> some View {
        let paused = w.phase == .paused
        HStack(spacing: Theme.Space.m) {
            PulseDot(color: Theme.danger, active: !paused)
            VStack(alignment: .leading, spacing: 1) {
                Text(paused ? LocalizedStringKey("Recording paused") : LocalizedStringKey("Recording")).font(Theme.Font.heading).foregroundStyle(Theme.danger)
                Text(w.apps.filter { w.selected.contains($0.bundleID) }.map(\.name).joined(separator: ", ")).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button { paused ? w.resume() : w.pause() } label: { Label(paused ? LocalizedStringKey("Resume") : LocalizedStringKey("Pause"), systemImage: paused ? "play.fill" : "pause.fill") }
                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("watch.pause")
            Button { w.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).keyboardShortcut(".", modifiers: .command).accessibilityIdentifier("watch.stop")
        }
        .padding(Theme.Space.l)
        .background(Theme.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        limitationList(w.limitations)
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader("Recorded so far", subtitle: "Newest last. Do the task once, at a normal pace.")
                let shown = w.actions.filter { WatchModel.reviewable.contains($0.kind) }
                if shown.isEmpty {
                    Text("Nothing yet. Switch to one of the selected applications and begin.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown.suffix(200)) { a in actionLine(a) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func limitationList(_ limitations: [String]) -> some View {
        if !limitations.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("What this recording cannot see").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                ForEach(limitations, id: \.self) { l in
                    Label(l, systemImage: "eye.slash").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        }
    }

    private func actionLine(_ a: RecordedAction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(verbatim: String(a.sequence)).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).frame(width: 28, alignment: .trailing)
            Image(systemName: WatchModel.symbol(a.kind)).font(.system(size: 11)).foregroundStyle(Theme.violet).frame(width: 18)
            Text(a.appName ?? a.bundleID ?? "").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading).lineLimit(1)
            Text(a.summary).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Review

    @ViewBuilder
    private func review(_ w: WatchModel) -> some View {
        @Bindable var w = w
        if w.isSample {
            Banner(kind: .warning, text: String(localized: "Sample recording. These actions are synthetic and were not captured from this Mac."))
        }
        Banner(kind: .info, text: String(localized: "This recording exists only in memory. Remove what should not be replayed, redact what should not be kept, and name the values that change from one time to the next."))
        limitationList(w.limitations)
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader("Recorded actions", subtitle: "\(String(w.items.count)) action(s) kept")
                if w.items.isEmpty {
                    Text("Every action was removed. There is nothing to turn into a workflow.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                LazyVStack(spacing: 0) {
                    ForEach($w.items) { $item in
                        reviewRow($item, w)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(title: "Workflow name")
                    TextField(String(localized: "Name of the workflow"), text: $w.workflowName).textFieldStyle(.roundedBorder).frame(maxWidth: 420).accessibilityIdentifier("watch.name")
                }
                HStack {
                    Button(role: .destructive) { w.discard() } label: { Label("Discard recording", systemImage: "trash") }
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).accessibilityIdentifier("watch.discard")
                    Text("Discarding leaves no trace: nothing was written.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button { Task { await w.propose() } } label: { Label("Propose workflow", systemImage: "wand.and.stars") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(w.items.isEmpty).accessibilityIdentifier("watch.propose")
                }
            }
        }
    }

    private func reviewRow(_ item: Binding<ReviewedAction>, _ w: WatchModel) -> some View {
        let a = item.wrappedValue.action
        let redacted = item.wrappedValue.redacted
        return HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: WatchModel.symbol(a.kind)).font(.system(size: 12)).foregroundStyle(Theme.violet).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(redacted ? String(localized: "Redacted: only the kind of action and the element's role are kept") : a.summary)
                    .font(Theme.Font.body).foregroundStyle(redacted ? Theme.textSecondary : Theme.text).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Pill(text: a.appName ?? a.bundleID ?? "—", symbol: "macwindow")
                    if let role = a.role { Pill(text: role) }
                    if a.coalesced > 1 { Pill(text: String(localized: "\(String(a.coalesced)) events merged")) }
                }
                if a.kind == .valueChanged && !RecordingToWorkflow.isSecure(a) {
                    HStack(spacing: 6) {
                        Image(systemName: "curlybraces").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                        TextField(String(localized: "Make it a parameter: name"), text: Binding(get: { item.wrappedValue.variable ?? "" }, set: { item.wrappedValue.variable = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder).font(Theme.Font.monoSmall).frame(maxWidth: 260)
                            .accessibilityIdentifier("watch.variable.\(a.id)")
                        if let v = item.wrappedValue.variable, !v.isEmpty {
                            Text(verbatim: "${{ params.\(RecordingToWorkflow.parameterName(v)) }}").font(Theme.Font.monoSmall).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            Spacer(minLength: Theme.Space.s)
            Toggle("Redact", isOn: item.redacted).toggleStyle(.checkbox).accessibilityIdentifier("watch.redact.\(a.id)")
            Button { w.remove(a.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                .accessibilityLabel(Text("Remove this action")).accessibilityIdentifier("watch.remove.\(a.id)")
        }
        .padding(.vertical, Theme.Space.s)
    }

    // MARK: Proposal

    @ViewBuilder
    private func proposal(_ w: WatchModel) -> some View {
        if let p = w.proposal {
            if w.isSample { Banner(kind: .warning, text: String(localized: "Sample recording. These actions are synthetic and were not captured from this Mac.")) }
            if let id = w.savedWorkflowID {
                Banner(kind: .success, text: String(localized: "Saved as “\(p.document.metadata.name)”. It has not been run, and its permissions still need your acceptance before the first run."),
                       actionTitle: "Open in Workflow Studio") { model.open(.workflow(id)) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Space.l) { yamlCard(p).frame(minWidth: 420); sideCards(p, w).frame(minWidth: 320, maxWidth: 420) }
                VStack(alignment: .leading, spacing: Theme.Space.l) { sideCards(p, w); yamlCard(p) }
            }
            HStack(spacing: Theme.Space.s) {
                Button { w.beginReview(w.actions, sample: w.isSample) } label: { Label("Back to review", systemImage: "chevron.left") }
                    .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("watch.backToReview")
                Button(role: .destructive) { w.discard() } label: { Label(w.savedWorkflowID == nil ? LocalizedStringKey("Discard recording") : LocalizedStringKey("Done"), systemImage: w.savedWorkflowID == nil ? "trash" : "checkmark") }
                    .buttonStyle(SecondaryButtonStyle(tint: w.savedWorkflowID == nil ? Theme.danger : Theme.text)).accessibilityIdentifier("watch.finish")
                Spacer()
                if w.savedWorkflowID == nil {
                    Button { Task { await w.save() } } label: { BusyLabel(title: "Approve and save workflow", busy: w.saving, symbol: "checkmark.seal") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(w.hasErrors || p.document.spec.steps.isEmpty || w.saving).accessibilityIdentifier("watch.save")
                }
            }
        }
    }

    private func yamlCard(_ p: WorkflowProposal) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader("Proposed workflow", subtitle: "\(String(p.document.spec.steps.count)) step(s) from \(String(p.convertedActions)) action(s). Elements are found by role and title, never by position.")
                CodeBlock(text: p.yaml, maxHeight: 460)
            }
        }
    }

    private func sideCards(_ p: WorkflowProposal, _ w: WatchModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader("Permissions it declares", subtitle: "Only the recorded applications. You accept them before the first run.")
                    if p.capabilities.isEmpty { Text("None.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                    ForEach(Array(p.capabilities.enumerated()), id: \.offset) { _, c in CapabilityRow(c) }
                    if !p.document.spec.parameters.isEmpty {
                        Divider()
                        Text("Parameters").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                        ForEach(p.document.spec.parameters, id: \.name) { param in
                            HStack(spacing: 6) {
                                Text(param.name).font(Theme.Font.monoSmall)
                                Text(param.required ? LocalizedStringKey("required") : LocalizedStringKey("has a default")).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SectionHeader("Validation")
                    let errors = w.diagnostics.filter { $0.severity == .error }, warnings = w.diagnostics.filter { $0.severity == .warning }
                    if errors.isEmpty {
                        Label("Valid against the tools installed now.", systemImage: "checkmark.circle.fill").font(Theme.Font.body).foregroundStyle(Theme.success)
                    }
                    ForEach(errors, id: \.self) { d in Label(d.message, systemImage: "xmark.octagon.fill").font(Theme.Font.caption).foregroundStyle(Theme.danger) }
                    ForEach(warnings, id: \.self) { d in Label(d.message, systemImage: "exclamationmark.triangle.fill").font(Theme.Font.caption).foregroundStyle(Theme.warning) }
                    if !p.notes.isEmpty {
                        Divider()
                        Text("Left out or changed").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                        ForEach(p.notes, id: \.self) { n in Label(n, systemImage: "info.circle").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Explanation(String(localized: "A recording shows one way through the task. Test the workflow with a dry run in the studio before relying on it."))
                }
            }
        }
    }
}
