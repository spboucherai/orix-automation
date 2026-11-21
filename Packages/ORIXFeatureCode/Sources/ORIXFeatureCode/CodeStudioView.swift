// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/CodeStudioView.swift
// Description      : Root of the Code Studio: the workflow code tab and the
//                    script workbench tab, sharing one console, one assistant
//                    and one diff panel.
// Module           : ORIXFeatureCode
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

/// Everything the Code Studio shows. One instance lives as long as the view; previews and tests build their own.
@MainActor
@Observable
public final class CodeStudioModel {
    public enum Tab: String, Sendable { case workflows, scripts }
    public enum BottomTab: String, Sendable { case problems, console }
    public var tab: Tab = .workflows
    public var bottomTab: BottomTab = .problems
    public var showAssistant = false
    /// The diff being reviewed, shown in place of the editor.
    public var diff: DiffPresentation?
    /// Format the buffer takes when the reviewed diff is accepted (format switch).
    public var diffTargetFormat: WorkflowFormat?
    /// The tool whose documentation card is open.
    public var toolDoc: ToolManifest?
    public let workflow = WorkflowCodeModel()
    public let scripts = ScriptWorkbenchModel()
    public let console = ConsoleBuffer()
    public let assistant = AssistantModel()

    public init() {
        workflow.editor.onOptionClick = { [weak self] offset in
            guard let self else { return }
            self.toolDoc = self.workflow.tool(at: offset)
        }
    }

    // MARK: Workflow commands

    /// Shows what formatting (or switching format) would change and drop; the buffer changes only on acceptance.
    public func requestFormat(as target: WorkflowFormat? = nil) {
        do {
            let result = try workflow.formatted(as: target)
            if result.text == workflow.text, target == nil || target == workflow.format {
                workflow.notice = (.info, String(localized: "The source is already in canonical form."))
                return
            }
            let switching = target != nil && target != workflow.format
            diffTargetFormat = switching ? target : nil
            diff = workflow.draftDiff(result.text,
                                      title: switching ? String(localized: "Switch to \(target == .json ? "JSON" : "YAML")") : String(localized: "Format the source"),
                                      notes: result.loss,
                                      acceptTitle: switching ? String(localized: "Switch format") : String(localized: "Apply format"))
        } catch {
            workflow.notice = (.error, String(localized: "The source cannot be rewritten until it parses: \(WorkflowCodeModel.describe(error))"))
            bottomTab = .problems
        }
    }

    /// Applies the reviewed diff to the buffer it belongs to.
    public func acceptDiff() {
        guard let d = diff else { return }
        switch d.acceptance {
        case .none: break
        case .replaceWorkflowBuffer: workflow.apply(d.new, format: diffTargetFormat)
        case .replaceScriptBuffer:
            if scripts.editor.isAttached { scripts.editor.replaceAll(with: d.new) } else { scripts.text = d.new }
        }
        assistant.proposal = nil
        diff = nil; diffTargetFormat = nil
    }

    public func closeDiff() { diff = nil; diffTargetFormat = nil }

    /// Opens the assistant's proposal in the diff panel.
    public func reviewProposal() {
        guard let p = assistant.proposal else { return }
        let title = String(localized: "Assistant proposal")
        switch p.subject {
        case .workflow:
            var d = workflow.draftDiff(p.replacement, title: title, acceptTitle: String(localized: "Replace the editor text"))
            d.old = workflow.text
            diff = d
        case .script:
            diff = DiffPresentation(title: title, old: scripts.text, new: p.replacement, oldTitle: String(localized: "Editor"), newTitle: String(localized: "Proposed"),
                                    acceptance: .replaceScriptBuffer, acceptTitle: String(localized: "Replace the editor text"))
        }
    }

    /// What the assistant receives for the current tab.
    public func assistantInput() -> AssistantInput {
        switch tab {
        case .workflows:
            let e = workflow.editor
            return AssistantInput(subject: .workflow(workflow.format), buffer: workflow.text, selection: e.selectedText, selectionRange: e.selectedRange,
                                  diagnostics: workflow.diagnostics, tools: workflow.tools)
        case .scripts:
            let e = scripts.editor
            return AssistantInput(subject: .script(scripts.language), buffer: scripts.text, selection: e.selectedText, selectionRange: e.selectedRange)
        }
    }
}

public struct CodeStudioView: View {
    @Environment(AppModel.self) private var model
    @State private var studio: CodeStudioModel

    public init() { _studio = State(initialValue: CodeStudioModel()) }
    /// For previews and tests: a studio prepared in a known state.
    public init(studio: CodeStudioModel) { _studio = State(initialValue: studio) }

    public var body: some View {
        @Bindable var studio = studio
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Code Studio").font(Theme.Font.title).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
                    Text("The source of your workflows, and a workbench for scripts.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                Picker("View", selection: $studio.tab) {
                    Text("Workflows").tag(CodeStudioModel.Tab.workflows)
                    Text("Scripts").tag(CodeStudioModel.Tab.scripts)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("code.tab")
                Toggle(isOn: $studio.showAssistant) { Label("Assistant", systemImage: "sparkles") }
                    .toggleStyle(.button).accessibilityIdentifier("code.assistant.toggle")
            }
            HStack(spacing: Theme.Space.m) {
                Group {
                    if let diff = studio.diff {
                        DiffPanel(studio: studio, presentation: diff)
                    } else {
                        switch studio.tab {
                        case .workflows: WorkflowCodeView(studio: studio)
                        case .scripts: ScriptWorkbenchView(studio: studio)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if studio.showAssistant {
                    AssistantPanel(studio: studio).frame(width: 300)
                }
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.canvas)
        .task(id: model.revision) {
            await studio.workflow.reload(model.services)
            await studio.scripts.restore(model.services)
        }
        .onDisappear { let s = studio, services = model.services; Task { await s.scripts.persist(services) } }
    }
}

// MARK: - Shared pieces

struct IconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var identifier: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22) }
            .buttonStyle(.borderless).help(Text(label)).accessibilityLabel(Text(label))
            .accessibilityIdentifier(identifier ?? "")
    }
}

/// The panel frame used by editors, lists and side panels.
struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// A diff under review: title, what will be dropped, the diff, and the decision.
struct DiffPanel: View {
    let studio: CodeStudioModel
    let presentation: DiffPresentation

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "plus.forwardslash.minus").foregroundStyle(Theme.violet)
                    Text(presentation.title).font(Theme.Font.heading).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Button { studio.closeDiff() } label: { Text(presentation.acceptance == .none ? "Close" : "Cancel") }
                        .buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction).accessibilityIdentifier("code.diff.close")
                    if presentation.acceptance != .none {
                        Button { studio.acceptDiff() } label: { Text(presentation.acceptTitle) }
                            .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("code.diff.accept")
                    }
                }
                if !presentation.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Rewriting from the model changes the text", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Font.captionStrong).foregroundStyle(Theme.warning)
                        ForEach(presentation.notes, id: \.self) { note in
                            Text(verbatim: "• " + note).font(Theme.Font.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                }
                DiffView(old: presentation.old, new: presentation.new, oldTitle: presentation.oldTitle, newTitle: presentation.newTitle, changes: presentation.changes)
            }
            .padding(Theme.Space.l)
        }
    }
}

/// The manifest of a tool, opened by ⌥-clicking its id.
struct ToolDocCard: View {
    let manifest: ToolManifest
    let onClose: () -> Void

    private var arguments: [(name: String, type: String, required: Bool, description: String)] {
        let props = manifest.inputSchema.raw["properties"]?.objectValue ?? [:]
        let required = manifest.inputSchema.raw["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let names = required.filter { props[$0] != nil } + props.keys.filter { !required.contains($0) }.sorted()
        return names.map { ($0, CompletionEngine.typeDescription(props[$0]), required.contains($0), props[$0]?["description"]?.stringValue ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: manifest.identifier).font(Theme.Font.mono.weight(.semibold)).foregroundStyle(Theme.text).textSelection(.enabled)
                Text(verbatim: manifest.name).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel(Text("Close the documentation"))
            }
            Text(verbatim: manifest.summary).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                TierBadge(tier: manifest.defaultTier)
                Pill(text: String(localized: "side effect: \(manifest.sideEffect.rawValue)"), symbol: "bolt")
                if manifest.supportsDryRun { Pill(text: String(localized: "dry run"), symbol: "eye", color: Theme.info) }
            }
            if !manifest.macPermissions.isEmpty {
                Label { Text("macOS permissions: \(manifest.macPermissions.map(\.rawValue).joined(separator: ", "))") } icon: { Image(systemName: "lock.shield") }
                    .font(Theme.Font.caption).foregroundStyle(Theme.warning)
            }
            if !arguments.isEmpty {
                Divider()
                Text("Arguments").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(arguments, id: \.name) { a in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(verbatim: a.name).font(Theme.Font.monoSmall.weight(.semibold)).foregroundStyle(Theme.text)
                                    Text(verbatim: a.type).font(Theme.Font.monoSmall).foregroundStyle(Theme.blue)
                                    if a.required { Text("required").font(Theme.Font.caption).foregroundStyle(Theme.warning) }
                                }
                                if !a.description.isEmpty { Text(verbatim: a.description).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 380, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.strokeStrong))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tool documentation"))
    }
}

// MARK: - Assistant

struct AssistantPanel: View {
    @Environment(AppModel.self) private var model
    let studio: CodeStudioModel

    private func title(_ action: AssistantAction) -> LocalizedStringKey {
        switch action {
        case .explain: return "Explain"
        case .generate: return "Generate"
        case .fix: return "Fix the reported problems"
        case .refactor: return "Refactor selection"
        }
    }

    private func symbol(_ action: AssistantAction) -> String {
        switch action {
        case .explain: return "text.magnifyingglass"
        case .generate: return "wand.and.stars"
        case .fix: return "bandage"
        case .refactor: return "arrow.triangle.2.circlepath"
        }
    }

    private func enabled(_ action: AssistantAction) -> Bool {
        let a = studio.assistant
        guard !a.isRunning else { return false }
        switch action {
        case .explain: return !(studio.tab == .workflows ? studio.workflow.text : studio.scripts.text).isEmpty
        case .generate: return !a.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .fix: return studio.tab == .workflows && !studio.workflow.diagnostics.isEmpty
        case .refactor: return (studio.tab == .workflows ? studio.workflow.editor : studio.scripts.editor).selectionLength > 0
        }
    }

    var body: some View {
        @Bindable var assistant = studio.assistant
        Panel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.violet)
                    Text("Assistant").font(Theme.Font.heading).foregroundStyle(Theme.text)
                    Spacer()
                    if let m = model.settings.defaultModel, !m.model.isEmpty {
                        ProviderGlyph(provider: m.provider, size: 18)
                        Text(verbatim: m.model).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                TextField(String(localized: "Ask about this file, or describe what to write"), text: $assistant.prompt, axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.Font.body).lineLimit(2...5)
                    .padding(Theme.Space.s)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                    .accessibilityIdentifier("code.assistant.prompt")
                VStack(spacing: 6) {
                    ForEach(AssistantAction.allCases) { action in
                        Button {
                            studio.assistant.run(action, input: studio.assistantInput(), app: model)
                        } label: {
                            Label(title(action), systemImage: symbol(action)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(SecondaryButtonStyle()).disabled(!enabled(action))
                        .accessibilityIdentifier("code.assistant.\(action.rawValue)")
                    }
                }
                Text("Nothing is sent until you press a button. The file, the selection and the listed problems go to the model above; the answer is limited to \(AssistantModel.maxOutputTokens) tokens.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                if let error = assistant.error {
                    Banner(kind: .error, text: error, actionTitle: assistant.needsModel ? "Open Settings" : nil,
                           action: assistant.needsModel ? { model.open(.section(.settings)) } : nil)
                }
                if assistant.isRunning {
                    HStack(spacing: Theme.Space.s) {
                        PulseDot(color: Theme.violet, active: true)
                        Text("Waiting for the model…").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button { studio.assistant.stop() } label: { Text("Stop") }.buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
                            .accessibilityIdentifier("code.assistant.stop")
                    }
                }
                if !assistant.answer.isEmpty {
                    ScrollView {
                        Text(verbatim: assistant.answer).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .padding(Theme.Space.s)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                } else {
                    Spacer(minLength: 0)
                }
                if assistant.proposal != nil {
                    Button { studio.reviewProposal() } label: { Label("Review the proposed changes", systemImage: "plus.forwardslash.minus").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("code.assistant.review")
                }
                if let usage = assistant.usage {
                    HStack(spacing: Theme.Space.s) {
                        Pill(text: String(localized: "in \(Format.tokens(usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens))"), symbol: "arrow.down")
                        Pill(text: String(localized: "out \(Format.tokens(usage.outputTokens))"), symbol: "arrow.up")
                        Pill(text: assistant.cost.map { Format.cost($0) } ?? String(localized: "cost unknown"), symbol: "dollarsign.circle")
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    if assistant.truncated {
                        Text("The answer stopped at the output limit.").font(Theme.Font.caption).foregroundStyle(Theme.warning)
                    }
                }
            }
            .padding(Theme.Space.l)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Assistant"))
    }
}
