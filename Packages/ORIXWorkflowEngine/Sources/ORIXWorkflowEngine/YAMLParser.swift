// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/YAMLParser.swift
// Description      : Hand-written parser for the documented YAML subset (which
//                    includes JSON), producing positioned nodes and collecting
//                    comments.
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

/// A parsed value with its 1-based source position.
struct YNode: Sendable {
    indirect enum Value: Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case seq([YNode])
        case map([YEntry])
    }
    var value: Value
    var line: Int
    var column: Int

    var typeName: String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .seq: return "sequence"
        case .map: return "mapping"
        }
    }

    var json: JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .seq(let a): return .array(a.map(\.json))
        case .map(let m): return .object(Dictionary(m.map { ($0.key, $0.value.json) }, uniquingKeysWith: { _, l in l }))
        }
    }

    static func from(_ v: JSONValue) -> YNode {
        switch v {
        case .null: return YNode(value: .null, line: 0, column: 0)
        case .bool(let b): return YNode(value: .bool(b), line: 0, column: 0)
        case .int(let i): return YNode(value: .int(i), line: 0, column: 0)
        case .number(let d): return YNode(value: .double(d), line: 0, column: 0)
        case .string(let s): return YNode(value: .string(s), line: 0, column: 0)
        case .array(let a): return YNode(value: .seq(a.map(YNode.from)), line: 0, column: 0)
        case .object(let o):
            return YNode(value: .map(o.keys.sorted().map { YEntry(key: $0, line: 0, column: 0, value: .from(o[$0]!)) }), line: 0, column: 0)
        }
    }
}

struct YEntry: Sendable {
    var key: String
    var line: Int
    var column: Int
    var value: YNode
}

struct YAMLSyntaxError: Error {
    var message: String
    var line: Int
    var column: Int
}

struct YAMLComment: Sendable, Hashable {
    var line: Int
    var column: Int
    var text: String
}

/// Scalar typing shared by the parser and the emitter, so that what is emitted plain is read back as the same type.
enum YAMLScalar {
    static func resolvePlain(_ s: String) -> YNode.Value {
        switch s {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .double(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .double(-.infinity)
        case ".nan", ".NaN", ".NAN": return .double(.nan)
        default: break
        }
        let u = Array(s.unicodeScalars)
        var i = 0
        if u[i] == "-" || u[i] == "+" { i += 1 }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
        let intStart = i
        while i < u.count, isDigit(u[i]) { i += 1 }
        let intDigits = i - intStart
        if intDigits > 1 && u[intStart] == "0" { return .string(s) }
        var isFloat = false
        var fracDigits = 0
        if i < u.count, u[i] == "." {
            isFloat = true; i += 1
            let f = i
            while i < u.count, isDigit(u[i]) { i += 1 }
            fracDigits = i - f
        }
        if intDigits == 0 && fracDigits == 0 { return .string(s) }
        if i < u.count, u[i] == "e" || u[i] == "E" {
            isFloat = true; i += 1
            if i < u.count, u[i] == "-" || u[i] == "+" { i += 1 }
            let e = i
            while i < u.count, isDigit(u[i]) { i += 1 }
            if i == e { return .string(s) }
        }
        if i != u.count { return .string(s) }
        if !isFloat {
            let digits = u.first == "+" ? String(s.dropFirst()) : s
            if let v = Int(digits) { return .int(v) }
        }
        let text = u.first == "+" ? String(s.dropFirst()) : s
        if let d = Double(text) { return .double(d) }
        return .string(s)
    }
}

struct YAMLParser {
    private struct Line {
        var number: Int
        var text: [Unicode.Scalar]
        var indent: Int { var i = 0; while i < text.count, text[i] == " " { i += 1 }; return i }
        var isWhitespace: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }
    }

    private var lines: [Line]
    private var pos = 0
    private var col = 0
    private(set) var comments: [YAMLComment] = []
    /// True when the source starts with a `---` document marker.
    private(set) var hasDocumentMarker = false
    private var depth = 0
    private static let maxDepth = 128

    init(_ source: String) {
        var out: [Line] = []
        var current: [Unicode.Scalar] = []
        var n = 1
        var scalars = Array(source.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        for u in scalars {
            if u == "\n" {
                if current.last == "\r" { current.removeLast() }
                out.append(Line(number: n, text: current)); current = []; n += 1
            } else { current.append(u) }
        }
        if current.last == "\r" { current.removeLast() }
        if !current.isEmpty { out.append(Line(number: n, text: current)) }
        lines = out
    }

    // MARK: Entry point

    mutating func parseDocument() throws -> YNode {
        try skipBlank()
        if pos < lines.count, isMarker(lines[pos], "---") {
            let rest = lines[pos].text.dropFirst(3).filter { $0 != " " }
            if !rest.isEmpty && rest.first != "#" {
                throw YAMLSyntaxError(message: "content on the same line as the '---' document marker is not supported", line: lines[pos].number, column: 4)
            }
            hasDocumentMarker = true
            pos += 1
            try skipBlank()
        }
        guard pos < lines.count else { return YNode(value: .null, line: 1, column: 1) }
        let node = try parseBlock()
        try skipBlank()
        if pos < lines.count {
            let l = lines[pos]
            throw YAMLSyntaxError(message: "unexpected content after the end of the document", line: l.number, column: l.indent + 1)
        }
        return node
    }

    // MARK: Lines

    private func isMarker(_ l: Line, _ marker: String) -> Bool {
        let m = Array(marker.unicodeScalars)
        guard l.text.count >= 3, Array(l.text.prefix(3)) == m else { return false }
        return l.text.count == 3 || l.text[3] == " "
    }

    /// Skips blank and comment-only lines; checks the next structural line.
    private mutating func skipBlank() throws {
        while pos < lines.count {
            let l = lines[pos]
            if l.isWhitespace { pos += 1; continue }
            var i = 0
            while i < l.text.count, l.text[i] == " " || l.text[i] == "\t" { i += 1 }
            if l.text[i] == "#" {
                comments.append(YAMLComment(line: l.number, column: i + 1, text: String(String.UnicodeScalarView(l.text[i...]))))
                pos += 1; continue
            }
            if l.text[..<i].contains("\t") {
                throw YAMLSyntaxError(message: "tab character in indentation; use spaces", line: l.number, column: (l.text.firstIndex(of: "\t") ?? 0) + 1)
            }
            if l.text[0] == "%" {
                throw YAMLSyntaxError(message: "YAML directives (%YAML, %TAG) are not supported", line: l.number, column: 1)
            }
            if isMarker(l, "---") && (hasDocumentMarker || sawContent) {
                throw YAMLSyntaxError(message: "multiple YAML documents are not supported; keep one automation per file", line: l.number, column: 1)
            }
            if isMarker(l, "...") {
                throw YAMLSyntaxError(message: "the '...' document end marker is not supported", line: l.number, column: 1)
            }
            return
        }
    }

    private var sawContent = false

    private func error(_ message: String, _ line: Line, _ column: Int) -> YAMLSyntaxError {
        YAMLSyntaxError(message: message, line: line.number, column: column + 1)
    }

    private func str(_ s: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(s)) }
    private func str(_ s: [Unicode.Scalar]) -> String { String(String.UnicodeScalarView(s)) }

    // MARK: Block structures

    private mutating func parseBlock() throws -> YNode {
        depth += 1
        defer { depth -= 1 }
        let l = lines[pos]
        let ind = l.indent
        if depth > Self.maxDepth { throw error("document is nested too deeply (limit \(Self.maxDepth))", l, ind) }
        sawContent = true
        let c = l.text[ind]
        if c == "-" && (ind + 1 == l.text.count || l.text[ind + 1] == " ") { return try parseSequence(indent: ind) }
        if c == "?" && (ind + 1 == l.text.count || l.text[ind + 1] == " ") {
            throw error("complex mapping keys ('? ') are not supported", l, ind)
        }
        if try mappingKey(l, from: ind) != nil { return try parseMapping(indent: ind) }
        col = ind
        let node = try parseInlineValue(flow: false)
        try finishLine()
        return node
    }

    private struct Key { var text: String; var column: Int; var after: Int }

    /// Detects `key:` at `from` on a line. Returns nil when the line is not a mapping entry.
    private func mappingKey(_ l: Line, from: Int) throws -> Key? {
        let t = l.text
        guard from < t.count else { return nil }
        let c = t[from]
        if c == "\"" || c == "'" {
            guard let (s, end) = try? scanQuoted(l, from) else { return nil }
            var j = end
            while j < t.count, t[j] == " " { j += 1 }
            guard j < t.count, t[j] == ":", j + 1 == t.count || t[j + 1] == " " else { return nil }
            return Key(text: s, column: from, after: j + 1)
        }
        if c == "[" || c == "{" { return nil }
        var j = from
        while j < t.count {
            if t[j] == "#" && j > from && t[j - 1] == " " { return nil }
            if t[j] == ":" && (j + 1 == t.count || t[j + 1] == " ") {
                var e = j
                while e > from, t[e - 1] == " " { e -= 1 }
                let key = str(t[from..<e])
                if key.isEmpty { throw error("empty mapping key", l, from) }
                if c == "&" || c == "*" { throw error("anchors and aliases (&, *) are not supported", l, from) }
                if c == "!" { throw error("tags (!) are not supported", l, from) }
                if key == "<<" { throw error("merge keys (<<) are not supported", l, from) }
                return Key(text: key, column: from, after: j + 1)
            }
            j += 1
        }
        return nil
    }

    private mutating func parseMapping(indent: Int) throws -> YNode {
        let first = lines[pos]
        var entries: [YEntry] = []
        var seen: Set<String> = []
        while true {
            try skipBlank()
            guard pos < lines.count else { break }
            let l = lines[pos]
            let ind = l.indent
            if ind < indent { break }
            if ind > indent {
                throw error("unexpected indentation (multi-line plain scalars are not supported; use '|' or '>')", l, ind)
            }
            if l.text[ind] == "-" && (ind + 1 == l.text.count || l.text[ind + 1] == " ") { break }
            guard let key = try mappingKey(l, from: ind) else {
                throw error("expected 'key: value'", l, ind)
            }
            if !seen.insert(key.text).inserted { throw error("duplicate key '\(key.text)'", l, key.column) }
            col = key.after
            let value = try parseEntryValue(parentIndent: indent, allowSameIndentSequence: true, fallback: (l.number, key.column + 1))
            entries.append(YEntry(key: key.text, line: l.number, column: key.column + 1, value: value))
        }
        return YNode(value: .map(entries), line: first.number, column: indent + 1)
    }

    /// Parses what follows `key:` or `- ` on the current line (cursor at `col`).
    private mutating func parseEntryValue(parentIndent: Int, allowSameIndentSequence: Bool, fallback: (Int, Int)) throws -> YNode {
        let l = lines[pos]
        let t = l.text
        while col < t.count, t[col] == " " || t[col] == "\t" { col += 1 }
        if col >= t.count || t[col] == "#" {
            try finishLine()
            try skipBlank()
            if pos < lines.count {
                let next = lines[pos]
                let ni = next.indent
                if ni > parentIndent { return try parseBlock() }
                if allowSameIndentSequence, ni == parentIndent, next.text[ni] == "-", ni + 1 == next.text.count || next.text[ni + 1] == " " {
                    return try parseSequence(indent: ni)
                }
            }
            return YNode(value: .null, line: fallback.0, column: fallback.1)
        }
        if t[col] == "|" || t[col] == ">" { return try parseBlockScalar(parentIndent: parentIndent) }
        let node = try parseInlineValue(flow: false)
        try finishLine()
        return node
    }

    private mutating func parseSequence(indent: Int) throws -> YNode {
        let first = lines[pos]
        var items: [YNode] = []
        while true {
            try skipBlank()
            guard pos < lines.count else { break }
            let l = lines[pos]
            let ind = l.indent
            if ind < indent { break }
            if ind > indent { throw error("unexpected indentation", l, ind) }
            guard l.text[ind] == "-", ind + 1 == l.text.count || l.text[ind + 1] == " " else { break }
            var c = ind + 1
            while c < l.text.count, l.text[c] == " " { c += 1 }
            var nested = false
            if c < l.text.count {
                if l.text[c] == "-" && (c + 1 == l.text.count || l.text[c + 1] == " ") { nested = true }
                else if try mappingKey(l, from: c) != nil { nested = true }
            }
            if nested {
                // Compact form `- key: value`: blank the dash so the rest reads as a block indented at `c`.
                lines[pos].text[ind] = " "
                items.append(try parseBlock())
            } else {
                col = ind + 1
                items.append(try parseEntryValue(parentIndent: indent, allowSameIndentSequence: false, fallback: (l.number, ind + 1)))
            }
        }
        return YNode(value: .seq(items), line: first.number, column: indent + 1)
    }

    /// After an inline value: only spaces or a comment may remain. Advances to the next line.
    private mutating func finishLine() throws {
        let l = lines[pos]
        let t = l.text
        var c = col
        while c < t.count, t[c] == " " || t[c] == "\t" { c += 1 }
        if c < t.count {
            guard t[c] == "#" else { throw error("unexpected characters after the value", l, c) }
            comments.append(YAMLComment(line: l.number, column: c + 1, text: str(t[c...])))
        }
        pos += 1
        col = 0
    }

    // MARK: Block scalars

    private mutating func parseBlockScalar(parentIndent: Int) throws -> YNode {
        let header = lines[pos]
        let t = header.text
        let startCol = col
        let folded = t[col] == ">"
        col += 1
        var chomp: Unicode.Scalar = " "
        var explicit: Int?
        for _ in 0..<2 where col < t.count {
            let c = t[col]
            if c == "-" || c == "+" { guard chomp == " " else { throw error("invalid block scalar header", header, col) }; chomp = c; col += 1 }
            else if c.value >= 49 && c.value <= 57 { guard explicit == nil else { throw error("invalid block scalar header", header, col) }; explicit = Int(c.value) - 48; col += 1 }
        }
        var c = col
        while c < t.count, t[c] == " " { c += 1 }
        if c < t.count {
            guard t[c] == "#" else { throw error("unexpected characters after the block scalar indicator", header, c) }
            comments.append(YAMLComment(line: header.number, column: c + 1, text: str(t[c...])))
        }
        pos += 1
        col = 0
        var contentIndent: Int? = explicit.map { parentIndent + $0 }
        var content: [String] = []
        while pos < lines.count {
            let l = lines[pos]
            if l.isWhitespace {
                if let ci = contentIndent, l.text.count > ci { content.append(str(l.text[ci...])) } else { content.append("") }
                pos += 1; continue
            }
            let ind = l.indent
            if contentIndent == nil {
                guard ind > parentIndent else { break }
                contentIndent = ind
            }
            guard let ci = contentIndent, ind >= ci else { break }
            content.append(str(l.text[ci...]))
            pos += 1
        }
        var trailing = 0
        while let last = content.last, last.isEmpty { content.removeLast(); trailing += 1 }
        var body: String
        if folded {
            body = ""
            var blanks = 0
            var prev: String?
            for line in content {
                if line.isEmpty { blanks += 1; continue }
                if let p = prev {
                    let special = line.hasPrefix(" ") || p.hasPrefix(" ")
                    if special { body += String(repeating: "\n", count: blanks + 1) }
                    else if blanks == 0 { body += " " }
                    else { body += String(repeating: "\n", count: blanks) }
                } else {
                    body += String(repeating: "\n", count: blanks)
                }
                body += line
                blanks = 0
                prev = line
            }
        } else {
            body = content.joined(separator: "\n")
        }
        // A scalar is at end of input without a final newline only when the source itself ended without one.
        switch chomp {
        case "-": break
        case "+": body += String(repeating: "\n", count: content.isEmpty ? trailing : trailing + 1)
        default: if !body.isEmpty { body += "\n" }
        }
        return YNode(value: .string(body), line: header.number, column: startCol + 1)
    }

    // MARK: Inline values

    private mutating func parseInlineValue(flow: Bool) throws -> YNode {
        let l = lines[pos]
        let t = l.text
        let start = col
        let c = t[col]
        switch c {
        case "\"", "'":
            let (s, end) = try scanQuoted(l, col)
            col = end
            return YNode(value: .string(s), line: l.number, column: start + 1)
        case "[": return try parseFlowSequence()
        case "{": return try parseFlowMapping()
        case "&", "*": throw error("anchors and aliases (&, *) are not supported", l, col)
        case "!": throw error("tags (!) are not supported", l, col)
        case "@", "`": throw error("'\(c)' is a reserved character and cannot start a plain scalar; quote the value", l, col)
        case "%": throw error("a plain scalar cannot start with '%'; quote the value", l, col)
        case "|", ">":
            if flow { throw error("block scalars are not allowed inside flow collections", l, col) }
        case "-":
            if !flow, col + 1 < t.count, t[col + 1] == " " {
                throw error("a block sequence entry cannot start on the same line as a key; put it on the next line or quote the value", l, col)
            }
        default: break
        }
        var j = col
        while j < t.count {
            let ch = t[j]
            if ch == "#" && j > start && (t[j - 1] == " " || t[j - 1] == "\t") { break }
            if flow {
                if ch == "," || ch == "]" || ch == "}" { break }
                if ch == "[" || ch == "{" { throw error("unexpected '\(ch)' in a plain scalar inside a flow collection; quote the value", l, j) }
                if ch == ":" && (j + 1 == t.count || t[j + 1] == " " || t[j + 1] == "," || t[j + 1] == "]" || t[j + 1] == "}") { break }
            } else if ch == ":" && j + 1 < t.count && t[j + 1] == " " {
                throw error("unexpected ': ' inside a plain scalar; quote the value", l, j)
            }
            j += 1
        }
        var e = j
        while e > start, t[e - 1] == " " || t[e - 1] == "\t" { e -= 1 }
        col = e
        let text = str(t[start..<e])
        return YNode(value: YAMLScalar.resolvePlain(text), line: l.number, column: start + 1)
    }

    /// Scans a quoted scalar starting at `from`; returns the value and the index after the closing quote.
    private func scanQuoted(_ l: Line, _ from: Int) throws -> (String, Int) {
        let t = l.text
        let quote = t[from]
        var out = String.UnicodeScalarView()
        var j = from + 1
        if quote == "'" {
            while j < t.count {
                if t[j] == "'" {
                    if j + 1 < t.count, t[j + 1] == "'" { out.append("'"); j += 2; continue }
                    return (String(out), j + 1)
                }
                out.append(t[j]); j += 1
            }
            throw error("unterminated single-quoted scalar (quoted scalars must end on the line where they start)", l, from)
        }
        func hex(_ start: Int, _ count: Int) throws -> UInt32 {
            guard start + count <= t.count, let v = UInt32(str(t[start..<start + count]), radix: 16) else {
                throw error("invalid escape sequence: expected \(count) hexadecimal digits", l, start)
            }
            return v
        }
        while j < t.count {
            let c = t[j]
            if c == "\"" { return (String(out), j + 1) }
            if c != "\\" { out.append(c); j += 1; continue }
            guard j + 1 < t.count else { break }
            let e = t[j + 1]
            j += 2
            switch e {
            case "0": out.append("\0")
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "t", "\t": out.append("\t")
            case "n": out.append("\n")
            case "v": out.append("\u{0B}")
            case "f": out.append("\u{0C}")
            case "r": out.append("\r")
            case "e": out.append("\u{1B}")
            case " ": out.append(" ")
            case "\"": out.append("\"")
            case "/": out.append("/")
            case "\\": out.append("\\")
            case "N": out.append("\u{85}")
            case "_": out.append("\u{A0}")
            case "L": out.append("\u{2028}")
            case "P": out.append("\u{2029}")
            case "x", "u", "U":
                let n = e == "x" ? 2 : (e == "u" ? 4 : 8)
                var v = try hex(j, n)
                j += n
                if e == "u", v >= 0xD800, v <= 0xDBFF, j + 6 <= t.count, t[j] == "\\", t[j + 1] == "u" {
                    let low = try hex(j + 2, 4)
                    if low >= 0xDC00, low <= 0xDFFF { v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00); j += 6 }
                }
                guard let s = Unicode.Scalar(v) else { throw error("escape sequence is not a valid Unicode scalar", l, j - n) }
                out.append(s)
            default:
                throw error("unknown escape sequence '\\\(e)'", l, j - 2)
            }
        }
        throw error("unterminated double-quoted scalar (quoted scalars must end on the line where they start)", l, from)
    }

    // MARK: Flow collections (may span lines; this is also how JSON is read)

    private mutating func flowSkip(open: (Line, Int)) throws {
        while true {
            guard pos < lines.count else { throw error("unterminated flow collection", open.0, open.1) }
            let t = lines[pos].text
            if col >= t.count { pos += 1; col = 0; continue }
            let c = t[col]
            if c == " " || c == "\t" { col += 1; continue }
            if c == "#" && (col == 0 || t[col - 1] == " " || t[col - 1] == "\t") {
                comments.append(YAMLComment(line: lines[pos].number, column: col + 1, text: str(t[col...])))
                col = t.count; continue
            }
            return
        }
    }

    private mutating func parseFlowNode(open: (Line, Int)) throws -> YNode {
        depth += 1
        defer { depth -= 1 }
        if depth > Self.maxDepth { throw error("document is nested too deeply (limit \(Self.maxDepth))", lines[pos], col) }
        return try parseInlineValue(flow: true)
    }

    private mutating func parseFlowSequence() throws -> YNode {
        let open = (lines[pos], col)
        col += 1
        var items: [YNode] = []
        while true {
            try flowSkip(open: open)
            if lines[pos].text[col] == "]" { col += 1; break }
            if lines[pos].text[col] == "," { throw error("unexpected ','", lines[pos], col) }
            items.append(try parseFlowNode(open: open))
            try flowSkip(open: open)
            let c = lines[pos].text[col]
            if c == "," { col += 1; continue }
            if c == "]" { col += 1; break }
            if c == ":" { throw error("single-pair mappings inside flow sequences are not supported; write {key: value}", lines[pos], col) }
            throw error("expected ',' or ']'", lines[pos], col)
        }
        return YNode(value: .seq(items), line: open.0.number, column: open.1 + 1)
    }

    private mutating func parseFlowMapping() throws -> YNode {
        let open = (lines[pos], col)
        col += 1
        var entries: [YEntry] = []
        var seen: Set<String> = []
        while true {
            try flowSkip(open: open)
            let l = lines[pos]
            let t = l.text
            if t[col] == "}" { col += 1; break }
            let keyCol = col
            var key: String
            if t[col] == "\"" || t[col] == "'" {
                let (s, end) = try scanQuoted(l, col)
                key = s; col = end
            } else {
                var j = col
                while j < t.count, t[j] != ":", t[j] != ",", t[j] != "}", t[j] != "{", t[j] != "[", t[j] != "]" { j += 1 }
                var e = j
                while e > col, t[e - 1] == " " { e -= 1 }
                key = str(t[col..<e]); col = j
                if key.isEmpty { throw error("expected a key", l, keyCol) }
                if key.hasPrefix("&") || key.hasPrefix("*") { throw error("anchors and aliases (&, *) are not supported", l, keyCol) }
                if key.hasPrefix("!") { throw error("tags (!) are not supported", l, keyCol) }
            }
            try flowSkip(open: open)
            guard lines[pos].text[col] == ":" else { throw error("expected ':' after the key '\(key)'", lines[pos], col) }
            col += 1
            try flowSkip(open: open)
            if !seen.insert(key).inserted { throw error("duplicate key '\(key)'", l, keyCol) }
            let next = lines[pos].text[col]
            let value: YNode
            if next == "," || next == "}" { value = YNode(value: .null, line: lines[pos].number, column: col + 1) }
            else { value = try parseFlowNode(open: open) }
            entries.append(YEntry(key: key, line: l.number, column: keyCol + 1, value: value))
            try flowSkip(open: open)
            let c = lines[pos].text[col]
            if c == "," { col += 1; continue }
            if c == "}" { col += 1; break }
            throw error("expected ',' or '}'", lines[pos], col)
        }
        return YNode(value: .map(entries), line: open.0.number, column: open.1 + 1)
    }
}
