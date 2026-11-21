// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/ExamplesTests.swift
// Description      : Integration tests of the 15 built-in automations (real
//                    files on disk and in the resource bundle) and of the
//                    published JSON Schema.
// Module           : ORIXWorkflowEngineTests
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
import Testing
import ORIXCore
@testable import ORIXWorkflowEngine

enum RepositoryLayout {
    /// Repository root, found from this file: <root>/Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/<file>.
    static func root(_ file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
    static var examples: URL { root().appendingPathComponent("Workflows/Examples") }
    static var resources: URL { root().appendingPathComponent("Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Resources/Examples") }
    static var schemaFile: URL { root().appendingPathComponent("Workflows/Schemas/automation.v1.schema.json") }

    static func yamlFiles(_ dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yaml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

let expectedExampleSlugs = [
    "smart-downloads-organizer", "pdf-to-structured-report", "weekly-research-digest", "git-test-and-review", "csv-cleanup-and-charts",
    "batch-image-conversion", "calendar-preparation", "folder-backup-and-verify", "website-change-monitor", "system-health-report",
    "meeting-notes-organizer", "document-metadata-catalog", "scheduled-window-screenshot", "spreadsheet-validation", "browser-data-entry",
]

@Suite("Built-in examples (integration: real files and resource bundle)") struct ExamplesTests {
    private func load() throws -> [(file: String, source: String, doc: WorkflowDocument)] {
        try RepositoryLayout.yamlFiles(RepositoryLayout.examples).map { url in
            let source = try String(contentsOf: url, encoding: .utf8)
            do { return (url.lastPathComponent, source, try WorkflowCodec.parse(source)) }
            catch { Issue.record("\(url.lastPathComponent) does not parse: \(error.localizedDescription)"); throw error }
        }
    }

    @Test func thereAreExactlyFifteenNumberedExamples() throws {
        let names = try RepositoryLayout.yamlFiles(RepositoryLayout.examples).map(\.lastPathComponent)
        #expect(names == expectedExampleSlugs.enumerated().map { String(format: "%02d-%@.yaml", $0.offset + 1, $0.element) })
    }

    @Test func everyExampleParsesAndValidatesWithoutErrorsOrWarnings() throws {
        for (file, source, doc) in try load() {
            let found = WorkflowValidator.validate(doc, tools: CanonicalTools.manifests(), agents: [], workflows: [])
            let problems = found.filter { $0.severity != .info }
            #expect(problems.isEmpty, "\(file): \(problems.map(\.description).joined(separator: "\n"))")
            let diagnosed = WorkflowCodec.diagnose(source: source, tools: CanonicalTools.manifests())
            #expect(diagnosed.document == doc)
            #expect(try WorkflowCodec.parse(WorkflowCodec.emit(doc)) == doc, "\(file) does not survive canonical emission")
        }
    }

    @Test func everyExampleIsCompleteAndUsesOnlyCanonicalTools() throws {
        let canonical = Set(CanonicalTools.identifiers)
        for (index, (file, source, doc)) in try load().enumerated() {
            #expect(doc.metadata.id == expectedExampleSlugs[index], "\(file)")
            #expect(doc.metadata.description.count > 80, "\(file) needs a real description")
            #expect(!doc.metadata.tags.isEmpty && !doc.spec.triggers.isEmpty, "\(file)")
            #expect(!doc.spec.parameters.isEmpty && doc.spec.parameters.allSatisfy { !$0.description.isEmpty && $0.defaultValue != nil }, "\(file)")
            #expect(!doc.spec.permissions.isEmpty && !doc.spec.budget.isEmpty, "\(file)")
            for p in doc.spec.parameters where p.type == .path {
                #expect(p.defaultValue?.stringValue?.hasPrefix("~/ORIX Samples/\(doc.metadata.id)/") == true, "\(file): \(p.name) must default under the sample workspace")
            }
            let steps = doc.allSteps.map(\.step)
            #expect(steps.contains { if case .verify(let v) = $0.kind { return !v.assertions.isEmpty }; return false }, "\(file) has no verify step")
            #expect(steps.contains { if case .output = $0.kind { return true }; return false }, "\(file) has no output step")
            for s in steps {
                if case .tool(let t) = s.kind { #expect(canonical.contains(t.tool), "\(file): \(t.tool) is not a canonical tool id") }
                if case .agent(let a) = s.kind {
                    guard case .inline(let inline) = a.agent else { Issue.record("\(file): agents must be inline"); continue }
                    #expect(inline.tools.allSatisfy(canonical.contains) && !a.expect.isEmpty, "\(file): agent \(s.id)")
                }
            }
            #expect(!steps.contains { if case .tool(let t) = $0.kind { return ["filesystem.delete", "git.push", "git.commit"].contains(t.tool) }; return false },
                    "\(file) must not delete, commit or push")
            #expect(source.contains("# Limitations"), "\(file) must state its limitations in comments")
            #expect(source.hasPrefix("# ORIX OS Automation\n# File: Workflows/Examples/\(file)\n"), "\(file) header")
        }
    }

    @Test func consequentialExamplesAskForApproval() throws {
        let docs = Dictionary(uniqueKeysWithValues: try load().map { ($0.doc.metadata.id, $0.doc) })
        for slug in ["smart-downloads-organizer", "browser-data-entry"] {
            let steps = docs[slug]?.allSteps.map(\.step) ?? []
            #expect(steps.contains { if case .approval = $0.kind { return true }; return false }, "\(slug) needs an approval gate")
        }
    }

    @Test func resourcesMirrorTheRepositoryExamplesByteForByte() throws {
        let a = try RepositoryLayout.yamlFiles(RepositoryLayout.examples)
        let b = try FileManager.default.contentsOfDirectory(at: RepositoryLayout.resources, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(a.map(\.lastPathComponent) == b.map(\.lastPathComponent))
        for (x, y) in zip(a, b) { #expect(try Data(contentsOf: x) == Data(contentsOf: y), "\(x.lastPathComponent) differs from its resource copy") }
    }

    @Test func builtInWorkflowsLoadFromTheBundle() throws {
        let all = BuiltInWorkflows.all()
        #expect(all.map(\.slug) == expectedExampleSlugs)
        let onDisk = try load()
        for (b, d) in zip(all, onDisk) {
            #expect(b.yaml == d.source && b.title == d.doc.metadata.name && b.summary == d.doc.metadata.description && b.id == b.slug)
            #expect(try b.document() == d.doc)
        }
        #expect(BuiltInWorkflows.workflow(slug: "system-health-report")?.title == "Local system health report")
        #expect(BuiltInWorkflows.workflow(slug: "nope") == nil)
        #expect(BuiltInWorkflows.slug(fileName: "03-weekly-research-digest.yaml") == "weekly-research-digest")
        #expect(BuiltInWorkflows.slug(fileName: "plain-name.yaml") == "plain-name")
    }

    @Test func capabilitiesAndProposedGrantsAreCanonicalAndScoped() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orix-home-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let home = PathResolver.resolveSymlinks(tmp.path)
        for (file, _, doc) in try load() {
            let caps = doc.declaredCapabilities(home: home)
            #expect(!caps.isEmpty, "\(file)")
            for c in caps where c.kind.hasPrefix("file.") {
                #expect(c.scope.hasPrefix(home + "/ORIX Samples/\(doc.metadata.id)"), "\(file): \(c.displayString)")
                #expect(!c.scope.contains("~") && !c.scope.contains("${{"))
            }
            let grants = doc.proposedGrants(workflowID: "wf-1", home: home)
            #expect(grants.map(\.capability) == caps)
            for g in grants {
                #expect(g.scope == .workflow(workflowID: "wf-1") && g.maxTier <= .consequential && g.source == "workflow:wf-1", "\(file)")
            }
        }
        let backup = try #require(BuiltInWorkflows.workflow(slug: "folder-backup-and-verify")).document()
        let custom = backup.declaredCapabilities(home: home, parameters: ["source": "~/Elsewhere"])
        #expect(custom.contains(.fileRead(path: home + "/Elsewhere")))
        let shot = try #require(BuiltInWorkflows.workflow(slug: "scheduled-window-screenshot")).document()
        #expect(shot.declaredCapabilities(home: home).contains(.screenCapture(scope: "window:com.apple.Safari")))
    }
}

@Suite("Automation JSON Schema (integration: schema file and Core validator)") struct WorkflowSchemaTests {
    private func canonicalJSON(_ doc: WorkflowDocument) throws -> JSONValue { try JSONValue.parse(WorkflowCodec.emit(doc, format: .json)) }

    @Test func publishedSchemaFileMatchesTheGeneratedSchema() throws {
        let text = WorkflowSchema.automationV1JSON()
        if ProcessInfo.processInfo.environment["ORIX_WRITE_SCHEMA"] == "1" {
            try FileManager.default.createDirectory(at: RepositoryLayout.schemaFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: RepositoryLayout.schemaFile, atomically: true, encoding: .utf8)
        }
        let onDisk = try String(contentsOf: RepositoryLayout.schemaFile, encoding: .utf8)
        #expect(onDisk == text, "run the tests once with ORIX_WRITE_SCHEMA=1 to regenerate Workflows/Schemas/automation.v1.schema.json")
        let parsed = try JSONValue.parse(onDisk)
        #expect(parsed == WorkflowSchema.automationV1().raw)
        #expect(parsed["$id"] == "https://orix.ai/schemas/automation.v1.schema.json")
    }

    @Test func schemaUsesOnlyKeywordsCoreEnforcesPlusAnnotations() {
        let allowed: Set<String> = ["$schema", "$id", "title", "description", "type", "properties", "required", "additionalProperties",
                                    "items", "enum", "minimum", "maximum", "minLength", "maxLength", "pattern", "minItems", "maxItems"]
        var seen: Set<String> = []
        func walk(_ v: JSONValue, isPropertyMap: Bool) {
            guard case .object(let o) = v else { return }
            for (k, child) in o {
                if isPropertyMap { walk(child, isPropertyMap: false); continue }
                seen.insert(k)
                switch k {
                case "properties": walk(child, isPropertyMap: true)
                case "items", "additionalProperties": walk(child, isPropertyMap: false)
                default: break
                }
            }
        }
        walk(WorkflowSchema.automationV1().raw, isPropertyMap: false)
        #expect(seen.subtracting(allowed).isEmpty, "unsupported keywords: \(seen.subtracting(allowed).sorted())")
    }

    @Test func everyExampleValidatesAgainstTheSchema() throws {
        let schema = WorkflowSchema.automationV1()
        for b in BuiltInWorkflows.all() {
            let violations = schema.validate(try canonicalJSON(try b.document()))
            #expect(violations.isEmpty, "\(b.slug): \(violations.map(\.description).joined(separator: "; "))")
        }
        let section9 = try WorkflowCodec.parse(claudeSection9Workflow)
        #expect(schema.validate(try canonicalJSON(section9)).isEmpty)
    }

    @Test func randomCanonicalDocumentsFitTheSchemaShape() throws {
        // Property check of the schema's structure: only id/name patterns and numeric bounds may be violated by random data.
        let schema = WorkflowSchema.automationV1()
        var generator = DocumentGenerator(seed: 2026)
        for _ in 0..<150 {
            let violations = schema.validate(try canonicalJSON(generator.document()))
            let structural = violations.filter { $0.message.contains("unexpected property") || $0.message.contains("expected ") || $0.message.contains("required") }
            #expect(structural.isEmpty, "\(structural.map(\.description).joined(separator: "; "))")
        }
    }

    @Test func schemaRejectsUnknownKeysAndWrongTypes() throws {
        let schema = WorkflowSchema.automationV1()
        var value = try canonicalJSON(try WorkflowCodec.parse(claudeSection9Workflow))
        guard case .array(var steps)? = value["spec"]?["steps"] else { Issue.record("no steps"); return }
        steps[0]["wiht"] = ["path": "/x"]
        var spec = value["spec"]!
        spec["steps"] = .array(steps)
        value["spec"] = spec
        #expect(schema.validate(value).contains { $0.path == "spec.steps.0.wiht" && $0.message == "unexpected property" })

        var wrong = try canonicalJSON(try WorkflowCodec.parse(claudeSection9Workflow))
        var spec2 = wrong["spec"]!
        spec2["budget"] = ["maxToolCalls": "many"]
        spec2["triggers"] = [["type": "sometimes"]]
        wrong["spec"] = spec2
        wrong["apiVersion"] = "orix.ai/v2"
        let found = schema.validate(wrong)
        #expect(found.contains { $0.path == "spec.budget.maxToolCalls" && $0.message.contains("expected integer") })
        #expect(found.contains { $0.path == "spec.triggers.0.type" })
        #expect(found.contains { $0.path == "apiVersion" })
        #expect(schema.validate(["kind": "Automation"]).contains { $0.message == "required property is missing" })
    }

    @Test func nestedStepsAreDescribedToTheDocumentedDepth() throws {
        func nest(_ depth: Int, bad: Bool) -> JSONValue {
            if depth == 0 { return bad ? ["id": "leaf", "delay": 1, "bogus": true] : ["id": "leaf", "delay": 1] }
            return ["id": .string("level\(depth)"), "while": "false", "maxIterations": 1, "steps": [nest(depth - 1, bad: bad)]]
        }
        func doc(_ depth: Int, bad: Bool, key: String = "steps") -> JSONValue {
            var spec: [String: JSONValue] = ["steps": []]
            spec[key] = [nest(depth, bad: bad)]
            return ["apiVersion": "orix.ai/v1", "kind": "Automation", "metadata": ["id": "n", "name": "N"], "spec": .object(spec)]
        }
        let schema = WorkflowSchema.automationV1()
        let depth = WorkflowSchema.describedNestingDepth
        #expect(depth == 2 && WorkflowSchema.describedHandlerNestingDepth == 1)
        #expect(schema.validate(doc(depth, bad: false)).isEmpty)
        #expect(schema.validate(doc(depth, bad: true)).contains { $0.message == "unexpected property" })
        #expect(schema.validate(doc(depth + 1, bad: true)).isEmpty, "beyond the described depth a nested step is any object")
        #expect(schema.validate(doc(1, bad: true, key: "onError")).contains { $0.message == "unexpected property" })
        #expect(schema.validate(doc(2, bad: true, key: "onError")).isEmpty)
        // Parallel branches nest the same way.
        let branch: JSONValue = ["id": "p", "parallel": [["name": "b", "steps": [["id": "x", "delay": 1, "bogus": 1]]]]]
        let withBranch: JSONValue = ["apiVersion": "orix.ai/v1", "kind": "Automation", "metadata": ["id": "n", "name": "N"], "spec": ["steps": [branch]]]
        #expect(schema.validate(withBranch).contains { $0.path == "spec.steps.0.parallel.0.steps.0.bogus" })
        #expect(WorkflowSchema.automationV1JSON().utf8.count < 400_000, "the published schema must stay a reasonable size")
    }

    @Test func canonicalToolCatalogueIsWellFormed() {
        let manifests = CanonicalTools.manifests()
        #expect(manifests.count == CanonicalTools.identifiers.count && Set(CanonicalTools.identifiers).count == manifests.count)
        for m in manifests { #expect(m.problems().isEmpty, "\(m.identifier): \(m.problems())") }
        #expect(manifests.first { $0.identifier == "filesystem.list" }?.idempotent == true)
        #expect(manifests.first { $0.identifier == "filesystem.move" }?.idempotent == false)
        #expect(manifests.first { $0.identifier == "filesystem.move" }?.supportsDryRun == true)
    }
}
