// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Schema.swift
// Description      : JSON Schema of the canonical automation document, built
//                    from code with the keyword subset Core's JSONSchema
//                    enforces.
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

public enum WorkflowSchema {
    /// Container levels (foreach / parallel / while bodies) described in full under `spec.steps`. Steps nested deeper are
    /// accepted as any object. Without `$ref` every level is an inlined copy and each level doubles the size (a step can nest
    /// through `steps` and through `parallel[].steps`): 2 levels keep the published file near 250 kB, 4 levels would be 1.5 MB.
    public static let describedNestingDepth = 2
    /// Container levels described in full under `spec.onError`.
    public static let describedHandlerNestingDepth = 1

    /// Schema of the canonical document shape, i.e. what `WorkflowCodec.emit(_, format: .json)` writes.
    /// Shorthand forms accepted by the parser (`trigger`, `verifier`, `runtimes`, …) are not part of it.
    public static func automationV1() -> JSONSchema { JSONSchema(raw: root()) }

    /// The schema as pretty-printed JSON with sorted keys (the content of `Workflows/Schemas/automation.v1.schema.json`).
    public static func automationV1JSON() -> String { root().serialized(pretty: true) + "\n" }

    // MARK: Builders

    private static func str(_ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string"]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
    private static func strings(_ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "array", "items": str()]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
    private static func number(_ description: String? = nil, minimum: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "number"]
        if let description { o["description"] = .string(description) }
        if let minimum { o["minimum"] = .int(minimum) }
        return .object(o)
    }
    private static func integer(_ description: String? = nil, minimum: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "integer"]
        if let description { o["description"] = .string(description) }
        if let minimum { o["minimum"] = .int(minimum) }
        return .object(o)
    }
    private static func boolean(_ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "boolean"]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
    private static func any(_ description: String) -> JSONValue { ["description": .string(description)] }
    private static func freeObject(_ description: String) -> JSONValue { ["type": "object", "description": .string(description)] }
    private static func object(_ properties: [String: JSONValue], required: [String] = [], description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "type": "object", "properties": .object(properties), "additionalProperties": false,
        ]
        if !required.isEmpty { o["required"] = .array(required.sorted().map(JSONValue.string)) }
        if let description { o["description"] = .string(description) }
        return .object(o)
    }
    private static func array(_ items: JSONValue, _ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "array", "items": items]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    static let identifierPattern = "^[A-Za-z_][A-Za-z0-9_-]*$"

    private static func assertion() -> JSONValue {
        object([
            "fileExists": str("Path that must exist."),
            "fileNonEmpty": str("Path of a file that must exist and be larger than zero bytes."),
            "fileContains": str("Path of a file that must contain `text`."),
            "text": str("Text searched by fileContains."),
            "dirNonEmpty": str("Path of a directory that must contain at least one entry."),
            "equals": ["type": "array", "minItems": 2, "maxItems": 2, "description": "Two values that must be equal after interpolation."],
            "truthy": any("Expression (or value) that must be truthy."),
            "stepSucceeded": str("Id of an upstream step that must have succeeded."),
        ], description: "One assertion: exactly one of fileExists, fileNonEmpty, fileContains (+ text), dirNonEmpty, equals, truthy, stepSucceeded.")
    }

    private static func step(depth: Int) -> JSONValue {
        let nested: JSONValue = depth > 0
            ? array(step(depth: depth - 1), "Nested steps (their own `needs` namespace).")
            : array(["type": "object"], "Nested steps. At this depth the schema accepts any object; the ORIX validator still checks them.")
        return object([
            "id": ["type": "string", "pattern": .string(identifierPattern), "description": "Unique in the whole document, nested steps included."],
            "name": str("Display name."),
            "needs": strings("Ids of steps of the same list that must finish first."),
            "when": str("Expression; the step is skipped when it is falsy."),
            "tool": str("tool step: canonical tool identifier, for example filesystem.list."),
            "with": freeObject("tool step: arguments. Strings may contain ${{ … }}."),
            "agent": ["type": ["string", "object"], "description": "agent step: profile name, or inline {instructions, model?, tools?}.",
                      "properties": ["instructions": str(), "model": str("provider/model"), "tools": strings("Tool ids or family.* patterns.")],
                      "required": ["instructions"], "additionalProperties": false],
            "objective": str("agent step: what the agent must achieve."),
            "inputs": freeObject("agent / subworkflow step: input values."),
            "expect": array(assertion(), "agent step: file postconditions checked by the runtime."),
            "if": str("condition step: expression."),
            "then": strings("condition step: ids that run when the condition is truthy."),
            "else": strings("condition step: ids that run when the condition is falsy."),
            "switch": str("switch step: expression whose value selects a case."),
            "cases": array(object(["value": any("Value compared with the switch expression."), "steps": strings()], required: ["value", "steps"])),
            "default": strings("switch step: ids that run when no case matches."),
            "foreach": ["type": ["string", "array"], "description": "foreach step: expression yielding a list, or a literal list."],
            "as": str("foreach step: loop variable name (default item)."),
            "concurrency": integer("foreach step: iterations run at once (default 1).", minimum: 1),
            "collect": str("foreach step: body step whose output is collected per iteration."),
            "steps": nested,
            "parallel": array(object(["name": str("Branch name."), "steps": nested], required: ["name", "steps"]), "parallel step: branches, joined implicitly."),
            "while": str("loop step: expression evaluated before every iteration."),
            "maxIterations": integer("loop step: mandatory upper bound.", minimum: 1),
            "approval": str("approval step: message shown to the person."),
            "delay": ["type": ["number", "string"], "description": "delay step: seconds, or an expression yielding seconds."],
            "set": freeObject("set step: variables to assign."),
            "transform": str("transform step: expression whose value becomes the step output."),
            "into": str("transform step: variable that also receives the value."),
            "verify": array(assertion(), "verify step: assertions checked by the runtime."),
            "subworkflow": str("subworkflow step: id or name of the workflow to run."),
            "notify": str("notify step: message."),
            "title": str("notify step: title."),
            "fail": str("fail step: failure message."),
            "output": freeObject("output step: workflow outputs."),
            "artifacts": strings("output step: paths recorded as run artifacts."),
            "retry": object(["maxAttempts": integer(minimum: 1), "backoffSeconds": number(minimum: 0), "backoffMultiplier": number(minimum: 1),
                             "force": boolean("Retry even when the step is not idempotent.")], required: ["maxAttempts"]),
            "timeoutSeconds": number(),
            "continueOnError": boolean(),
            "onError": str("Id of a handler step of the same list."),
        ], required: ["id"], description: "A step. Exactly one kind key: tool, agent, if, switch, foreach, parallel, while, approval, delay, set, transform, verify, subworkflow, notify, fail, output.")
    }

    private static func root() -> JSONValue {
        let trigger = object([
            "type": ["type": "string", "enum": ["manual", "schedule", "once", "interval", "fileChange", "login", "appLaunch"]],
            "cron": str("schedule: five-field cron expression."), "timezone": str("schedule: IANA time zone."),
            "at": str("once: ISO 8601 date-time."), "seconds": number("interval: period in seconds."),
            "path": str("fileChange: watched path."), "glob": str("fileChange: file name pattern."),
            "debounceSeconds": number("fileChange: quiet period before the run starts.", minimum: 0),
            "bundleID": str("appLaunch: bundle identifier."),
        ], required: ["type"])
        let parameter = object([
            "name": ["type": "string", "pattern": "^[A-Za-z_][A-Za-z0-9_]*$"],
            "type": ["type": "string", "enum": .array(WorkflowParameterType.allCases.map { .string($0.rawValue) })],
            "default": any("Default value."), "description": str(), "required": boolean(),
        ], required: ["name", "type"])
        let permissions = object([
            "filesystem": object(["read": strings(), "write": strings(), "delete": strings()],
                                 description: "Absolute or ~/ paths; entries may use ${{ params.<name> }}."),
            "processes": strings("Executables the workflow may run."),
            "scripts": strings("Script runtimes: bash, python, swift, javascript, applescript, jxa."),
            "apps": object(["automation": strings(), "accessibility": strings(), "control": strings()], description: "Bundle identifiers."),
            "network": strings("Hosts for outbound requests."),
            "browser": strings("Hosts the browser tools may open."),
            "secrets": strings("Keychain secret reference names."),
            "clipboard": object(["read": boolean(), "write": boolean()]),
            "notifications": boolean(),
            "screen": strings("Capture scopes: display, window:<bundleID>, region."),
        ])
        let budget = object([
            "maxDurationSeconds": number(), "maxProviderCostUSD": number(minimum: 0),
            "maxToolCalls": integer(minimum: 1), "maxTokens": integer(minimum: 1),
        ])
        let position = object(["x": number(), "y": number()], required: ["x", "y"])
        let steps = array(step(depth: describedNestingDepth))
        let spec = object([
            "triggers": array(trigger), "parameters": array(parameter), "permissions": permissions, "budget": budget,
            "variables": freeObject("Initial variables."), "steps": steps,
            "onError": array(step(depth: describedHandlerNestingDepth), "Handler steps run when the workflow fails."),
            "layout": ["type": "object", "additionalProperties": position, "description": "Visual editor node positions keyed by step id."],
        ], required: ["steps"])
        return [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "https://orix.ai/schemas/automation.v1.schema.json",
            "title": "ORIX OS Automation workflow (orix.ai/v1)",
            "description": .string("Canonical form of an ORIX automation document, as written by the code view. Uses only type, properties, required, additionalProperties, items, enum, pattern and numeric/length bounds. Without $ref, nested steps are described in full for \(describedNestingDepth) container levels under spec.steps (\(describedHandlerNestingDepth) under spec.onError) and accepted as any object beyond; cross-field rules (exactly one step kind, DAG of needs, expressions, permissions) are enforced by the ORIX validator, not by this schema."),
            "type": "object",
            "properties": [
                "apiVersion": ["type": "string", "enum": [.string(WorkflowDocument.currentAPIVersion)]],
                "kind": ["type": "string", "enum": [.string(WorkflowDocument.automationKind)]],
                "metadata": object(["id": ["type": "string", "pattern": .string(identifierPattern)], "name": ["type": "string", "minLength": 1],
                                    "description": str(), "tags": strings()], required: ["id", "name"]),
                "spec": spec,
            ],
            "required": ["apiVersion", "kind", "metadata", "spec"],
            "additionalProperties": false,
        ]
    }
}
