// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/RecordingToWorkflow.swift
// Description      : Turns reviewed Watch & Learn actions into a workflow
//                    document: app launches and role/title-based Accessibility
//                    steps with postconditions, never coordinates, with
//                    permissions limited to the recorded apps.
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

import Foundation
import ORIXAppUI

/// One recorded action after the user's review.
public struct ReviewedAction: Sendable, Hashable, Identifiable {
    public var action: RecordedAction
    /// The user removed what this action captured: its value and its title are dropped before conversion.
    public var redacted: Bool
    /// When set, the recorded value becomes a workflow parameter with this name.
    public var variable: String?
    public var id: String { action.id }

    public init(action: RecordedAction, redacted: Bool = false, variable: String? = nil) {
        self.action = action; self.redacted = redacted; self.variable = variable
    }
}

/// The reviewed recording as a workflow, with what could not be converted and why.
public struct WorkflowProposal: Sendable, Hashable {
    public var document: WorkflowDocument
    public var yaml: String
    /// Plain sentences about actions that were left out or need attention.
    public var notes: [String]
    /// How many recorded actions became steps.
    public var convertedActions: Int

    public var capabilities: [Capability] { document.declaredCapabilities(home: NSHomeDirectory()) }
}

public enum RecordingToWorkflow {
    /// Converts reviewed actions, in order, to a linear workflow.
    /// - Application launches and activations become `system.launchApp`; quits become `system.quitApp`.
    /// - Focus, value and menu actions become `accessibility.find` (by role, title, identifier) followed by the action on
    ///   the element found, then `accessibility.waitFor` as the postcondition. Positions are never used.
    /// - Declared permissions name only the applications that appear in the kept actions.
    public static func convert(_ reviewed: [ReviewedAction], name: String, description: String = "") -> WorkflowProposal {
        var b = Builder()
        for item in reviewed { b.add(item) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Recorded workflow" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        var spec = WorkflowSpec(triggers: [.manual], parameters: b.parameters)
        spec.permissions.apps = .init(accessibility: b.accessibilityApps, control: b.controlApps)
        spec.steps = b.steps
        let about = description.isEmpty ? "Proposed from a Watch & Learn recording. Review every step before running." : description
        let doc = WorkflowDocument(metadata: WorkflowMetadata(id: WorkflowMetadata.slug(title), name: title, description: about, tags: ["recorded"]), spec: spec)
        if b.steps.isEmpty { b.notes.append("No recorded action could be turned into a step.") }
        return WorkflowProposal(document: doc, yaml: WorkflowCodec.emit(doc, format: .yaml), notes: b.notes, convertedActions: b.converted)
    }

    /// A valid parameter name from free text: letters and digits, camelCase, never empty, never starting with a digit.
    public static func parameterName(_ raw: String) -> String {
        var words: [String] = []
        var current = ""
        for u in raw.unicodeScalars {
            let isLetter = (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122)
            let isDigit = u.value >= 48 && u.value <= 57
            if isLetter || isDigit { current.unicodeScalars.append(u) } else if !current.isEmpty { words.append(current); current = "" }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return "value" }
        var out = first.prefix(1).lowercased() + first.dropFirst()
        for w in words.dropFirst() { out += w.prefix(1).uppercased() + w.dropFirst() }
        if let f = out.unicodeScalars.first, f.value >= 48 && f.value <= 57 { out = "v" + out }
        return String(out.prefix(40))
    }

    static func isSecure(_ a: RecordedAction) -> Bool { a.role == "AXSecureTextField" || a.subrole == "AXSecureTextField" }

    struct Builder {
        var steps: [WorkflowStep] = []
        var parameters: [WorkflowParameter] = []
        var notes: [String] = []
        var accessibilityApps: [String] = []
        var controlApps: [String] = []
        var converted = 0
        private var counter = 0
        private var lastApp: String?

        private mutating func append(_ id: String, tool: String, _ arguments: [String: JSONValue], name: String) {
            steps.append(WorkflowStep(id: id, name: name, needs: steps.last.map { [$0.id] } ?? [], kind: .tool(ToolStep(tool: tool, arguments: arguments))))
        }

        private mutating func uniqueParameter(_ wanted: String, defaultValue: JSONValue?, about: String) -> String {
            let base = RecordingToWorkflow.parameterName(wanted)
            var name = base
            var n = 2
            while parameters.contains(where: { $0.name == name }) { name = "\(base)\(n)"; n += 1 }
            parameters.append(WorkflowParameter(name: name, type: .string, defaultValue: defaultValue, description: about, required: defaultValue == nil))
            return name
        }

        private func label(_ a: RecordedAction, redacted: Bool) -> (title: String?, identifier: String?) {
            let t = redacted ? nil : a.title.flatMap { $0.isEmpty ? nil : $0 }
            let i = a.identifier.flatMap { $0.isEmpty ? nil : $0 }
            return (t, i)
        }

        private func what(_ a: RecordedAction) -> String { "Action \(a.sequence) (\(a.kind.rawValue))" }

        /// `find` arguments for an element, or nil when nothing stable identifies it.
        private func locator(_ a: RecordedAction, bundleID: String, redacted: Bool) -> [String: JSONValue]? {
            let (title, identifier) = label(a, redacted: redacted)
            guard let role = a.role, !role.isEmpty, title != nil || identifier != nil else { return nil }
            var args: [String: JSONValue] = ["bundleID": .string(bundleID), "role": .string(role)]
            if let title { args["title"] = .string(title) }
            if let identifier { args["identifier"] = .string(identifier) }
            return args
        }

        private mutating func noteApp(_ id: String, accessibility: Bool) {
            if accessibility { if !accessibilityApps.contains(id) { accessibilityApps.append(id) } }
            else if !controlApps.contains(id) { controlApps.append(id) }
        }

        mutating func add(_ item: ReviewedAction) {
            let a = item.action
            switch a.kind {
            case .recordingStarted, .recordingPaused, .recordingResumed, .recordingStopped, .limitation:
                return
            case .appLaunched, .appActivated:
                guard let id = a.bundleID else { return }
                // Launch followed by its own activation is one step.
                if lastApp == id, case .tool(let t)? = steps.last?.kind, t.tool == "system.launchApp" { return }
                counter += 1
                append("open\(counter)", tool: "system.launchApp", ["bundleID": .string(id), "activate": true], name: "Open \(a.appName ?? id)")
                noteApp(id, accessibility: false); lastApp = id; converted += 1
            case .appTerminated:
                guard let id = a.bundleID else { return }
                counter += 1
                append("quit\(counter)", tool: "system.quitApp", ["bundleID": .string(id)], name: "Quit \(a.appName ?? id)")
                noteApp(id, accessibility: false); lastApp = nil; converted += 1
            case .focusChanged:
                guard let id = a.bundleID else { return }
                if RecordingToWorkflow.isSecure(a) { notes.append("\(what(a)) was on a secure field and is never replayed."); return }
                guard let find = locator(a, bundleID: id, redacted: item.redacted) else {
                    notes.append("\(what(a)) was left out: the element has no title or identifier to find it by."); return
                }
                counter += 1
                let n = counter, title = label(a, redacted: item.redacted).title
                var findArgs = find; findArgs["maxResults"] = 1
                append("find\(n)", tool: "accessibility.find", findArgs, name: "Find \(a.role ?? "element")\(title.map { " “\($0)”" } ?? "")")
                var focus: [String: JSONValue] = ["bundleID": .string(id), "element": .string("${{ steps.find\(n).output.matches[0].path }}")]
                if let title { focus["expectedTitle"] = .string(title) }
                append("focus\(n)", tool: "accessibility.focus", focus, name: "Focus it")
                var wait = find; wait["condition"] = "focused"
                append("check\(n)", tool: "accessibility.waitFor", wait, name: "Confirm it has the focus")
                noteApp(id, accessibility: true); lastApp = id; converted += 1
            case .valueChanged:
                guard let id = a.bundleID else { return }
                if RecordingToWorkflow.isSecure(a) { notes.append("\(what(a)) edited a secure field. Its content was never recorded and it is never replayed."); return }
                guard let find = locator(a, bundleID: id, redacted: item.redacted) else {
                    notes.append("\(what(a)) was left out: the field has no title or identifier to find it by."); return
                }
                counter += 1
                let n = counter, title = label(a, redacted: item.redacted).title
                let recorded = item.redacted ? nil : a.value
                var value: JSONValue
                var expected: String?
                if let wanted = item.variable?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
                    let p = uniqueParameter(wanted, defaultValue: recorded.map { .string($0.displayString) }, about: "Value for \(title ?? a.role ?? "the field")")
                    value = .string("${{ params.\(p) }}"); expected = "${{ params.\(p) }}"
                } else if let recorded {
                    value = recorded; expected = recorded.displayString
                } else {
                    let p = uniqueParameter(title ?? a.identifier ?? "value", defaultValue: nil, about: "Text for \(title ?? a.role ?? "the field") (the recording kept only its length)")
                    value = .string("${{ params.\(p) }}"); expected = "${{ params.\(p) }}"
                    notes.append("\(what(a)): the text itself was not recorded, so it became the required parameter “\(p)”.")
                }
                var findArgs = find; findArgs["maxResults"] = 1
                append("find\(n)", tool: "accessibility.find", findArgs, name: "Find \(a.role ?? "field")\(title.map { " “\($0)”" } ?? "")")
                var set: [String: JSONValue] = ["bundleID": .string(id), "element": .string("${{ steps.find\(n).output.matches[0].path }}"), "value": value]
                if let title { set["expectedTitle"] = .string(title) }
                append("set\(n)", tool: "accessibility.setValue", set, name: "Set its value")
                var wait = find; wait["condition"] = "valueEquals"; wait["expected"] = .string(expected ?? "")
                append("check\(n)", tool: "accessibility.waitFor", wait, name: "Confirm the value")
                noteApp(id, accessibility: true); lastApp = id; converted += 1
            case .menuItemSelected:
                guard let id = a.bundleID else { return }
                let (title, identifier) = label(a, redacted: item.redacted)
                guard title != nil || identifier != nil else { notes.append("\(what(a)) was left out: the menu item has no title to find it by."); return }
                counter += 1
                let n = counter
                var find: [String: JSONValue] = ["bundleID": .string(id), "role": "AXMenuItem", "includeMenuBar": true, "maxResults": 1]
                if let title { find["title"] = .string(title) }
                if let identifier { find["identifier"] = .string(identifier) }
                append("find\(n)", tool: "accessibility.find", find, name: "Find menu item\(title.map { " “\($0)”" } ?? "")")
                var press: [String: JSONValue] = ["bundleID": .string(id), "element": .string("${{ steps.find\(n).output.matches[0].path }}")]
                if let title { press["expectedTitle"] = .string(title) }
                append("press\(n)", tool: "accessibility.press", press, name: "Choose it")
                noteApp(id, accessibility: true); lastApp = id; converted += 1
            case .windowCreated, .windowFocused:
                guard let id = a.bundleID else { return }
                guard let title = label(a, redacted: item.redacted).title else { notes.append("\(what(a)) was left out: the window has no title to wait for."); return }
                counter += 1
                append("window\(counter)", tool: "accessibility.waitFor",
                       ["bundleID": .string(id), "role": "AXWindow", "title": .string(title), "condition": "exists"], name: "Wait for window “\(title)”")
                noteApp(id, accessibility: true); lastApp = id; converted += 1
            case .selectionChanged:
                notes.append("\(what(a)) was left out: a selection change cannot be replayed reliably from what Accessibility reports.")
            }
        }
    }
}
