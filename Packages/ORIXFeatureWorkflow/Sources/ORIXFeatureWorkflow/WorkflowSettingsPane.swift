// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/WorkflowSettingsPane.swift
// Description      : Workflow-level settings shown in the inspector when no
//                    step is selected: metadata, triggers with their next fire
//                    times, parameters, declared permissions and budget.
// Module           : ORIXFeatureWorkflow
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

import ORIXAppUI
import SwiftUI

/// The next instants a trigger fires, computed with the scheduler's own cron and interval maths.
enum TriggerPreview {
    static func spec(_ t: WorkflowTrigger) -> TriggerSpec? {
        switch t {
        case .schedule(let cron, let tz): return .cron(expression: cron, timezone: tz)
        case .interval(let s): return .interval(seconds: s)
        case .once(let at): return ISO8601DateFormatter().date(from: at).map { .once(at: $0) }
        default: return nil
        }
    }

    /// Up to `count` fire dates after `now`. Empty for event triggers and for invalid schedules.
    static func nextFireDates(_ t: WorkflowTrigger, after now: Date = Date(), count: Int = 3) -> [Date] {
        if case .schedule(let cron, let tz) = t {
            guard let expr = try? CronExpression(cron) else { return [] }
            let zone: TimeZone
            if let tz { guard let z = TimeZone(identifier: tz) else { return [] }; zone = z } else { zone = .current }
            var out: [Date] = []
            var cursor = now
            while out.count < count, let next = expr.nextFireDate(after: cursor, in: zone) { out.append(next); cursor = next }
            return out
        }
        guard let spec = spec(t), spec.problems().isEmpty else { return [] }
        var out: [Date] = []
        var cursor = now
        // An interval is counted from when its schedule is created; "from now" is what saving it now would give.
        while out.count < count, let next = spec.nextFireDate(after: cursor, anchor: now) { out.append(next); cursor = next }
        return out
    }

    static func problems(_ t: WorkflowTrigger) -> [String] { spec(t)?.problems() ?? [] }
}

struct WorkflowSettingsPane: View {
    @Bindable var vm: WorkflowStudioModel
    let document: WorkflowDocument
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            metadata
            triggers
            parameters
            permissions
            budget
        }
    }

    private func edit(_ body: @escaping (inout WorkflowDocument) -> Void) -> String? { vm.updateDocument(body) }

    private func editParameter(_ i: Int, _ body: @escaping (inout WorkflowParameter) -> Void) -> String? {
        edit { doc in if doc.spec.parameters.indices.contains(i) { body(&doc.spec.parameters[i]) } }
    }

    // MARK: Metadata

    private var metadata: some View {
        InspectorSection(title: "Workflow") {
            KeyValueRow(key: "Identifier", value: document.metadata.id, mono: true)
            CommitField(title: "Name", value: document.metadata.name, identifier: "workflow.settings.name") { text in
                let t = text.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? String(localized: "A workflow needs a name.") : edit { $0.metadata.name = t }
            }
            CommitField(title: "Description", value: document.metadata.description, multiline: true) { text in edit { $0.metadata.description = text } }
            CommitField(title: "Tags (comma separated)", value: document.metadata.tags.joined(separator: ", ")) { text in
                edit { $0.metadata.tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            }
        }
    }

    // MARK: Triggers

    private var triggers: some View {
        InspectorSection(title: "Triggers") {
            if document.spec.triggers.isEmpty { Text("No trigger. The workflow only runs when started by hand.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            ForEach(Array(document.spec.triggers.enumerated()), id: \.offset) { i, t in triggerRow(i, t) }
            Menu {
                Button("Manual") { add(.manual) }
                Button("Schedule") { add(.schedule(cron: "0 9 * * 1-5", timezone: TimeZone.current.identifier)) }
                Button("Interval") { add(.interval(seconds: 3600)) }
                Button("File change") { add(.fileChange(path: "~/Documents", glob: nil, debounceSeconds: nil)) }
                Button("Login") { add(.login) }
            } label: { Label("Add trigger", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityIdentifier("workflow.settings.addTrigger")
            if document.spec.triggers.contains(where: { $0 != .manual }) {
                Text("Schedules created from triggers start switched off. Turn them on in the Scheduler after saving.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            InlineError(text: error)
        }
    }

    private func add(_ t: WorkflowTrigger) { error = edit { $0.spec.triggers.append(t) } }

    private func replace(_ i: Int, _ t: WorkflowTrigger) -> String? {
        edit { doc in if doc.spec.triggers.indices.contains(i) { doc.spec.triggers[i] = t } }
    }

    private static func title(_ t: WorkflowTrigger) -> LocalizedStringKey {
        switch t {
        case .manual: return "Manual"
        case .schedule: return "Schedule"
        case .once: return "Once"
        case .interval: return "Interval"
        case .fileChange: return "File change"
        case .login: return "Login"
        case .appLaunch: return "App launch"
        }
    }

    @ViewBuilder private func triggerRow(_ i: Int, _ t: WorkflowTrigger) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(CategoryStyle.amber)
                Text(Self.title(t)).font(Theme.Font.bodyStrong)
                Spacer()
                Button {
                    error = edit { doc in
                        if doc.spec.triggers.indices.contains(i) { doc.spec.triggers.remove(at: i) }
                        doc.spec.layout = doc.spec.layout.filter { !$0.key.hasPrefix("trigger:") }
                    }
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).accessibilityLabel(Text("Remove this trigger"))
            }
            switch t {
            case .manual: Text("Started with the Run button.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            case .login: Text("Starts when you log in, if its schedule is switched on.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            case .schedule(let cron, let tz):
                CommitField(title: "Cron (minute hour day month weekday)", value: cron, mono: true, identifier: "workflow.settings.cron") { text in
                    let c = text.trimmingCharacters(in: .whitespaces)
                    do { _ = try CronExpression(c) } catch { return "\(error)" }
                    return replace(i, .schedule(cron: c, timezone: tz))
                }
                CommitField(title: "Time zone", value: tz ?? "", prompt: String(localized: "this Mac's time zone"), mono: true) { text in
                    let z = text.trimmingCharacters(in: .whitespaces)
                    if !z.isEmpty, TimeZone(identifier: z) == nil { return String(localized: "“\(z)” is not a known time zone. Use a name such as America/Toronto.") }
                    return replace(i, .schedule(cron: cron, timezone: z.isEmpty ? nil : z))
                }
                fireTimes(t)
            case .interval(let s):
                NumberField(title: "Every (seconds)", value: s) { v in
                    guard let v, v >= 1 else { return String(localized: "Use 1 second or more.") }
                    return replace(i, .interval(seconds: v))
                }
                fireTimes(t)
            case .once(let at):
                CommitField(title: "At (ISO 8601)", value: at, mono: true) { text in
                    ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespaces)) == nil ? String(localized: "Use a date such as 2027-01-31T09:00:00Z.") : replace(i, .once(at: text.trimmingCharacters(in: .whitespaces)))
                }
                fireTimes(t)
            case .fileChange(let path, let glob, let debounce):
                CommitField(title: "Folder or file", value: path, mono: true) { text in
                    let p = text.trimmingCharacters(in: .whitespaces)
                    return p.isEmpty ? String(localized: "Enter an absolute path or one that starts with ~/.") : replace(i, .fileChange(path: p, glob: glob, debounceSeconds: debounce))
                }
                CommitField(title: "Only files matching", value: glob ?? "", prompt: "*.pdf", mono: true) { text in
                    let g = text.trimmingCharacters(in: .whitespaces)
                    return replace(i, .fileChange(path: path, glob: g.isEmpty ? nil : g, debounceSeconds: debounce))
                }
                NumberField(title: "Wait for changes to settle (seconds)", value: debounce) { v in
                    if let v, v < 0 { return String(localized: "Use 0 or more.") }
                    return replace(i, .fileChange(path: path, glob: glob, debounceSeconds: v))
                }
            case .appLaunch(let bundle):
                CommitField(title: "App bundle identifier", value: bundle, mono: true) { text in
                    let b = text.trimmingCharacters(in: .whitespaces)
                    return b.isEmpty ? String(localized: "Enter a bundle identifier such as com.apple.Safari.") : replace(i, .appLaunch(bundleID: b))
                }
            }
        }
        .padding(8).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
    }

    @ViewBuilder private func fireTimes(_ t: WorkflowTrigger) -> some View {
        let dates = TriggerPreview.nextFireDates(t)
        if dates.isEmpty {
            Text("No upcoming run can be computed for this trigger.").font(Theme.Font.caption).foregroundStyle(Theme.warning)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Next runs once switched on").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                ForEach(dates, id: \.self) { d in
                    Text(verbatim: d.formatted(date: .abbreviated, time: .shortened) + "  ·  " + Format.relative(d)).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workflow.settings.nextRuns")
        }
    }

    // MARK: Parameters

    private var parameters: some View {
        InspectorSection(title: "Parameters") {
            if document.spec.parameters.isEmpty { Text("No parameter. Steps read parameters as params.name.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            ForEach(Array(document.spec.parameters.enumerated()), id: \.offset) { i, p in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .top) {
                        CommitField(value: p.name, prompt: String(localized: "name"), mono: true) { text in
                            let n = text.trimmingCharacters(in: .whitespaces)
                            guard n.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { return String(localized: "Use letters, digits and _ only, not starting with a digit.") }
                            guard !document.spec.parameters.enumerated().contains(where: { $0.offset != i && $0.element.name == n }) else { return String(localized: "Another parameter already has this name.") }
                            return editParameter(i) { $0.name = n }
                        }
                        Picker(selection: Binding(get: { p.type }, set: { v in error = editParameter(i) { $0.type = v } })) {
                            ForEach(WorkflowParameterType.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                        } label: { EmptyView() }
                        .labelsHidden().frame(width: 92)
                        Button { error = edit { if $0.spec.parameters.indices.contains(i) { $0.spec.parameters.remove(at: i) } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).padding(.top, 5).accessibilityLabel(Text("Remove parameter \(p.name)"))
                    }
                    CommitField(title: "Default", value: ArgumentForm.text(for: p.defaultValue), prompt: String(localized: "none"), mono: true) { text in
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return editParameter(i) { $0.defaultValue = t.isEmpty ? nil : Self.defaultValue(text, type: p.type) }
                    }
                    CommitField(title: "Description", value: p.description) { text in editParameter(i) { $0.description = text } }
                    CommitToggle(title: "Required", isOn: p.required) { on in editParameter(i) { $0.required = on } }
                }
                .padding(8).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            }
            Button {
                var n = document.spec.parameters.count + 1
                while document.spec.parameters.contains(where: { $0.name == "param\(n)" }) { n += 1 }
                error = edit { $0.spec.parameters.append(WorkflowParameter(name: "param\(n)")) }
            } label: { Label("Add parameter", systemImage: "plus") }
            .buttonStyle(.borderless).accessibilityIdentifier("workflow.settings.addParameter")
        }
    }

    /// Text and path parameters keep the text as typed; the other types read JSON literals.
    static func defaultValue(_ text: String, type: WorkflowParameterType) -> JSONValue {
        switch type {
        case .string, .path: return .string(text)
        default: return ArgumentForm.parseLoose(text)
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        let p = document.spec.permissions
        return InspectorSection(title: "Declared permissions") {
            Text("What the workflow asks for. Nothing is granted until you review and accept it before a run. Changing this list withdraws an earlier acceptance.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            LinesField(title: "Read files in (one path per line)", lines: p.filesystem.read, prompt: "~/Documents/Research") { v in edit { $0.spec.permissions.filesystem.read = v } }
            LinesField(title: "Create or change files in", lines: p.filesystem.write, prompt: "~/Documents/Reports") { v in edit { $0.spec.permissions.filesystem.write = v } }
            LinesField(title: "Move to the Trash or delete in", lines: p.filesystem.delete) { v in edit { $0.spec.permissions.filesystem.delete = v } }
            LinesField(title: "Run programs", lines: p.processes, prompt: "git") { v in edit { $0.spec.permissions.processes = v } }
            LinesField(title: "Run scripts (bash, python, applescript…)", lines: p.scripts) { v in edit { $0.spec.permissions.scripts = v } }
            LinesField(title: "Connect to hosts", lines: p.network, prompt: "api.example.com") { v in edit { $0.spec.permissions.network = v } }
            LinesField(title: "Open pages on hosts", lines: p.browser) { v in edit { $0.spec.permissions.browser = v } }
            LinesField(title: "Send commands to apps (bundle identifiers)", lines: p.apps.automation, prompt: "com.apple.finder") { v in edit { $0.spec.permissions.apps.automation = v } }
            LinesField(title: "Operate the interface of apps", lines: p.apps.accessibility) { v in edit { $0.spec.permissions.apps.accessibility = v } }
            LinesField(title: "Open or quit apps", lines: p.apps.control) { v in edit { $0.spec.permissions.apps.control = v } }
            LinesField(title: "Use secrets (names only)", lines: p.secrets) { v in edit { $0.spec.permissions.secrets = v } }
            LinesField(title: "Capture the screen (display, window:bundle.id, region)", lines: p.screen) { v in edit { $0.spec.permissions.screen = v } }
            CommitToggle(title: "Read the clipboard", isOn: p.clipboard.read) { on in edit { $0.spec.permissions.clipboard.read = on } }
            CommitToggle(title: "Replace the clipboard", isOn: p.clipboard.write) { on in edit { $0.spec.permissions.clipboard.write = on } }
            CommitToggle(title: "Post notifications", isOn: p.notifications) { on in edit { $0.spec.permissions.notifications = on } }
        }
    }

    // MARK: Budget

    private var budget: some View {
        let b = document.spec.budget
        return InspectorSection(title: "Budget") {
            NumberField(title: "Longest run (seconds)", value: b.maxDurationSeconds) { v in
                if let v, v <= 0 { return String(localized: "Use a positive number, or leave empty for no limit.") }
                return edit { $0.spec.budget.maxDurationSeconds = v }
            }
            NumberField(title: "Most model spending (USD)", value: b.maxProviderCostUSD) { v in
                if let v, v <= 0 { return String(localized: "Use a positive number, or leave empty for no limit.") }
                return edit { $0.spec.budget.maxProviderCostUSD = v }
            }
            NumberField(title: "Most tool calls", value: b.maxToolCalls.map(Double.init), integer: true) { v in
                if let v, v <= 0 { return String(localized: "Use a positive number, or leave empty for no limit.") }
                return edit { $0.spec.budget.maxToolCalls = v.map { Int($0) } }
            }
            NumberField(title: "Most tokens", value: b.maxTokens.map(Double.init), integer: true) { v in
                if let v, v <= 0 { return String(localized: "Use a positive number, or leave empty for no limit.") }
                return edit { $0.spec.budget.maxTokens = v.map { Int($0) } }
            }
        }
    }
}
