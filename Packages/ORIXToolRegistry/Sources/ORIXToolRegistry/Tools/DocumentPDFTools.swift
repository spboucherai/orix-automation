// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/DocumentPDFTools.swift
// Description      : documents.pdfText and documents.pdfInfo (PDFKit) and
//                    documents.renderPDF, a CoreText paginator for
//                    Markdown-like text with headings, lists, tables, code
//                    blocks, images and page numbers.
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
import PDFKit
import CoreText
import CoreGraphics
import ImageIO
import ORIXCore

private var fm: FileManager { FileManager.default }
private func show(_ path: String) -> String { PathResolver.display(path) }

private func openPDF(_ path: String) throws -> PDFDocument {
    try ToolSupport.requireFile(path)
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { throw ToolError.unsupported("\(show(path)) is not a readable PDF") }
    return doc
}

// MARK: - pdfText

public struct DocumentsPDFTextTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "documents.pdfText", name: "Extract PDF text",
        summary: "Extracts the text layer of a PDF, page by page, for a page range. Scanned PDFs without a text layer return empty pages (hasText false).",
        family: "documents",
        inputSchema: Schema.input(["path": Schema.path, "firstPage": .integer("1-based (default 1).", minimum: 1), "lastPage": .integer("Inclusive (default: last).", minimum: 1),
                                   "maxBytes": .integer("Total text bound (default 200000).", minimum: 1, maximum: 4_000_000)], required: ["path"]),
        outputSchema: Schema.output(["pageCount": .integer(), "pages": .array(of: .any), "hasText": .boolean(), "truncated": .boolean()],
                                    required: ["pageCount", "pages", "hasText", "truncated"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 180, maxOutputBytes: 6_000_000, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        if let a = input.arguments["firstPage"]?.intValue, let b = input.arguments["lastPage"]?.intValue, b < a { throw ToolError.invalidInput("lastPage is before firstPage") }
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Extract the text of \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        let doc = try openPDF(path)
        guard !doc.isLocked else { throw ToolError.unsupported("\(show(path)) is password-protected") }
        let count = doc.pageCount
        let first = input.int("firstPage", default: 1), last = min(count, input.int("lastPage", default: count))
        guard first <= max(count, 1) else { throw ToolError.invalidInput("firstPage \(first) is beyond the \(count) pages of the document") }
        var budget = input.int("maxBytes", default: 200_000)
        var pages: [JSONValue] = []
        var truncated = false, hasText = false
        if count > 0 {
            for n in first...max(first, last) where n <= count {
                try Task.checkCancellation()
                let text = doc.page(at: n - 1)?.string ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
                let cut = text.truncated(maxBytes: max(0, budget))
                pages.append(["page": .int(n), "text": .string(cut.text)])
                budget -= text.utf8.count
                if cut.truncated || budget <= 0 { truncated = truncated || cut.truncated || n < last; break }
            }
        }
        var result = ToolResult.success(["pageCount": .int(count), "pages": .array(pages), "hasText": .bool(hasText), "truncated": .bool(truncated)],
                                        summary: "Text of \(ToolSupport.plural(pages.count, "page")) of \(count) from \(show(path))\(hasText ? "" : " (no text layer)")")
        result.truncated = truncated
        return result
    }
}

// MARK: - pdfInfo

public struct DocumentsPDFInfoTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "documents.pdfInfo", name: "PDF information",
        summary: "Returns the page count, page size, encryption state and document properties (title, author, dates) of a PDF.",
        family: "documents",
        inputSchema: Schema.input(["path": Schema.path], required: ["path"]),
        outputSchema: Schema.output(["pageCount": .integer(), "encrypted": .boolean(), "locked": .boolean(), "bytes": .integer()],
                                    required: ["pageCount", "encrypted", "locked", "bytes"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Inspect the PDF \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        let doc = try openPDF(path)
        var out: [String: JSONValue] = [
            "path": .string(path), "pageCount": .int(doc.pageCount), "encrypted": .bool(doc.isEncrypted), "locked": .bool(doc.isLocked),
            "bytes": .int(ToolSupport.fileSize(path)), "version": .string("\(doc.majorVersion).\(doc.minorVersion)"),
            "allowsCopying": .bool(doc.allowsCopying), "allowsPrinting": .bool(doc.allowsPrinting),
        ]
        if let page = doc.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            out["pageSize"] = ["widthPoints": .number(Double(box.width)), "heightPoints": .number(Double(box.height)), "rotation": .int(page.rotation)]
        }
        let attrs = doc.documentAttributes ?? [:]
        for (key, name) in [(PDFDocumentAttribute.titleAttribute, "title"), (.authorAttribute, "author"), (.subjectAttribute, "subject"),
                            (.creatorAttribute, "creator"), (.producerAttribute, "producer")] {
            if let v = attrs[key] as? String, !v.isEmpty { out[name] = .string(v) }
        }
        if let d = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date { out["created"] = ToolSupport.iso(d) }
        if let d = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date { out["modified"] = ToolSupport.iso(d) }
        if let k = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] { out["keywords"] = .array(k.map(JSONValue.string)) }
        return .success(.object(out), summary: "\(show(path)): \(ToolSupport.plural(doc.pageCount, "page"))\(doc.isEncrypted ? ", encrypted" : "")")
    }
}

// MARK: - renderPDF

/// Markdown-like source split into blocks.
enum PDFBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(marker: String, text: String)
    case code(String)
    case table(rows: [[String]], hasHeader: Bool)
    case image(alt: String, path: String)
    case rule

    static func parse(_ source: String) -> [PDFBlock] {
        var blocks: [PDFBlock] = []
        var paragraph: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func flush() { if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] } }
        var i = 0
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1; continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if let m = trimmed.range(of: #"^#{1,4}\s+"#, options: .regularExpression) {
                flush()
                blocks.append(.heading(level: trimmed[m].filter { $0 == "#" }.count, text: String(trimmed[m.upperBound...])))
                i += 1; continue
            }
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { flush(); blocks.append(.rule); i += 1; continue }
            if let m = trimmed.range(of: #"^!\[([^\]]*)\]\(([^)]+)\)$"#, options: .regularExpression), m.lowerBound == trimmed.startIndex {
                flush()
                let alt = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<trimmed.firstIndex(of: "]")!]
                let open = trimmed.range(of: "](")!.upperBound
                blocks.append(.image(alt: String(alt), path: String(trimmed[open..<trimmed.index(before: trimmed.endIndex)])))
                i += 1; continue
            }
            if trimmed.hasPrefix("|") {
                flush()
                var rows: [[String]] = []
                var hasHeader = false
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var cells = lines[i].trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.first == "" { cells.removeFirst() }
                    if cells.last == "" { cells.removeLast() }
                    if !cells.isEmpty, cells.allSatisfy({ $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil }) { hasHeader = rows.count == 1 }
                    else { rows.append(cells) }
                    i += 1
                }
                if !rows.isEmpty { blocks.append(.table(rows: rows, hasHeader: hasHeader)) }
                continue
            }
            if let m = trimmed.range(of: #"^([-*+]|\d{1,3}[.)])\s+"#, options: .regularExpression) {
                flush()
                let marker = trimmed[m].trimmingCharacters(in: .whitespaces)
                var text = String(trimmed[m.upperBound...])
                // Continuation lines: indented, not starting another block.
                while i + 1 < lines.count, lines[i + 1].hasPrefix("  "), !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty,
                      lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^([-*+]|\d{1,3}[.)])\s+"#, options: .regularExpression) == nil {
                    text += " " + lines[i + 1].trimmingCharacters(in: .whitespaces); i += 1
                }
                blocks.append(.bullet(marker: ["-", "*", "+"].contains(marker) ? "•" : marker, text: text))
                i += 1; continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flush()
        return blocks
    }

    /// Image paths referenced by the source, in order.
    static func imagePaths(_ source: String) -> [String] {
        parse(source).compactMap { if case .image(_, let p) = $0 { return p }; return nil }
    }
}

/// Lays blocks out on pages with CoreText, then draws them into a PDF context.
final class PDFComposer {
    private enum Op {
        case frame(CTFrame)
        case fill(CGRect, CGFloat)          // gray level
        case stroke(CGRect, CGFloat)
        case line(CGPoint, CGPoint, CGFloat)
        case image(CGImage, CGRect)
    }

    let pageSize: CGSize
    let margin: CGFloat
    let baseSize: CGFloat
    private var pages: [[Op]] = [[]]
    private var y: CGFloat = 0   // distance from the top of the content area

    init(pageSize: CGSize, margin: CGFloat = 56, baseSize: CGFloat = 11) {
        self.pageSize = pageSize; self.margin = margin; self.baseSize = baseSize
    }

    private var contentWidth: CGFloat { pageSize.width - 2 * margin }
    private var contentHeight: CGFloat { pageSize.height - 2 * margin - 18 }  // room for the page number
    var pageCount: Int { pages.count }

    private func newPage() { pages.append([]); y = 0 }
    private func add(_ op: Op) { pages[pages.count - 1].append(op) }
    /// Converts a top-based rectangle of the content area into PDF coordinates.
    private func rect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: margin + x, y: pageSize.height - margin - top - height, width: width, height: height)
    }

    // MARK: Text

    private func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

    private func attributes(_ fontName: String, _ size: CGFloat, gray: CGFloat = 0.1) -> [NSAttributedString.Key: Any] {
        [NSAttributedString.Key(kCTFontAttributeName as String): font(fontName, size),
         NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)]
    }

    /// Inline `**bold**`, `*italic*`, `` `code` ``.
    func inline(_ text: String, size: CGFloat, bold: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let regular = bold ? "Helvetica-Bold" : "Helvetica"
        var rest = Substring(text)
        func plain(_ s: Substring) { if !s.isEmpty { out.append(NSAttributedString(string: String(s), attributes: attributes(regular, size))) } }
        while !rest.isEmpty {
            let candidates: [(String, String, CGFloat)] = [("**", "Helvetica-Bold", size), ("`", "Menlo-Regular", size * 0.92), ("*", bold ? "Helvetica-BoldOblique" : "Helvetica-Oblique", size)]
            var best: (open: Range<Substring.Index>, close: Range<Substring.Index>, font: String, size: CGFloat)?
            for (mark, fontName, s) in candidates {
                guard let open = rest.range(of: mark), let close = rest[open.upperBound...].range(of: mark), close.lowerBound > open.upperBound else { continue }
                if best == nil || open.lowerBound < best!.open.lowerBound { best = (open, close, fontName, s) }
            }
            guard let b = best else { plain(rest); break }
            plain(rest[..<b.open.lowerBound])
            out.append(NSAttributedString(string: String(rest[b.open.upperBound..<b.close.lowerBound]), attributes: attributes(b.font, b.size)))
            rest = rest[b.close.upperBound...]
        }
        return out
    }

    private func measure(_ setter: CTFramesetter, from: Int, width: CGFloat, height: CGFloat) -> (size: CGSize, fit: Int) {
        var fit = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: from, length: 0), nil, CGSize(width: width, height: height), &fit)
        return (size, fit.length)
    }

    /// Flows text over as many pages as needed. `background` paints a gray box behind each chunk; `marker` is drawn once, left of the first line.
    private func flow(_ text: NSAttributedString, indent: CGFloat = 0, after: CGFloat, background: CGFloat? = nil, marker: NSAttributedString? = nil) {
        guard text.length > 0 else { y += after; return }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let pad: CGFloat = background == nil ? 0 : 6
        let width = contentWidth - indent - 2 * pad
        var location = 0
        var first = true
        var guardCount = 0
        while location < text.length {
            guardCount += 1
            if guardCount > 10_000 { break }
            let available = contentHeight - y - 2 * pad
            let m = measure(setter, from: location, width: width, height: max(0, available))
            if m.fit == 0 || available < baseSize {
                if y == 0 { break }  // a single glyph that cannot fit on an empty page: give up on the remainder
                newPage(); continue
            }
            let h = ceil(m.size.height)
            if let background { add(.fill(rect(x: indent, top: y, width: contentWidth - indent, height: h + 2 * pad), background)) }
            let r = rect(x: indent + pad, top: y + pad, width: width, height: h)
            add(.frame(CTFramesetterCreateFrame(setter, CFRange(location: location, length: m.fit), CGPath(rect: r, transform: nil), nil)))
            if first, let marker {
                let ms = CTFramesetterCreateWithAttributedString(marker)
                let mr = rect(x: max(0, indent - 18), top: y, width: 18, height: h)
                add(.frame(CTFramesetterCreateFrame(ms, CFRange(location: 0, length: marker.length), CGPath(rect: mr, transform: nil), nil)))
            }
            first = false
            y += h + 2 * pad
            location += m.fit
        }
        y += after
    }

    // MARK: Blocks

    func add(_ block: PDFBlock, imageLoader: (String) throws -> CGImage) throws {
        switch block {
        case .heading(let level, let text):
            let size = baseSize * [2.0, 1.6, 1.3, 1.12][min(level, 4) - 1]
            if y > 0 { y += size * 0.5 }
            if contentHeight - y < size * 3 { newPage() }  // keep a heading with what follows
            flow(inline(text, size: size, bold: true), after: size * 0.45)
        case .paragraph(let text):
            flow(inline(text, size: baseSize), after: baseSize * 0.75)
        case .bullet(let marker, let text):
            flow(inline(text, size: baseSize), indent: 20, after: baseSize * 0.3,
                 marker: NSAttributedString(string: marker, attributes: attributes("Helvetica", baseSize)))
        case .code(let code):
            flow(NSAttributedString(string: code.isEmpty ? " " : code, attributes: attributes("Menlo-Regular", baseSize * 0.85)), after: baseSize * 0.8, background: 0.94)
        case .rule:
            y += 4
            add(.line(CGPoint(x: margin, y: pageSize.height - margin - y), CGPoint(x: margin + contentWidth, y: pageSize.height - margin - y), 0.6))
            y += 10
        case .table(let rows, let hasHeader):
            table(rows, hasHeader: hasHeader)
        case .image(let alt, let path):
            let image = try imageLoader(path)
            let maxHeight = contentHeight * 0.75
            let scale = min(1, contentWidth / CGFloat(image.width), maxHeight / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            if contentHeight - y < h { newPage() }
            add(.image(image, rect(x: (contentWidth - w) / 2, top: y, width: w, height: h)))
            y += h + 4
            if !alt.isEmpty { flow(NSAttributedString(string: alt, attributes: attributes("Helvetica-Oblique", baseSize * 0.85, gray: 0.35)), after: baseSize * 0.6) }
            else { y += baseSize * 0.6 }
        }
    }

    private func table(_ rows: [[String]], hasHeader: Bool) {
        let columns = min(rows.map(\.count).max() ?? 0, 12)
        guard columns > 0 else { return }
        let cellWidth = contentWidth / CGFloat(columns), pad: CGFloat = 4, size = baseSize * 0.9
        for (index, row) in rows.enumerated() {
            let header = hasHeader && index == 0
            let cells: [(NSAttributedString, CTFramesetter)] = (0..<columns).map { c in
                let s = inline(c < row.count ? row[c] : "", size: size, bold: header)
                let text = s.length == 0 ? NSAttributedString(string: " ", attributes: attributes("Helvetica", size)) : s
                return (text, CTFramesetterCreateWithAttributedString(text))
            }
            let limit = contentHeight * 0.6
            let height = min(limit, cells.map { ceil(measure($0.1, from: 0, width: cellWidth - 2 * pad, height: limit).size.height) }.max() ?? size) + 2 * pad
            if contentHeight - y < height { newPage() }
            for (c, cell) in cells.enumerated() {
                let box = rect(x: CGFloat(c) * cellWidth, top: y, width: cellWidth, height: height)
                if header { add(.fill(box, 0.9)) }
                add(.stroke(box, 0.5))
                let inner = box.insetBy(dx: pad, dy: pad)
                add(.frame(CTFramesetterCreateFrame(cell.1, CFRange(location: 0, length: 0), CGPath(rect: inner, transform: nil), nil)))
            }
            y += height
        }
        y += baseSize * 0.8
    }

    // MARK: Output

    func write(to url: URL, title: String?, author: String?) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        var info: [CFString: Any] = [kCGPDFContextCreator: "ORIX OS Automation"]
        if let title { info[kCGPDFContextTitle] = title }
        if let author { info[kCGPDFContextAuthor] = author }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw ToolError.io("Cannot create a PDF at \(url.path)") }
        for (index, ops) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            for op in ops {
                switch op {
                case .frame(let f): CTFrameDraw(f, ctx)
                case .fill(let r, let gray): ctx.setFillColor(gray: gray, alpha: 1); ctx.fill(r)
                case .stroke(let r, let w): ctx.setStrokeColor(gray: 0.55, alpha: 1); ctx.setLineWidth(w); ctx.stroke(r)
                case .line(let a, let b, let w):
                    ctx.setStrokeColor(gray: 0.55, alpha: 1); ctx.setLineWidth(w); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                case .image(let image, let r): ctx.draw(image, in: r)
                }
            }
            let label = NSAttributedString(string: "\(index + 1) / \(pages.count)", attributes: attributes("Helvetica", 9, gray: 0.45))
            let line = CTLineCreateWithAttributedString(label)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: (pageSize.width - width) / 2, y: margin * 0.55)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

public struct DocumentsRenderPDFTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "documents.renderPDF", name: "Render a PDF report",
        summary: "Renders Markdown-like text into a paginated PDF: # headings, paragraphs with **bold** *italic* `code`, bullet and numbered lists, | tables |, ``` code blocks, --- rules, ![caption](image.png) images and page numbers.",
        family: "documents",
        inputSchema: Schema.input([
            "destination": .string("Path of the .pdf to create."), "content": .string("Markdown-like source."), "title": .string("Document title (also printed as the first heading)."),
            "author": .string(), "pageSize": .string("letter (default) or a4.", enum: ["letter", "a4"]),
            "fontSize": .integer("Body size in points (default 11).", minimum: 7, maximum: 24), "overwrite": .boolean(),
        ], required: ["destination", "content"]),
        outputSchema: Schema.output(["path": .string(), "pages": .integer(), "bytes": .integer()], required: ["path", "pages", "bytes"]),
        sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 180, supportsDryRun: true)

    func plan(_ input: ToolInput, _ context: ToolExecutionContext) throws -> (destination: String, blocks: [PDFBlock], images: [String: String]) {
        let destination = try input.path("destination", context)
        guard destination.lowercased().hasSuffix(".pdf") else { throw ToolError.invalidInput("destination must end with .pdf") }
        let blocks = PDFBlock.parse(try input.string("content"))
        var images: [String: String] = [:]
        for case .image(_, let raw) in blocks {
            guard !raw.contains("://") else { throw ToolError.unsupported("Remote images are not supported; give a local file path") }
            images[raw] = try PathResolver.canonical(raw, relativeTo: context.workingDirectory)
        }
        return (destination, blocks, images)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input, context)
        let caps = [Capability.fileWrite(path: p.destination)] + p.images.values.sorted().map { .fileRead(path: $0) }
        return ToolRequirements(capabilities: caps, tier: .reversibleWrite,
                                summary: "Render a PDF to \(show(p.destination))\(p.images.isEmpty ? "" : " with \(ToolSupport.plural(p.images.count, "image"))")")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input, context)
        let existing = ToolSupport.kind(of: p.destination)
        if existing.isDirectory { throw ToolError.invalidInput("\(show(p.destination)) is a directory") }
        if existing.exists && !input.bool("overwrite", default: false) {
            throw ToolError.invalidInput("\(show(p.destination)) already exists; pass overwrite: true to replace it (a backup is kept)")
        }
        for path in p.images.values { try ToolSupport.requireFile(path) }
        let size = input.optionalString("pageSize") == "a4" ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792)
        let composer = PDFComposer(pageSize: size, baseSize: CGFloat(input.int("fontSize", default: 11)))
        let title = input.optionalString("title")
        var blocks = p.blocks
        if let title, !title.isEmpty { blocks.insert(.heading(level: 1, text: title), at: 0) }
        for block in blocks {
            try Task.checkCancellation()
            try composer.add(block) { raw in
                guard let path = p.images[raw], let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ToolError.unsupported("Image \(raw) cannot be decoded")
                }
                return image
            }
        }
        if input.dryRun {
            return .simulated(["path": .string(p.destination), "pages": .int(composer.pageCount), "wouldReplace": .bool(existing.exists)],
                              summary: "Would render \(ToolSupport.plural(composer.pageCount, "page")) to \(show(p.destination))")
        }
        let parent = (p.destination as NSString).deletingLastPathComponent
        let staging = parent + "/.orix-render-" + UUID().uuidString.prefix(8) + ".pdf"
        var backup: String?
        try ToolSupport.io("Writing \(show(p.destination))") {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: staging) }
            try composer.write(to: URL(fileURLWithPath: staging), title: title, author: input.optionalString("author"))
            if existing.exists { backup = try ToolSupport.backup(p.destination, context: context); try fm.removeItem(atPath: p.destination) }
            try fm.moveItem(atPath: staging, toPath: p.destination)
        }
        return .success(["path": .string(p.destination), "pages": .int(composer.pageCount), "bytes": .int(ToolSupport.fileSize(p.destination)),
                         "backupPath": backup.map(JSONValue.string) ?? .null],
                        summary: "Rendered \(ToolSupport.plural(composer.pageCount, "page")) to \(show(p.destination))",
                        artifacts: [ToolSupport.artifact(p.destination, kind: "report", note: title ?? "Rendered PDF")])
    }
}
