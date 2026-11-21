// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/ScriptScanner.swift
// Description      : Static scan of AppleScript and JXA source: application
//                    targets, shell/ObjC/file escapes, clipboard use and
//                    constructs that cannot be verified statically.
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

public enum ScriptLanguage: String, Codable, Sendable, CaseIterable {
    case applescript, jxa
    public var displayName: String { self == .applescript ? "AppleScript" : "JavaScript for Automation" }
}

/// What a script's text says it will talk to. Static and conservative: anything that hides its target is reported in
/// `dynamicConstructs` and refused by the tools. This is a guard in front of approval and TCC, not a sandbox.
public struct ScriptScan: Sendable, Hashable {
    /// Names, paths or identifiers given as `application "X"` / `Application("X")`.
    public var applicationReferences: [String] = []
    /// Identifiers given as `application id "x"`.
    public var bundleIDReferences: [String] = []
    public var usesCurrentApplication = false
    /// `do shell script`, `doShellScript`, `$.system`.
    public var usesShell = false
    /// `use framework`, `ObjC.import`, `$.…`.
    public var usesObjCBridge = false
    /// File access through scripting additions (`open for access`, `POSIX file`, `read file`, `Path(…)`).
    public var usesFileIO = false
    public var readsClipboard = false
    public var writesClipboard = false
    public var opensLocation = false
    /// Human-readable reasons the script cannot be verified (variable targets, `run script`, `eval` …).
    public var dynamicConstructs: [String] = []

    /// True when the script can reach beyond Apple Events to declared apps: it then also needs the `bash` runtime grant.
    public var needsShellRuntime: Bool { usesShell || usesObjCBridge || usesFileIO }
    public var hasTargets: Bool { !applicationReferences.isEmpty || !bundleIDReferences.isEmpty }
}

public enum ScriptTargetScanner {
    public static func scan(_ script: String, language: ScriptLanguage) -> ScriptScan {
        switch language {
        case .applescript: return scanAppleScript(script)
        case .jxa: return scanJXA(script)
        }
    }

    /// Checks every application the script addresses against `declared` and returns the canonical declared targets.
    /// Throws `ToolError.invalidInput` for an undeclared, unresolvable or dynamic target.
    public static func verifiedTargets(_ scan: ScriptScan, declared: [String],
                                       resolve: (String) -> String? = AppResolver.bundleID(forReference:),
                                       canonical: (String) -> String = AppResolver.canonicalBundleID) throws -> [String] {
        if let first = scan.dynamicConstructs.first {
            throw ToolError.invalidInput("The script cannot be verified statically: \(first). Address applications with a literal name or bundle identifier and do not evaluate generated code.")
        }
        var targets: [String] = []
        for raw in declared {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AppResolver.isValidBundleID(id) else { throw ToolError.invalidInput("targets: \"\(raw)\" is not a valid bundle identifier") }
            let c = canonical(id)
            if !targets.contains(where: { $0.lowercased() == c.lowercased() }) { targets.append(c) }
        }
        let allowed = Set(targets.map { $0.lowercased() })
        for id in scan.bundleIDReferences where !allowed.contains(id.lowercased()) {
            throw ToolError.invalidInput("The script addresses application id \"\(id)\", which is not listed in targets.")
        }
        for ref in scan.applicationReferences {
            if allowed.contains(ref.lowercased()) { continue }
            guard let id = resolve(ref) else {
                throw ToolError.invalidInput("The script addresses application \"\(ref)\", which could not be resolved to an installed application. Use its bundle identifier.")
            }
            if !allowed.contains(id.lowercased()) {
                throw ToolError.invalidInput("The script addresses \"\(ref)\" (\(id)), which is not listed in targets.")
            }
        }
        return targets
    }

    // MARK: Masking

    /// Source with comments removed and every string literal replaced by `"<index>"`, so patterns never match inside text.
    struct Masked {
        var text = ""
        var strings: [String] = []
        /// Indices of template literals containing `${…}`.
        var interpolated: Set<Int> = []
    }

    static func maskAppleScript(_ source: String) -> Masked {
        var m = Masked()
        let c = Array(source)
        var i = 0
        func at(_ k: Int) -> Character? { k < c.count ? c[k] : nil }
        while i < c.count {
            let ch = c[i]
            if ch == "\"" {
                var s = ""
                i += 1
                while i < c.count, c[i] != "\"" {
                    if c[i] == "\\", i + 1 < c.count { s.append(c[i + 1]); i += 2 } else { s.append(c[i]); i += 1 }
                }
                i += 1
                m.text += "\"\(m.strings.count)\""
                m.strings.append(s)
            } else if ch == "-", at(i + 1) == "-" {
                while i < c.count, c[i] != "\n" { i += 1 }
            } else if ch == "#" {
                while i < c.count, c[i] != "\n" { i += 1 }
            } else if ch == "(", at(i + 1) == "*" {
                var depth = 1
                i += 2
                while i < c.count, depth > 0 {
                    if c[i] == "(", at(i + 1) == "*" { depth += 1; i += 2 }
                    else if c[i] == "*", at(i + 1) == ")" { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                m.text += " "
            } else if ch == "|" {
                // |quoted identifier|
                var j = i + 1
                while j < c.count, c[j] != "|", c[j] != "\n" { j += 1 }
                if at(j) == "|" { m.text += "quotedIdentifier"; i = j + 1 } else { m.text.append(ch); i += 1 }
            } else if ch == "¬" {
                // Line continuation.
                i += 1
                while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 }
                if at(i) == "\n" { i += 1 }
                m.text += " "
            } else {
                m.text.append(ch); i += 1
            }
        }
        return m
    }

    static func maskJavaScript(_ source: String) -> Masked {
        var m = Masked()
        let c = Array(source)
        var i = 0
        func at(_ k: Int) -> Character? { k < c.count ? c[k] : nil }
        while i < c.count {
            let ch = c[i]
            if ch == "\"" || ch == "'" || ch == "`" {
                var s = ""
                var dynamic = false
                i += 1
                while i < c.count, c[i] != ch {
                    if c[i] == "\\", i + 1 < c.count { s.append(c[i + 1]); i += 2; continue }
                    if ch == "`", c[i] == "$", at(i + 1) == "{" { dynamic = true }
                    if ch != "`", c[i] == "\n" { break }
                    s.append(c[i]); i += 1
                }
                i += 1
                if dynamic { m.interpolated.insert(m.strings.count) }
                m.text += "\"\(m.strings.count)\""
                m.strings.append(s)
            } else if ch == "/", at(i + 1) == "/" {
                while i < c.count, c[i] != "\n" { i += 1 }
            } else if ch == "/", at(i + 1) == "*" {
                i += 2
                while i < c.count, !(c[i] == "*" && at(i + 1) == "/") { i += 1 }
                i += 2
                m.text += " "
            } else {
                m.text.append(ch); i += 1
            }
        }
        return m
    }

    // MARK: AppleScript

    /// Words that may follow `application` without naming a target (`application process`, `current application to …`).
    private static let harmlessAfterApplication: Set<String> = [
        "to", "of", "in", "is", "isn", "as", "then", "and", "or", "whose", "where", "that", "process", "processes", "file", "files",
        "responses", "support", "bundle", "bundles", "window", "windows", "folder", "end", "with", "without", "on", "from", "into",
        "at", "for", "by", "does", "contains", "equals", "returning", "not", "else", "thru", "through", "scripts", "if", "s",
    ]

    static func scanAppleScript(_ source: String) -> ScriptScan {
        var scan = ScriptScan()
        let m = maskAppleScript(source)
        let text = m.text

        for g in regexGroups(#"\b(?:application|app)\s+(id\s+)?"(\d+)""#, in: text) {
            guard let idx = g[2].flatMap({ Int($0) }), m.strings.indices.contains(idx) else { continue }
            let value = m.strings[idx]
            if g[1] != nil { append(&scan.bundleIDReferences, value) } else { append(&scan.applicationReferences, value) }
        }
        // `application <variable>` / `application (expression)`: target decided at run time.
        for g in regexGroups(#"\b(?:application|app)\s+(?:id\s+)?(?!"|id\b)(\(|[A-Za-z_][A-Za-z0-9_]*)"#, in: text) {
            guard let token = g[1] else { continue }
            if token == "(" { append(&scan.dynamicConstructs, "an application chosen by an expression"); continue }
            if !harmlessAfterApplication.contains(token.lowercased()) {
                append(&scan.dynamicConstructs, "an application chosen at run time (\(token))")
            }
        }
        if regexFound(#"\bcurrent\s+application\b|\btell\s+me\b"#, in: text) { scan.usesCurrentApplication = true }
        if regexFound(#"\bdo\s+shell\s+script\b"#, in: text) { scan.usesShell = true }
        if regexFound(#"\buse\s+framework\b"#, in: text) { scan.usesObjCBridge = true }
        if regexFound(#"\bopen\s+for\s+access\b|\bPOSIX\s+file\b|\bread\s+(?:file|alias)\b"#, in: text) { scan.usesFileIO = true }
        if regexFound(#"\b(?:run|load)\s+script\b"#, in: text) { append(&scan.dynamicConstructs, "run script / load script evaluates code that is not in the script text") }
        if regexFound(#"\bset\s+the\s+clipboard\b"#, in: text) { scan.writesClipboard = true }
        if regexFound(#"\bthe\s+clipboard\b|\bclipboard\s+info\b"#, in: text.replacingOccurrences(of: "set the clipboard", with: "", options: .caseInsensitive)) {
            scan.readsClipboard = true
        }
        if regexFound(#"\bopen\s+location\b"#, in: text) { scan.opensLocation = true }
        return scan
    }

    // MARK: JXA

    static func scanJXA(_ source: String) -> ScriptScan {
        var scan = ScriptScan()
        let m = maskJavaScript(source)
        var text = m.text

        let literal = #"\bApplication\s*\(\s*"(\d+)"\s*\)"#
        for g in regexGroups(literal, in: text, options: []) {
            guard let idx = g[1].flatMap({ Int($0) }), m.strings.indices.contains(idx) else { continue }
            if m.interpolated.contains(idx) { append(&scan.dynamicConstructs, "Application(…) with an interpolated template string") }
            else { append(&scan.applicationReferences, m.strings[idx]) }
        }
        text = replace(literal, in: text, with: " knownApplication ")
        let current = #"\bApplication\s*\.\s*currentApplication\s*\(\s*\)"#
        if regexFound(current, in: text, options: []) { scan.usesCurrentApplication = true }
        text = replace(current, in: text, with: " currentApp ")
        if regexFound(#"\bApplication\b"#, in: text, options: []) {
            append(&scan.dynamicConstructs, "Application used with a non-literal argument or through an alias")
        }
        if regexFound(#"\beval\s*\(|\bFunction\s*\(|\bglobalThis\b|\bthis\s*\[|\bLibrary\s*\("#, in: text, options: []) {
            append(&scan.dynamicConstructs, "eval / Function / globalThis / Library evaluates or reaches code that is not in the script text")
        }
        if regexFound(#"\bdoShellScript\b|\$\s*\.\s*system\b"#, in: text, options: []) { scan.usesShell = true }
        if regexFound(#"\bObjC\b|\$\s*\.|\$\s*\("#, in: text, options: []) { scan.usesObjCBridge = true }
        if regexFound(#"\bPath\s*\(|\bopenForAccess\b"#, in: text, options: []) { scan.usesFileIO = true }
        if regexFound(#"\bsetTheClipboardTo\b"#, in: text, options: []) { scan.writesClipboard = true }
        if regexFound(#"\btheClipboard\b|\bclipboardInfo\b"#, in: text, options: []) { scan.readsClipboard = true }
        if regexFound(#"\bopenLocation\b"#, in: text, options: []) { scan.opensLocation = true }
        return scan
    }

    private static func append(_ list: inout [String], _ value: String) {
        if !list.contains(value) { list.append(value) }
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}
