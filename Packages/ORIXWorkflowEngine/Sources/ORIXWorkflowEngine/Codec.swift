// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Codec.swift
// Description      : Public codec: parse YAML/JSON into the IR, emit canonical
//                    text, report what a rewrite would drop, and map document
//                    paths to source positions.
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

public enum WorkflowFormat: String, Sendable, Codable, CaseIterable {
    case yaml
    case json
}

public struct WorkflowSourcePosition: Sendable, Hashable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) { self.line = line; self.column = column }
}

public enum WorkflowCodec {
    /// Parses a document. Throws `WorkflowParseError` whose diagnostics carry line and column.
    /// JSON is read by the same parser (JSON is inside the supported YAML subset), so both formats report positions.
    public static func parse(_ source: String, format: WorkflowFormat = .yaml) throws -> WorkflowDocument {
        let (root, _, _) = try syntaxTree(source)
        var decoder = DocumentDecoder()
        guard let doc = decoder.decode(root) else { throw WorkflowParseError(diagnostics: decoder.diagnostics) }
        return doc
    }

    /// Canonical text: fixed key order, minimal quoting, two-space indentation. `parse(emit(doc)) == doc`.
    public static func emit(_ doc: WorkflowDocument, format: WorkflowFormat = .yaml) -> String {
        let tree = DocumentEncoder.encode(doc)
        switch format {
        case .yaml: return YAMLWriter.write(tree)
        case .json: return JSONWriter.write(tree)
        }
    }

    /// `json` when the first significant character opens a JSON object, else `yaml`.
    public static func detectFormat(_ source: String) -> WorkflowFormat {
        for u in source.unicodeScalars where !(u == " " || u == "\n" || u == "\t" || u == "\r" || u == "\u{FEFF}") {
            return u == "{" ? .json : .yaml
        }
        return .yaml
    }

    /// What rewriting `source` from the model (after a visual edit) would drop or change. Empty means the text is already canonical.
    public static func roundTripLoss(source: String, format: WorkflowFormat = .yaml) -> [String] {
        let root: YNode, comments: [YAMLComment], marker: Bool
        do { (root, comments, marker) = try syntaxTree(source) }
        catch let e as WorkflowParseError { return ["the source does not parse, so it cannot be rewritten from the model: \(e.diagnostics.first?.message ?? "syntax error")"] }
        catch { return ["the source does not parse"] }
        var decoder = DocumentDecoder()
        guard let doc = decoder.decode(root) else {
            return ["the source is not a valid automation, so it cannot be rewritten from the model: \(decoder.diagnostics.first?.message ?? "invalid document")"]
        }
        var out: [String] = []
        if !comments.isEmpty {
            let lines = comments.map { String($0.line) }
            let shown = lines.prefix(12).joined(separator: ", ") + (lines.count > 12 ? ", …" : "")
            out.append("\(comments.count) comment\(comments.count == 1 ? "" : "s") would be removed (line\(comments.count == 1 ? "" : "s") \(shown))")
        }
        if marker { out.append("the leading '---' document marker would be removed") }
        out.append(contentsOf: decoder.notes)
        if withoutComments(source, comments) != emit(doc, format: format) {
            out.append("the text would be rewritten in canonical form: key order, quoting, indentation and blank lines are normalised")
        }
        return out
    }

    private static func withoutComments(_ source: String, _ comments: [YAMLComment]) -> String {
        guard !comments.isEmpty else { return source }
        var byLine: [Int: Int] = [:]
        for c in comments { byLine[c.line] = min(byLine[c.line] ?? .max, c.column) }
        var out: [String] = []
        for (i, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let col = byLine[i + 1] else { out.append(String(line)); continue }
            let kept = String(String.UnicodeScalarView(line.unicodeScalars.prefix(col - 1)))
            let trimmed = kept.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        return out.joined(separator: "\n")
    }

    /// Positions of every node of `source`, keyed by document path (`spec.steps[0].with.path`).
    public static func sourcePositions(source: String) -> [String: WorkflowSourcePosition] {
        guard let (root, _, _) = try? syntaxTree(source) else { return [:] }
        var out: [String: WorkflowSourcePosition] = [:]
        func walk(_ node: YNode, _ path: String) {
            out[path] = WorkflowSourcePosition(line: node.line, column: node.column)
            switch node.value {
            case .map(let entries):
                for e in entries {
                    let p = path.isEmpty ? e.key : "\(path).\(e.key)"
                    walk(e.value, p)
                    out[p] = WorkflowSourcePosition(line: e.line, column: e.column)
                }
            case .seq(let items):
                for (i, item) in items.enumerated() { walk(item, "\(path)[\(i)]") }
            default: break
            }
        }
        walk(root, "")
        return out
    }

    /// Fills `line`/`column` of diagnostics that only carry a document path (validator output), using the longest path prefix found in `source`.
    public static func locate(_ diagnostics: [WorkflowDiagnostic], in source: String) -> [WorkflowDiagnostic] {
        let positions = sourcePositions(source: source)
        return diagnostics.map { d in
            guard d.line == 0 else { return d }
            var path = d.path
            while true {
                if let p = positions[path], p.line > 0 {
                    var out = d; out.line = p.line; out.column = p.column
                    return out
                }
                guard !path.isEmpty else { return d }
                if path.hasSuffix("]"), let i = path.lastIndex(of: "[") { path = String(path[..<i]) }
                else if let i = path.lastIndex(of: ".") { path = String(path[..<i]) }
                else { path = "" }
            }
        }
    }

    /// One call for the code editor: syntax and structure errors, then validator diagnostics, all with source positions.
    public static func diagnose(source: String, format: WorkflowFormat = .yaml, tools: [ToolManifest], agents: [String] = [],
                                workflows: [String] = []) -> (document: WorkflowDocument?, diagnostics: [WorkflowDiagnostic]) {
        do {
            let doc = try parse(source, format: format)
            let found = WorkflowValidator.validate(doc, tools: tools, agents: agents, workflows: workflows)
            return (doc, locate(found, in: source))
        } catch let e as WorkflowParseError {
            return (nil, e.diagnostics)
        } catch {
            return (nil, [WorkflowDiagnostic(code: "syntax", message: "\(error)")])
        }
    }

    static func syntaxTree(_ source: String) throws -> (YNode, [YAMLComment], Bool) {
        var parser = YAMLParser(source)
        do {
            let root = try parser.parseDocument()
            return (root, parser.comments, parser.hasDocumentMarker)
        } catch let e as YAMLSyntaxError {
            throw WorkflowParseError(diagnostics: [WorkflowDiagnostic(code: "syntax", message: e.message, line: e.line, column: e.column)])
        }
    }
}

// MARK: - Codable

extension WorkflowDocument: Codable {
    /// The document as a JSON value in canonical shape (what `emit(_, format: .json)` writes, without key order).
    public var jsonValue: JSONValue { DocumentEncoder.encode(self).jsonValue }

    public init(jsonValue: JSONValue) throws {
        var decoder = DocumentDecoder()
        guard let doc = decoder.decode(YNode.from(jsonValue)) else { throw WorkflowParseError(diagnostics: decoder.diagnostics) }
        self = doc
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        do { self = try WorkflowDocument(jsonValue: value) }
        catch let e as WorkflowParseError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: e.errorDescription ?? "invalid workflow document"))
        }
    }

    public func encode(to encoder: Encoder) throws { try jsonValue.encode(to: encoder) }
}
