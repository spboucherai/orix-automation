// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Sources/orix-preview-code/main.swift
// Description      : Renders every Code Studio screen to PNG files on a
//                    throwaway data folder: `orix-preview-code --shot <dir>`.
//                    Scripts are really run through the services; approvals are
//                    answered automatically here and nowhere else.
// Module           : orix-preview-code
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
import ORIXFeatureCode
import SwiftUI

@MainActor
enum PreviewRunner {
    static let compact = CGSize(width: 1100, height: 700)
    static let large = CGSize(width: 1600, height: 1000)

    static func shot(_ name: String, _ studio: CodeStudioModel, _ model: AppModel, in dir: URL, size: CGSize = compact,
                     prepare: (@MainActor () -> Void)? = nil) async throws {
        for dark in [true, false] {
            if let prepare {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    prepare()
                }
            }
            let url = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try await ShotRenderer.render(CodeStudioView(studio: studio).environment(model), size: size, dark: dark, settle: prepare == nil ? 1.4 : 2.2, to: url)
            print("SHOT \(url.path)")
        }
    }

    static func makeStudio(_ model: AppModel, open id: String?) async -> CodeStudioModel {
        let studio = CodeStudioModel()
        await studio.workflow.reload(model.services)
        if let id {
            await studio.workflow.open(id, services: model.services)
            model.selectedWorkflowID = id
        }
        return studio
    }

    static func run(_ dir: URL) async throws {
        let model = try await PreviewEnvironment.make()
        let services = model.services
        // Preview only: every approval request is granted once, so the script runs below are real.
        let approver = Task {
            for await pending in services.approvals.updates() {
                for request in pending { await services.approvals.resolve(id: request.id, response: .approveOnce) }
            }
        }
        defer { approver.cancel() }
        let sample = "system-health-report"

        // 1. A stored workflow, highlighted.
        var studio = await makeStudio(model, open: sample)
        try await shot("workflow-editor", studio, model, in: dir)
        try await shot("workflow-editor-large", studio, model, in: dir, size: large)

        // 2. The same with intentional mistakes: squiggles, gutter markers and the problems list.
        studio = await makeStudio(model, open: sample)
        var broken = studio.workflow.text
        broken = broken.replacingOccurrences(of: "tool: system.info", with: "tool: system.infoo")
        broken = broken.replacingOccurrences(of: "maxToolCalls: 15", with: "maxToolCalls: 0")
        studio.workflow.text = broken + "    - id: last\n      needs: [doesNotExist]\n      delay: 1\n"
        await studio.workflow.validateNow()
        let firstError = studio.workflow.diagnostics.first { $0.line > 0 }
        try await shot("workflow-problems", studio, model, in: dir) { [studio] in
            if let d = firstError { studio.workflow.editor.goTo(line: d.line, column: d.column) }
        }

        // 3. Completion after `tool: `.
        studio = await makeStudio(model, open: nil)
        let typed = WorkflowSnippets.starter + "    - id: read\n      needs: [list]\n      tool: filesystem."
        studio.workflow.startNew(source: typed)
        await studio.workflow.validateNow()
        try await shot("workflow-completion", studio, model, in: dir) { [studio] in
            let end = (studio.workflow.text as NSString).length
            studio.workflow.editor.select(NSRange(location: end, length: 0))
            studio.workflow.editor.triggerCompletion(explicit: true)
            studio.workflow.editor.moveCompletion(4)
        }

        // 4. Diff of unsaved changes against the stored version, with the semantic change list.
        studio = await makeStudio(model, open: sample)
        var edited = studio.workflow.text
        edited = edited.replacingOccurrences(of: "notifications: true", with: "notifications: true\n    network: [example.com]")
        edited = edited.replacingOccurrences(of: "tool: system.info", with: "tool: system.info\n              timeoutSeconds: 20")
        studio.workflow.text = edited
        studio.diff = studio.workflow.unsavedDiff()
        try await shot("diff", studio, model, in: dir)

        // 5. The same workflow as JSON.
        studio = await makeStudio(model, open: sample)
        if let json = try? studio.workflow.formatted(as: .json) { studio.workflow.apply(json.text, format: .json) }
        await studio.workflow.validateNow()
        try await shot("workflow-json", studio, model, in: dir)

        // 6. Script workbench after really running a Python and a Bash script through the tools.
        studio = await makeStudio(model, open: nil)
        studio.tab = .scripts
        studio.scripts.language = .python
        studio.scripts.text = "import platform\n\nvalues = [3, 1, 4, 1, 5, 9, 2, 6]\nprint(f\"Python {platform.python_version()}\")\nprint(\"sum =\", sum(values), \"max =\", max(values))\n"
        let python = await studio.scripts.run(source: studio.scripts.text, defaultWorkspace: model.defaultWorkspace, services: services, console: studio.console)
        print("PYTHON \(python?.status.rawValue ?? "nil") exit=\(python?.exitCode.map(String.init) ?? "nil") \(python?.message ?? "")")
        studio.scripts.language = .bash
        studio.scripts.text = "#!/bin/bash\nset -euo pipefail\n\necho \"Working in $(basename \"$(pwd)\")\"\nfor n in 1 2 3; do\n    printf 'step %s of 3\\n' \"$n\"\ndone\nprintf '\\033[32mall steps done\\033[0m\\n'\nprintf '\\033[33mwarning: nothing was written\\033[0m\\n' >&2\n"
        let bash = await studio.scripts.run(source: studio.scripts.text, defaultWorkspace: model.defaultWorkspace, services: services, console: studio.console)
        print("BASH \(bash?.status.rawValue ?? "nil") exit=\(bash?.exitCode.map(String.init) ?? "nil") \(bash?.message ?? "")")
        try await shot("script-workbench", studio, model, in: dir)

        // 7. The assistant panel beside the editor (idle: nothing is sent by a preview).
        studio = await makeStudio(model, open: sample)
        studio.showAssistant = true
        try await shot("assistant", studio, model, in: dir)

        // 8. Tool documentation card.
        studio = await makeStudio(model, open: sample)
        studio.toolDoc = studio.workflow.tools.first { $0.identifier == "filesystem.write" }
        try await shot("tool-docs", studio, model, in: dir)

        // 9. Save as skill, after a real proposal (analysis + sandboxed tests).
        let form = SkillFormModel(language: .python, source: ScriptTemplates.templates(.python).first { $0.id == "python.skill" }?.body ?? "")
        form.name = "Count words"
        form.summary = "Counts the words and characters of a text."
        form.inputSchemaJSON = "{\n  \"type\": \"object\",\n  \"properties\": { \"text\": { \"type\": \"string\" } },\n  \"required\": [\"text\"],\n  \"additionalProperties\": false\n}"
        form.tests = [SkillTestDraft(name: "two words", inputJSON: "{\"text\": \"hello world\"}", expectSucceeded: true, expectOutputJSON: "{\"words\": 2}")]
        await form.submit(services)
        print("SKILL draft=\(form.draft?.id ?? "nil") installable=\(form.draft?.installable ?? false) problems=\(form.problems)")
        for dark in [true, false] {
            let url = dir.appendingPathComponent("skill-form-\(dark ? "dark" : "light").png")
            try await ShotRenderer.render(SkillFormView(form: form, onClose: {}, openSkills: {}).environment(model), size: CGSize(width: 640, height: 640), dark: dark, to: url)
            print("SHOT \(url.path)")
        }
    }
}

_ = NSApplication.shared
let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--shot"), flag + 1 < arguments.count else {
    print("usage: orix-preview-code --shot <directory>")
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[flag + 1])
Task { @MainActor in
    do { try await PreviewRunner.run(directory); exit(0) }
    catch { print("FAILED \(error)"); exit(1) }
}
RunLoop.main.run()
