// ORIX OS Automation
// File: Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/CodeTextView.swift
// Description: The AppKit side of the code editor: an NSTextView (TextKit 1) with soft tabs, auto-indent, bracket and quote pairing, comment toggling, current-line highlight and squiggles, a line-number gutter with problem markers, and incremental syntax colouring.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI

/// A problem placed on the text.
struct EditorMark {
    var range: NSRange
    var severity: EditorDiagnostic.Severity
    var message: String
    var line: Int
}

@MainActor
public final class CodeTextView: NSTextView {
    weak var editor: CodeEditorContainer?
    var language: CodeLanguage = .yaml
    var marks: [EditorMark] = [] { didSet { needsDisplay = true } }
    private var hoverTask: Task<Void, Never>?
    private var hoverArea: NSTrackingArea?

    private var ns: NSString { (textStorage?.mutableString ?? NSMutableString()) as NSString }
    private var indentUnit: String { String(repeating: " ", count: language.indentWidth) }

    // MARK: Editing primitives

    /// One undoable replacement, with the editor's typing attributes.
    func performEdit(_ range: NSRange, _ replacement: String, select: NSRange? = nil) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: typingAttributes))
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    private func character(at index: Int) -> unichar? { index >= 0 && index < ns.length ? ns.character(at: index) : nil }

    private static let pairs: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
    private static let closers: Set<unichar> = [41, 93, 125]
    private func isQuote(_ c: unichar) -> Bool { c == 34 || c == 39 || (c == 96 && (language == .bash || language == .javascript)) }
    private func isWordCharacter(_ c: unichar?) -> Bool {
        guard let c else { return false }
        return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
    }
    private func canPairBefore(_ next: unichar?) -> Bool {
        guard let next else { return true }
        return next == 32 || next == 9 || next == 10 || next == 13 || next == 44 || next == 58 || Self.closers.contains(next)
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let typed = string as? String, typed.utf16.count == 1, !hasMarkedText(), let c = typed.utf16.first else {
            super.insertText(string, replacementRange: replacementRange); return
        }
        let sel = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let next = character(at: NSMaxRange(sel))
        if sel.length == 0, next == c, Self.closers.contains(c) || isQuote(c) {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))   // type over the closer
            return
        }
        if let close = Self.pairs[c] {
            let closing = String(utf16CodeUnits: [close], count: 1)
            if sel.length > 0 {
                let inner = ns.substring(with: sel)
                performEdit(sel, typed + inner + closing, select: NSRange(location: sel.location + 1, length: sel.length))
                return
            }
            if canPairBefore(next) {
                performEdit(sel, typed + closing, select: NSRange(location: sel.location + 1, length: 0))
                return
            }
        } else if isQuote(c) {
            if sel.length > 0 {
                let inner = ns.substring(with: sel)
                performEdit(sel, typed + inner + typed, select: NSRange(location: sel.location + 1, length: sel.length))
                return
            }
            let previous = character(at: sel.location - 1)
            if !isWordCharacter(previous), previous != c, canPairBefore(next) {
                performEdit(sel, typed + typed, select: NSRange(location: sel.location + 1, length: 0))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    public override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length == 0, sel.location > 0, let previous = character(at: sel.location - 1) {
            let next = character(at: sel.location)
            if let next, Self.pairs[previous] == next || (isQuote(previous) && previous == next) {
                performEdit(NSRange(location: sel.location - 1, length: 2), "", select: NSRange(location: sel.location - 1, length: 0))
                return
            }
            // Soft tab: delete back to the previous indentation stop when only spaces precede the cursor.
            let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
            let column = sel.location - lineStart
            if column > 1, (lineStart..<sel.location).allSatisfy({ ns.character(at: $0) == 32 }) {
                let remove = column % language.indentWidth == 0 ? language.indentWidth : column % language.indentWidth
                performEdit(NSRange(location: sel.location - remove, length: remove), "", select: NSRange(location: sel.location - remove, length: 0))
                return
            }
        }
        super.deleteBackward(sender)
    }

    public override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        let leading = String(before.prefix { $0 == " " || $0 == "\t" })
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        var indent = leading
        if language == .yaml, trimmed.hasPrefix("- ") { indent += "  " }
        var opens = false
        if let last = trimmed.last {
            if "{[(".contains(last) { opens = true }
            else if last == ":", language == .yaml || language == .python { opens = true }
            else if language == .bash, ["then", "do", "else", "{"].contains(where: { trimmed.hasSuffix($0) }) { opens = true }
            else if language == .yaml, trimmed.hasSuffix(": |") || trimmed.hasSuffix(": >") || trimmed.hasSuffix(": |-") { opens = true }
        }
        if opens { indent += indentUnit }
        let next = character(at: NSMaxRange(sel))
        if opens, let last = trimmed.utf16.last, let next, Self.pairs[last] == next {
            // Between a bracket pair: put the closer on its own line.
            performEdit(sel, "\n" + indent + "\n" + leading, select: NSRange(location: sel.location + 1 + indent.utf16.count, length: 0))
        } else {
            performEdit(sel, "\n" + indent, select: NSRange(location: sel.location + 1 + indent.utf16.count, length: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    public override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0, ns.substring(with: sel).contains("\n") { shiftSelectedLines(indent: true); return }
        let lineStart = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let column = sel.location - lineStart
        let count = language.indentWidth - column % language.indentWidth
        performEdit(sel, String(repeating: " ", count: count), select: NSRange(location: sel.location + count, length: 0))
    }

    public override func insertBacktab(_ sender: Any?) { shiftSelectedLines(indent: false) }

    /// Rewrites the lines touched by the selection through `transform` as one undoable edit and keeps them selected.
    private func rewriteSelectedLines(_ transform: ([String]) -> [String]) {
        let sel = selectedRange()
        var block = ns.lineRange(for: sel)
        let endsWithNewline = block.length > 0 && ns.character(at: NSMaxRange(block) - 1) == 10
        if endsWithNewline { block.length -= 1 }
        let lines = ns.substring(with: block).components(separatedBy: "\n")
        let out = transform(lines).joined(separator: "\n")
        guard out != ns.substring(with: block) else { return }
        performEdit(block, out, select: NSRange(location: block.location, length: (out as NSString).length))
    }

    func shiftSelectedLines(indent: Bool) {
        let unit = indentUnit
        let width = language.indentWidth
        rewriteSelectedLines { lines in
            lines.map { line in
                if indent { return line.isEmpty ? line : unit + line }
                let spaces = line.prefix { $0 == " " }.count
                return String(line.dropFirst(min(spaces, width)))
            }
        }
    }

    /// Comments or uncomments the selected lines with the language's line comment.
    func toggleComment() {
        guard let prefix = language.lineComment else { NSSound.beep(); return }
        rewriteSelectedLines { lines in
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !content.isEmpty else { return lines }
            let allCommented = content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }
            if allCommented {
                return lines.map { line in
                    guard let r = line.range(of: prefix) else { return line }
                    var rest = line[r.upperBound...]
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    return String(line[..<r.lowerBound]) + rest
                }
            }
            let column = content.map { $0.prefix { $0 == " " }.count }.min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let i = line.index(line.startIndex, offsetBy: column)
                return String(line[..<i]) + prefix + " " + line[i...]
            }
        }
    }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) {
        let controller = editor?.controller
        if let controller, controller.completion != nil {
            switch event.keyCode {
            case 125: controller.moveCompletion(1); return
            case 126: controller.moveCompletion(-1); return
            case 36, 76, 48: controller.acceptCompletion(); return
            case 53: controller.completion = nil; return
            default: break
            }
        }
        if event.keyCode == 49, event.modifierFlags.contains(.control) { controller?.triggerCompletion(explicit: true); return }
        controller?.hover = nil
        super.keyDown(with: event)
    }

    public override func cancelOperation(_ sender: Any?) { editor?.controller?.dismissTransient() }
    public override func complete(_ sender: Any?) { editor?.controller?.triggerCompletion(explicit: true) }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case ([.command], "f"): editor?.showFind(replace: false); return true
        case ([.command, .option], "f"): editor?.showFind(replace: true); return true
        case ([.command], "g"): editor?.find(.nextMatch); return true
        case ([.command, .shift], "g"): editor?.find(.previousMatch); return true
        case ([.command], "/"): toggleComment(); return true
        case ([.command], "l"):
            if let request = editor?.controller?.onGoToLineRequest { request(); return true }
        default: break
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        editor?.controller?.dismissTransient()
        if event.modifierFlags.contains(.option), let index = characterIndex(at: convert(event.locationInWindow, from: nil)),
           let handler = editor?.controller?.onOptionClick {
            handler(index)
            return
        }
        super.mouseDown(with: event)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// The character under a point of the view, or nil when the point is not on a glyph.
    func characterIndex(at point: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, ns.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = lm.glyphIndex(for: p, in: tc)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).insetBy(dx: -1, dy: -1).contains(p) else { return nil }
        return lm.characterIndexForGlyph(at: glyph)
    }

    /// What hovering a character should show: problems first, then documentation.
    func hoverText(at index: Int) -> String? {
        var parts = marks.filter { NSLocationInRange(index, $0.range) }.map(\.message)
        parts += (editor?.hovers ?? []).filter { NSLocationInRange(index, $0.range) }.map(\.text)
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoverTask?.cancel()
        let point = convert(event.locationInWindow, from: nil)
        guard let index = characterIndex(at: point), let text = hoverText(at: index) else {
            if editor?.controller?.hover != nil { editor?.controller?.hover = nil }
            return
        }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let self, let editor = self.editor else { return }
            editor.controller?.hover = HoverCard(text: text, anchor: editor.anchor(forCharacterAt: index))
        }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverTask?.cancel()
        editor?.controller?.hover = nil
    }

    // MARK: Drawing

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, selectedRange().length == 0 else { return }
        let sel = selectedRange()
        var lineRect: NSRect
        if sel.location >= ns.length, ns.length == 0 || ns.character(at: ns.length - 1) == 10 {
            lineRect = lm.extraLineFragmentRect
        } else {
            let glyph = lm.glyphIndexForCharacter(at: min(sel.location, max(0, ns.length - 1)))
            lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        guard lineRect.height > 0 else { return }
        lineRect.origin.y += textContainerOrigin.y
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        SyntaxTheme.text.withAlphaComponent(0.055).setFill()
        lineRect.intersection(rect).fill()
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !marks.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let origin = textContainerOrigin
        let visibleGlyphs = lm.glyphRange(forBoundingRect: visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let visible = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        for mark in marks where mark.range.length > 0 && NSMaxRange(mark.range) <= ns.length && NSIntersectionRange(mark.range, visible).length > 0 {
            let glyphs = lm.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            let color = SyntaxTheme.color(mark.severity)
            lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
                let y = rect.maxY + origin.y - 1.5
                let path = NSBezierPath()
                var x = rect.minX + origin.x
                let end = max(rect.maxX + origin.x, x + 6)
                var up = true
                path.move(to: NSPoint(x: x, y: y))
                while x < end {
                    x += 2.5
                    path.line(to: NSPoint(x: min(x, end), y: y + (up ? -2.2 : 0)))
                    up.toggle()
                }
                path.lineWidth = 1.1
                color.setStroke()
                path.stroke()
            }
        }
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true   // the current-line band moves
    }
}

// MARK: - Gutter

@MainActor
final class GutterView: NSView {
    weak var editor: CodeEditorContainer?
    /// Worst severity and messages per line index.
    var markers: [Int: (EditorDiagnostic.Severity, String)] = [:] { didSet { needsDisplay = true } }
    private var area: NSTrackingArea?
    override var isFlipped: Bool { true }

    static func width(lineCount: Int) -> CGFloat {
        let digits = max(3, String(lineCount).count)
        let glyph = ("0" as NSString).size(withAttributes: [.font: SyntaxTheme.gutterFont]).width
        return ceil(CGFloat(digits) * glyph) + 30
    }

    /// Top and height (in gutter coordinates) of every visible line.
    private func visibleLines() -> [(line: Int, y: CGFloat, height: CGFloat)] {
        guard let editor, let lm = editor.textView.layoutManager, let tc = editor.textView.textContainer else { return [] }
        let tv = editor.textView
        let origin = tv.textContainerOrigin
        let length = (tv.string as NSString).length
        let highlighter = editor.highlighter
        var out: [(Int, CGFloat, CGFloat)] = []
        let glyphs = lm.glyphRange(forBoundingRect: tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = highlighter.lineIndex(at: chars.location)
        while line < highlighter.lineCount {
            let start = highlighter.lineStarts[line]
            if start > NSMaxRange(chars) { break }
            var rect: NSRect
            if start >= length {
                rect = lm.extraLineFragmentRect
                if rect.height == 0 { break }
            } else {
                rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let y = convert(NSPoint(x: 0, y: rect.minY + origin.y), from: tv).y
            out.append((line, y, rect.height))
            line += 1
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        SyntaxTheme.gutterBackground.setFill()
        bounds.fill()
        NSColor(Theme.stroke).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        guard let editor else { return }
        let current = editor.highlighter.lineIndex(at: editor.textView.selectedRange().location)
        for (line, y, height) in visibleLines() {
            let isCurrent = line == current
            let attributes: [NSAttributedString.Key: Any] = [.font: SyntaxTheme.gutterFont, .foregroundColor: isCurrent ? SyntaxTheme.text : SyntaxTheme.gutterText]
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.maxX - 8 - size.width, y: y + (height - size.height) / 2), withAttributes: attributes)
            if let (severity, _) = markers[line] {
                let color = SyntaxTheme.color(severity)
                color.setFill()
                let box = NSRect(x: 6, y: y + (height - 9) / 2, width: 9, height: 9)
                // Shape as well as colour: a diamond for errors, a triangle for warnings, a dot for notes.
                let path = NSBezierPath()
                switch severity {
                case .error:
                    path.move(to: NSPoint(x: box.midX, y: box.minY)); path.line(to: NSPoint(x: box.maxX, y: box.midY))
                    path.line(to: NSPoint(x: box.midX, y: box.maxY)); path.line(to: NSPoint(x: box.minX, y: box.midY)); path.close()
                case .warning:
                    path.move(to: NSPoint(x: box.midX, y: box.minY)); path.line(to: NSPoint(x: box.maxX, y: box.maxY))
                    path.line(to: NSPoint(x: box.minX, y: box.maxY)); path.close()
                case .info: path.appendOval(in: box.insetBy(dx: 1.5, dy: 1.5))
                }
                path.fill()
            }
        }
    }

    private func line(at point: NSPoint) -> Int? {
        visibleLines().first { point.y >= $0.y && point.y < $0.y + $0.height }?.line
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let line = line(at: p), let (_, message) = markers[line] { toolTip = message } else { toolTip = nil }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let editor, let line = line(at: p) else { return }
        editor.goTo(line: line + 1, column: 1)
        if let (_, message) = markers[line] {
            editor.controller?.hover = HoverCard(text: message, anchor: CGPoint(x: frame.maxX + 4, y: p.y + 10))
        }
    }

    override func accessibilityLabel() -> String? { String(localized: "Line numbers") }
}
