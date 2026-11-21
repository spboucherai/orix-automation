// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/SkillsModel.swift
// Description      : View model of the Skills section: installed skills,
//                    drafts, the tool catalog, installation with audit entries,
//                    tests, and the manual authoring form that builds a
//                    manifest.
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
import Observation
import SwiftUI
import ORIXAppUI

/// The manual authoring form. `build()` turns it into a manifest and sources or explains what is wrong.
struct SkillForm: Sendable, Hashable {
    struct Fixture: Sendable, Hashable, Identifiable { var id = UUID(); var path = ""; var content = "" }
    struct TestForm: Sendable, Hashable, Identifiable {
        var id = UUID()
        var name = "example"
        var inputJSON = "{}"
        var fixtures: [Fixture] = []
        var expectFailure = false
        var expectOutputJSON = "{}"
        var expectFiles = ""
    }

    var name = ""
    var summary = ""
    var version = "1.0.0"
    var runtime = "python"
    var source = ""
    var inputSchemaJSON = "{\n  \"type\": \"object\",\n  \"properties\": {},\n  \"additionalProperties\": false\n}"
    var outputSchemaJSON = "{\n  \"type\": \"object\"\n}"
    var fileRead = ""
    var fileWrite = ""
    var network = ""
    var timeoutSeconds = 30.0
    var tests: [TestForm] = []

    struct Problem: Error, LocalizedError, Sendable, Hashable {
        let message: String
        var errorDescription: String? { message }
    }

    var entry: String { runtime == "bash" ? "main.sh" : "main.py" }
    var identifier: String { "skill." + RecordingToWorkflow.parameterName(name) }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func object(_ text: String, _ what: String) throws -> JSONValue {
        guard let v = try? JSONValue.parse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : text), v.objectValue != nil else {
            throw Problem(message: String(localized: "\(what) is not a JSON object."))
        }
        return v
    }

    func build() throws -> (manifest: SkillManifest, sources: [String: String]) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem(message: String(localized: "Give the skill a name.")) }
        guard !summary.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem(message: String(localized: "Describe in one sentence what the skill does.")) }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Problem(message: String(localized: "The source is empty.")) }
        let input = JSONSchema(raw: try Self.object(inputSchemaJSON, String(localized: "The input schema")))
        let output = JSONSchema(raw: try Self.object(outputSchemaJSON, String(localized: "The output schema")))
        var cases: [SkillTestCase] = []
        for t in tests {
            let label = String(localized: "The input of test “\(t.name)”")
            let expect = try Self.object(t.expectOutputJSON, String(localized: "The expected output of test “\(t.name)”")).objectValue ?? [:]
            var files: [String: String] = [:]
            for f in t.fixtures where !f.path.trimmingCharacters(in: .whitespaces).isEmpty { files[f.path.trimmingCharacters(in: .whitespaces)] = f.content }
            cases.append(SkillTestCase(name: t.name.isEmpty ? "test" : t.name, input: try Self.object(t.inputJSON, label), files: files,
                                       expectStatus: t.expectFailure ? "failed" : "succeeded", expectOutput: expect, expectFiles: Self.lines(t.expectFiles)))
        }
        let manifest = SkillManifest(id: identifier, name: name.trimmingCharacters(in: .whitespaces), version: version.trimmingCharacters(in: .whitespaces),
                                     summary: summary.trimmingCharacters(in: .whitespaces), runtime: runtime, entry: entry, inputSchema: input, outputSchema: output,
                                     permissions: SkillPermissions(fileRead: Self.lines(fileRead), fileWrite: Self.lines(fileWrite), network: Self.lines(network)),
                                     timeoutSeconds: timeoutSeconds, author: NSFullUserName(), tests: cases)
        let problems = manifest.problems()
        guard problems.isEmpty else { throw Problem(message: problems.joined(separator: "; ")) }
        return (manifest, [entry: source.hasSuffix("\n") ? source : source + "\n"])
    }

    /// A complete, working starting point: counts words and lines of a text file given by the caller.
    static var wordCountTemplate: SkillForm {
        var f = SkillForm()
        f.name = "Word count"
        f.summary = "Counts the words and lines of a text file."
        f.source = """
        import json, sys

        args = json.load(sys.stdin)
        with open(args["path"], "r", encoding="utf-8") as handle:
            text = handle.read()
        print(json.dumps({"words": len(text.split()), "lines": len(text.splitlines())}))
        """
        f.inputSchemaJSON = """
        {
          "type": "object",
          "properties": { "path": { "type": "string", "description": "Text file to count." } },
          "required": ["path"],
          "additionalProperties": false
        }
        """
        f.outputSchemaJSON = """
        {
          "type": "object",
          "properties": { "words": { "type": "integer" }, "lines": { "type": "integer" } },
          "required": ["words", "lines"]
        }
        """
        f.fileRead = "$input.path"
        f.tests = [TestForm(name: "counts a small file", inputJSON: "{ \"path\": \"$fixture/sample.txt\" }",
                            fixtures: [Fixture(path: "sample.txt", content: "one two three\nfour five\n")],
                            expectOutputJSON: "{ \"words\": 5, \"lines\": 2 }")]
        return f
    }
}

@MainActor
@Observable
final class SkillsModel {
    let services: ORIXServices
    private(set) var installed: [InstalledSkill] = []
    private(set) var drafts: [SkillDraft] = []
    private(set) var manifests: [ToolManifest] = []
    private(set) var loaded = false
    private(set) var testResults: [String: [SkillTestResult]] = [:]
    private(set) var testing: Set<String> = []
    private(set) var busy: String?
    var message: (kind: Banner.Kind, text: String)?

    init(services: ORIXServices) { self.services = services }

    func reload() async {
        installed = await services.skills.installed()
        drafts = await services.skills.allDrafts()
        manifests = await services.registry.manifests().sorted { $0.identifier < $1.identifier }
        loaded = true
    }

    private func fail(_ error: Error) { message = (.error, ManageText.describe(error)) }

    /// What a skill manifest declares, as rows a person can judge. `$input.<field>` entries are explained in words.
    static func permissionLines(_ m: SkillManifest) -> [(symbol: String, text: String)] {
        func path(_ p: String) -> String {
            p.hasPrefix("$input.") ? String(localized: "the path given in “\(String(p.dropFirst(7)))”") : PathResolver.display(p)
        }
        var out: [(String, String)] = [("scroll", String(localized: "Run a \(m.runtime) script, confined to what is listed here"))]
        out += m.permissions.fileRead.map { ("doc.text.magnifyingglass", String(localized: "Read \(path($0))")) }
        out += m.permissions.fileWrite.map { ("square.and.pencil", String(localized: "Create or change files in \(path($0))")) }
        if m.permissions.network.isEmpty { out.append(("network.slash", String(localized: "No network access"))) }
        else { out += m.permissions.network.map { ("network", String(localized: "Connect to \($0)")) } }
        return out
    }

    func setEnabled(_ enabled: Bool, id: String) async {
        do { try await services.skills.setEnabled(enabled, id: id); await services.refreshSkillTools(); await reload() } catch { fail(error) }
    }

    func rollback(_ id: String) async {
        do {
            let v = try await services.skills.rollback(id: id)
            await services.refreshSkillTools(); await reload()
            message = (.success, String(localized: "\(id) is back on version \(v)."))
        } catch { fail(error) }
    }

    func activate(_ id: String, version: String) async {
        do {
            try await services.skills.activate(id: id, version: version)
            await services.refreshSkillTools(); await reload()
            message = (.success, String(localized: "\(id) now uses version \(version)."))
        } catch { fail(error) }
    }

    func uninstall(_ id: String) async {
        do {
            try await services.skills.uninstall(id: id)
            await services.audit.record(AuditEntry(kind: .skillRemoved, toolID: id, detail: "Skill \(id) uninstalled by the user"))
            await services.refreshSkillTools(); await reload()
            testResults[id] = nil
            message = (.success, String(localized: "\(id) was uninstalled."))
        } catch { fail(error) }
    }

    /// Installs a reviewed draft, then refreshes the tool registry so agents and workflows can call it.
    @discardableResult
    func install(draftID: String) async -> InstalledSkill? {
        busy = draftID; defer { busy = nil }
        do {
            let skill = try await services.skills.install(draftID: draftID)
            let m = skill.package.manifest
            await services.audit.record(AuditEntry(kind: .skillInstalled, toolID: m.id, tier: m.tier,
                                                   detail: "Skill \(m.id) \(m.version) installed by the user (digest \(skill.package.digest.prefix(12)))",
                                                   data: ["digest": .string(skill.package.digest), "version": .string(m.version)]))
            await services.refreshSkillTools()
            await reload()
            message = (.success, String(localized: "\(m.name) \(m.version) is installed and available as \(m.id)."))
            return skill
        } catch { fail(error); return nil }
    }

    func discard(draftID: String) async { await services.skills.discardDraft(id: draftID); await reload() }

    /// Imports a package folder as a draft for review. Nothing is installed.
    @discardableResult
    func importFolder(_ url: URL) async -> SkillDraft? {
        busy = "import"; defer { busy = nil }
        do {
            let d = try await services.skills.importDraft(from: url)
            await reload()
            message = (.info, String(localized: "“\(d.package.manifest.name)” was imported as a draft. It is untrusted until you review its source, findings and tests below."))
            return d
        } catch { fail(error); return nil }
    }

    @discardableResult
    func propose(_ form: SkillForm) async -> SkillDraft? {
        busy = "propose"; defer { busy = nil }
        do {
            let built = try form.build()
            let d = try await services.skills.propose(manifest: built.manifest, sources: built.sources, source: "user")
            await reload()
            message = (.info, String(localized: "“\(built.manifest.name)” was analysed and tested. Review the draft, then install it."))
            return d
        } catch { fail(error); return nil }
    }

    /// Runs the manifest's own tests of an installed skill again, confined, with networking denied.
    func test(_ skill: InstalledSkill) async {
        testing.insert(skill.id)
        testResults[skill.id] = await SkillTestRunner.run(skill.package, runner: services.runner)
        testing.remove(skill.id)
    }

    func catalog(search: String) -> [(family: String, tools: [ToolManifest])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = q.isEmpty ? manifests : manifests.filter { $0.identifier.lowercased().contains(q) || $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
        return Dictionary(grouping: shown, by: { ToolGrantTree.family(of: $0.identifier) }).map { (family: $0.key, tools: $0.value) }.sorted { $0.family < $1.family }
    }
}
