// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/Highlighter.swift
// Description      : Incremental highlighting state for one document: line
//                    starts and the tokenizer state at the end of every line,
//                    updated from each edit so only the lines an edit can
//                    affect are tokenized again; plus the mapping from
//                    diagnostics to text ranges.
// Module           : ORIXFeatureCode
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

import AppKit
import ORIXAppUI
import SwiftUI

/// Line table and per-line tokenizer states of a document.
public struct SyntaxHighlighter {
    public var language: CodeLanguage
    /// UTF-16 offset of the first character of every line. Always starts with 0.
    public private(set) var lineStarts: [Int] = [0]
    private var endStates: [LineState] = [.normal]
    private var length = 0

    public init(language: CodeLanguage) { self.language = language }

    public var lineCount: Int { lineStarts.count }

    /// Index of the line containing a UTF-16 offset.
    public func lineIndex(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Range of a line without its terminator.
    public func lineRange(_ line: Int) -> NSRange {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func scanLineStarts(_ text: NSString, from: Int, to: Int) -> [Int] {
        guard to > from else { return [] }
        var buffer = [unichar](repeating: 0, count: to - from)
        text.getCharacters(&buffer, range: NSRange(location: from, length: to - from))
        var out: [Int] = []
        for (k, c) in buffer.enumerated() where c == 10 { out.append(from + k + 1) }
        return out
    }

    private func characters(_ text: NSString, line: Int) -> [unichar] {
        let r = lineRange(line)
        guard r.length > 0 else { return [] }
        var buffer = [unichar](repeating: 0, count: r.length)
        text.getCharacters(&buffer, range: r)
        return buffer
    }

    /// Rebuilds everything for a new document.
    public mutating func reset(_ text: NSString) {
        length = text.length
        lineStarts = [0] + Self.scanLineStarts(text, from: 0, to: length)
        endStates = [LineState](repeating: .normal, count: lineStarts.count)
        var state = LineState.normal
        for line in 0..<lineStarts.count {
            state = SyntaxTokenizer.tokenize(line: characters(text, line: line), offset: lineStarts[line], state: state, language: language).state
            endStates[line] = state
        }
    }

    /// Applies one edit (`editedRange` in the new text, as reported by the text storage) and returns the lines whose
    /// colours must be refreshed. Lines after the edit are re-tokenized only while their incoming state differs.
    public mutating func update(_ text: NSString, editedRange: NSRange, changeInLength delta: Int) -> ClosedRange<Int> {
        let oldEnd = editedRange.location + editedRange.length - delta
        let first = lineIndex(at: editedRange.location)
        let lastOld = lineIndex(at: max(oldEnd, editedRange.location))
        let inserted = Self.scanLineStarts(text, from: editedRange.location, to: editedRange.location + editedRange.length)
        let tailStarts = lineStarts[(lastOld + 1)...].map { $0 + delta }
        let oldStateOfLast = endStates[lastOld]
        let tailStates = Array(endStates[(lastOld + 1)...])
        lineStarts = Array(lineStarts[...first]) + inserted + tailStarts
        endStates = Array(endStates[..<first]) + [LineState](repeating: .normal, count: inserted.count + 1) + tailStates
        length = text.length
        let lastEdited = first + inserted.count
        var state = first == 0 ? LineState.normal : endStates[first - 1]
        var line = first
        while line < lineStarts.count {
            state = SyntaxTokenizer.tokenize(line: characters(text, line: line), offset: lineStarts[line], state: state, language: language).state
            if line >= lastEdited {
                let before = line == lastEdited ? oldStateOfLast : endStates[line]
                endStates[line] = state
                if before == state { break }
            } else {
                endStates[line] = state
            }
            line += 1
        }
        return first...min(line, lineStarts.count - 1)
    }

    /// Tokens of a run of lines, from the stored states.
    public func tokens(_ text: NSString, lines: ClosedRange<Int>) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        var state = lines.lowerBound == 0 ? LineState.normal : endStates[lines.lowerBound - 1]
        for line in lines where line < lineStarts.count {
            let r = SyntaxTokenizer.tokenize(line: characters(text, line: line), offset: lineStarts[line], state: state, language: language)
            out.append(contentsOf: r.tokens); state = r.state
        }
        return out
    }

    /// Characters covered by a run of lines, terminators included.
    public func characterRange(lines: ClosedRange<Int>) -> NSRange {
        let start = lineStarts[lines.lowerBound]
        let end = lines.upperBound + 1 < lineStarts.count ? lineStarts[lines.upperBound + 1] : length
        return NSRange(location: start, length: max(0, end - start))
    }
}

// MARK: - Colours

/// Colours of the editor, all derived from `Theme` so they follow the window's appearance.
@MainActor
public enum SyntaxTheme {
    public static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    public static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    public static let text = NSColor(Theme.text)
    public static let background = NSColor(Theme.surface)
    public static let gutterBackground = NSColor(Theme.surfaceRaised)
    public static let gutterText = NSColor(Theme.textTertiary)
    public static let selection = NSColor(Theme.accentSoft)

    private static let palette: [TokenKind: NSColor] = [
        .comment: NSColor(Theme.textTertiary), .string: NSColor(Theme.success), .number: NSColor(Theme.warning),
        .keyword: NSColor(Theme.violet), .type: NSColor(Theme.blue), .key: NSColor(Theme.blue), .function: NSColor(Theme.violet),
        .variable: NSColor(Theme.blue), .constant: NSColor(Theme.warning), .op: NSColor(Theme.textSecondary),
        .punctuation: NSColor(Theme.textSecondary), .interpolation: NSColor(Theme.danger), .attribute: NSColor(Theme.warning),
    ]

    public static func color(_ kind: TokenKind) -> NSColor { palette[kind] ?? text }

    public static func color(_ severity: EditorDiagnostic.Severity) -> NSColor {
        switch severity {
        case .error: return NSColor(Theme.danger)
        case .warning: return NSColor(Theme.warning)
        case .info: return NSColor(Theme.blue)
        }
    }
}

// MARK: - Diagnostics

/// A problem shown in the editor. Lines and columns are 1-based; 0 means "no position".
public struct EditorDiagnostic: Hashable, Identifiable, Sendable {
    public enum Severity: Int, Sendable, Comparable {
        case error = 0, warning = 1, info = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public var severity: Severity
    public var code: String
    public var message: String
    public var line: Int
    public var column: Int
    public var id: String { "\(line):\(column):\(code):\(message)" }

    public init(severity: Severity, code: String = "", message: String, line: Int = 0, column: Int = 0) {
        self.severity = severity; self.code = code; self.message = message; self.line = line; self.column = column
    }

    public init(_ d: WorkflowDiagnostic) {
        let s: Severity = d.severity == .error ? .error : (d.severity == .warning ? .warning : .info)
        self.init(severity: s, code: d.code, message: d.message, line: d.line, column: d.column)
    }
}

/// A piece of text with documentation shown on hover.
public struct EditorHover: Hashable, Sendable {
    public var range: NSRange
    public var text: String
    public init(range: NSRange, text: String) { self.range = range; self.text = text }
}

public enum DiagnosticMapper {
    /// The text a diagnostic underlines: the token at its position (a quoted string, a key, a word), at least one
    /// character when the line has any. A diagnostic without a position, or past the end, gets an empty range.
    public static func range(line: Int, column: Int, in text: NSString) -> NSRange {
        guard line > 0 else { return NSRange(location: 0, length: 0) }
        // Find the line.
        var start = 0
        var current = 1
        let length = text.length
        while current < line, start < length {
            let r = text.range(of: "\n", options: [], range: NSRange(location: start, length: length - start))
            if r.location == NSNotFound { return NSRange(location: length, length: 0) }
            start = r.location + 1; current += 1
        }
        guard current == line else { return NSRange(location: length, length: 0) }
        var end = text.range(of: "\n", options: [], range: NSRange(location: start, length: length - start)).location
        if end == NSNotFound { end = length }
        if end > start, text.character(at: end - 1) == 13 { end -= 1 }
        return range(column: column, start: start, end: end, in: text)
    }

    /// Same, for a line whose bounds are known (`end` excludes the terminator).
    public static func range(column: Int, start: Int, end rawEnd: Int, in text: NSString) -> NSRange {
        var end = rawEnd
        if end > start, text.character(at: end - 1) == 13 { end -= 1 }
        guard end > start else { return NSRange(location: start, length: 0) }
        // Columns count Unicode scalars; convert to UTF-16.
        var offset = start
        var remaining = max(0, column - 1)
        while remaining > 0, offset < end {
            let c = text.character(at: offset)
            offset += (c >= 0xD800 && c <= 0xDBFF && offset + 1 < end) ? 2 : 1
            remaining -= 1
        }
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }
        if offset >= end {
            // Past the end: underline the last visible character.
            var last = end - 1
            while last > start, isSpace(text.character(at: last)) { last -= 1 }
            return NSRange(location: last, length: 1)
        }
        while offset < end - 1, isSpace(text.character(at: offset)) { offset += 1 }
        let first = text.character(at: offset)
        var stop = offset + 1
        if first == 34 || first == 39 {
            while stop < end, text.character(at: stop) != first { stop += text.character(at: stop) == 92 ? 2 : 1 }
            stop = min(stop + 1, end)
        } else {
            while stop < end {
                let c = text.character(at: stop)
                if isSpace(c) || c == 44 || c == 93 || c == 125 { break }
                if c == 58, stop + 1 >= end || isSpace(text.character(at: stop + 1)) { break }
                stop += 1
            }
        }
        return NSRange(location: offset, length: max(1, stop - offset))
    }
}
