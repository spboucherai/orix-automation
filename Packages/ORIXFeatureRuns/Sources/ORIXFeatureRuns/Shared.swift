// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/Shared.swift
// Description: Small views shared by the Dashboard, Runs and Scheduler screens: card titles, copy buttons, ticking elapsed time, a labelled meter, compact run rows and the recovery sheet.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

struct CardTitle<Trailing: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.violet)
            Text(title).font(Theme.Font.heading).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.s)
            trailing
        }
    }
}

extension CardTitle where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, symbol: String) { self.title = title; self.symbol = symbol; self.trailing = EmptyView() }
}

/// Copies a value and confirms it for a moment.
struct CopyButton: View {
    let value: String
    let label: LocalizedStringKey
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10)) }
            .buttonStyle(.borderless).foregroundStyle(copied ? Theme.success : Theme.textTertiary)
            .accessibilityLabel(Text(label))
            .help(Text(label))
    }
}

/// Elapsed time of a run, ticking once a second while it is in flight.
struct ElapsedText: View {
    let run: RunRecord
    var body: some View {
        if run.status.isTerminal || run.startedAt == nil {
            Text(Format.duration(run.durationSeconds))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.duration(run.startedAt.map { max(0, context.date.timeIntervalSince($0)) }))
            }
        }
    }
}

/// A meter that states its value in words: the bar is never the only carrier.
struct LabeledMeter: View {
    let title: LocalizedStringKey
    let valueText: String
    let fraction: Double
    var detail: String?
    private var tint: Color { fraction >= 1 ? Theme.danger : (fraction >= 0.8 ? Theme.warning : Theme.violet) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(valueText).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSunken)
                    Capsule().fill(tint).frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 8)
            .overlay(Capsule().strokeBorder(Theme.stroke))
            if let detail { Text(detail).font(Theme.Font.caption).foregroundStyle(fraction >= 0.8 ? tint : Theme.textTertiary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title)).accessibilityValue(Text(valueText + (detail.map { ". " + $0 } ?? "")))
    }
}

/// One run on one line: status, title, kind, when, how long, cost.
struct RunLine: View {
    let run: RunRecord
    var showCost = true
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            StatusBadge(run.status, compact: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    Label(RunKind.title(run.kind), systemImage: RunKind.symbol(run.kind)).labelStyle(.titleAndIcon)
                    Text(verbatim: "·")
                    Text(Format.relative(run.startedAt ?? run.queuedAt))
                    Text(verbatim: "·")
                    ElapsedText(run: run)
                }
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            if showCost, run.usage.costUSD > 0 || !run.usage.costIsComplete {
                Text(Format.cost(run.usage.costUSD, complete: run.usage.costIsComplete)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A plain row button that highlights on hover and is reachable by keyboard.
struct RowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            label.padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
                .background(hover ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Decides what happens to a run a crash left unfinished. Agent runs: let the agent look and continue, or leave it.
/// Workflow runs: one explicit choice per step that was in flight.
struct RecoverySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let run: RunRecord
    @State private var loaded = false
    @State private var agentCheckpoint: AgentCheckpoint?
    @State private var workflowCheckpoint: WorkflowCheckpoint?
    @State private var choices: [String: Bool] = [:]   // step key → true = run again, false = mark done
    @State private var working = false
    @State private var failure: String?

    private var undecided: [InFlightStep] { (workflowCheckpoint?.inFlight ?? []).filter { !$0.isContainer && !$0.idempotent } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "bandage.fill").foregroundStyle(Theme.warning)
                Text("Recover this run").font(Theme.Font.title)
            }
            Text(run.title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
            Text("ORIX stopped while this run was in the middle of something. It did not finish, and nothing has been retried on its own.")
                .font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let failure { Banner(kind: .error, text: failure) }
            if !loaded {
                HStack { ProgressView().controlSize(.small); Text("Reading the last checkpoint").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
            } else if run.kind == "agent" { agentChoices }
            else { workflowChoices }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .background(Theme.surface)
        .task {
            agentCheckpoint = try? await model.services.store.get(AgentCheckpoint.self, collection: Collections.agentCheckpoints, id: run.id)
            workflowCheckpoint = try? await model.services.store.get(WorkflowCheckpoint.self, collection: Collections.workflowCheckpoints, id: run.id)
            loaded = true
        }
    }

    @ViewBuilder private var agentChoices: some View {
        if let cp = agentCheckpoint {
            if let call = cp.inFlightCall {
                Banner(kind: .warning, text: String(localized: "The action “\(call.toolID)” had started and its outcome is unknown. It will not be repeated automatically."))
            }
            choice(symbol: "eye", title: "Let the agent inspect and continue",
                   text: "The agent is told that the last action may or may not have happened. It looks at the current state first, then carries on from turn \(cp.turn). Approvals are asked again.",
                   button: "Inspect and continue", primary: true, id: "recovery.continue") {
                await act { try await model.services.runs.resumeAgentRun(runID: run.id, resolution: .treatAsUnknown) }
            }
            choice(symbol: "stop.circle", title: "Leave it stopped",
                   text: "Nothing more happens. The run stays in the history as it is, and you can still read its timeline.",
                   button: "Leave it stopped", primary: false, id: "recovery.leave") { dismiss() }
        } else {
            Banner(kind: .info, text: String(localized: "No checkpoint was saved for this run, so it cannot be continued. Its timeline shows how far it got."))
            HStack { Spacer(); Button { dismiss() } label: { Text("Close") }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction) }
        }
    }

    @ViewBuilder private var workflowChoices: some View {
        if let cp = workflowCheckpoint {
            Text("\(cp.results.count) steps had finished and will not run again.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            if undecided.isEmpty {
                Text("No step needs a decision: what was in flight is safe to run again.").font(Theme.Font.body).foregroundStyle(Theme.text)
            } else {
                Text("These steps were running. Check what they did, then choose for each one:").font(Theme.Font.body).foregroundStyle(Theme.text)
                ForEach(undecided, id: \.key) { step in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.stepID).font(Theme.Font.mono).foregroundStyle(Theme.text)
                            Text(step.kind).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Picker(selection: Binding(get: { choices[step.key].map { $0 ? 1 : 2 } ?? 0 }, set: { choices[step.key] = $0 == 0 ? nil : $0 == 1 })) {
                            Text("Choose").tag(0)
                            Text("Run it again").tag(1)
                            Text("It already happened: mark it done").tag(2)
                        } label: { Text("Decision for \(step.stepID)") }
                        .labelsHidden().frame(width: 260)
                        .accessibilityIdentifier("recovery.step.\(step.stepID)")
                    }
                    .padding(Theme.Space.s).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                }
                Text("“Mark it done” continues with an empty result for that step; later steps that read its output may fail.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { dismiss() } label: { Text("Leave it stopped") }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button {
                    Task {
                        var resolutions: [String: ORIXWorkflowEngine.InFlightResolution] = [:]
                        for step in undecided { resolutions[step.key] = choices[step.key] == true ? .rerun : .markSucceeded(output: .null) }
                        await act { try await model.services.workflows.resumeRun(runID: run.id, resolutions: resolutions) }
                    }
                } label: { Text("Resume the workflow") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(working || undecided.contains { choices[$0.key] == nil })
                    .accessibilityIdentifier("recovery.resumeWorkflow")
            }
        } else {
            Banner(kind: .info, text: String(localized: "No checkpoint was saved for this run, so it cannot be continued. Its timeline shows how far it got."))
            HStack { Spacer(); Button { dismiss() } label: { Text("Close") }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction) }
        }
    }

    private func choice(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey, button: LocalizedStringKey, primary: Bool, id: String,
                        action: @escaping () async -> Void) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(primary ? Theme.violet : Theme.textSecondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            if primary {
                Button { Task { await action() } } label: { Text(button) }.buttonStyle(PrimaryButtonStyle()).disabled(working).accessibilityIdentifier(id)
            } else {
                Button { Task { await action() } } label: { Text(button) }.buttonStyle(SecondaryButtonStyle()).disabled(working).accessibilityIdentifier(id)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func act(_ work: @escaping () async throws -> Void) async {
        working = true; failure = nil
        do { try await work(); working = false; model.open(.run(run.id)); dismiss() }
        catch { working = false; failure = Redactor.shared.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    }
}
