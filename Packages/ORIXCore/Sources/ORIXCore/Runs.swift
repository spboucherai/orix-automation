// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXCore/Sources/ORIXCore/Runs.swift
// Description      : Versioned run-time models: statuses, budgets, plans,
//                    events, observations, verification, memory, sessions,
//                    agent profiles and receipts.
// Module           : ORIXCore
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

/// Schema version stamped on persisted models so stores can migrate them.
public let orixModelVersion = 1

public enum RunStatus: String, Codable, Sendable, CaseIterable {
    // In flight
    case queued = "QUEUED"
    case running = "RUNNING"
    case paused = "PAUSED"
    case recovering = "RECOVERING"
    case waitingApproval = "WAITING_APPROVAL"
    // Outcomes
    case succeeded = "SUCCEEDED"
    case partiallySucceeded = "PARTIALLY_SUCCEEDED"
    case failed = "FAILED"
    case canceled = "CANCELED"
    case timedOut = "TIMED_OUT"
    case blockedPermission = "BLOCKED_PERMISSION"
    case budgetExceeded = "BUDGET_EXCEEDED"
    case recoveryRequired = "RECOVERY_REQUIRED"

    public var isTerminal: Bool {
        switch self {
        case .queued, .running, .paused, .recovering, .waitingApproval: return false
        default: return true
        }
    }

    /// Legal state-machine transitions. Terminal states have none.
    public func canTransition(to next: RunStatus) -> Bool {
        if self == next { return false }
        switch self {
        case .queued: return [.running, .canceled, .failed, .waitingApproval].contains(next)
        case .running: return next != .queued
        case .paused: return [.running, .canceled, .failed, .timedOut].contains(next)
        case .recovering: return next != .queued
        case .waitingApproval: return [.running, .canceled, .failed, .timedOut, .blockedPermission, .paused].contains(next)
        case .recoveryRequired: return [.recovering, .canceled].contains(next)
        default: return false
        }
    }
}

public struct Budget: Codable, Sendable, Hashable {
    public var maxTurns: Int
    public var maxWallSeconds: Double
    public var maxTotalTokens: Int
    public var maxCostUSD: Double
    public var maxToolCalls: Int
    public var maxSubprocessSeconds: Double
    public var maxConcurrentTasks: Int

    public init(maxTurns: Int = 30, maxWallSeconds: Double = 900, maxTotalTokens: Int = 400_000, maxCostUSD: Double = 1.0,
                maxToolCalls: Int = 80, maxSubprocessSeconds: Double = 300, maxConcurrentTasks: Int = 4) {
        self.maxTurns = maxTurns; self.maxWallSeconds = maxWallSeconds; self.maxTotalTokens = maxTotalTokens; self.maxCostUSD = maxCostUSD
        self.maxToolCalls = maxToolCalls; self.maxSubprocessSeconds = maxSubprocessSeconds; self.maxConcurrentTasks = maxConcurrentTasks
    }

    public static let quick = Budget(maxTurns: 12, maxWallSeconds: 300, maxTotalTokens: 150_000, maxCostUSD: 0.50, maxToolCalls: 30)
    public static let standard = Budget()
}

public struct RunUsage: Codable, Sendable, Hashable {
    public var turns: Int = 0
    public var toolCalls: Int = 0
    public var tokens: TokenUsage = .init()
    /// Sum of known costs. `costIsComplete` is false when at least one turn had no price information.
    public var costUSD: Double = 0
    public var costIsComplete: Bool = true
    public init() {}
}

public struct PlanStep: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, inProgress, done, failed, skipped }
    public var id: String
    public var title: String
    public var status: Status
    public var expectedArtifact: String?
    public var note: String
    public init(id: String, title: String, status: Status = .pending, expectedArtifact: String? = nil, note: String = "") {
        self.id = id; self.title = title; self.status = status; self.expectedArtifact = expectedArtifact; self.note = note
    }
}

public struct AgentPlan: Codable, Sendable, Hashable {
    public var objective: String
    public var steps: [PlanStep]
    public var revision: Int
    public init(objective: String, steps: [PlanStep] = [], revision: Int = 1) {
        self.objective = objective; self.steps = steps; self.revision = revision
    }
}

/// A fact the runtime observed itself (tool output, filesystem state), as opposed to something a model said.
public struct RunObservation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var timestamp: Date
    public var source: String
    public var summary: String
    public var data: JSONValue
    public var untrusted: Bool
    public init(id: String = UUID().uuidString, timestamp: Date = Date(), source: String, summary: String, data: JSONValue = .null, untrusted: Bool = false) {
        self.id = id; self.timestamp = timestamp; self.source = source; self.summary = summary; self.data = data; self.untrusted = untrusted
    }
}

/// A postcondition check performed by the runtime, not by the model.
public struct VerificationResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Human-readable assertion, for example `File ~/Reports/weekly.pdf exists and is larger than 1 kB`.
    public var assertion: String
    /// `file_exists`, `file_nonempty`, `file_contains`, `sha256`, `exit_code`, `tool_succeeded`, `json_path`, `custom`.
    public var kind: String
    public var passed: Bool
    public var evidence: String
    public var checkedAt: Date
    public init(id: String = UUID().uuidString, assertion: String, kind: String, passed: Bool, evidence: String, checkedAt: Date = Date()) {
        self.id = id; self.assertion = assertion; self.kind = kind; self.passed = passed; self.evidence = evidence; self.checkedAt = checkedAt
    }
}

public struct MemoryRecord: Codable, Sendable, Hashable, Identifiable {
    public enum Scope: Codable, Sendable, Hashable {
        case session(String)
        case workflow(String)
        case agent(String)
        case user
        public var key: String {
            switch self {
            case .session(let s): return "session:\(s)"
            case .workflow(let w): return "workflow:\(w)"
            case .agent(let a): return "agent:\(a)"
            case .user: return "user"
            }
        }
    }
    public var id: String
    public var scope: Scope
    /// `preference`, `fix`, `fact`, `summary`, `convention`.
    public var kind: String
    public var text: String
    /// Where it came from: run id, tool call, or `user`.
    public var provenance: String
    /// True when a person approved keeping it. User-scope memories are only injected when approved.
    public var approved: Bool
    public var createdAt: Date
    public init(id: String = UUID().uuidString, scope: Scope, kind: String, text: String, provenance: String, approved: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.scope = scope; self.kind = kind; self.text = text; self.provenance = provenance; self.approved = approved; self.createdAt = createdAt
    }
}

/// A reusable agent definition (Agents section).
public struct AgentProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// `planner`, `worker`, `specialist`, `verifier`, `reviewer`.
    public var role: String
    public var instructions: String
    public var model: ModelRef
    public var budget: Budget
    /// Tool identifiers or `family.*` patterns this agent may be offered. Empty means none.
    public var toolPatterns: [String]
    /// Which memory scopes are injected: `session`, `workflow`, `agent`, `user`.
    public var memoryScopes: [String]
    public var maxConcurrency: Int
    public var builtIn: Bool

    public init(id: String = UUID().uuidString, name: String, role: String = "worker", instructions: String, model: ModelRef,
                budget: Budget = .standard, toolPatterns: [String] = ["*"], memoryScopes: [String] = ["session"], maxConcurrency: Int = 1, builtIn: Bool = false) {
        self.id = id; self.name = name; self.role = role; self.instructions = instructions; self.model = model; self.budget = budget
        self.toolPatterns = toolPatterns; self.memoryScopes = memoryScopes; self.maxConcurrency = maxConcurrency; self.builtIn = builtIn
    }

    public func allows(toolID: String) -> Bool {
        toolPatterns.contains { p in
            if p == "*" || p == toolID { return true }
            if p.hasSuffix(".*") { return toolID.hasPrefix(String(p.dropLast(1))) }
            return false
        }
    }
}

/// One objective handed to an agent.
public struct AgentTask: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var objective: String
    public var mode: ExecutionMode
    public var workingDirectory: String
    public var budget: Budget
    /// Extra data given to the agent as untrusted context (for example the output of previous workflow steps).
    public var inputs: JSONValue
    /// Postconditions the runtime checks before it will report success.
    public var expectations: [Expectation]
    public init(id: String = UUID().uuidString, objective: String, mode: ExecutionMode = .guided, workingDirectory: String,
                budget: Budget = .standard, inputs: JSONValue = .null, expectations: [Expectation] = []) {
        self.id = id; self.objective = objective; self.mode = mode; self.workingDirectory = workingDirectory
        self.budget = budget; self.inputs = inputs; self.expectations = expectations
    }
}

/// A declarative postcondition. Evaluated by the runtime against real state.
public struct Expectation: Codable, Sendable, Hashable {
    /// `file_exists`, `file_nonempty`, `file_contains`, `dir_nonempty`.
    public var kind: String
    public var path: String
    public var text: String?
    public init(kind: String, path: String, text: String? = nil) { self.kind = kind; self.path = path; self.text = text }
}

/// A conversation with an agent: several tasks sharing history.
public struct AgentSession: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var agentID: String?
    public var model: ModelRef
    public var mode: ExecutionMode
    public var workingDirectory: String
    public var createdAt: Date
    public var updatedAt: Date
    public var modelVersion: Int
    public init(id: String = UUID().uuidString, title: String, agentID: String? = nil, model: ModelRef, mode: ExecutionMode = .guided,
                workingDirectory: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.agentID = agentID; self.model = model; self.mode = mode
        self.workingDirectory = workingDirectory; self.createdAt = createdAt; self.updatedAt = updatedAt; self.modelVersion = orixModelVersion
    }
}

public struct RunRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// `agent` or `workflow`.
    public var kind: String
    public var title: String
    public var sessionID: String?
    public var workflowID: String?
    public var workflowVersion: Int?
    /// `manual`, `schedule`, `file`, `login`, `agent`, `debug`.
    public var trigger: String
    public var mode: ExecutionMode
    public var status: RunStatus
    public var model: ModelRef?
    public var queuedAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var usage: RunUsage
    public var errorSummary: String?
    public var parentRunID: String?
    public var modelVersion: Int

    public init(id: String = UUID().uuidString, kind: String, title: String, sessionID: String? = nil, workflowID: String? = nil,
                workflowVersion: Int? = nil, trigger: String = "manual", mode: ExecutionMode, status: RunStatus = .queued,
                model: ModelRef? = nil, queuedAt: Date = Date(), startedAt: Date? = nil, endedAt: Date? = nil, usage: RunUsage = .init(),
                errorSummary: String? = nil, parentRunID: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.sessionID = sessionID; self.workflowID = workflowID
        self.workflowVersion = workflowVersion; self.trigger = trigger; self.mode = mode; self.status = status; self.model = model
        self.queuedAt = queuedAt; self.startedAt = startedAt; self.endedAt = endedAt; self.usage = usage
        self.errorSummary = errorSummary; self.parentRunID = parentRunID; self.modelVersion = orixModelVersion
    }

    public var durationSeconds: Double? {
        guard let s = startedAt else { return nil }
        return (endedAt ?? Date()).timeIntervalSince(s)
    }
}

/// Append-only run timeline. Everything the console and the Runs section show comes from these.
public struct RunEvent: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case statusChanged, userMessage, assistantText, reasoningSummary, planUpdated
        case toolRequested, toolProgress, toolFinished
        case approvalRequested, approvalResolved
        case stepStarted, stepFinished
        case verification, usage, retry, checkpoint, memory, log, error, receipt
    }
    public var id: String
    public var runID: String
    /// Monotonic per run, assigned by the store.
    public var seq: Int
    public var timestamp: Date
    public var kind: Kind
    /// Workflow step id or agent name the event belongs to, when any.
    public var stepID: String?
    /// Already redacted.
    public var text: String
    public var data: JSONValue

    public init(id: String = UUID().uuidString, runID: String, seq: Int = 0, timestamp: Date = Date(), kind: Kind, stepID: String? = nil,
                text: String = "", data: JSONValue = .null) {
        self.id = id; self.runID = runID; self.seq = seq; self.timestamp = timestamp; self.kind = kind
        self.stepID = stepID; self.text = text; self.data = data
    }
}

public protocol RunEventSink: Sendable {
    func emit(_ event: RunEvent) async
}

/// Final evidence document for a run.
public struct RunReceipt: Codable, Sendable, Hashable {
    public var runID: String
    public var title: String
    public var status: RunStatus
    public var objective: String
    public var model: ModelRef?
    public var startedAt: Date
    public var endedAt: Date
    public var usage: RunUsage
    public var toolCalls: [ToolCallRecord]
    public var approvals: [String]
    public var permissionsUsed: [String]
    public var artifacts: [Artifact]
    public var verifications: [VerificationResult]
    /// The agent's closing statement. Labeled as a claim; status comes from verification, not from this text.
    public var agentSummary: String
    public var limitations: [String]
    public var errors: [String]
    public var modelVersion: Int

    public init(runID: String, title: String, status: RunStatus, objective: String, model: ModelRef?, startedAt: Date, endedAt: Date,
                usage: RunUsage, toolCalls: [ToolCallRecord] = [], approvals: [String] = [], permissionsUsed: [String] = [],
                artifacts: [Artifact] = [], verifications: [VerificationResult] = [], agentSummary: String = "",
                limitations: [String] = [], errors: [String] = []) {
        self.runID = runID; self.title = title; self.status = status; self.objective = objective; self.model = model
        self.startedAt = startedAt; self.endedAt = endedAt; self.usage = usage; self.toolCalls = toolCalls; self.approvals = approvals
        self.permissionsUsed = permissionsUsed; self.artifacts = artifacts; self.verifications = verifications
        self.agentSummary = agentSummary; self.limitations = limitations; self.errors = errors; self.modelVersion = orixModelVersion
    }

    public func markdown() -> String {
        let f = ISO8601DateFormatter()
        var s = "# Execution receipt — \(title)\n\n"
        s += "- Run: `\(runID)`\n- Status: **\(status.rawValue)**\n- Started: \(f.string(from: startedAt))\n- Ended: \(f.string(from: endedAt))\n"
        if let model { s += "- Model: \(model.displayString)\n" }
        s += "- Turns: \(usage.turns) · Tool calls: \(usage.toolCalls) · Tokens: \(usage.tokens.totalTokens)\n"
        s += "- Cost: " + (usage.costIsComplete ? String(format: "$%.4f", usage.costUSD) : String(format: "≥ $%.4f (some turns had no price information)", usage.costUSD)) + "\n\n"
        s += "## Objective\n\n\(objective)\n\n"
        s += "## Verification (performed by the runtime)\n\n"
        if verifications.isEmpty { s += "No postcondition was declared or checkable for this run.\n\n" }
        for v in verifications { s += "- \(v.passed ? "PASS" : "FAIL") — \(v.assertion) — \(v.evidence)\n" }
        if !verifications.isEmpty { s += "\n" }
        s += "## Tool calls\n\n"
        if toolCalls.isEmpty { s += "None.\n" }
        for c in toolCalls { s += "- `\(c.toolID)` — \(c.status.rawValue) — \(c.durationMs) ms — \(c.summary)\n" }
        s += "\n## Artifacts\n\n"
        if artifacts.isEmpty { s += "None.\n" }
        for a in artifacts { s += "- \(a.path) (\(a.bytes) bytes" + (a.sha256.map { ", sha256 \($0.prefix(16))…" } ?? "") + ")\n" }
        if !approvals.isEmpty { s += "\n## Approvals\n\n" + approvals.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !permissionsUsed.isEmpty { s += "\n## Permissions used\n\n" + permissionsUsed.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !errors.isEmpty { s += "\n## Errors\n\n" + errors.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !limitations.isEmpty { s += "\n## Limitations\n\n" + limitations.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !agentSummary.isEmpty { s += "\n## Agent's closing statement (a claim, not evidence)\n\n\(agentSummary)\n" }
        return s
    }
}

public struct ToolCallRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var toolID: String
    /// Redacted.
    public var arguments: JSONValue
    public var status: ToolStatus
    public var summary: String
    public var durationMs: Int
    public var tier: ApprovalTier?
    public var startedAt: Date
    public init(id: String, toolID: String, arguments: JSONValue, status: ToolStatus, summary: String, durationMs: Int, tier: ApprovalTier? = nil, startedAt: Date = Date()) {
        self.id = id; self.toolID = toolID; self.arguments = arguments; self.status = status; self.summary = summary
        self.durationMs = durationMs; self.tier = tier; self.startedAt = startedAt
    }
}

/// Runs an agent to completion. Implemented by ORIXAgentRuntime; the workflow engine calls it for agent steps.
public protocol AgentRunning: Sendable {
    func run(task: AgentTask, profile: AgentProfile, runID: String, workflowID: String?, stepID: String?) async -> AgentOutcome
}

public struct AgentOutcome: Codable, Sendable, Hashable {
    public var status: RunStatus
    public var finalText: String
    /// Structured result when the agent returned one through its `task.complete` tool.
    public var result: JSONValue
    public var usage: RunUsage
    public var artifacts: [Artifact]
    public var verifications: [VerificationResult]
    public var errorSummary: String?
    public init(status: RunStatus, finalText: String = "", result: JSONValue = .null, usage: RunUsage = .init(), artifacts: [Artifact] = [],
                verifications: [VerificationResult] = [], errorSummary: String? = nil) {
        self.status = status; self.finalText = finalText; self.result = result; self.usage = usage; self.artifacts = artifacts
        self.verifications = verifications; self.errorSummary = errorSummary
    }
}
