// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/DocumentEncoder.swift
// Description      : Canonical emission of the workflow IR: ordered tree
//                    construction, then deterministic YAML and JSON writers
//                    with minimal quoting.
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

/// Ordered emission tree. `flow` asks for the one-line form when every child is a scalar and the line stays short.
indirect enum ENode {
    case scalar(JSONValue)
    case seq([ENode], flow: Bool)
    case map([(String, ENode)], flow: Bool)

    static func string(_ s: String) -> ENode { .scalar(.string(s)) }
    static func strings(_ a: [String]) -> ENode { .seq(a.map { .scalar(.string($0)) }, flow: true) }

    /// Typed doubles are written as integers when integral, so `timeoutSeconds: 30` stays readable.
    static func number(_ d: Double) -> ENode {
        if d.rounded() == d, abs(d) < 1e15 { return .scalar(.int(Int(d))) }
        return .scalar(.number(d))
    }

    static func json(_ v: JSONValue) -> ENode {
        switch v {
        case .array(let a): return .seq(a.map(ENode.json), flow: true)
        case .object(let o): return .map(o.keys.sorted().map { ($0, ENode.json(o[$0]!)) }, flow: false)
        default: return .scalar(v)
        }
    }

    static func object(_ o: [String: JSONValue]) -> ENode { .json(.object(o)) }

    var jsonValue: JSONValue {
        switch self {
        case .scalar(let v): return v
        case .seq(let items, _): return .array(items.map(\.jsonValue))
        case .map(let entries, _): return .object(Dictionary(entries.map { ($0.0, $0.1.jsonValue) }, uniquingKeysWith: { _, l in l }))
        }
    }
}

enum DocumentEncoder {
    static func encode(_ doc: WorkflowDocument) -> ENode {
        var meta: [(String, ENode)] = [("id", .string(doc.metadata.id)), ("name", .string(doc.metadata.name))]
        if !doc.metadata.description.isEmpty { meta.append(("description", .string(doc.metadata.description))) }
        if !doc.metadata.tags.isEmpty { meta.append(("tags", .strings(doc.metadata.tags))) }
        return .map([
            ("apiVersion", .string(doc.apiVersion)),
            ("kind", .string(doc.kind)),
            ("metadata", .map(meta, flow: false)),
            ("spec", encode(doc.spec)),
        ], flow: false)
    }

    static func encode(_ spec: WorkflowSpec) -> ENode {
        var out: [(String, ENode)] = []
        if !spec.triggers.isEmpty { out.append(("triggers", .seq(spec.triggers.map(encode), flow: false))) }
        if !spec.parameters.isEmpty {
            out.append(("parameters", .seq(spec.parameters.map { p in
                var e: [(String, ENode)] = [("name", .string(p.name)), ("type", .string(p.type.rawValue))]
                if let d = p.defaultValue { e.append(("default", .json(d))) }
                if !p.description.isEmpty { e.append(("description", .string(p.description))) }
                if p.required { e.append(("required", .scalar(.bool(true)))) }
                return .map(e, flow: false)
            }, flow: false)))
        }
        if !spec.permissions.isEmpty { out.append(("permissions", encode(spec.permissions))) }
        if !spec.budget.isEmpty {
            var b: [(String, ENode)] = []
            if let v = spec.budget.maxDurationSeconds { b.append(("maxDurationSeconds", .number(v))) }
            if let v = spec.budget.maxProviderCostUSD { b.append(("maxProviderCostUSD", .number(v))) }
            if let v = spec.budget.maxToolCalls { b.append(("maxToolCalls", .scalar(.int(v)))) }
            if let v = spec.budget.maxTokens { b.append(("maxTokens", .scalar(.int(v)))) }
            out.append(("budget", .map(b, flow: false)))
        }
        if !spec.variables.isEmpty { out.append(("variables", .object(spec.variables))) }
        out.append(("steps", .seq(spec.steps.map(encode), flow: false)))
        if !spec.onError.isEmpty { out.append(("onError", .seq(spec.onError.map(encode), flow: false))) }
        if !spec.layout.isEmpty {
            out.append(("layout", .map(spec.layout.keys.sorted().map { k in
                let p = spec.layout[k]!
                return (k, .map([("x", .number(p.x)), ("y", .number(p.y))], flow: true))
            }, flow: false)))
        }
        return .map(out, flow: false)
    }

    static func encode(_ t: WorkflowTrigger) -> ENode {
        var e: [(String, ENode)] = [("type", .string(t.typeName))]
        switch t {
        case .manual, .login: break
        case .schedule(let cron, let tz):
            e.append(("cron", .string(cron)))
            if let tz { e.append(("timezone", .string(tz))) }
        case .once(let at): e.append(("at", .string(at)))
        case .interval(let s): e.append(("seconds", .number(s)))
        case .fileChange(let path, let glob, let debounce):
            e.append(("path", .string(path)))
            if let glob { e.append(("glob", .string(glob))) }
            if let debounce { e.append(("debounceSeconds", .number(debounce))) }
        case .appLaunch(let b): e.append(("bundleID", .string(b)))
        }
        return .map(e, flow: false)
    }

    static func encode(_ p: WorkflowPermissions) -> ENode {
        var out: [(String, ENode)] = []
        if !p.filesystem.isEmpty {
            var fs: [(String, ENode)] = []
            if !p.filesystem.read.isEmpty { fs.append(("read", .strings(p.filesystem.read))) }
            if !p.filesystem.write.isEmpty { fs.append(("write", .strings(p.filesystem.write))) }
            if !p.filesystem.delete.isEmpty { fs.append(("delete", .strings(p.filesystem.delete))) }
            out.append(("filesystem", .map(fs, flow: false)))
        }
        if !p.processes.isEmpty { out.append(("processes", .strings(p.processes))) }
        if !p.scripts.isEmpty { out.append(("scripts", .strings(p.scripts))) }
        if !p.apps.isEmpty {
            var a: [(String, ENode)] = []
            if !p.apps.automation.isEmpty { a.append(("automation", .strings(p.apps.automation))) }
            if !p.apps.accessibility.isEmpty { a.append(("accessibility", .strings(p.apps.accessibility))) }
            if !p.apps.control.isEmpty { a.append(("control", .strings(p.apps.control))) }
            out.append(("apps", .map(a, flow: false)))
        }
        if !p.network.isEmpty { out.append(("network", .strings(p.network))) }
        if !p.browser.isEmpty { out.append(("browser", .strings(p.browser))) }
        if !p.secrets.isEmpty { out.append(("secrets", .strings(p.secrets))) }
        if p.clipboard.read || p.clipboard.write {
            var c: [(String, ENode)] = []
            if p.clipboard.read { c.append(("read", .scalar(.bool(true)))) }
            if p.clipboard.write { c.append(("write", .scalar(.bool(true)))) }
            out.append(("clipboard", .map(c, flow: true)))
        }
        if p.notifications { out.append(("notifications", .scalar(.bool(true)))) }
        if !p.screen.isEmpty { out.append(("screen", .strings(p.screen))) }
        return .map(out, flow: false)
    }

    static func encode(_ s: WorkflowStep) -> ENode {
        var e: [(String, ENode)] = [("id", .string(s.id))]
        if let n = s.name { e.append(("name", .string(n))) }
        if !s.needs.isEmpty { e.append(("needs", .strings(s.needs))) }
        if let w = s.when { e.append(("when", .string(w))) }
        func steps(_ list: [WorkflowStep]) -> ENode { .seq(list.map(encode), flow: false) }
        switch s.kind {
        case .tool(let t):
            e.append(("tool", .string(t.tool)))
            if !t.arguments.isEmpty { e.append(("with", .object(t.arguments))) }
        case .agent(let a):
            switch a.agent {
            case .profile(let p): e.append(("agent", .string(p)))
            case .inline(let i):
                var m: [(String, ENode)] = [("instructions", .string(i.instructions))]
                if let model = i.model { m.append(("model", .string(model))) }
                if !i.tools.isEmpty { m.append(("tools", .strings(i.tools))) }
                e.append(("agent", .map(m, flow: false)))
            }
            if !a.objective.isEmpty { e.append(("objective", .string(a.objective))) }
            if !a.inputs.isEmpty { e.append(("inputs", .object(a.inputs))) }
            if !a.expect.isEmpty { e.append(("expect", .seq(a.expect.map(encode), flow: false))) }
        case .condition(let c):
            e.append(("if", .string(c.condition)))
            if !c.then.isEmpty { e.append(("then", .strings(c.then))) }
            if !c.otherwise.isEmpty { e.append(("else", .strings(c.otherwise))) }
        case .switch(let sw):
            e.append(("switch", .string(sw.on)))
            if !sw.cases.isEmpty {
                e.append(("cases", .seq(sw.cases.map { .map([("value", .json($0.value)), ("steps", .strings($0.steps))], flow: false) }, flow: false)))
            }
            if !sw.defaultSteps.isEmpty { e.append(("default", .strings(sw.defaultSteps))) }
        case .foreach(let fe):
            e.append(("foreach", .json(fe.items)))
            if fe.itemName != "item" { e.append(("as", .string(fe.itemName))) }
            if fe.concurrency != 1 { e.append(("concurrency", .scalar(.int(fe.concurrency)))) }
            if let c = fe.collect { e.append(("collect", .string(c))) }
            e.append(("steps", steps(fe.steps)))
        case .parallel(let p):
            e.append(("parallel", .seq(p.branches.map { .map([("name", .string($0.name)), ("steps", steps($0.steps))], flow: false) }, flow: false)))
        case .loop(let l):
            e.append(("while", .string(l.condition)))
            e.append(("maxIterations", .scalar(.int(l.maxIterations))))
            e.append(("steps", steps(l.steps)))
        case .approval(let a): e.append(("approval", .string(a.message)))
        case .delay(let d): e.append(("delay", .json(d.seconds)))
        case .set(let st): e.append(("set", .object(st.values)))
        case .transform(let t):
            e.append(("transform", .string(t.expression)))
            if let into = t.into { e.append(("into", .string(into))) }
        case .verify(let v): e.append(("verify", .seq(v.assertions.map(encode), flow: false)))
        case .subworkflow(let sw):
            e.append(("subworkflow", .string(sw.workflow)))
            if !sw.inputs.isEmpty { e.append(("inputs", .object(sw.inputs))) }
        case .notify(let n):
            e.append(("notify", .string(n.message)))
            if let t = n.title { e.append(("title", .string(t))) }
        case .fail(let f): e.append(("fail", .string(f.message)))
        case .output(let o):
            e.append(("output", .object(o.values)))
            if !o.artifacts.isEmpty { e.append(("artifacts", .strings(o.artifacts))) }
        }
        if let r = s.retry {
            var m: [(String, ENode)] = [("maxAttempts", .scalar(.int(r.maxAttempts)))]
            if r.backoffSeconds != 0 { m.append(("backoffSeconds", .number(r.backoffSeconds))) }
            if r.backoffMultiplier != 1 { m.append(("backoffMultiplier", .number(r.backoffMultiplier))) }
            if r.force { m.append(("force", .scalar(.bool(true)))) }
            e.append(("retry", .map(m, flow: true)))
        }
        if let t = s.timeoutSeconds { e.append(("timeoutSeconds", .number(t))) }
        if s.continueOnError { e.append(("continueOnError", .scalar(.bool(true)))) }
        if let h = s.onError { e.append(("onError", .string(h))) }
        return .map(e, flow: false)
    }

    static func encode(_ a: WorkflowAssertion) -> ENode {
        switch a {
        case .fileExists(let p): return .map([("fileExists", .string(p))], flow: false)
        case .fileNonEmpty(let p): return .map([("fileNonEmpty", .string(p))], flow: false)
        case .dirNonEmpty(let p): return .map([("dirNonEmpty", .string(p))], flow: false)
        case .fileContains(let p, let t): return .map([("fileContains", .string(p)), ("text", .string(t))], flow: false)
        case .equals(let l, let r): return .map([("equals", .seq([.json(l), .json(r)], flow: true))], flow: false)
        case .truthy(let v): return .map([("truthy", .json(v))], flow: false)
        case .stepSucceeded(let s): return .map([("stepSucceeded", .string(s))], flow: false)
        }
    }
}

// MARK: - Text writers

enum ScalarText {
    static func double(_ d: Double, json: Bool) -> String {
        if d.isNaN { return json ? "null" : ".nan" }
        if d.isInfinite { return json ? "null" : (d < 0 ? "-.inf" : ".inf") }
        return "\(d)"
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if needsEscape(u) { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func needsEscape(_ u: Unicode.Scalar) -> Bool {
        u.value < 0x20 || (u.value >= 0x7F && u.value <= 0xA0) || u.value == 0x2028 || u.value == 0x2029 || u.value == 0xFEFF
    }

    /// True when `s` can be written without quotes and read back as the same string.
    static func isPlainSafe(_ s: String, flow: Bool, key: Bool = false) -> Bool {
        let u = Array(s.unicodeScalars)
        guard let first = u.first, let last = u.last else { return false }
        if first == " " || last == " " { return false }
        if "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(first) { return false }
        for (i, c) in u.enumerated() {
            if needsEscape(c) { return false }
            if c == ":" && (flow || i + 1 == u.count || u[i + 1] == " ") { return false }
            if c == "#" && i > 0 && u[i - 1] == " " { return false }
            if flow, c == "," || c == "[" || c == "]" || c == "{" || c == "}" { return false }
        }
        if key { return true }
        if case .string = YAMLScalar.resolvePlain(s) { return true }
        return false
    }

    static func yaml(_ v: JSONValue, flow: Bool) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return "\(i)"
        case .number(let d): return double(d, json: false)
        case .string(let s): return isPlainSafe(s, flow: flow) ? s : quoted(s)
        case .array, .object: return v.serialized()
        }
    }

    static func key(_ k: String) -> String { isPlainSafe(k, flow: true, key: true) ? k : quoted(k) }

    /// Multi-line text that can be written as a literal block scalar and read back exactly.
    static func isLiteralEligible(_ s: String) -> Bool {
        guard s.contains("\n"), !s.hasSuffix("\n\n") else { return false }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, !first.isEmpty, !first.hasPrefix(" ") else { return false }
        for line in lines {
            if line.hasSuffix(" ") { return false }
            if line.unicodeScalars.contains(where: needsEscape) { return false }
        }
        return true
    }
}

struct YAMLWriter {
    private var lines: [String] = []
    private static let flowWidth = 80

    static func write(_ root: ENode) -> String {
        var w = YAMLWriter()
        switch root {
        case .map(let entries, _) where !entries.isEmpty: w.writeMap(entries, indent: 0)
        case .seq(let items, _) where !items.isEmpty: w.writeSeq(items, indent: 0)
        default: w.lines.append(flowText(root, limit: .max) ?? "null")
        }
        return w.lines.joined(separator: "\n") + "\n"
    }

    private static func flowText(_ node: ENode, limit: Int = flowWidth) -> String? {
        func scalar(_ n: ENode) -> String? {
            guard case .scalar(let v) = n else { return nil }
            if case .string(let s) = v, s.contains("\n") { return nil }
            return ScalarText.yaml(v, flow: true)
        }
        var text: String
        switch node {
        case .scalar(let v): return ScalarText.yaml(v, flow: false)
        case .seq(let items, let flow):
            if items.isEmpty { return "[]" }
            guard flow else { return nil }
            var parts: [String] = []
            for i in items { guard let t = scalar(i) else { return nil }; parts.append(t) }
            text = "[" + parts.joined(separator: ", ") + "]"
        case .map(let entries, let flow):
            if entries.isEmpty { return "{}" }
            guard flow else { return nil }
            var parts: [String] = []
            for (k, v) in entries { guard let t = scalar(v) else { return nil }; parts.append("\(ScalarText.key(k)): \(t)") }
            text = "{" + parts.joined(separator: ", ") + "}"
        }
        return text.count <= limit ? text : nil
    }

    /// Writes `head` followed by the node: inline when possible, as a literal block, or as nested lines.
    private mutating func writeValue(_ node: ENode, head: String, indent: Int, separator: String) {
        let pad = String(repeating: " ", count: indent + 2)
        if case .scalar(.string(let s)) = node, ScalarText.isLiteralEligible(s) {
            lines.append(head + separator + (s.hasSuffix("\n") ? "|" : "|-"))
            let body = s.hasSuffix("\n") ? String(s.dropLast()) : s
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) { lines.append(line.isEmpty ? "" : pad + line) }
            return
        }
        if let text = Self.flowText(node) {
            lines.append(head + separator + text)
            return
        }
        if separator == " " {
            // Sequence item: write the nested block two columns in, then put the dash on its first line.
            let start = lines.count
            switch node {
            case .map(let entries, _): writeMap(entries, indent: indent + 2)
            case .seq(let items, _): writeSeq(items, indent: indent + 2)
            case .scalar: break
            }
            lines[start] = head + " " + lines[start].dropFirst(indent + 2)
        } else {
            lines.append(head + ":")
            switch node {
            case .map(let entries, _): writeMap(entries, indent: indent + 2)
            case .seq(let items, _): writeSeq(items, indent: indent + 2)
            case .scalar: break
            }
        }
    }

    private mutating func writeMap(_ entries: [(String, ENode)], indent: Int) {
        let pad = String(repeating: " ", count: indent)
        for (k, v) in entries { writeValue(v, head: pad + ScalarText.key(k), indent: indent, separator: ": ") }
    }

    private mutating func writeSeq(_ items: [ENode], indent: Int) {
        let pad = String(repeating: " ", count: indent)
        for item in items { writeValue(item, head: pad + "-", indent: indent, separator: " ") }
    }
}

enum JSONWriter {
    static func write(_ root: ENode) -> String {
        var out = ""
        write(root, indent: 0, into: &out)
        return out + "\n"
    }

    private static func write(_ node: ENode, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent + 1)
        let close = String(repeating: "  ", count: indent)
        switch node {
        case .scalar(let v):
            switch v {
            case .null: out += "null"
            case .bool(let b): out += b ? "true" : "false"
            case .int(let i): out += "\(i)"
            case .number(let d): out += ScalarText.double(d, json: true)
            case .string(let s): out += ScalarText.quoted(s)
            case .array, .object: out += v.serialized()
            }
        case .seq(let items, _):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += pad
                write(item, indent: indent + 1, into: &out)
                out += i + 1 < items.count ? ",\n" : "\n"
            }
            out += close + "]"
        case .map(let entries, _):
            if entries.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, (k, v)) in entries.enumerated() {
                out += pad + ScalarText.quoted(k) + ": "
                write(v, indent: indent + 1, into: &out)
                out += i + 1 < entries.count ? ",\n" : "\n"
            }
            out += close + "}"
        }
    }
}
