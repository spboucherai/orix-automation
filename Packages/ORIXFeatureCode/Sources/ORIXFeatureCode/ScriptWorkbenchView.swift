// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/ScriptWorkbenchView.swift
// Description      : The script workbench tab: a scratch editor per language
//                    with templates, run / run selection / stop through the
//                    policy engine, the approval card, the console, and the
//                    "save as skill" form.
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

struct ScriptWorkbenchView: View {
    @Environment(AppModel.self) private var model
    let studio: CodeStudioModel
    @State private var skillForm: SkillFormModel?

    private var scripts: ScriptWorkbenchModel { studio.scripts }

    private func run(selectionOnly: Bool) {
        let source = selectionOnly ? scripts.editor.selectedText : scripts.text
        Task {
            await scripts.persist(model.services)
            await scripts.run(source: source, selectionOnly: selectionOnly, defaultWorkspace: model.defaultWorkspace, services: model.services, console: studio.console)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use this folder")
        panel.directoryURL = URL(fileURLWithPath: scripts.effectiveDirectory(default: model.defaultWorkspace))
        if panel.runModal() == .OK, let url = panel.url { scripts.workingDirectory = url.path }
    }

    var body: some View {
        @Bindable var scripts = studio.scripts
        VStack(spacing: Theme.Space.m) {
            Panel {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    optionsRow
                    if let notice = scripts.notice {
                        Banner(kind: notice.kind, text: notice.text, actionTitle: "Dismiss") { studio.scripts.notice = nil }
                            .padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s)
                    }
                    CodeEditor(text: $scripts.text, language: scripts.language.codeLanguage, controller: scripts.editor)
                        .padding(.horizontal, Theme.Space.s).padding(.bottom, Theme.Space.s)
                }
            }
            if let runID = scripts.currentRunID, model.pendingApprovals.contains(where: { $0.access.runID == runID }) {
                ScrollView { AttentionStack(runID: runID) }.frame(maxHeight: 260)
            }
            Panel {
                VStack(spacing: 0) {
                    runStatus
                    Divider()
                    ConsoleView(buffer: studio.console)
                }
            }
            .frame(height: 230)
        }
        .sheet(item: $skillForm) { form in
            SkillFormView(form: form) { skillForm = nil } openSkills: { skillForm = nil; model.open(.section(.skills)) }
                .environment(model)
        }
    }

    private var toolbar: some View {
        @Bindable var scripts = studio.scripts
        return HStack(spacing: Theme.Space.s) {
            Picker("Language", selection: $scripts.language) {
                ForEach(WorkbenchLanguage.allCases) { l in Text(verbatim: l.displayName).tag(l) }
            }
            .labelsHidden().fixedSize().disabled(scripts.isRunning).accessibilityIdentifier("code.script.language")
            Menu {
                ForEach(ScriptTemplates.templates(scripts.language)) { t in
                    Button(t.title) { if scripts.editor.isAttached { scripts.editor.replaceAll(with: t.body) } else { studio.scripts.text = t.body } }
                }
            } label: { Label("Templates", systemImage: "doc.badge.plus") }
            .fixedSize().help(Text("Replace the buffer with a template (undo brings the text back)")).accessibilityIdentifier("code.script.templates")
            IconButton(symbol: "magnifyingglass", label: "Find and replace") { scripts.editor.showFind(replace: true) }
            Button { scripts.editor.toggleComment() } label: { Image(systemName: "number").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22) }
                .buttonStyle(.borderless).keyboardShortcut("/", modifiers: .command).help(Text("Comment or uncomment the selected lines"))
                .accessibilityLabel(Text("Comment or uncomment the selected lines"))
            Spacer(minLength: Theme.Space.s)
            Button {
                skillForm = SkillFormModel(language: scripts.language, source: scripts.text)
            } label: { Label("Save as skill…", systemImage: "puzzlepiece.extension") }
            .buttonStyle(SecondaryButtonStyle()).disabled(scripts.language.skillRuntime == nil)
            .help(Text(scripts.language.skillRuntime == nil ? "Skills can be written in Python or Bash" : "Propose this script as a reusable skill"))
            .accessibilityIdentifier("code.script.saveSkill")
            if scripts.isRunning {
                Button { Task { await studio.scripts.stop(services: model.services) } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("code.script.stop")
            } else {
                Button { run(selectionOnly: true) } label: { Text("Run selection") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(scripts.editor.selectionLength == 0)
                    .accessibilityIdentifier("code.script.runSelection")
                Button { run(selectionOnly: false) } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut("r", modifiers: .command)
                    .accessibilityIdentifier("code.script.run")
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
    }

    private var optionsRow: some View {
        @Bindable var scripts = studio.scripts
        return HStack(spacing: Theme.Space.s) {
            Button(action: chooseFolder) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(verbatim: PathResolver.display(scripts.effectiveDirectory(default: model.defaultWorkspace))).lineLimit(1).truncationMode(.middle)
                }
                .font(Theme.Font.caption)
            }
            .buttonStyle(.borderless).disabled(scripts.isRunning)
            .help(Text("Choose the working folder")).accessibilityLabel(Text("Working folder")).accessibilityIdentifier("code.script.folder")
            Picker("Folder access", selection: $scripts.access) {
                Text("Read only").tag(WorkspaceAccess.read)
                Text("Read and write").tag(WorkspaceAccess.readWrite)
            }
            .labelsHidden().fixedSize().controlSize(.small).disabled(scripts.isRunning)
            .help(Text("What the script may do in the working folder during this run")).accessibilityIdentifier("code.script.access")
            if scripts.language.usesTargets {
                TextField(String(localized: "Target apps (bundle ids, separated by commas)"), text: $scripts.targets)
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(maxWidth: 280)
                    .help(Text("Every application the script addresses must be listed. Leave empty for a script that only computes."))
                    .accessibilityIdentifier("code.script.targets")
            }
            Spacer(minLength: 0)
            Text("Line \(scripts.editor.cursorLine), column \(scripts.editor.cursorColumn)").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).monospacedDigit()
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
    }

    private var runStatus: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Console").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
            if scripts.isRunning {
                StatusBadge(model.pendingApprovals.contains { $0.access.runID == scripts.currentRunID } ? .waitingApproval : .running)
            } else if let last = scripts.last {
                StatusBadge(last.status)
                if let code = last.exitCode { Text("Exit code \(code)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).monospacedDigit() }
                Text(verbatim: Format.duration(last.durationSeconds)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).monospacedDigit()
                Button("Open in Runs") { model.open(.run(last.runID)) }.buttonStyle(.link).font(Theme.Font.caption)
                    .accessibilityIdentifier("code.script.openRun")
            } else {
                Text("Run a script to see its output here.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
    }
}

extension SkillFormModel: Identifiable {}

/// Proposes the current script as a skill. Installing stays in the Skills section.
public struct SkillFormView: View {
    @Environment(AppModel.self) private var model
    let form: SkillFormModel
    let onClose: () -> Void
    let openSkills: () -> Void

    public init(form: SkillFormModel, onClose: @escaping () -> Void, openSkills: @escaping () -> Void) {
        self.form = form; self.onClose = onClose; self.openSkills = openSkills
    }

    private func field(_ title: LocalizedStringKey, _ hint: LocalizedStringKey? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
            content()
            if let hint { Text(hint).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func codeField(_ text: Binding<String>, lines: ClosedRange<Int>) -> some View {
        TextField("", text: text, axis: .vertical).textFieldStyle(.plain).font(Theme.Font.monoSmall).lineLimit(lines)
            .padding(Theme.Space.s).background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }

    public var body: some View {
        @Bindable var form = form
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Save as skill", systemImage: "puzzlepiece.extension").font(Theme.Font.heading)
                Spacer()
                Pill(text: SkillFormModel.identifier(from: form.name), symbol: "number")
            }
            .padding(Theme.Space.l)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text("A skill is a reusable tool. It reads its input as one JSON object on standard input and prints one JSON object on standard output. It is analysed and its tests run in a sandbox before anything is installed.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if let draft = form.draft { result(draft) }
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        field("Name") { TextField(String(localized: "Count words"), text: $form.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("code.skill.name") }
                        field("Runtime") {
                            Picker("Runtime", selection: $form.runtime) { Text(verbatim: "Python").tag("python"); Text(verbatim: "Bash").tag("bash") }
                                .labelsHidden().fixedSize()
                        }
                    }
                    field("Summary", "One sentence a model can use to decide when to call the skill.") {
                        TextField(String(localized: "Counts the words of a text"), text: $form.summary).textFieldStyle(.roundedBorder).accessibilityIdentifier("code.skill.summary")
                    }
                    field("Input schema (JSON Schema, an object)") { codeField($form.inputSchemaJSON, lines: 4...9).accessibilityIdentifier("code.skill.schema") }
                    field("Permissions", "One entry per line. Paths are absolute, start with ~/, or name an input field as $input.<field>. No network host means the skill runs offline.") {
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            VStack(alignment: .leading, spacing: 2) { Text("Read").font(Theme.Font.caption); codeField($form.fileRead, lines: 2...4) }
                            VStack(alignment: .leading, spacing: 2) { Text("Write").font(Theme.Font.caption); codeField($form.fileWrite, lines: 2...4) }
                            VStack(alignment: .leading, spacing: 2) { Text("Network hosts").font(Theme.Font.caption); codeField($form.network, lines: 2...4) }
                        }
                    }
                    field("Tests", "At least one. A test passes when the run ends as expected and every expected output value matches.") {
                        ForEach($form.tests) { $test in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    TextField(String(localized: "Test name"), text: $test.name).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                                    Toggle("Must succeed", isOn: $test.expectSucceeded).toggleStyle(.checkbox)
                                    Spacer()
                                    Button { form.tests.removeAll { $0.id == test.id } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless).disabled(form.tests.count <= 1).accessibilityLabel(Text("Remove this test"))
                                }
                                HStack(alignment: .top, spacing: Theme.Space.s) {
                                    VStack(alignment: .leading, spacing: 2) { Text("Input (JSON object)").font(Theme.Font.caption); codeField($test.inputJSON, lines: 1...4) }
                                    VStack(alignment: .leading, spacing: 2) { Text("Expected output values (JSON object, optional)").font(Theme.Font.caption); codeField($test.expectOutputJSON, lines: 1...4) }
                                }
                            }
                            .padding(Theme.Space.s)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).strokeBorder(Theme.stroke))
                        }
                        Button { form.tests.append(SkillTestDraft(name: "test \(form.tests.count + 1)")) } label: { Label("Add a test", systemImage: "plus") }
                            .buttonStyle(.borderless)
                    }
                    if !form.problems.isEmpty {
                        Banner(kind: .error, text: form.problems.joined(separator: "\n"))
                    }
                }
                .padding(Theme.Space.l)
            }
            Divider()
            HStack {
                Button { onClose() } label: { Text("Close") }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if form.draft != nil {
                    Button { openSkills() } label: { Text("Review and install in Skills") }.buttonStyle(SecondaryButtonStyle(tint: Theme.violet))
                        .accessibilityIdentifier("code.skill.openSkills")
                }
                Button { Task { await form.submit(model.services) } } label: {
                    HStack(spacing: 5) { if form.isSubmitting { ProgressView().controlSize(.small) }; Text(form.draft == nil ? "Analyse and test" : "Analyse and test again") }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(form.isSubmitting).accessibilityIdentifier("code.skill.submit")
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 640, height: 640)
        .background(Theme.surface)
    }

    @ViewBuilder private func result(_ draft: SkillDraft) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Banner(kind: draft.installable ? .success : .warning,
                   text: draft.installable ? String(localized: "The draft passed analysis and its tests. Install it from the Skills section.")
                                           : String(localized: "The draft was created but cannot be installed yet: see the findings and tests below."))
            Text("Analysis").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
            if draft.findings.isEmpty { Text("No finding.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            ForEach(Array(draft.findings.enumerated()), id: \.offset) { _, f in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Pill(text: f.severity.rawValue, color: f.severity == .blocker ? Theme.danger : (f.severity == .warning ? Theme.warning : Theme.info))
                    Text(verbatim: "\(f.file):\(f.line)").font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary)
                    Text(verbatim: f.message).font(Theme.Font.caption).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Tests").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
            ForEach(Array(draft.tests.enumerated()), id: \.offset) { _, t in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Label(t.passed ? "Passed" : "Failed", systemImage: t.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(Theme.Font.captionStrong).foregroundStyle(t.passed ? Theme.success : Theme.danger)
                    Text(verbatim: t.name).font(Theme.Font.caption).foregroundStyle(Theme.text)
                    Text(verbatim: Format.duration(Double(t.durationMs) / 1000)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    if !t.detail.isEmpty { Text(verbatim: t.detail).font(Theme.Font.monoSmall).foregroundStyle(Theme.textSecondary).lineLimit(3) }
                }
            }
        }
    }
}
