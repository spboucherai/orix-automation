// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Model.swift
// Description      : The workflow intermediate representation (IR): one
//                    validated model behind the agent, visual and code views.
// Module           : ORIXWorkflowEngine
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

/// A declarative automation. The canonical text form is produced by `WorkflowCodec.emit`.
public struct WorkflowDocument: Sendable, Hashable {
    public static let currentAPIVersion = "orix.ai/v1"
    public static let automationKind = "Automation"

    public var apiVersion: String
    public var kind: String
    public var metadata: WorkflowMetadata
    public var spec: WorkflowSpec

    public init(apiVersion: String = WorkflowDocument.currentAPIVersion, kind: String = WorkflowDocument.automationKind,
                metadata: WorkflowMetadata, spec: WorkflowSpec = .init()) {
        self.apiVersion = apiVersion; self.kind = kind; self.metadata = metadata; self.spec = spec
    }
}

public struct WorkflowMetadata: Sendable, Hashable {
    /// Stable identifier (`[A-Za-z_][A-Za-z0-9_-]*`). Defaults to a slug of `name` when the source omits it.
    public var id: String
    public var name: String
    public var description: String
    public var tags: [String]

    public init(id: String, name: String, description: String = "", tags: [String] = []) {
        self.id = id; self.name = name; self.description = description; self.tags = tags
    }

    /// Lowercase slug used as the default id: letters, digits and single dashes.
    public static func slug(_ text: String) -> String {
        var out = ""
        var lastDash = true
        for u in text.lowercased().unicodeScalars {
            let ok = (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57)
            if ok { out.unicodeScalars.append(u); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { return "workflow" }
        if let f = out.unicodeScalars.first, f.value >= 48 && f.value <= 57 { out = "w-" + out }
        return out
    }
}

public struct WorkflowSpec: Sendable, Hashable {
    public var triggers: [WorkflowTrigger]
    public var parameters: [WorkflowParameter]
    public var permissions: WorkflowPermissions
    public var budget: WorkflowBudget
    public var variables: [String: JSONValue]
    public var steps: [WorkflowStep]
    /// Workflow-level handler steps, run when the workflow ends in failure.
    public var onError: [WorkflowStep]
    /// Node positions for the visual editor, keyed by step id.
    public var layout: [String: WorkflowNodePosition]

    public init(triggers: [WorkflowTrigger] = [], parameters: [WorkflowParameter] = [], permissions: WorkflowPermissions = .init(),
                budget: WorkflowBudget = .init(), variables: [String: JSONValue] = [:], steps: [WorkflowStep] = [],
                onError: [WorkflowStep] = [], layout: [String: WorkflowNodePosition] = [:]) {
        self.triggers = triggers; self.parameters = parameters; self.permissions = permissions; self.budget = budget
        self.variables = variables; self.steps = steps; self.onError = onError; self.layout = layout
    }
}

public enum WorkflowTrigger: Sendable, Hashable {
    case manual
    /// Five-field cron expression, optional IANA timezone.
    case schedule(cron: String, timezone: String?)
    /// One run at an ISO 8601 instant.
    case once(at: String)
    case interval(seconds: Double)
    case fileChange(path: String, glob: String?, debounceSeconds: Double?)
    case login
    case appLaunch(bundleID: String)

    public var typeName: String {
        switch self {
        case .manual: return "manual"
        case .schedule: return "schedule"
        case .once: return "once"
        case .interval: return "interval"
        case .fileChange: return "fileChange"
        case .login: return "login"
        case .appLaunch: return "appLaunch"
        }
    }
}

public enum WorkflowParameterType: String, Sendable, Hashable, CaseIterable {
    case string, number, integer, boolean, path, array, object
}

public struct WorkflowParameter: Sendable, Hashable {
    public var name: String
    public var type: WorkflowParameterType
    /// `nil` means no default; `.null` is an explicit null default.
    public var defaultValue: JSONValue?
    public var description: String
    public var required: Bool

    public init(name: String, type: WorkflowParameterType = .string, defaultValue: JSONValue? = nil, description: String = "", required: Bool = false) {
        self.name = name; self.type = type; self.defaultValue = defaultValue; self.description = description; self.required = required
    }
}

public struct WorkflowPermissions: Sendable, Hashable {
    public struct Filesystem: Sendable, Hashable {
        public var read: [String]
        public var write: [String]
        public var delete: [String]
        public init(read: [String] = [], write: [String] = [], delete: [String] = []) { self.read = read; self.write = write; self.delete = delete }
        public var isEmpty: Bool { read.isEmpty && write.isEmpty && delete.isEmpty }
    }
    public struct Apps: Sendable, Hashable {
        /// Bundle identifiers that may receive Apple Events.
        public var automation: [String]
        /// Bundle identifiers that may be inspected/controlled through Accessibility.
        public var accessibility: [String]
        /// Bundle identifiers that may be launched or quit.
        public var control: [String]
        public init(automation: [String] = [], accessibility: [String] = [], control: [String] = []) {
            self.automation = automation; self.accessibility = accessibility; self.control = control
        }
        public var isEmpty: Bool { automation.isEmpty && accessibility.isEmpty && control.isEmpty }
    }
    public struct Clipboard: Sendable, Hashable {
        public var read: Bool
        public var write: Bool
        public init(read: Bool = false, write: Bool = false) { self.read = read; self.write = write }
    }

    public var filesystem: Filesystem
    /// Executables (bare names or absolute paths).
    public var processes: [String]
    /// Script runtimes: `bash`, `python`, `swift`, `javascript`, `applescript`, `jxa`.
    public var scripts: [String]
    public var apps: Apps
    /// Outbound network hosts (`*.example.com` covers subdomains).
    public var network: [String]
    /// Hosts the browser tools may open.
    public var browser: [String]
    /// Keychain secret reference names.
    public var secrets: [String]
    public var clipboard: Clipboard
    public var notifications: Bool
    /// Screen capture scopes: `display`, `window:<bundleID>`, `region`.
    public var screen: [String]

    public init(filesystem: Filesystem = .init(), processes: [String] = [], scripts: [String] = [], apps: Apps = .init(),
                network: [String] = [], browser: [String] = [], secrets: [String] = [], clipboard: Clipboard = .init(),
                notifications: Bool = false, screen: [String] = []) {
        self.filesystem = filesystem; self.processes = processes; self.scripts = scripts; self.apps = apps
        self.network = network; self.browser = browser; self.secrets = secrets; self.clipboard = clipboard
        self.notifications = notifications; self.screen = screen
    }

    public var isEmpty: Bool { self == WorkflowPermissions() }
}

public struct WorkflowBudget: Sendable, Hashable {
    public var maxDurationSeconds: Double?
    public var maxProviderCostUSD: Double?
    public var maxToolCalls: Int?
    public var maxTokens: Int?

    public init(maxDurationSeconds: Double? = nil, maxProviderCostUSD: Double? = nil, maxToolCalls: Int? = nil, maxTokens: Int? = nil) {
        self.maxDurationSeconds = maxDurationSeconds; self.maxProviderCostUSD = maxProviderCostUSD
        self.maxToolCalls = maxToolCalls; self.maxTokens = maxTokens
    }
    public var isEmpty: Bool { self == WorkflowBudget() }
}

public struct WorkflowNodePosition: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct WorkflowRetryPolicy: Sendable, Hashable {
    /// Total attempts including the first one.
    public var maxAttempts: Int
    public var backoffSeconds: Double
    public var backoffMultiplier: Double
    /// Retry even when the step is not idempotent. The author takes responsibility for repeated side effects.
    public var force: Bool

    public init(maxAttempts: Int, backoffSeconds: Double = 0, backoffMultiplier: Double = 1, force: Bool = false) {
        self.maxAttempts = maxAttempts; self.backoffSeconds = backoffSeconds; self.backoffMultiplier = backoffMultiplier; self.force = force
    }
}

public struct WorkflowStep: Sendable, Hashable, Identifiable {
    /// Unique in the whole document, including nested bodies.
    public var id: String
    public var name: String?
    /// Steps of the same scope that must finish first.
    public var needs: [String]
    /// Expression; the step is skipped when it evaluates falsy.
    public var when: String?
    public var retry: WorkflowRetryPolicy?
    public var timeoutSeconds: Double?
    public var continueOnError: Bool
    /// Id of a catch/compensation step of the same scope. That step only runs as a handler.
    public var onError: String?
    public var kind: WorkflowStepKind

    public init(id: String, name: String? = nil, needs: [String] = [], when: String? = nil, retry: WorkflowRetryPolicy? = nil,
                timeoutSeconds: Double? = nil, continueOnError: Bool = false, onError: String? = nil, kind: WorkflowStepKind) {
        self.id = id; self.name = name; self.needs = needs; self.when = when; self.retry = retry
        self.timeoutSeconds = timeoutSeconds; self.continueOnError = continueOnError; self.onError = onError; self.kind = kind
    }
}

public indirect enum WorkflowStepKind: Sendable, Hashable {
    case tool(ToolStep)
    case agent(AgentStep)
    case condition(ConditionStep)
    case `switch`(SwitchStep)
    case foreach(ForeachStep)
    case parallel(ParallelStep)
    case loop(LoopStep)
    case approval(ApprovalStep)
    case delay(DelayStep)
    case set(SetStep)
    case transform(TransformStep)
    case verify(VerifyStep)
    case subworkflow(SubworkflowStep)
    case notify(NotifyStep)
    case fail(FailStep)
    case output(OutputStep)

    /// Kind name used in diagnostics, the graph and the schema.
    public var name: String {
        switch self {
        case .tool: return "tool"
        case .agent: return "agent"
        case .condition: return "condition"
        case .switch: return "switch"
        case .foreach: return "foreach"
        case .parallel: return "parallel"
        case .loop: return "loop"
        case .approval: return "approval"
        case .delay: return "delay"
        case .set: return "set"
        case .transform: return "transform"
        case .verify: return "verify"
        case .subworkflow: return "subworkflow"
        case .notify: return "notify"
        case .fail: return "fail"
        case .output: return "output"
        }
    }
}

public struct ToolStep: Sendable, Hashable {
    /// Canonical tool identifier, for example `filesystem.list`.
    public var tool: String
    /// The `with:` block. String values may contain `${{ … }}`.
    public var arguments: [String: JSONValue]
    public init(tool: String, arguments: [String: JSONValue] = [:]) { self.tool = tool; self.arguments = arguments }
}

public struct InlineAgent: Sendable, Hashable {
    public var instructions: String
    /// `provider/model`, for example `anthropic/claude-sonnet-4-5`. Nil uses the engine's default model.
    public var model: String?
    /// Tool identifiers or `family.*` patterns. Empty grants no tool.
    public var tools: [String]
    public init(instructions: String, model: String? = nil, tools: [String] = []) {
        self.instructions = instructions; self.model = model; self.tools = tools
    }
}

public enum AgentReference: Sendable, Hashable {
    /// A reusable agent profile, by name.
    case profile(String)
    case inline(InlineAgent)
}

public struct AgentStep: Sendable, Hashable {
    public var agent: AgentReference
    public var objective: String
    public var inputs: [String: JSONValue]
    /// Postconditions checked by the agent runtime. Only the four file assertions are allowed here.
    public var expect: [WorkflowAssertion]
    public init(agent: AgentReference, objective: String = "", inputs: [String: JSONValue] = [:], expect: [WorkflowAssertion] = []) {
        self.agent = agent; self.objective = objective; self.inputs = inputs; self.expect = expect
    }
}

public struct ConditionStep: Sendable, Hashable {
    public var condition: String
    /// Step ids of the same scope that run only when the condition is truthy.
    public var then: [String]
    /// Step ids of the same scope that run only when the condition is falsy.
    public var otherwise: [String]
    public init(condition: String, then: [String] = [], otherwise: [String] = []) {
        self.condition = condition; self.then = then; self.otherwise = otherwise
    }
}

public struct SwitchCase: Sendable, Hashable {
    public var value: JSONValue
    public var steps: [String]
    public init(value: JSONValue, steps: [String]) { self.value = value; self.steps = steps }
}

public struct SwitchStep: Sendable, Hashable {
    /// Expression whose value selects a case.
    public var on: String
    public var cases: [SwitchCase]
    /// Step ids that run when no case matches.
    public var defaultSteps: [String]
    public init(on: String, cases: [SwitchCase] = [], defaultSteps: [String] = []) { self.on = on; self.cases = cases; self.defaultSteps = defaultSteps }
}

public struct ForeachStep: Sendable, Hashable {
    /// An expression string yielding an array, or a literal array.
    public var items: JSONValue
    /// Name of the loop variable (`item` by default). `index` is always available.
    public var itemName: String
    public var concurrency: Int
    public var steps: [WorkflowStep]
    /// Body step whose output is collected per iteration. Nil collects an object of every body step output.
    public var collect: String?
    public init(items: JSONValue, itemName: String = "item", concurrency: Int = 1, steps: [WorkflowStep] = [], collect: String? = nil) {
        self.items = items; self.itemName = itemName; self.concurrency = concurrency; self.steps = steps; self.collect = collect
    }
}

public struct ParallelBranch: Sendable, Hashable {
    public var name: String
    public var steps: [WorkflowStep]
    public init(name: String, steps: [WorkflowStep] = []) { self.name = name; self.steps = steps }
}

public struct ParallelStep: Sendable, Hashable {
    public var branches: [ParallelBranch]
    public init(branches: [ParallelBranch] = []) { self.branches = branches }
}

public struct LoopStep: Sendable, Hashable {
    /// `while` expression, evaluated before every iteration.
    public var condition: String
    /// Mandatory upper bound (> 0).
    public var maxIterations: Int
    public var steps: [WorkflowStep]
    public init(condition: String, maxIterations: Int, steps: [WorkflowStep] = []) {
        self.condition = condition; self.maxIterations = maxIterations; self.steps = steps
    }
}

public struct ApprovalStep: Sendable, Hashable {
    public var message: String
    public init(message: String) { self.message = message }
}

public struct DelayStep: Sendable, Hashable {
    /// A number of seconds, or an expression string yielding one.
    public var seconds: JSONValue
    public init(seconds: JSONValue) { self.seconds = seconds }
}

public struct SetStep: Sendable, Hashable {
    public var values: [String: JSONValue]
    public init(values: [String: JSONValue]) { self.values = values }
}

public struct TransformStep: Sendable, Hashable {
    public var expression: String
    /// Optional variable that also receives the value.
    public var into: String?
    public init(expression: String, into: String? = nil) { self.expression = expression; self.into = into }
}

public enum WorkflowAssertion: Sendable, Hashable {
    case fileExists(path: String)
    case fileNonEmpty(path: String)
    case fileContains(path: String, text: String)
    case dirNonEmpty(path: String)
    case equals(JSONValue, JSONValue)
    case truthy(JSONValue)
    case stepSucceeded(String)

    public var kindName: String {
        switch self {
        case .fileExists: return "fileExists"
        case .fileNonEmpty: return "fileNonEmpty"
        case .fileContains: return "fileContains"
        case .dirNonEmpty: return "dirNonEmpty"
        case .equals: return "equals"
        case .truthy: return "truthy"
        case .stepSucceeded: return "stepSucceeded"
        }
    }

    public static let kindNames = ["fileExists", "fileNonEmpty", "fileContains", "dirNonEmpty", "equals", "truthy", "stepSucceeded"]
}

public struct VerifyStep: Sendable, Hashable {
    public var assertions: [WorkflowAssertion]
    public init(assertions: [WorkflowAssertion]) { self.assertions = assertions }
}

public struct SubworkflowStep: Sendable, Hashable {
    /// Workflow id or name, resolved by the caller-provided loader.
    public var workflow: String
    public var inputs: [String: JSONValue]
    public init(workflow: String, inputs: [String: JSONValue] = [:]) { self.workflow = workflow; self.inputs = inputs }
}

public struct NotifyStep: Sendable, Hashable {
    public var message: String
    public var title: String?
    public init(message: String, title: String? = nil) { self.message = message; self.title = title }
}

public struct FailStep: Sendable, Hashable {
    public var message: String
    public init(message: String) { self.message = message }
}

public struct OutputStep: Sendable, Hashable {
    public var values: [String: JSONValue]
    /// Paths of files to record as run artifacts.
    public var artifacts: [String]
    public init(values: [String: JSONValue] = [:], artifacts: [String] = []) { self.values = values; self.artifacts = artifacts }
}

// MARK: - Diagnostics

public struct WorkflowDiagnostic: Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Severity: String, Sendable, Codable { case error, warning, info }
    public var severity: Severity
    /// Stable machine-readable code, for example `unknown-tool`.
    public var code: String
    public var message: String
    /// 1-based; 0 when the diagnostic has no source position.
    public var line: Int
    public var column: Int
    public var stepID: String?
    /// Path in the document, for example `spec.steps[2].with.path`.
    public var path: String

    public init(severity: Severity = .error, code: String, message: String, line: Int = 0, column: Int = 0, stepID: String? = nil, path: String = "") {
        self.severity = severity; self.code = code; self.message = message; self.line = line; self.column = column
        self.stepID = stepID; self.path = path
    }

    public var description: String {
        var s = "\(severity.rawValue)"
        if line > 0 { s += " \(line):\(column)" }
        if let stepID { s += " [\(stepID)]" }
        s += " \(message)"
        if !path.isEmpty { s += " (\(path))" }
        return s
    }
}

/// Thrown by `WorkflowCodec.parse`. Carries every diagnostic found, the first one being the cause.
public struct WorkflowParseError: Error, Sendable, Hashable, LocalizedError {
    public var diagnostics: [WorkflowDiagnostic]
    public init(diagnostics: [WorkflowDiagnostic]) { self.diagnostics = diagnostics }
    public var errorDescription: String? { diagnostics.map(\.description).joined(separator: "\n") }
}
