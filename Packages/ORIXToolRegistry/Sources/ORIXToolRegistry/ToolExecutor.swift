// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/ToolExecutor.swift
// Description      : The only door to side effects: schema validation,
//                    protected-path refusal, policy, approval, idempotency,
//                    concurrency gate, timeout, redaction, audit and run events
//                    around every tool call.
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

public actor ToolExecutor: ToolInvoking {
    private let registry: ToolRegistry
    private let policy: any PolicyDeciding
    private let approvals: any ApprovalBroker
    private let audit: (any AuditSink)?
    private let events: (any RunEventSink)?
    private let secrets: (any SecretResolving)?
    private let redactor: Redactor

    /// How long a tool gets to unwind after its task was cancelled before the call is reported anyway.
    private var unwindGraceSeconds: Double = 4

    private var flights: [UUID: Flight] = [:]
    private var serialHeld: Set<String> = []
    private var serialWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var exclusiveHeld = false
    private var exclusiveWaiters: [CheckedContinuation<Void, Never>] = []
    /// Successful results by run, then by `toolID + key`.
    private var idempotentResults: [String: [String: ToolResult]] = [:]
    private var idempotentPending: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(registry: ToolRegistry, policy: any PolicyDeciding, approvals: any ApprovalBroker, audit: (any AuditSink)? = nil,
                events: (any RunEventSink)? = nil, secrets: (any SecretResolving)? = nil, redactor: Redactor = .shared) {
        self.registry = registry; self.policy = policy; self.approvals = approvals; self.audit = audit
        self.events = events; self.secrets = secrets; self.redactor = redactor
    }

    public func manifests() async -> [ToolManifest] { await registry.manifests() }

    /// Calls accepted and not yet answered (waiting for approval, for a concurrency slot, or executing).
    public var inFlightCount: Int { flights.count }

    /// Emergency stop: cancels every in-flight call. Pair it with `ProcessRunner.killAll()`.
    public func cancelAll() {
        for f in flights.values { f.cancel(grace: unwindGraceSeconds) }
    }

    public func cancel(runID: String) {
        for f in flights.values where f.runID == runID { f.cancel(grace: unwindGraceSeconds) }
    }

    /// Shortens the unwind grace period (tests of tools that ignore cancellation).
    func setUnwindGrace(_ seconds: Double) { unwindGraceSeconds = max(0.01, seconds) }

    /// Drops the idempotency records of a finished run.
    public func forgetRun(_ runID: String) { idempotentResults[runID] = nil }

    // MARK: Pipeline

    public func invoke(_ call: ToolCall, context: InvocationContext) async -> ToolResult {
        let started = ContinuousClock.now
        let flightID = UUID()
        let flight = Flight(runID: context.runID)
        flights[flightID] = flight
        let grace = unwindGraceSeconds
        let outcome = await withTaskCancellationHandler {
            await pipeline(call, context: context, flight: flight)
        } onCancel: {
            flight.cancel(grace: grace)
        }
        flights[flightID] = nil
        return await finish(outcome, call: call, context: context, started: started)
    }

    /// What the pipeline decided, before redaction/audit/events.
    private struct Outcome {
        var result: ToolResult
        var manifest: ToolManifest?
        var tier: ApprovalTier?
        var capabilities: [Capability] = []
        var grantIDs: [String] = []
        var executed = false
        var replayed = false
    }

    private func pipeline(_ call: ToolCall, context: InvocationContext, flight: Flight) async -> Outcome {
        // 1. Lookup.
        guard let tool = await registry.tool(id: call.toolID) else {
            await emit(.toolRequested, context: context, text: call.toolID,
                       data: ["callID": .string(call.id), "toolID": .string(call.toolID), "arguments": redactor.redact(call.arguments)])
            return Outcome(result: .failure(.failed, ToolFailure(code: "not_found", message: "Unknown tool \(call.toolID)",
                                                                  recovery: "Use one of the registered tool identifiers.")))
        }
        let manifest = tool.manifest
        var outcome = Outcome(result: ToolResult(), manifest: manifest, tier: manifest.defaultTier)
        let shownArguments = redactor.redact(call.arguments, keys: Set(manifest.redactedInputKeys))
        await emit(.toolRequested, context: context, text: manifest.identifier, data: [
            "callID": .string(call.id), "toolID": .string(manifest.identifier), "arguments": shownArguments,
            "tier": .int(manifest.defaultTier.rawValue), "dryRun": .bool(call.dryRun),
        ])

        // 2. Schema.
        let violations = manifest.inputSchema.validate(call.arguments)
        if !violations.isEmpty {
            let text = violations.prefix(8).map(\.description).joined(separator: "; ")
            outcome.result = Self.result(for: ToolError.invalidInput("Arguments do not match the schema of \(manifest.identifier): \(text)"))
            return outcome
        }
        if call.dryRun && !manifest.supportsDryRun {
            outcome.result = Self.result(for: ToolError.unsupported("\(manifest.identifier) does not support dry runs; nothing was executed"))
            return outcome
        }

        // 3. Requirements and protected paths.
        var timeout = min(manifest.defaultTimeoutSeconds, context.maxToolSeconds)
        if let own = call.arguments["timeoutSeconds"]?.doubleValue, own > 0, own < timeout { timeout = own }
        let callID = call.id
        let redactor = self.redactor
        let forward = context.progress
        var toolContext = ToolExecutionContext(
            runID: context.runID, callID: callID, workflowID: context.workflowID, mode: context.mode,
            workingDirectory: context.workingDirectory, artifactsDirectory: context.artifactsDirectory, timeoutSeconds: timeout,
            confinement: await policy.confinement(runID: context.runID, workflowID: context.workflowID), secrets: nil,
            progress: { p in forward(callID, ToolProgress(stream: p.stream, text: redactor.redact(p.text))) })
        let input = ToolInput(arguments: call.arguments, dryRun: call.dryRun, idempotencyKey: call.idempotencyKey)
        let requirements: ToolRequirements
        do { requirements = try tool.requirements(for: input, context: toolContext) }
        catch { outcome.result = Self.result(for: error); return outcome }
        outcome.tier = requirements.tier
        outcome.capabilities = requirements.capabilities

        if let protected = requirements.capabilities.first(where: { Self.isFile($0) && PathResolver.isProtected($0.scope) }) {
            let message = "\(manifest.identifier) targets a protected location (\(PathResolver.display(protected.scope))) that no grant can cover"
            await record(.policyViolation, context: context, toolID: manifest.identifier, tier: requirements.tier, detail: message,
                         data: ["callID": .string(callID), "capability": .string(protected.displayString)])
            outcome.result = Self.result(for: ToolError.permissionDenied(message))
            return outcome
        }

        // 4. Policy. Capabilities under the run's artifacts directory are implicitly granted.
        let artifactsRoot = PathResolver.resolveSymlinks(context.artifactsDirectory.path)
        let needed = requirements.capabilities.filter { !(Self.isFile($0) && Self.path(artifactsRoot, contains: $0.scope)) }
        let access = AccessRequest(runID: context.runID, callID: callID, workflowID: context.workflowID, toolID: manifest.identifier,
                                   capabilities: needed, tier: requirements.tier, sideEffect: manifest.sideEffect, mode: context.mode,
                                   summary: redactor.redact(requirements.summary), argumentsPreview: shownArguments, dryRun: call.dryRun)
        switch await policy.evaluate(access) {
        case .allow(let ids):
            outcome.grantIDs = ids
        case .deny(let reason):
            outcome.result = Self.result(for: ToolError.permissionDenied("Policy refused \(manifest.identifier): \(reason)"))
            return outcome
        case .needsApproval(let request):
            // 5. Approval. Waiting here suspends only this call.
            let approvalData: JSONValue = [
                "callID": .string(callID), "toolID": .string(manifest.identifier), "approvalID": .string(request.id),
                "tier": .int(requirements.tier.rawValue), "summary": .string(access.summary), "reason": .string(request.reason),
                "missing": .array(request.missing.map { .string($0.displayString) }), "arguments": shownArguments,
            ]
            await emit(.approvalRequested, context: context, text: access.summary, data: approvalData)
            await record(.approvalRequested, context: context, toolID: manifest.identifier, tier: requirements.tier,
                         detail: access.summary, data: approvalData)
            let response = await approvals.requestApproval(request)
            await emit(.approvalResolved, context: context, text: Self.label(response), data: [
                "callID": .string(callID), "approvalID": .string(request.id), "response": .string(Self.label(response)),
                "approved": .bool(response.isApproval),
            ])
            guard response.isApproval else {
                let why: String
                switch response {
                case .deny(let reason): why = reason.isEmpty ? "The user refused." : "The user refused: \(reason)"
                default: why = "Nobody answered the approval request."
                }
                await record(.approvalDenied, context: context, toolID: manifest.identifier, tier: requirements.tier, detail: why,
                             data: ["callID": .string(callID), "approvalID": .string(request.id)])
                outcome.result = .failure(.notApproved, ToolFailure(
                    code: "not_approved", message: "\(manifest.identifier) was not approved. \(why)",
                    recovery: "Do not retry the same action or look for another route; continue without it or ask the user."))
                return outcome
            }
            outcome.grantIDs = await policy.recordApproval(response, for: request)
            await record(.approvalGranted, context: context, toolID: manifest.identifier, tier: requirements.tier,
                         detail: "\(Self.label(response)): \(access.summary)",
                         data: ["callID": .string(callID), "approvalID": .string(request.id), "grantIDs": .array(outcome.grantIDs.map(JSONValue.string))])
            // Grants created by the approval widen the confinement of this call.
            toolContext.confinement = await policy.confinement(runID: context.runID, workflowID: context.workflowID)
        }
        // The call's own capabilities were just authorised (grant, approval or artifacts directory): they are part of
        // its envelope even when the grant is single-use and therefore absent from the run-level confinement.
        for cap in requirements.capabilities {
            switch cap {
            case .fileRead(let p): if !toolContext.confinement.readRoots.contains(p) { toolContext.confinement.readRoots.append(p) }
            case .fileWrite(let p), .fileDelete(let p): if !toolContext.confinement.writeRoots.contains(p) { toolContext.confinement.writeRoots.append(p) }
            case .network(let h): if !toolContext.confinement.networkHosts.contains(h) { toolContext.confinement.networkHosts.append(h) }
            case .browser(let h): if !toolContext.confinement.browserHosts.contains(h) { toolContext.confinement.browserHosts.append(h) }
            default: break
            }
        }
        if flight.isCanceled { outcome.result = Self.result(for: ToolError.canceled); return outcome }

        // 6. Idempotency.
        let idempotencyKey = call.idempotencyKey.map { "\(context.runID)\u{1f}\(manifest.identifier)\u{1f}\($0)" }
        if let key = idempotencyKey {
            while idempotentPending[key] != nil {
                await withCheckedContinuation { idempotentPending[key]?.append($0) }
            }
            if let stored = idempotentResults[context.runID]?[key] {
                outcome.result = stored; outcome.replayed = true
                return outcome
            }
            idempotentPending[key] = []
        }
        defer {
            if let key = idempotencyKey, let waiters = idempotentPending.removeValue(forKey: key) { waiters.forEach { $0.resume() } }
        }

        // 7. Concurrency gate, then execution under a timeout.
        await acquire(manifest)
        defer { release(manifest) }
        if flight.isCanceled { outcome.result = Self.result(for: ToolError.canceled); return outcome }

        if let secrets {
            let allowed = Set(requirements.capabilities.compactMap { c -> String? in if case .secret(let r) = c { return r }; return nil })
            toolContext.secrets = ScopedSecretResolver(base: secrets, allowed: allowed, redactor: redactor, audit: audit,
                                                       runID: context.runID, toolID: manifest.identifier)
        }
        outcome.executed = true
        let execution = await Self.execute(tool, input: input, context: toolContext, timeout: timeout, grace: unwindGraceSeconds, flight: flight)

        // 8. Typed errors and output schema.
        var result: ToolResult
        if flight.didTimeOut { result = Self.result(for: ToolError.timeout(seconds: timeout)) }
        else if flight.isCanceled { result = Self.result(for: ToolError.canceled) }
        else {
            switch execution {
            case .success(let r): result = r
            case .failure(let error): result = Self.result(for: error)
            case nil: result = Self.result(for: ToolError.canceled)
            }
        }
        if result.status == .succeeded {
            let problems = manifest.outputSchema.validate(result.output)
            if !problems.isEmpty {
                let text = problems.prefix(6).map(\.description).joined(separator: "; ")
                result = .failure(.failed, ToolFailure(code: "output_invalid", message: "\(manifest.identifier) returned an output that does not match its schema: \(text)"))
            } else if let key = idempotencyKey {
                idempotentResults[context.runID, default: [:]][key] = result
            }
        }
        outcome.result = result
        return outcome
    }

    /// Steps 8–9 for every outcome: duration, redaction, truncation, grant consumption, audit, `toolFinished`.
    private func finish(_ outcome: Outcome, call: ToolCall, context: InvocationContext, started: ContinuousClock.Instant) async -> ToolResult {
        var result = outcome.result
        let elapsed = ContinuousClock.now - started
        result.durationMs = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        if let manifest = outcome.manifest {
            result.untrusted = result.untrusted || (manifest.outputIsUntrusted && result.status == .succeeded)
        }
        result.output = redactor.redact(result.output)
        result.summary = redactor.redact(result.summary)
        if var failure = result.failure {
            failure.message = redactor.redact(failure.message)
            failure.recovery = failure.recovery.map(redactor.redact)
            result.failure = failure
        }
        let limit = outcome.manifest?.maxOutputBytes ?? 262_144
        let (bounded, cut) = Self.bounded(result.output, maxBytes: limit)
        if cut { result.output = bounded; result.truncated = true }
        result.summary = result.summary.truncated(maxBytes: 2_000).text

        // 9. Consume single-use grants, audit, event.
        if outcome.executed || outcome.replayed, !outcome.grantIDs.isEmpty {
            await policy.consume(grantIDs: outcome.grantIDs, callID: call.id)
        }
        let kind: AuditEntry.Kind
        switch result.status {
        case .succeeded, .simulated: kind = .toolExecuted
        case .denied, .notApproved: kind = .toolDenied
        default: kind = .toolFailed
        }
        let toolID = outcome.manifest?.identifier ?? call.toolID
        var data: [String: JSONValue] = [
            "callID": .string(call.id), "toolID": .string(toolID), "status": .string(result.status.rawValue),
            "durationMs": .int(result.durationMs), "summary": .string(result.summary),
            "arguments": redactor.redact(call.arguments, keys: Set(outcome.manifest?.redactedInputKeys ?? [])),
        ]
        if let tier = outcome.tier { data["tier"] = .int(tier.rawValue) }
        if let failure = result.failure { data["failureCode"] = .string(failure.code) }
        if outcome.replayed { data["replayed"] = .bool(true) }
        if result.truncated { data["truncated"] = .bool(true) }
        if !result.artifacts.isEmpty { data["artifacts"] = .array(result.artifacts.map { .string($0.path) }) }
        var auditData = data
        auditData["capabilities"] = .array(outcome.capabilities.map { .string($0.displayString) })
        await record(kind, context: context, toolID: toolID, tier: outcome.tier,
                     detail: outcome.replayed ? "Replayed stored result: \(result.summary)" : result.summary, data: .object(auditData))
        await emit(.toolFinished, context: context, text: result.summary, data: .object(data))
        return result
    }

    // MARK: Execution

    /// Runs `tool.execute` in its own task. Returns `nil` when the tool did not unwind within the grace period after a
    /// timeout or a cancellation (the call is then reported from the flight's flags).
    private static func execute(_ tool: any ORIXTool, input: ToolInput, context: ToolExecutionContext, timeout: Double, grace: Double,
                                flight: Flight) async -> Result<ToolResult, Error>? {
        let timer = TaskBox()
        let value: Result<ToolResult, Error>? = await withCheckedContinuation { (cont: CheckedContinuation<Result<ToolResult, Error>?, Never>) in
            let once = ResumeOnce(cont)
            let work = Task<Void, Never> {
                do { once.resume(.success(try await tool.execute(input: input, context: context))) }
                catch { once.resume(.failure(error)) }
            }
            flight.attach(work: work, abandon: { once.resume(nil) }, grace: grace)
            timer.set(Task {
                try? await Task.sleep(for: .seconds(timeout))
                if Task.isCancelled { return }
                flight.markTimedOut()
                work.cancel()
                try? await Task.sleep(for: .seconds(grace))
                if Task.isCancelled { return }
                once.resume(nil)
            })
        }
        timer.cancel()
        return value
    }

    // MARK: Concurrency gate

    private func acquire(_ manifest: ToolManifest) async {
        switch manifest.concurrency {
        case .unlimited: return
        case .serial:
            let id = manifest.identifier
            if serialHeld.contains(id) { await withCheckedContinuation { serialWaiters[id, default: []].append($0) } }
            else { serialHeld.insert(id) }
        case .exclusive:
            if exclusiveHeld { await withCheckedContinuation { exclusiveWaiters.append($0) } }
            else { exclusiveHeld = true }
        }
    }

    /// Hands the slot directly to the next waiter, so ownership never lapses between two calls.
    private func release(_ manifest: ToolManifest) {
        switch manifest.concurrency {
        case .unlimited: return
        case .serial:
            let id = manifest.identifier
            if var queue = serialWaiters[id], !queue.isEmpty {
                let next = queue.removeFirst()
                serialWaiters[id] = queue.isEmpty ? nil : queue
                next.resume()
            } else { serialHeld.remove(id) }
        case .exclusive:
            if !exclusiveWaiters.isEmpty { exclusiveWaiters.removeFirst().resume() } else { exclusiveHeld = false }
        }
    }

    // MARK: Sinks

    private func emit(_ kind: RunEvent.Kind, context: InvocationContext, text: String, data: JSONValue) async {
        guard let events else { return }
        await events.emit(RunEvent(runID: context.runID, kind: kind, text: redactor.redact(text), data: data))
    }

    private func record(_ kind: AuditEntry.Kind, context: InvocationContext, toolID: String, tier: ApprovalTier?, detail: String,
                        data: JSONValue) async {
        guard let audit else { return }
        await audit.record(AuditEntry(kind: kind, runID: context.runID, toolID: toolID, tier: tier, detail: redactor.redact(detail), data: data))
    }

    // MARK: Helpers

    static func result(for error: Error) -> ToolResult {
        if let e = error as? ToolError { return .failure(e.status, e.failure) }
        if error is CancellationError { return .failure(.canceled, ToolError.canceled.failure) }
        if let u = error as? URLError, u.code == .cancelled { return .failure(.canceled, ToolError.canceled.failure) }
        let e = ToolError.internalError(String(describing: error))
        return .failure(e.status, e.failure)
    }

    private static func isFile(_ c: Capability) -> Bool {
        switch c {
        case .fileRead, .fileWrite, .fileDelete: return true
        default: return false
        }
    }

    private static func path(_ root: String, contains child: String) -> Bool {
        guard root.hasPrefix("/"), root != "/" else { return false }
        return child == root || child.hasPrefix(root + "/")
    }

    private static func label(_ response: ApprovalResponse) -> String {
        switch response {
        case .approveOnce: return "approveOnce"
        case .approveForRun: return "approveForRun"
        case .approvePersistent: return "approvePersistent"
        case .deny: return "deny"
        case .unanswered: return "unanswered"
        }
    }

    /// Shrinks an output to `maxBytes` of JSON: long strings are cut first; if that is not enough the value is replaced
    /// by a preview object.
    static func bounded(_ value: JSONValue, maxBytes: Int) -> (JSONValue, Bool) {
        let whole = value.serialized()
        if whole.utf8.count <= maxBytes { return (value, false) }
        var cap = max(64, maxBytes / 2)
        while cap >= 64 {
            let candidate = cut(value, stringCap: cap)
            if candidate.serialized().utf8.count <= maxBytes { return (candidate, true) }
            cap /= 2
        }
        return (["truncated": true, "preview": .string(whole.truncated(maxBytes: max(32, maxBytes / 2)).text)], true)
    }

    private static func cut(_ value: JSONValue, stringCap: Int) -> JSONValue {
        switch value {
        case .string(let s): return .string(s.truncated(maxBytes: stringCap).text)
        case .array(let a): return .array(a.map { cut($0, stringCap: stringCap) })
        case .object(let o): return .object(o.mapValues { cut($0, stringCap: stringCap) })
        default: return value
        }
    }
}

// MARK: - Per-call state

/// Cancellation and timeout flags of one in-flight call, reachable from outside the actor.
final class Flight: @unchecked Sendable {
    let runID: String
    private let lock = NSLock()
    private var canceled = false
    private var timedOut = false
    private var work: Task<Void, Never>?
    private var abandon: (@Sendable () -> Void)?

    init(runID: String) { self.runID = runID }

    var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }

    func markTimedOut() { lock.lock(); if !canceled { timedOut = true }; lock.unlock() }

    func attach(work: Task<Void, Never>, abandon: @escaping @Sendable () -> Void, grace: Double) {
        lock.lock()
        self.work = work; self.abandon = abandon
        let already = canceled
        lock.unlock()
        if already { work.cancel(); Self.later(grace, abandon) }
    }

    func cancel(grace: Double) {
        lock.lock()
        if canceled || timedOut { lock.unlock(); return }
        canceled = true
        let w = work, a = abandon
        lock.unlock()
        w?.cancel()
        if let a { Self.later(grace, a) }
    }

    private static func later(_ seconds: Double, _ body: @escaping @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: body)
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { continuation = c }
    func resume(_ value: T) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var canceled = false
    func set(_ t: Task<Void, Never>) {
        lock.lock(); task = t; let c = canceled; lock.unlock()
        if c { t.cancel() }
    }
    func cancel() { lock.lock(); canceled = true; let t = task; lock.unlock(); t?.cancel() }
}

/// Resolves only the secret references the call declared, registers each value for redaction and audits the use.
private struct ScopedSecretResolver: SecretResolving {
    let base: any SecretResolving
    let allowed: Set<String>
    let redactor: Redactor
    let audit: (any AuditSink)?
    let runID: String
    let toolID: String

    func secret(reference: String) async throws -> String {
        guard allowed.contains(reference) else {
            throw ToolError.permissionDenied("Secret \(reference) was not declared by this call")
        }
        let value = try await base.secret(reference: reference)
        redactor.register(secret: value)
        await audit?.record(AuditEntry(kind: .secretUsed, runID: runID, toolID: toolID, detail: "Secret reference \(reference) used",
                                       data: ["reference": .string(reference)]))
        return value
    }
}
