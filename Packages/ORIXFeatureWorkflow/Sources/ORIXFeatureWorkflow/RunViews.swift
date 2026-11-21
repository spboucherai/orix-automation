// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/RunViews.swift
// Description: Running from the studio: the permission review sheet with the typed parameter form, the toolbar run controls, and the bottom drawer (events, approvals, variables while paused, outcome).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

/// Typed text entry for workflow parameters.
enum ParameterForm {
    static func text(_ p: WorkflowParameter) -> String { ArgumentForm.text(for: p.defaultValue) }

    /// Values to pass to a run. A field left at its default is not passed, so the default (which may be an expression) applies.
    static func values(_ parameters: [WorkflowParameter], texts: [String: String]) -> Result<[String: JSONValue], FormError> {
        var out: [String: JSONValue] = [:]
        for p in parameters {
            let raw = texts[p.name] ?? text(p)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw == text(p) && p.defaultValue != nil { continue }
            if trimmed.isEmpty {
                if p.required && p.defaultValue == nil { return .failure(FormError(message: String(localized: "“\(p.name)” is required."))) }
                continue
            }
            switch p.type {
            case .string, .path: out[p.name] = .string(raw)
            case .integer:
                guard let i = Int(trimmed) else { return .failure(FormError(message: String(localized: "“\(p.name)” must be a whole number."))) }
                out[p.name] = .int(i)
            case .number:
                guard let d = Double(trimmed.replacingOccurrences(of: ",", with: ".")), d.isFinite else { return .failure(FormError(message: String(localized: "“\(p.name)” must be a number."))) }
                out[p.name] = ArgumentForm.normalized(.number(d))
            case .boolean:
                guard trimmed == "true" || trimmed == "false" else { return .failure(FormError(message: String(localized: "“\(p.name)” must be true or false."))) }
                out[p.name] = .bool(trimmed == "true")
            case .array:
                let v = trimmed.hasPrefix("[") ? (try? JSONValue.parse(trimmed)) : JSONValue.array(trimmed.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { .string($0.trimmingCharacters(in: .whitespaces)) })
                guard let v, v.arrayValue != nil else { return .failure(FormError(message: String(localized: "“\(p.name)” must be a list."))) }
                out[p.name] = ArgumentForm.normalized(v)
            case .object:
                guard let v = try? JSONValue.parse(trimmed), v.objectValue != nil else { return .failure(FormError(message: String(localized: "“\(p.name)” must be a JSON object."))) }
                out[p.name] = ArgumentForm.normalized(v)
            }
        }
        return .success(out)
    }
}

struct PermissionReviewSheet: View {
    @Bindable var vm: WorkflowStudioModel
    let kind: RunKind
    @State private var texts: [String: String] = [:]
    @State private var review: PermissionReview?
    @State private var problem: String?
    @State private var starting = false

    private var parameters: [WorkflowParameter] { vm.savedDocument?.spec.parameters ?? [] }

    private var title: LocalizedStringKey {
        switch kind {
        case .run: return "Review before running"
        case .dryRun: return "Review before the dry run"
        case .debug: return "Review before debugging"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.Font.title).foregroundStyle(Theme.text)
                Text(verbatim: vm.savedDocument?.metadata.name ?? "").font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Space.l)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if kind == .dryRun {
                        Banner(kind: .info, text: String(localized: "Dry run: nothing is changed. Tools that can simulate are asked to; the others, agents, approvals and delays are not executed and are reported as simulated."))
                    } else if kind == .debug {
                        Banner(kind: .info, text: String(localized: "The run starts paused. Use Step over to run one step at a time, or Resume to run to the next breakpoint."))
                    }
                    if !parameters.isEmpty { parameterForm }
                    grants
                }
                .padding(Theme.Space.l)
            }
            Divider()
            HStack(spacing: Theme.Space.s) {
                Button("Cancel") { vm.runRequest = nil }.keyboardShortcut(.cancelAction).accessibilityIdentifier("workflow.review.cancel")
                Spacer()
                if starting { ProgressView().controlSize(.small) }
                if review?.accepted == true || review?.proposed.isEmpty == true {
                    Button { start(accept: false) } label: { Text(loc(kind == .dryRun, "Start dry run", loc(kind == .debug, "Start debugging", "Run"))) }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(review == nil || starting)
                        .accessibilityIdentifier("workflow.review.run")
                } else {
                    Button { start(accept: false) } label: { Text("Run and ask each time") }
                        .buttonStyle(SecondaryButtonStyle()).disabled(review == nil || starting)
                        .accessibilityIdentifier("workflow.review.askEachTime")
                    Button { start(accept: true) } label: { Text("Accept and run") }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(review == nil || starting)
                        .accessibilityIdentifier("workflow.review.accept")
                }
            }
            .padding(Theme.Space.l)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 560)
        .background(Theme.canvas)
        .task(id: texts) { await refresh() }
    }

    private var parameterForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Parameters").font(Theme.Font.heading)
            ForEach(parameters, id: \.name) { p in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: p.name).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                        Text(verbatim: p.type.rawValue).font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                        if p.required { Text("required").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.violet) }
                    }
                    let binding = Binding(get: { texts[p.name] ?? ParameterForm.text(p) }, set: { texts[p.name] = $0 })
                    if p.type == .boolean {
                        Toggle(isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" })) { EmptyView() }.labelsHidden().toggleStyle(.switch).controlSize(.small)
                    } else {
                        TextField("", text: binding).textFieldStyle(.roundedBorder).font(Theme.Font.monoSmall)
                            .accessibilityIdentifier("workflow.review.param.\(p.name)")
                    }
                    if !p.description.isEmpty { Text(verbatim: p.description).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
    }

    @ViewBuilder private var grants: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("What this workflow asks for").font(Theme.Font.heading)
            if let problem {
                Banner(kind: .error, text: problem)
            } else if let review {
                if review.proposed.isEmpty {
                    Text("It declares no permission. Each action that needs one will ask when it happens.").font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    if review.accepted {
                        Banner(kind: .success, text: String(localized: "You already accepted exactly these permissions for this workflow."))
                    } else {
                        Text("Accepting lets this workflow, and only this workflow, do the following without asking again, up to the tier shown. High-risk actions always ask. You can revoke this in Permissions.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(review.proposed.enumerated()), id: \.element.id) { i, g in
                            HStack(alignment: .center, spacing: Theme.Space.s) {
                                CapabilityRow(g.capability)
                                TierBadge(tier: g.maxTier).fixedSize()
                            }
                            .padding(.vertical, 7).padding(.horizontal, Theme.Space.m)
                            if i < review.proposed.count - 1 { Divider() }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
                    .accessibilityIdentifier("workflow.review.grants")
                }
            } else {
                SkeletonLine(width: 260); SkeletonLine(width: 200)
            }
        }
    }

    private func values() -> [String: JSONValue]? {
        switch ParameterForm.values(parameters, texts: texts) {
        case .success(let v): return v
        case .failure(let e): problem = e.message; review = nil; return nil
        }
    }

    private func refresh() async {
        guard let id = vm.workflowID, let values = values() else { return }
        do {
            let r = try await vm.services.workflows.permissionReview(workflowID: id, parameters: values)
            problem = nil
            review = r
        } catch {
            review = nil
            problem = WorkflowStudioModel.message(error)
        }
    }

    private func start(accept: Bool) {
        guard let values = values() else { return }
        starting = true
        Task {
            if await vm.start(kind, parameters: values, accept: accept) != nil { vm.runRequest = nil }
            starting = false
        }
    }
}

// MARK: - Toolbar controls

struct RunControls: View {
    @Bindable var vm: WorkflowStudioModel
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            if vm.runIsLive, let status = vm.runStatus {
                StatusBadge(status, compact: compact).fixedSize()
                if vm.runIsDry, !compact { Pill(text: String(localized: "dry run"), symbol: "eye", color: Theme.info) }
                if vm.runIsPaused {
                    control("play.fill", "Resume") { vm.resumeRun() }.accessibilityIdentifier("workflow.run.resume")
                } else {
                    control("pause.fill", "Pause before the next step") { vm.pauseRun() }.accessibilityIdentifier("workflow.run.pause")
                }
                control("arrow.turn.down.right", "Step over: run one step, then pause") { vm.stepOver() }.accessibilityIdentifier("workflow.run.stepOver")
                control("stop.fill", "Stop the run", tint: Theme.danger) { vm.stopRun() }.accessibilityIdentifier("workflow.run.stop")
            } else {
                if vm.isStartingRun { ProgressView().controlSize(.small) }
                Button { Task { await vm.requestRun(.run) } } label: { runLabel("Run", "play.fill") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(disabled)
                    .keyboardShortcut("r", modifiers: .command)
                    .help(Text(disabledReason ?? "Run this workflow"))
                    .accessibilityIdentifier("workflow.run.run")
                Button { Task { await vm.requestRun(.dryRun) } } label: { runLabel("Dry run", "eye") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(disabled)
                    .help(Text("Simulate: nothing is changed, and the result says what was simulated"))
                    .accessibilityIdentifier("workflow.run.dry")
                Button { Task { await vm.requestRun(.debug) } } label: { runLabel("Debug", "ladybug") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(disabled)
                    .help(Text("Start paused and stop at breakpoints"))
                    .accessibilityIdentifier("workflow.run.debug")
                Menu {
                    Button("Run with options…") { Task { await vm.requestRun(.run, alwaysReview: true) } }
                    Button("Dry run with options…") { Task { await vm.requestRun(.dryRun, alwaysReview: true) } }
                    Button("Debug with options…") { Task { await vm.requestRun(.debug, alwaysReview: true) } }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(disabled)
                .help(Text("Choose parameters and review permissions first")).accessibilityLabel(Text("More ways to run"))
            }
        }
    }

    @ViewBuilder private func runLabel(_ title: LocalizedStringKey, _ symbol: String) -> some View {
        if compact { Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(height: 16) } else { Label(title, systemImage: symbol).lineLimit(1).fixedSize() }
    }

    private var disabled: Bool { vm.document == nil || !vm.errors.isEmpty || vm.isStartingRun }
    private var disabledReason: LocalizedStringKey? { vm.errors.isEmpty ? nil : "Fix the errors before running" }

    private func control(_ symbol: String, _ label: LocalizedStringKey, tint: Color = Theme.text, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 18, height: 16) }
            .buttonStyle(SecondaryButtonStyle(tint: tint)).help(Text(label)).accessibilityLabel(Text(label))
    }
}

// MARK: - Drawer

struct RunDrawer: View {
    @Bindable var vm: WorkflowStudioModel
    let runID: String
    enum Tab: String, CaseIterable { case events, attention, variables, summary }
    @State private var tab: Tab = .events

    private var attentionCount: Int {
        vm.app.pendingApprovals.filter { $0.access.runID == runID }.count + vm.app.pendingInteractions.filter { item in
            switch item { case .question(let q): return q.runID == runID; case .plan(let p): return p.runID == runID }
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                if let s = vm.runStatus { StatusBadge(s).fixedSize() }
                if vm.runIsDry { Pill(text: String(localized: "dry run"), symbol: "eye", color: Theme.info).fixedSize() }
                if vm.canvasSize.width >= 760 {
                    Text(verbatim: vm.runRecord?.title ?? "").font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).lineLimit(1)
                    if let started = vm.runRecord?.startedAt { Text(verbatim: relativeOrNow(started)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize() }
                }
                Spacer()
                Picker(selection: $tab) {
                    Text("Events").tag(Tab.events)
                    Text(loc(attentionCount > 0, "Needs you (\(attentionCount))", "Needs you")).tag(Tab.attention)
                    Text("Variables").tag(Tab.variables)
                    Text("Outcome").tag(Tab.summary)
                } label: { EmptyView() }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("workflow.drawer.tabs")
                Button { vm.app.open(.run(runID)) } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(Text("Open in Runs")).accessibilityLabel(Text("Open in Runs"))
                Button { vm.showDrawer = false } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(Text("Hide the run panel")).accessibilityLabel(Text("Hide the run panel"))
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 7)
            Divider()
            Group {
                switch tab {
                case .events: RunEventList(runID: runID)
                case .attention: attention
                case .variables: variables
                case .summary: summary
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surface)
        .onChange(of: attentionCount) { old, new in if new > old { tab = .attention } }
        .onChange(of: vm.runOutcome?.runID) { _, new in if new != nil { tab = .summary } }
        .onChange(of: vm.runIsPaused) { _, paused in if paused, vm.runKind == .debug { tab = .variables } }
        .onAppear { if vm.runOutcome != nil || (vm.runRecord?.status.isTerminal ?? false) { tab = .summary } }
    }

    @ViewBuilder private var attention: some View {
        if attentionCount == 0 {
            Text("Nothing is waiting for you in this run.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        } else {
            ScrollView { AttentionStack(runID: runID).padding(Theme.Space.m).frame(maxWidth: 620) }
        }
    }

    @ViewBuilder private var variables: some View {
        if vm.runHandle != nil, vm.runIsPaused {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let at = vm.runState?.pausedAt, !at.isEmpty {
                        Text("Paused before: \(at.joined(separator: ", "))").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if vm.runVariables.isEmpty { Text("No variable is set yet.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                    ForEach(vm.runVariables.keys.sorted(), id: \.self) { name in
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            Text(verbatim: name).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).frame(width: 140, alignment: .leading).padding(.top, 5)
                            CommitField(value: ArgumentForm.text(for: vm.runVariables[name]), mono: true, identifier: "workflow.drawer.variable.\(name)") { text in
                                Task { _ = await vm.setVariable(name, text: text) }
                                return nil
                            }
                        }
                    }
                    Text("A changed value is used by the steps that start afterwards.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Variables can be read and changed while a run started with Debug is paused.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private var summary: some View {
        let outcome = vm.runOutcome
        let receipt = vm.runReceipt
        let verifications = outcome?.verifications ?? receipt?.verifications ?? []
        let artifacts = outcome?.artifacts ?? receipt?.artifacts ?? []
        let errors = outcome?.errors ?? receipt?.errors ?? []
        let simulated = outcome?.simulations ?? (vm.runIsDry ? (receipt?.limitations ?? []) : [])
        let counts = Dictionary(grouping: vm.stepInfo.values, by: \.status).mapValues(\.count)
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if vm.runIsLive {
                    Text("The run is still going. The outcome appears here when it ends.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
                HStack(spacing: Theme.Space.s) {
                    if let s = vm.runStatus { StatusBadge(s) }
                    ForEach(StepStatus.allCases.filter { counts[$0] != nil }, id: \.self) { s in
                        Pill(text: "\(counts[s] ?? 0) " + StepStyle.of(s).label.lowercased(), symbol: StepStyle.of(s).symbol, color: StepStyle.of(s).color)
                    }
                    if let r = vm.runRecord, let a = r.startedAt, let b = r.endedAt { Text(verbatim: Format.duration(b.timeIntervalSince(a))).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                }
                if vm.runIsDry {
                    Banner(kind: .info, text: String(localized: "Dry run: nothing was changed. The status says how the simulation went, not how a real run would."))
                    if !simulated.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("What was simulated").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                            ForEach(Array(simulated.enumerated()), id: \.offset) { _, line in
                                Label { Text(verbatim: line).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).textSelection(.enabled) } icon: { Image(systemName: "eye").foregroundStyle(Theme.info) }
                            }
                        }
                        .accessibilityIdentifier("workflow.drawer.simulated")
                    }
                }
                ForEach(Array(errors.enumerated()), id: \.offset) { _, e in Banner(kind: .error, text: e) }
                if !verifications.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Checks").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                        ForEach(verifications) { v in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: v.passed ? "checkmark.seal.fill" : "xmark.seal.fill").foregroundStyle(v.passed ? Theme.success : Theme.danger)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: (v.passed ? String(localized: "Passed") : String(localized: "Failed")) + " · " + v.assertion).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled)
                                    if !v.evidence.isEmpty { Text(verbatim: v.evidence).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(3) }
                                }
                            }
                        }
                    }
                }
                if !artifacts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Files produced").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                        ForEach(artifacts) { a in
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "doc").foregroundStyle(Theme.textSecondary)
                                Text(verbatim: PathResolver.display(a.path)).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                if a.bytes > 0 { Text(verbatim: Format.bytes(a.bytes)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                                Spacer()
                                let exists = FileManager.default.fileExists(atPath: a.path)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) } label: { Text("Reveal in Finder") }
                                    .buttonStyle(.link).disabled(!exists)
                                    .help(Text(loc(exists, "Show this file in the Finder", "The file is not there any more")))
                            }
                        }
                    }
                    .accessibilityIdentifier("workflow.drawer.artifacts")
                }
                if !vm.runIsLive, verifications.isEmpty, artifacts.isEmpty, errors.isEmpty, !vm.runIsDry {
                    Text("This run recorded no check, file or error.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
