// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/ScriptTools.swift
// Description      : script.swift (/usr/bin/swift) and script.javascript (the
//                    system jsc helper, out of process), both
//                    Seatbelt-confined.
// Module           : ORIXToolRegistry
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
import ORIXCore

private func show(_ path: String) -> String { PathResolver.display(path) }

/// Shared implementation: write the source into the run's artifacts, run the interpreter on it, confined.
struct ScriptRuntime: Sendable {
    let toolID: String
    let runtime: String
    let displayName: String
    let interpreter: String
    let fileExtension: String
    /// Builds the interpreter arguments from the script path and the user arguments.
    let arguments: @Sendable (String, [String]) -> [String]

    func manifest(summary: String) -> ToolManifest {
        ToolManifest(
            identifier: toolID, name: "Run \(displayName)", summary: summary, family: "script",
            inputSchema: Schema.input([
                "script": JSONSchema(raw: ["type": "string", "description": .string("\(displayName) source."), "minLength": 1, "maxLength": 400_000]),
                "args": .array(of: .string()), "cwd": .string("Working directory (default: a fresh folder in the run's artifacts)."),
                "timeoutSeconds": Schema.timeout, "maxBytes": .integer(minimum: 1, maximum: 4_000_000),
            ], required: ["script"]),
            outputSchema: ProcessToolSupport.outputSchema,
            sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 1_800, maxOutputBytes: 6_000_000, outputIsUntrusted: true)
    }

    func scratch(_ context: ToolExecutionContext) -> String {
        PathResolver.resolveSymlinks(context.artifactsDirectory.path) + "/scripts/" + context.callID
    }

    func requirements(_ input: ToolInput, _ context: ToolExecutionContext) throws -> ToolRequirements {
        let script = try input.string("script")
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.invalidInput("script is empty") }
        let cwd = try input.optionalPath("cwd", context) ?? scratch(context)
        return ToolRequirements(capabilities: [.scriptRuntime(name: runtime), .fileRead(path: cwd)], tier: .consequential,
                                summary: "Run \(script.split(whereSeparator: \.isNewline).count) lines of \(displayName) in \(show(cwd))")
    }

    func execute(_ input: ToolInput, _ context: ToolExecutionContext, runner: ProcessRunner) async throws -> ToolResult {
        guard FileManager.default.isExecutableFile(atPath: interpreter) else {
            throw ToolError.unsupported("\(displayName) scripts need \(interpreter), which is not present on this Mac")
        }
        let artifactsDir = try ToolSupport.artifactsDirectory(context)
        let dir = try ToolSupport.artifactsDirectory(context, subdirectory: "scripts/" + context.callID)
        let cwd = try input.optionalPath("cwd", context) ?? dir
        try ToolSupport.requireDirectory(cwd)
        let file = dir + "/main." + fileExtension
        try ToolSupport.io("Writing the script") { try Data(try input.string("script").utf8).write(to: URL(fileURLWithPath: file), options: .atomic) }
        let timeout = min(context.timeoutSeconds, input.double("timeoutSeconds", default: 120))
        let maxBytes = input.int("maxBytes", default: 100_000)
        let watched = [cwd, artifactsDir]
        let before = ProcessToolSupport.snapshot(watched)
        let spec = ProcessSpec(executable: interpreter, arguments: arguments(file, input.strings("args")), environment: ["ORIX_ARTIFACTS_DIR": artifactsDir],
                               workingDirectory: cwd, timeoutSeconds: timeout, maxOutputBytes: maxBytes, confinement: ToolSupport.profile(context))
        let out = try await ToolSupport.run(spec, context: context, runner: runner, stream: true)
        let artifacts = ProcessToolSupport.newArtifacts(before: before, after: ProcessToolSupport.snapshot(watched), excluding: [file], note: "Created by \(toolID)")
        return ProcessToolSupport.result(out, label: displayName, maxBytes: maxBytes, extra: ["files": .array(artifacts.map { .string($0.path) })], artifacts: artifacts)
    }
}

public struct ScriptSwiftTool: ORIXTool {
    static let runtime = ScriptRuntime(toolID: "script.swift", runtime: "swift", displayName: "Swift", interpreter: "/usr/bin/swift", fileExtension: "swift",
                                       arguments: { file, args in [file] + args })
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ScriptSwiftTool.runtime.manifest(
        summary: "Runs a Swift script with the system toolchain inside a sandbox limited to the run's granted folders (no network unless a host is granted). Needs the Xcode command line tools.")
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements { try Self.runtime.requirements(input, context) }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult { try await Self.runtime.execute(input, context, runner: runner) }
}

public struct ScriptJavaScriptTool: ORIXTool {
    public static let jscPath = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"
    static let runtime = ScriptRuntime(toolID: "script.javascript", runtime: "javascript", displayName: "JavaScript", interpreter: jscPath, fileExtension: "js",
                                       arguments: { file, args in args.isEmpty ? [file] : [file, "--"] + args })
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ScriptJavaScriptTool.runtime.manifest(
        summary: "Runs JavaScript in the system JavaScriptCore shell (jsc) as a separate sandboxed process: print(), readFile(), arguments are available; there is no DOM, no Node API and no network.")
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements { try Self.runtime.requirements(input, context) }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult { try await Self.runtime.execute(input, context, runner: runner) }
}
