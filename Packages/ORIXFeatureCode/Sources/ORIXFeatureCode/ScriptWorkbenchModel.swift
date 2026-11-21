// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/ScriptWorkbenchModel.swift
// Description      : The script workbench: scratch buffers per language,
//                    running a buffer or a selection through the real script
//                    tools under a recorded run (policy, approval, sandbox),
//                    live output, stop, and the "save as skill" proposal form.
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

import Foundation
import ORIXAppUI
import SwiftUI

/// How a script run ended.
public struct ScriptOutcome: Sendable, Equatable {
    public var runID: String
    public var status: RunStatus
    public var toolStatus: ToolStatus?
    public var exitCode: Int?
    public var durationSeconds: Double
    public var message: String
}

struct WorkbenchState: Codable, Sendable {
    var language: WorkbenchLanguage
    var buffers: [String: String]
    var workingDirectory: String?
    var access: WorkspaceAccess
}

@MainActor
@Observable
public final class ScriptWorkbenchModel {
    public var language: WorkbenchLanguage = .python
    public var buffers: [WorkbenchLanguage: String] = [:]
    /// Empty means "the default workspace".
    public var workingDirectory = ""
    public var access: WorkspaceAccess = .read
    /// Bundle identifiers an AppleScript/JXA script talks to, separated by commas or spaces.
    public var targets = ""
    public var timeoutSeconds: Double = 120
    public private(set) var isRunning = false
    public private(set) var currentRunID: String?
    public private(set) var last: ScriptOutcome?
    public var notice: (kind: Banner.Kind, text: String)?
    public let editor = CodeEditorController()
    @ObservationIgnored private var restored = false

    public init() {}

    public var text: String {
        get { buffers[language] ?? ScriptTemplates.starter(language) }
        set { buffers[language] = newValue }
    }

    static let stateCollection = "code-studio"

    /// Restores the scratch buffers saved by an earlier session (once).
    public func restore(_ services: ORIXServices) async {
        guard !restored else { return }
        restored = true
        // A buffer already typed in this session wins over what an earlier session saved.
        guard buffers.isEmpty, let s = try? await services.store.get(WorkbenchState.self, collection: Self.stateCollection, id: "workbench") else { return }
        language = s.language
        for (k, v) in s.buffers { if let l = WorkbenchLanguage(rawValue: k), buffers[l] == nil { buffers[l] = v } }
        if workingDirectory.isEmpty { workingDirectory = s.workingDirectory ?? "" }
        access = s.access
    }

    public func persist(_ services: ORIXServices) async {
        let state = WorkbenchState(language: language, buffers: Dictionary(uniqueKeysWithValues: buffers.map { ($0.key.rawValue, $0.value) }),
                                   workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory, access: access)
        try? await services.store.put(state, collection: Self.stateCollection, id: "workbench")
    }

    public func effectiveDirectory(default fallback: String) -> String { workingDirectory.isEmpty ? fallback : workingDirectory }

    var targetList: [String] {
        targets.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Running

    /// Runs `source` through the language's tool. The call goes through the policy engine: anything not granted asks
    /// for approval, and the process runs sandboxed. Returns when the run has ended.
    @discardableResult
    public func run(source: String, selectionOnly: Bool = false, defaultWorkspace: String, services: ORIXServices, console: ConsoleBuffer) async -> ScriptOutcome? {
        guard !isRunning else { return nil }
        let language = self.language
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = (.warning, String(localized: "There is nothing to run."))
            return nil
        }
        // The working folder is the user's choice; it must exist and must not be a protected location.
        let directory: String
        do {
            directory = try PathResolver.canonical(effectiveDirectory(default: defaultWorkspace), relativeTo: URL(fileURLWithPath: NSHomeDirectory()))
        } catch {
            notice = (.error, WorkflowCodeModel.describe(error)); return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            notice = (.error, String(localized: "The working folder \(PathResolver.display(directory)) does not exist."))
            return nil
        }
        guard !PathResolver.isProtected(directory) else {
            notice = (.error, String(localized: "\(PathResolver.display(directory)) is a protected location and cannot be a working folder."))
            return nil
        }
        notice = nil
        isRunning = true
        last = nil
        let runID = UUID().uuidString
        currentRunID = runID
        defer { isRunning = false; currentRunID = nil }

        let lineCount = source.split(whereSeparator: \.isNewline).count
        let title = "Script · \(language.displayName) · \(lineCount) line\(lineCount == 1 ? "" : "s")" + (selectionOnly ? " (selection)" : "")
        let started = Date()
        var record = RunRecord(id: runID, kind: "script", title: title, trigger: "manual", mode: .guided, status: .running, startedAt: started)
        try? await services.store.saveRun(record)
        await services.store.emit(RunEvent(runID: runID, kind: .statusChanged, text: RunStatus.running.rawValue))
        await services.store.emit(RunEvent(runID: runID, kind: .log, text: "Run from Code Studio with \(language.toolID) in \(PathResolver.display(directory))"))

        // The folder the user picked is granted for this run only, like the workspace of an agent run.
        _ = await services.policy.add(PermissionGrant(capability: .fileRead(path: directory), scope: .run(runID: runID), maxTier: .readOnly, source: "user", note: "Working folder of this script run"))
        if access == .readWrite {
            _ = await services.policy.add(PermissionGrant(capability: .fileWrite(path: directory), scope: .run(runID: runID), maxTier: .reversibleWrite, source: "user", note: "Working folder of this script run"))
        }

        let artifacts = services.paths.artifacts.appendingPathComponent(runID)
        try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        console.note("▶ \(title) — \(PathResolver.display(directory))", stream: .status)

        let (stream, continuation) = AsyncStream<ToolProgress>.makeStream(bufferingPolicy: .bufferingNewest(4_000))
        let pump = Task { @MainActor () -> Bool in
            var sawOutput = false
            for await p in stream {
                switch p.stream {
                case .stdout: console.append(p.text, stream: .stdout); sawOutput = true
                case .stderr: console.append(p.text, stream: .stderr); sawOutput = true
                case .status: console.append(p.text.hasSuffix("\n") ? p.text : p.text + "\n", stream: .info)
                }
            }
            return sawOutput
        }
        let context = InvocationContext(runID: runID, mode: .guided, workingDirectory: URL(fileURLWithPath: directory), artifactsDirectory: artifacts,
                                        maxToolSeconds: max(1, timeoutSeconds), progress: { _, p in continuation.yield(p) })
        let call = ToolCall(toolID: language.toolID, arguments: language.arguments(script: source, workingDirectory: directory,
                                                                                   timeoutSeconds: max(1, timeoutSeconds), targets: targetList))
        let result = await services.executor.invoke(call, context: context)
        continuation.finish()
        let streamed = await pump.value
        console.flush()

        // Tools that do not stream (AppleScript, JXA) return their output at the end.
        let output = result.output
        if !streamed {
            if let out = output["stdout"]?.stringValue, !out.isEmpty { console.append(out.hasSuffix("\n") ? out : out + "\n", stream: .stdout) }
            if let text = output["result"]?.stringValue, !text.isEmpty { console.append(text + "\n", stream: .stdout) }
            if let err = output["stderr"]?.stringValue, !err.isEmpty { console.append(err.hasSuffix("\n") ? err : err + "\n", stream: .stderr) }
        }
        let exitCode = output["exitCode"]?.intValue
        let duration = Date().timeIntervalSince(started)
        let status: RunStatus
        var message: String
        switch result.status {
        case .succeeded, .simulated:
            if let code = exitCode, code != 0 { status = .failed; message = "Exit code \(code)" } else { status = .succeeded; message = exitCode.map { "Exit code \($0)" } ?? "Finished" }
        case .canceled: status = .canceled; message = "Stopped"
        case .timedOut: status = .timedOut; message = result.failure?.message ?? "Timed out"
        case .blockedPermission: status = .blockedPermission; message = result.failure?.message ?? "A macOS permission is missing"
        case .notApproved: status = .canceled; message = "Not approved: nothing was run"
        case .denied, .failed, .invalidInput, .unsupported: status = .failed; message = result.failure?.message ?? result.summary
        }
        if let recovery = result.failure?.recovery, !result.isSuccess { message += " " + recovery }
        if output["truncated"]?.boolValue == true { console.note("The tool truncated the output it returned.", stream: .info) }
        console.note("■ \(message) · \(Format.duration(duration))", stream: status == .succeeded ? .status : .stderr)

        record.status = status
        record.endedAt = Date()
        record.usage.toolCalls = 1
        record.errorSummary = status == .succeeded ? nil : Redactor.shared.redact(message)
        await services.store.emit(RunEvent(runID: runID, kind: status == .succeeded ? .log : .error, text: Redactor.shared.redact(message)))
        await services.store.emit(RunEvent(runID: runID, kind: .statusChanged, text: status.rawValue))
        let receipt = RunReceipt(runID: runID, title: title, status: status, objective: "Run a \(language.displayName) script from Code Studio", model: nil,
                                 startedAt: started, endedAt: record.endedAt ?? Date(), usage: record.usage,
                                 toolCalls: [ToolCallRecord(id: call.id, toolID: call.toolID, arguments: ["lines": .int(lineCount), "cwd": .string(directory)],
                                                            status: result.status, summary: result.summary, durationMs: result.durationMs, tier: .consequential, startedAt: started)],
                                 artifacts: result.artifacts, errors: status == .succeeded ? [] : [Redactor.shared.redact(message)])
        try? await services.store.saveReceipt(receipt)
        try? await services.store.saveRun(record)
        // Run-scoped authority ends with the run.
        _ = await services.policy.revokeRun(runID: runID)
        await services.executor.forgetRun(runID)

        let outcome = ScriptOutcome(runID: runID, status: status, toolStatus: result.status, exitCode: exitCode, durationSeconds: duration, message: message)
        last = outcome
        return outcome
    }

    /// Stops the running script: the tool call is canceled (its process group is killed) and a pending approval is refused.
    public func stop(services: ORIXServices) async {
        guard let runID = currentRunID else { return }
        await services.executor.cancel(runID: runID)
        await services.approvals.denyAll(runID: runID, reason: "The run was stopped.")
    }
}

// MARK: - Save as skill

public struct SkillTestDraft: Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name = "basic"
    public var inputJSON = "{}"
    public var expectSucceeded = true
    /// Dotted output path → expected value, as a JSON object. Empty means "any output".
    public var expectOutputJSON = ""

    public init(name: String = "basic", inputJSON: String = "{}", expectSucceeded: Bool = true, expectOutputJSON: String = "") {
        self.name = name; self.inputJSON = inputJSON; self.expectSucceeded = expectSucceeded; self.expectOutputJSON = expectOutputJSON
    }
}

@MainActor
@Observable
public final class SkillFormModel {
    public var name = ""
    public var summary = ""
    public var runtime = "python"
    public var source = ""
    public var inputSchemaJSON = "{\n  \"type\": \"object\",\n  \"properties\": {},\n  \"additionalProperties\": false\n}"
    public var fileRead = ""
    public var fileWrite = ""
    public var network = ""
    public var tests: [SkillTestDraft] = [SkillTestDraft()]
    public private(set) var isSubmitting = false
    public private(set) var problems: [String] = []
    public private(set) var draft: SkillDraft?

    public init(language: WorkbenchLanguage, source: String) {
        runtime = language.skillRuntime ?? "python"
        self.source = source
    }

    public var entry: String { runtime == "bash" ? "main.sh" : "main.py" }

    /// `Count words` → `skill.countWords`.
    public static func identifier(from name: String) -> String {
        let words = name.split { !($0.isLetter || $0.isNumber) }.map { String($0).filter { $0.isASCII } }.filter { !$0.isEmpty }
        guard let first = words.first else { return "skill." }
        return "skill." + first.lowercased() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
    }

    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Builds the manifest from the form, or reports what is wrong with the form itself.
    public enum ManifestResult: Sendable { case success(SkillManifest), failure([String]) }

    public func manifest() -> ManifestResult {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(String(localized: "Give the skill a name.")) }
        let schema: JSONValue
        if let v = try? JSONValue.parse(inputSchemaJSON) { schema = v } else { schema = .null; issues.append(String(localized: "The input schema is not valid JSON.")) }
        if tests.isEmpty { issues.append(String(localized: "Add at least one test.")) }
        var cases: [SkillTestCase] = []
        for t in tests {
            guard let input = try? JSONValue.parse(t.inputJSON), input.objectValue != nil else {
                issues.append(String(localized: "The input of test “\(t.name)” must be a JSON object.")); continue
            }
            var expect: [String: JSONValue] = [:]
            if !t.expectOutputJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let o = (try? JSONValue.parse(t.expectOutputJSON))?.objectValue else {
                    issues.append(String(localized: "The expected output of test “\(t.name)” must be a JSON object.")); continue
                }
                expect = o
            }
            cases.append(SkillTestCase(name: t.name, input: input, expectStatus: t.expectSucceeded ? "succeeded" : "failed", expectOutput: expect))
        }
        guard issues.isEmpty else { return .failure(issues) }
        let m = SkillManifest(id: Self.identifier(from: name), name: name.trimmingCharacters(in: .whitespaces), summary: summary.trimmingCharacters(in: .whitespaces),
                              runtime: runtime, entry: entry, inputSchema: JSONSchema(raw: schema),
                              permissions: SkillPermissions(fileRead: Self.list(fileRead), fileWrite: Self.list(fileWrite), network: Self.list(network)),
                              author: NSFullUserName(), tests: cases)
        let found = m.problems()
        return found.isEmpty ? .success(m) : .failure(found)
    }

    /// Proposes the skill: the package is analysed and its tests run confined. Nothing is installed.
    public func submit(_ services: ORIXServices) async {
        guard !isSubmitting else { return }
        draft = nil
        switch manifest() {
        case .failure(let issues): problems = issues
        case .success(let m):
            problems = []
            isSubmitting = true
            defer { isSubmitting = false }
            do { draft = try await services.skills.propose(manifest: m, sources: [entry: source], source: "user") }
            catch { problems = [WorkflowCodeModel.describe(error)] }
        }
    }
}
