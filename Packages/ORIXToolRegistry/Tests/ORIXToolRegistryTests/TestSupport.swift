// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Tests/ORIXToolRegistryTests/TestSupport.swift
// Description      : Shared test fixtures: an executor harness over a temp
//                    directory, configurable policies, probe tools and process
//                    helpers.
// Module           : ORIXToolRegistryTests
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
import ORIXTestingSupport
@testable import ORIXToolRegistry

/// Allows everything but confines subprocesses to the given envelope.
struct ConfinedAllowPolicy: PolicyDeciding {
    let confinement: Confinement
    func evaluate(_ request: AccessRequest) async -> PolicyDecision { .allow(grantIDs: []) }
    func recordApproval(_ response: ApprovalResponse, for request: ApprovalRequest) async -> [String] { [] }
    func consume(grantIDs: [String], callID: String) async {}
    func confinement(runID: String, workflowID: String?) async -> Confinement { confinement }
}

/// Small custom policy: tier 0 is allowed, everything else needs approval once per call; records what it saw.
actor ApprovalPolicy: PolicyDeciding {
    private(set) var requests: [AccessRequest] = []
    private(set) var approvals: [ApprovalResponse] = []
    private(set) var consumed: [String] = []
    private var runGrants: Set<String> = []
    let confinementValue: Confinement
    let denyTools: Set<String>

    init(confinement: Confinement = Confinement(), denyTools: Set<String> = []) { confinementValue = confinement; self.denyTools = denyTools }

    func evaluate(_ request: AccessRequest) async -> PolicyDecision {
        requests.append(request)
        if denyTools.contains(request.toolID) { return .deny(reason: "tool is on the deny list") }
        if request.tier == .readOnly || runGrants.contains(request.runID + request.toolID) { return .allow(grantIDs: []) }
        return .needsApproval(ApprovalRequest(access: request, missing: request.capabilities, reason: "no grant covers this call"))
    }
    func recordApproval(_ response: ApprovalResponse, for request: ApprovalRequest) async -> [String] {
        approvals.append(response)
        if response == .approveForRun { runGrants.insert(request.access.runID + request.access.toolID) }
        return ["grant-\(request.access.callID)"]
    }
    func consume(grantIDs: [String], callID: String) async { consumed += grantIDs }
    func confinement(runID: String, workflowID: String?) async -> Confinement { confinementValue }
}

/// A broker whose answer is held until `release` is called.
actor GatedBroker: ApprovalBroker {
    private var waiting: [CheckedContinuation<ApprovalResponse, Never>] = []
    private(set) var asked = 0
    func requestApproval(_ request: ApprovalRequest) async -> ApprovalResponse {
        asked += 1
        return await withCheckedContinuation { waiting.append($0) }
    }
    func release(_ response: ApprovalResponse) { waiting.forEach { $0.resume(returning: response) }; waiting = [] }
}

struct MapSecrets: SecretResolving {
    let values: [String: String]
    func secret(reference: String) async throws -> String {
        guard let v = values[reference] else { throw ToolError.notFound("no secret \(reference)") }
        return v
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0, live = 0, peak = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func increment() { lock.lock(); n += 1; lock.unlock() }
    func enter() { lock.lock(); live += 1; peak = max(peak, live); n += 1; lock.unlock() }
    func leave() { lock.lock(); live -= 1; lock.unlock() }
}

/// A configurable tool for pipeline tests. Clearly a test double: family `test`.
struct ProbeTool: ORIXTool {
    var manifest: ToolManifest
    var capabilities: @Sendable (ToolInput, ToolExecutionContext) throws -> [Capability] = { _, _ in [] }
    var tier: ApprovalTier?
    var body: @Sendable (ToolInput, ToolExecutionContext) async throws -> ToolResult

    init(_ id: String, sideEffect: SideEffect = .read, tier: ApprovalTier = .readOnly, concurrency: ToolConcurrency = .unlimited,
         idempotent: Bool = false, supportsDryRun: Bool = false, maxOutputBytes: Int = 262_144, timeout: Double = 30,
         redactedKeys: [String] = [], untrusted: Bool = false,
         outputSchema: JSONSchema = .any,
         body: @escaping @Sendable (ToolInput, ToolExecutionContext) async throws -> ToolResult) {
        manifest = ToolManifest(identifier: id, name: id, summary: "Probe tool used by the executor tests.", family: "test",
                                inputSchema: .object(["text": .string(), "seconds": .number(), "timeoutSeconds": .number(), "apiKey": .string(), "path": .string()], additional: false),
                                outputSchema: outputSchema, sideEffect: sideEffect, defaultTier: tier, defaultTimeoutSeconds: timeout,
                                maxOutputBytes: maxOutputBytes, concurrency: concurrency, supportsDryRun: supportsDryRun,
                                idempotent: idempotent || sideEffect == .read, redactedInputKeys: redactedKeys, outputIsUntrusted: untrusted)
        self.tier = tier
        self.body = body
    }

    func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: try capabilities(input, context), tier: tier ?? manifest.defaultTier, summary: "Probe \(manifest.identifier)")
    }
    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult { try await body(input, context) }
}

/// Executor + sinks over a temp directory with every built-in tool registered.
struct Harness {
    let tmp: TempDirectory
    let registry: ToolRegistry
    let executor: ToolExecutor
    let events = CollectingEventSink()
    let audit = CollectingAuditSink()
    let redactor = Redactor()

    init(policy: (any PolicyDeciding)? = nil, approvals: any ApprovalBroker = ScriptedApprovalBroker(), extra: [any ORIXTool] = [],
         secrets: (any SecretResolving)? = nil, builtIns: Bool = true, pythonEnvRoot: URL? = nil, directory: TempDirectory? = nil) async throws {
        tmp = try directory ?? TempDirectory(prefix: "orix-tools")
        registry = ToolRegistry()
        if builtIns { try await registry.registerAll(ORIXToolRegistryTools.all(pythonEnvRoot: pythonEnvRoot ?? tmp.url.appendingPathComponent("py-env-unused"))) }
        try await registry.registerAll(extra)
        // By default: everything allowed, subprocesses confined to this temp directory, no network.
        let effective = policy ?? ConfinedAllowPolicy(confinement: Confinement(readRoots: [tmp.url.path], writeRoots: [tmp.url.path]))
        executor = ToolExecutor(registry: registry, policy: effective, approvals: approvals, audit: audit, events: events, secrets: secrets, redactor: redactor)
    }

    @discardableResult
    func call(_ toolID: String, _ arguments: JSONValue = [:], dryRun: Bool = false, key: String? = nil, runID: String = "run-test",
              mode: ExecutionMode = .guided, maxToolSeconds: Double = 600, id: String = UUID().uuidString) async -> ToolResult {
        var context = tmp.invocation(runID: runID, mode: mode)
        context.maxToolSeconds = maxToolSeconds
        return await executor.invoke(ToolCall(id: id, toolID: toolID, arguments: arguments, dryRun: dryRun, idempotencyKey: key), context: context)
    }

    func path(_ name: String) -> String { tmp.url.appendingPathComponent(name).path }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
    func read(_ name: String) -> String { (try? String(contentsOfFile: path(name), encoding: .utf8)) ?? "" }
}

enum TestProcess {
    /// Runs a helper process directly (test setup only, unconfined).
    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: String, env: [String: String] = [:]) async throws -> ProcessOutput {
        try await ProcessRunner().run(ProcessSpec(executable: executable, arguments: args, environment: env, workingDirectory: cwd, timeoutSeconds: 60))
    }

    static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Waits until `condition` holds or the timeout expires.
    static func eventually(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    static func pid(inFile path: String) -> Int32? {
        (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Creates a throwaway git repository with one commit.
    static func makeRepository(at dir: String) async throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let env = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        try await run("/usr/bin/git", ["init", "-q", "-b", "main", dir], cwd: dir, env: env).requireSuccess(timeoutSeconds: 60)
        for (k, v) in [("user.name", "ORIX Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false")] {
            try await run("/usr/bin/git", ["-C", dir, "config", k, v], cwd: dir).requireSuccess(timeoutSeconds: 60)
        }
        try "hello\n".write(toFile: dir + "/README.md", atomically: true, encoding: .utf8)
        try await run("/usr/bin/git", ["-C", dir, "add", "README.md"], cwd: dir).requireSuccess(timeoutSeconds: 60)
        try await run("/usr/bin/git", ["-C", dir, "commit", "-q", "-m", "initial"], cwd: dir).requireSuccess(timeoutSeconds: 60)
    }
}
