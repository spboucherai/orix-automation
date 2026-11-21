// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/ScriptTools.swift
// Description      : applescript.run and jxa.run: statically checked targets,
//                    out-of-process execution through /usr/bin/osascript,
//                    structured results and Apple Events error mapping.
// Module           : ORIXAppleAutomation
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

/// Runs AppleScript or JXA source through `/usr/bin/osascript`, script on stdin, never in-process.
public struct ScriptRunTool: ORIXTool {
    public let language: ScriptLanguage

    public init(language: ScriptLanguage) { self.language = language }

    public var manifest: ToolManifest {
        let id = language == .applescript ? "applescript.run" : "jxa.run"
        let example: JSONValue = language == .applescript
            ? ["script": "tell application \"Finder\" to get name of startup disk", "targets": ["com.apple.finder"]]
            : ["script": "Application(\"Finder\").startupDisk.name()", "targets": ["com.apple.finder"]]
        return ToolManifest(
            identifier: id,
            name: language == .applescript ? "Run AppleScript" : "Run JavaScript for Automation",
            summary: "Runs \(language.displayName) source out of process and returns its result. Every application the script addresses must be listed in targets (bundle identifiers); a script with no target only computes. Shell, Objective-C bridge and file access from the script need the bash runtime grant.",
            family: "applescript",
            inputSchema: .object([
                "script": .string("The \(language.displayName) source text."),
                "targets": .array(of: bundleIDSchema, "Bundle identifiers of every application the script talks to. Empty for pure computation."),
                "timeoutSeconds": .number("Maximum run time in seconds (default 30)."),
            ], required: ["script"]),
            outputSchema: outputObject([
                "result": .string("Result as text: AppleScript source form, or the display string for JXA."),
                "value": .any,
                "parsed": .boolean("True when value is a structured rendering of the result."),
                "stderr": .string(), "language": .string(), "targets": .array(of: .string()),
            ], required: ["result", "parsed", "language", "targets"]),
            sideEffect: .external, defaultTier: .consequential, macPermissions: [.appleEvents],
            defaultTimeoutSeconds: 120, concurrency: .serial, supportsDryRun: true, idempotent: false,
            outputIsUntrusted: true, examples: [example])
    }

    struct Plan {
        var script: String
        var scan: ScriptScan
        var targets: [String]
        var requirements: ToolRequirements
    }

    func plan(_ input: ToolInput) throws -> Plan {
        let script = try input.nonEmptyString("script")
        guard script.utf8.count <= 1_000_000 else { throw ToolError.invalidInput("script is larger than 1 MB") }
        let scan = ScriptTargetScanner.scan(script, language: language)
        let targets = try ScriptTargetScanner.verifiedTargets(scan, declared: input.strings("targets"))
        var capabilities: [Capability] = [.scriptRuntime(name: language.rawValue)]
        capabilities += targets.map { .appAutomation(bundleID: $0) }
        if scan.needsShellRuntime { capabilities.append(.scriptRuntime(name: "bash")) }
        if scan.readsClipboard { capabilities.append(.clipboardRead) }
        if scan.writesClipboard { capabilities.append(.clipboardWrite) }
        let consequential = !targets.isEmpty || scan.needsShellRuntime || scan.opensLocation
        let lines = script.split(separator: "\n", omittingEmptySubsequences: true).count
        var summary = "Run a \(lines)-line \(language.displayName) script that "
        summary += targets.isEmpty ? "addresses no application" : "controls " + targets.map(AppResolver.displayName).joined(separator: ", ")
        if scan.needsShellRuntime { summary += " and can run shell commands or native code" }
        if scan.opensLocation { summary += " and opens a URL" }
        return Plan(script: script, scan: scan, targets: targets,
                    requirements: ToolRequirements(capabilities: capabilities, tier: consequential ? .consequential : .reversibleWrite, summary: summary))
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        try plan(input).requirements
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let plan = try plan(input)
        if input.dryRun {
            return .simulated(["language": .string(language.rawValue), "targets": .array(plan.targets.map(JSONValue.string)),
                               "wouldRun": true, "usesShell": .bool(plan.scan.needsShellRuntime)],
                              summary: "Would: " + plan.requirements.summary)
        }
        // Consent already refused: say so without running anything. An undetermined consent lets macOS show its own prompt.
        for target in plan.targets where MacPermissions.automationStatus(bundleID: target) == .denied {
            throw ToolError.tccBlocked(.appleEvents, "macOS does not allow this app to send Apple Events to \(AppResolver.displayName(target)) (\(target)).")
        }
        let timeout = input.timeout(default: 30, context: context)
        let started = Date()
        let run: SubprocessOutput
        switch language {
        case .applescript:
            run = try await Subprocess.run("/usr/bin/osascript", ["-ss"], stdin: Data(plan.script.utf8), timeout: timeout)
        case .jxa:
            run = try await Subprocess.run("/usr/bin/osascript", ["-l", "JavaScript"], stdin: Data(Self.jxaWrapper(plan.script).utf8), timeout: timeout)
        }
        if run.timedOut { throw ToolError.timeout(seconds: timeout) }
        let stdout = String(decoding: run.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let stderr = String(decoding: run.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        return try await catchingTypedFailures {
            var value: JSONValue = .null
            var parsed = false
            var text = stdout
            switch language {
            case .applescript:
                if run.exitCode != 0 { throw failure(ScriptError.parseOsascript(stderr, script: plan.script), targets: plan.targets, stderr: stderr) }
                if let v = AppleScriptValueParser.parse(stdout) { value = v; parsed = true }
            case .jxa:
                guard run.exitCode == 0, let envelope = try? JSONValue.parse(stdout), let ok = envelope["ok"]?.boolValue else {
                    throw failure(ScriptError.parseOsascript(stderr.isEmpty ? stdout : stderr, script: plan.script), targets: plan.targets, stderr: stderr)
                }
                if !ok {
                    var e = ScriptError.fromJXA(envelope)
                    if e.isSyntax { e = await Self.jxaCompileError(plan.script, fallback: e) }
                    throw failure(e, targets: plan.targets, stderr: stderr)
                }
                value = envelope["value"] ?? .null
                parsed = envelope["serializable"]?.boolValue ?? false
                text = envelope["display"]?.stringValue ?? value.displayString
            }
            let (cut, truncated) = text.truncated(maxBytes: 200_000)
            if truncated { value = .null; parsed = false }
            var result = ToolResult.success([
                "result": .string(cut), "value": value, "parsed": .bool(parsed), "stderr": .string(String(stderr.prefix(4000))),
                "language": .string(language.rawValue), "targets": .array(plan.targets.map(JSONValue.string)), "elapsedMs": .int(elapsed),
            ], summary: "\(language.displayName) finished in \(elapsed) ms" + (cut.isEmpty ? " with no result" : ": \(cut.prefix(120))"))
            result.truncated = truncated || run.truncated
            result.untrusted = true
            return result
        }
    }

    /// Maps a script error to the typed outcome: TCC block, application not running, syntax error, or a plain script error.
    private func failure(_ e: ScriptError, targets: [String], stderr: String) -> Error {
        let names = targets.map { "\(AppResolver.displayName($0)) (\($0))" }.joined(separator: ", ")
        switch e.number {
        case -1743, -1744:
            let whom = targets.isEmpty ? "the application it addresses" : names
            return ToolError.tccBlocked(.appleEvents, "macOS blocked Apple Events from this app to \(whom)" + (e.number == -1744 ? " (user consent is required)." : ".") + " \(e.message)")
        case -600, -609, -10810, -10827:
            return TypedFailure(code: "app_not_running", message: "The target application is not running or could not be reached\(targets.isEmpty ? "" : " (\(names))"): \(e.message)",
                                recovery: "Launch it with system.launchApp, then call again.", retryable: true, output: e.json)
        default:
            if e.isSyntax {
                let place = e.line.map { " at line \($0)" + (e.column.map { ", column \($0)" } ?? "") } ?? ""
                return TypedFailure(code: "syntax_error", message: "Syntax error\(place): \(e.message)", recovery: "Fix the script and call again.", output: e.json)
            }
            return TypedFailure(code: "script_error", message: "Script error\(e.number.map { " \($0)" } ?? "")\(e.line.map { " at line \($0)" } ?? ""): \(e.message)", output: e.json)
        }
    }

    /// JavaScriptCore reports a SyntaxError raised by `eval` at the eval call, not inside the source. Compiling the script
    /// alone (osacompile never runs it) gives the real line; a SyntaxError thrown at run time (JSON.parse …) compiles fine
    /// and is then an ordinary script error.
    static func jxaCompileError(_ script: String, fallback: ScriptError) async -> ScriptError {
        let out = NSTemporaryDirectory() + "orix-jxa-check-\(UUID().uuidString).scpt"
        defer { try? FileManager.default.removeItem(atPath: out) }
        guard let run = try? await Subprocess.run("/usr/bin/osacompile", ["-l", "JavaScript", "-o", out], stdin: Data(script.utf8), timeout: 10) else { return fallback }
        var e = fallback
        if run.exitCode == 0 { e.isSyntax = false; e.line = nil; e.column = nil; return e }
        let text = String(decoding: run.stderr, as: UTF8.self)
        e.column = nil
        e.line = regexGroups(#"Error on line (\d+)"#, in: text, options: []).first.flatMap { $0[1].flatMap { Int($0) } }
        return e
    }

    /// Wraps user JXA so the result (or the error, with line and Apple Event number) comes back as one JSON envelope.
    static func jxaWrapper(_ script: String) -> String {
        let literal = JSONValue.string(script).serialized()
        return """
        (function () {
          var __src = \(literal);
          var __out;
          try {
            var __r = (0, eval)(__src);
            if (typeof run === 'function') {
              var __run = run;
              // osascript calls a global run() itself after the script: take it away so the envelope stays the result.
              try { delete globalThis.run; } catch (e) {}
              if (typeof globalThis.run === 'function') { globalThis.run = undefined; }
              __r = __run([]);
            }
            var __json;
            try { __json = JSON.stringify(__r); } catch (e) { __json = undefined; }
            var __disp;
            try { __disp = (typeof __r === 'string') ? __r : Automation.getDisplayString(__r); } catch (e) { __disp = String(__r); }
            if (__disp === undefined || __disp === null) { __disp = ''; }
            __out = '{"ok":true,"value":' + (__json === undefined ? 'null' : __json) + ',"serializable":' + (__json !== undefined) +
              ',"display":' + JSON.stringify(String(__disp)) + ',"type":' + JSON.stringify(typeof __r) + '}';
          } catch (e) {
            var __n = null;
            try { if (typeof e.errorNumber === 'number') { __n = e.errorNumber; } } catch (x) {}
            __out = JSON.stringify({ ok: false, name: String(e && e.name), message: String(e && e.message),
              line: (e && typeof e.line === 'number') ? e.line : null, column: (e && typeof e.column === 'number') ? e.column : null, errorNumber: __n });
          }
          return __out;
        })()
        """
    }
}

/// A script failure reduced to what the tools need. Numbers are Apple Event / OSA error codes, never localized text.
struct ScriptError {
    var message: String
    var number: Int?
    var line: Int?
    var column: Int?
    var isSyntax: Bool

    var json: JSONValue {
        ["message": .string(message), "errorNumber": number.map(JSONValue.int) ?? .null, "line": line.map(JSONValue.int) ?? .null,
         "column": column.map(JSONValue.int) ?? .null, "syntax": .bool(isSyntax)]
    }

    /// Parses osascript's stderr: `39:40: syntax error: … (-2741)` / `6:12: execution error: … (42)`. Offsets are characters.
    static func parseOsascript(_ stderr: String, script: String) -> ScriptError {
        let line = stderr.split(separator: "\n").last(where: { $0.contains("error") }).map(String.init) ?? stderr
        var e = ScriptError(message: line, number: nil, line: nil, column: nil, isSyntax: false)
        if let g = regexGroups(#"\((-?\d+)\)\s*$"#, in: line).first, let n = g[1].flatMap({ Int($0) }) { e.number = n }
        if let g = regexGroups(#"^(?:.*?:)?(\d+):(\d+):\s*(syntax|execution|script) error:\s*(.*?)(?:\s*\(-?\d+\))?\s*$"#, in: line, options: [.dotMatchesLineSeparators]).first {
            e.isSyntax = g[3] == "syntax"
            e.message = g[4] ?? line
            if let offset = g[1].flatMap({ Int($0) }) {
                let (l, c) = position(ofCharacter: offset, in: script)
                e.line = l; e.column = c
            }
        }
        if e.number == -2741 || e.number == -2740 { e.isSyntax = true }
        if let g = regexGroups(#"Error on line (\d+)"#, in: line, options: []).first, let l = g[1].flatMap({ Int($0) }) { e.line = l; e.column = nil }
        return e
    }

    static func fromJXA(_ envelope: JSONValue) -> ScriptError {
        let message = envelope["message"]?.stringValue ?? "unknown error"
        let name = envelope["name"]?.stringValue ?? "Error"
        var number = envelope["errorNumber"]?.intValue
        if number == nil, let g = regexGroups(#"\((-\d+)\)\s*$"#, in: message).first { number = g[1].flatMap { Int($0) } }
        return ScriptError(message: name == "Error" ? message : "\(name): \(message)", number: number, line: envelope["line"]?.intValue,
                           column: envelope["column"]?.intValue, isSyntax: name == "SyntaxError")
    }

    /// 1-based line and column of a UTF-16 offset.
    static func position(ofCharacter offset: Int, in script: String) -> (Int, Int) {
        var line = 1, column = 1
        for (i, unit) in script.utf16.enumerated() {
            if i >= offset { break }
            if unit == 10 { line += 1; column = 1 } else { column += 1 }
        }
        return (line, column)
    }
}

/// Parses the AppleScript source form of simple results (numbers, text, booleans, lists, records, missing value) into JSON.
/// Anything else (dates, object specifiers, raw data) is left as text: `parse` returns nil.
enum AppleScriptValueParser {
    static func parse(_ source: String) -> JSONValue? {
        var p = Parser(chars: Array(source.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard !p.chars.isEmpty, let v = p.value() else { return nil }
        p.skipSpaces()
        return p.i == p.chars.count ? v : nil
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        var peek: Character? { i < chars.count ? chars[i] : nil }
        mutating func skipSpaces() { while let c = peek, c == " " || c == "\n" || c == "\t" { i += 1 } }

        mutating func keyword(_ word: String) -> Bool {
            let w = Array(word)
            guard i + w.count <= chars.count, Array(chars[i..<i + w.count]) == w else { return false }
            if i + w.count < chars.count, chars[i + w.count].isLetter { return false }
            i += w.count
            return true
        }

        mutating func value() -> JSONValue? {
            skipSpaces()
            guard let c = peek else { return nil }
            if c == "\"" { return string().map(JSONValue.string) }
            if c == "{" { return collection() }
            if c == "-" || c.isNumber { return number() }
            if keyword("true") { return .bool(true) }
            if keyword("false") { return .bool(false) }
            if keyword("missing value") || keyword("null") { return .null }
            return nil
        }

        mutating func string() -> String? {
            guard peek == "\"" else { return nil }
            i += 1
            var s = ""
            while let c = peek {
                i += 1
                if c == "\"" { return s }
                if c == "\\", let n = peek {
                    i += 1
                    switch n {
                    case "n": s.append("\n")
                    case "r": s.append("\r")
                    case "t": s.append("\t")
                    default: s.append(n)
                    }
                } else { s.append(c) }
            }
            return nil
        }

        mutating func number() -> JSONValue? {
            let start = i
            if peek == "-" { i += 1 }
            var digits = false, real = false
            while let c = peek, c.isASCII, c.isNumber { i += 1; digits = true }
            // Decimal separator follows the system locale ("." or ","); a list separator is always ", " with a space.
            if let c = peek, c == "." || c == ",", i + 1 < chars.count, chars[i + 1].isASCII, chars[i + 1].isNumber {
                real = true; i += 1
                while let d = peek, d.isASCII, d.isNumber { i += 1 }
            }
            if let c = peek, c == "E" || c == "e" {
                real = true; i += 1
                if let s = peek, s == "+" || s == "-" { i += 1 }
                while let d = peek, d.isASCII, d.isNumber { i += 1 }
            }
            guard digits else { return nil }
            let text = String(chars[start..<i]).replacingOccurrences(of: ",", with: ".")
            if !real, let n = Int(text) { return .int(n) }
            return Double(text).map(JSONValue.number)
        }

        mutating func collection() -> JSONValue? {
            i += 1
            skipSpaces()
            if peek == "}" { i += 1; return .array([]) }
            var items: [JSONValue] = []
            var record: [String: JSONValue] = [:]
            var isRecord: Bool?
            while true {
                skipSpaces()
                let save = i
                var key: String?
                if let c = peek, c.isLetter || c == "|" || c == "_" {
                    var k = ""
                    if c == "|" {
                        i += 1
                        while let d = peek, d != "|" { k.append(d); i += 1 }
                        i += 1
                    } else {
                        while let d = peek, d.isLetter || d.isNumber || d == "_" || d == " " { k.append(d); i += 1 }
                    }
                    if peek == ":" { i += 1; key = k.trimmingCharacters(in: .whitespaces) } else { i = save }
                }
                if isRecord == nil { isRecord = key != nil }
                guard isRecord == (key != nil), let v = value() else { return nil }
                if let key { record[key] = v } else { items.append(v) }
                skipSpaces()
                if peek == "," { i += 1; continue }
                if peek == "}" { i += 1; break }
                return nil
            }
            return isRecord == true ? .object(record) : .array(items)
        }
    }
}
