// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/CodeEditor.swift
// Description      : The code editor component: the AppKit container (scroll
//                    view, text view, gutter, incremental colouring), the
//                    controller a screen uses to drive it (go to line,
//                    snippets, find, completion), and the SwiftUI view with its
//                    completion list and hover card.
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

public struct CompletionSession: Equatable, Sendable {
    public var items: [CompletionItem]
    public var selected: Int
    public var replaceRange: NSRange
    /// Where the list hangs, in the editor's coordinates (top-left origin).
    public var anchor: CGPoint
    public init(items: [CompletionItem], selected: Int = 0, replaceRange: NSRange, anchor: CGPoint) {
        self.items = items; self.selected = selected; self.replaceRange = replaceRange; self.anchor = anchor
    }
}

public struct HoverCard: Equatable, Sendable {
    public var text: String
    public var anchor: CGPoint
}

public struct CompletionResult: Sendable {
    public var items: [CompletionItem]
    public var replaceRange: NSRange
    public init(items: [CompletionItem], replaceRange: NSRange) { self.items = items; self.replaceRange = replaceRange }
}

/// Drives one `CodeEditor` from outside: the owner keeps it and calls it from buttons and menus.
@MainActor
@Observable
public final class CodeEditorController {
    @ObservationIgnored weak var container: CodeEditorContainer?
    public var completion: CompletionSession?
    public var hover: HoverCard?
    public private(set) var cursorLine = 1
    public private(set) var cursorColumn = 1
    public private(set) var selectionLength = 0
    /// Returns candidates for the text and cursor (UTF-16), or nil. `explicit` is true for ⌃Space.
    @ObservationIgnored public var completionProvider: ((_ text: String, _ cursor: Int, _ explicit: Bool) -> CompletionResult?)?
    /// ⌥-click on a character.
    @ObservationIgnored public var onOptionClick: ((Int) -> Void)?
    /// ⌘L inside the editor.
    @ObservationIgnored public var onGoToLineRequest: (() -> Void)?
    @ObservationIgnored private var accepting = false

    public init() {}

    public var isAttached: Bool { container != nil }
    public var text: String { container?.textView.string ?? "" }
    public var selectedRange: NSRange { container?.textView.selectedRange() ?? NSRange(location: 0, length: 0) }
    public var selectedText: String {
        guard let tv = container?.textView else { return "" }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }

    func cursorMoved(line: Int, column: Int, length: Int) {
        if cursorLine != line { cursorLine = line }
        if cursorColumn != column { cursorColumn = column }
        if selectionLength != length { selectionLength = length }
    }

    public func dismissTransient() {
        if completion != nil { completion = nil }
        if hover != nil { hover = nil }
    }

    public func focus() { if let tv = container?.textView { tv.window?.makeFirstResponder(tv) } }
    public func goTo(line: Int, column: Int = 1) { container?.goTo(line: line, column: column) }
    public func select(_ range: NSRange) { container?.select(range) }
    public func showFind(replace: Bool = false) { container?.showFind(replace: replace) }
    public func toggleComment() { container?.textView.toggleComment() }
    public func undo() { container?.textView.undoManager?.undo() }
    public func redo() { container?.textView.undoManager?.redo() }

    /// Replaces the whole buffer as one undoable edit.
    public func replaceAll(with text: String) {
        guard let tv = container?.textView else { return }
        tv.performEdit(NSRange(location: 0, length: (tv.string as NSString).length), text, select: NSRange(location: 0, length: 0))
    }

    public func replace(_ range: NSRange, with text: String) {
        guard let tv = container?.textView, NSMaxRange(range) <= (tv.string as NSString).length else { return }
        tv.performEdit(range, text, select: NSRange(location: range.location + (text as NSString).length, length: 0))
    }

    /// Inserts multi-line text at the cursor, indenting every following line like the cursor's line.
    public func insertSnippet(_ snippet: String) {
        guard let tv = container?.textView else { return }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let text = Self.indented(snippet, forInsertionAt: sel.location, in: ns)
        tv.performEdit(sel, text, select: NSRange(location: sel.location + (text as NSString).length, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        focus()
    }

    /// The snippet as it must be inserted at `location`: on a line that only holds indentation the snippet takes that
    /// indentation; in the middle of a line it starts on a new line with the line's indentation.
    public static func indented(_ snippet: String, forInsertionAt location: Int, in ns: NSString) -> String {
        let lineRange = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: min(location, ns.length) - lineRange.location))
        let leading = String(before.prefix { $0 == " " })
        let lines = snippet.components(separatedBy: "\n")
        let body = lines.enumerated().map { i, l in i == 0 || l.isEmpty ? l : leading + l }.joined(separator: "\n")
        return before.trimmingCharacters(in: .whitespaces).isEmpty ? body : "\n" + leading + body
    }

    // MARK: Completion

    public func triggerCompletion(explicit: Bool) {
        guard !accepting, let container, let provider = completionProvider else { completion = nil; return }
        let tv = container.textView
        let sel = tv.selectedRange()
        guard sel.length == 0, let result = provider(tv.string, sel.location, explicit), !result.items.isEmpty else { completion = nil; return }
        let keep = completion.flatMap { old in result.items.firstIndex { $0.id == old.items[safe: old.selected]?.id } } ?? 0
        completion = CompletionSession(items: result.items, selected: keep, replaceRange: result.replaceRange,
                                       anchor: container.anchor(forCharacterAt: result.replaceRange.location))
    }

    public func moveCompletion(_ delta: Int) {
        guard var c = completion, !c.items.isEmpty else { return }
        c.selected = (c.selected + delta + c.items.count) % c.items.count
        completion = c
    }

    public func acceptCompletion(_ index: Int? = nil) {
        guard let c = completion, let item = c.items[safe: index ?? c.selected], let tv = container?.textView else { return }
        completion = nil
        accepting = true
        tv.performEdit(c.replaceRange, item.insertText, select: NSRange(location: c.replaceRange.location + (item.insertText as NSString).length, length: 0))
        accepting = false
        // A candidate that ends where more is expected (`steps.`, `params.`) opens the next list.
        if item.insertText.hasSuffix(".") { triggerCompletion(explicit: false) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - AppKit container

@MainActor
public final class CodeEditorContainer: NSView, NSTextViewDelegate {
    public let scrollView = NSScrollView()
    public let textView: CodeTextView
    let gutter = GutterView()
    var highlighter: SyntaxHighlighter
    weak var controller: CodeEditorController?
    var onTextChange: ((String) -> Void)?
    var hovers: [EditorHover] = []
    private var diagnostics: [EditorDiagnostic] = []
    private var pendingDirty: ClosedRange<Int>?
    private var isLoading = false
    private var gutterWidth: CGFloat = 0
    /// Each editor has its own undo history, also when it is not in a window.
    private let undo = UndoManager()
    /// Seconds spent colouring after the last edit (measured, for the latency test).
    public private(set) var lastHighlightSeconds: Double = 0

    public override var isFlipped: Bool { true }

    public init(language: CodeLanguage) {
        highlighter = SyntaxHighlighter(language: language)
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))

        textView.editor = self
        textView.language = language
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = SyntaxTheme.font
        textView.textColor = SyntaxTheme.text
        textView.backgroundColor = SyntaxTheme.background
        textView.insertionPointColor = NSColor(Theme.violet)
        textView.selectedTextAttributes = [.backgroundColor: SyntaxTheme.selection]
        textView.typingAttributes = [.font: SyntaxTheme.font, .foregroundColor: SyntaxTheme.text]
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.setAccessibilityIdentifier("code.editor")
        textView.setAccessibilityLabel(String(localized: "Code editor"))

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = SyntaxTheme.background
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        gutter.editor = self
        addSubview(scrollView)
        addSubview(gutter)

        NotificationCenter.default.addObserver(self, selector: #selector(storageDidProcess(_:)), name: NSTextStorage.didProcessEditingNotification, object: storage)
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        updateGutterWidth()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func layout() {
        super.layout()
        gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
    }

    private func updateGutterWidth() {
        let w = GutterView.width(lineCount: highlighter.lineCount)
        if w != gutterWidth { gutterWidth = w; needsLayout = true }
        gutter.needsDisplay = true
    }

    public var language: CodeLanguage {
        get { highlighter.language }
        set {
            guard newValue != highlighter.language else { return }
            highlighter.language = newValue
            textView.language = newValue
            rehighlightAll()
        }
    }

    private var storageString: NSString { (textView.textStorage?.mutableString ?? NSMutableString()) as NSString }

    // MARK: Loading and colouring

    /// Replaces the document (not undoable): used when another file is opened.
    public func loadText(_ text: String) {
        isLoading = true
        textView.string = text
        textView.textStorage?.setAttributes([.font: SyntaxTheme.font, .foregroundColor: SyntaxTheme.text],
                                            range: NSRange(location: 0, length: storageString.length))
        isLoading = false
        pendingDirty = nil
        textView.undoManager?.removeAllActions()
        rehighlightAll()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        setDiagnostics(diagnostics)
        controller?.dismissTransient()
    }

    private func rehighlightAll() {
        highlighter.reset(storageString)
        applyColors(lines: 0...(highlighter.lineCount - 1))
        updateGutterWidth()
    }

    private func applyColors(lines: ClosedRange<Int>) {
        guard let lm = textView.layoutManager else { return }
        let text = storageString
        let range = highlighter.characterRange(lines: lines)
        guard NSMaxRange(range) <= text.length else { return }
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        for token in highlighter.tokens(text, lines: lines) where NSMaxRange(token.range) <= text.length {
            lm.addTemporaryAttribute(.foregroundColor, value: SyntaxTheme.color(token.kind), forCharacterRange: token.range)
        }
    }

    @objc private func storageDidProcess(_ note: Notification) {
        guard !isLoading, let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        let started = CFAbsoluteTimeGetCurrent()
        let range = storage.editedRange
        let delta = storage.changeInLength
        let linesBefore = highlighter.lineCount
        let dirty = highlighter.update(storage.mutableString, editedRange: range, changeInLength: delta)
        if let p = pendingDirty {
            // Several edits before the colours were applied: widen conservatively.
            let grow = abs(highlighter.lineCount - linesBefore)
            pendingDirty = min(p.lowerBound, dirty.lowerBound)...min(highlighter.lineCount - 1, max(p.upperBound + grow, dirty.upperBound))
        } else {
            pendingDirty = dirty
        }
        shiftAnnotations(editedRange: range, delta: delta)
        lastHighlightSeconds = CFAbsoluteTimeGetCurrent() - started
        DispatchQueue.main.async { [weak self] in self?.flushColors() }
    }

    private func flushColors() {
        guard let dirty = pendingDirty else { return }
        pendingDirty = nil
        let started = CFAbsoluteTimeGetCurrent()
        applyColors(lines: dirty.lowerBound...min(dirty.upperBound, highlighter.lineCount - 1))
        lastHighlightSeconds += CFAbsoluteTimeGetCurrent() - started
        updateGutterWidth()
    }

    /// Keeps squiggles and hover ranges attached to their text until the next validation replaces them.
    private func shiftAnnotations(editedRange: NSRange, delta: Int) {
        let oldEnd = editedRange.location + editedRange.length - delta
        func shifted(_ r: NSRange) -> NSRange? {
            if r.location >= oldEnd { return NSRange(location: r.location + delta, length: r.length) }
            if NSMaxRange(r) <= editedRange.location { return r }
            return nil
        }
        if !textView.marks.isEmpty {
            textView.marks = textView.marks.compactMap { m in shifted(m.range).map { EditorMark(range: $0, severity: m.severity, message: m.message, line: highlighter.lineIndex(at: $0.location)) } }
            refreshGutterMarkers()
        }
        if !hovers.isEmpty { hovers = hovers.compactMap { h in shifted(h.range).map { EditorHover(range: $0, text: h.text) } } }
    }

    // MARK: NSTextViewDelegate

    public func undoManager(for view: NSTextView) -> UndoManager? { undo }

    public func textDidChange(_ notification: Notification) {
        flushColors()
        onTextChange?(textView.string)
        controller?.hover = nil
        controller?.triggerCompletion(explicit: false)
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        let sel = textView.selectedRange()
        let line = highlighter.lineIndex(at: min(sel.location, storageString.length))
        controller?.cursorMoved(line: line + 1, column: sel.location - highlighter.lineStarts[line] + 1, length: sel.length)
        gutter.needsDisplay = true
        // Moving the caret away from what is being completed closes the list.
        if let c = controller?.completion, sel.length > 0 || sel.location < c.replaceRange.location { controller?.completion = nil }
    }

    @objc private func clipDidScroll(_ note: Notification) {
        gutter.needsDisplay = true
        guard let controller else { return }
        if controller.hover != nil { controller.hover = nil }
        // The list follows the text it completes.
        if var c = controller.completion {
            c.anchor = anchor(forCharacterAt: c.replaceRange.location)
            if c != controller.completion { controller.completion = c }
        }
    }

    // MARK: Diagnostics

    public func setDiagnostics(_ list: [EditorDiagnostic]) {
        diagnostics = list
        let text = storageString
        var marks: [EditorMark] = []
        for d in list where d.line > 0 && d.line <= highlighter.lineCount {
            let lr = highlighter.lineRange(d.line - 1)
            let r = DiagnosticMapper.range(column: d.column, start: lr.location, end: NSMaxRange(lr), in: text)
            marks.append(EditorMark(range: r, severity: d.severity, message: d.message, line: d.line - 1))
        }
        textView.marks = marks
        refreshGutterMarkers()
    }

    private func refreshGutterMarkers() {
        var out: [Int: (EditorDiagnostic.Severity, String)] = [:]
        for m in textView.marks {
            if let (s, text) = out[m.line] { out[m.line] = (min(s, m.severity), text + "\n" + m.message) } else { out[m.line] = (m.severity, m.message) }
        }
        gutter.markers = out
    }

    /// Ranges currently underlined (for tests).
    var markRanges: [NSRange] { textView.marks.map(\.range) }

    // MARK: Commands

    public func offset(line: Int, column: Int) -> Int {
        let l = max(0, min(line - 1, highlighter.lineCount - 1))
        let r = highlighter.lineRange(l)
        return r.location + max(0, min(column - 1, r.length))
    }

    public func goTo(line: Int, column: Int) {
        let location = offset(line: line, column: column)
        select(NSRange(location: location, length: 0))
        textView.showFindIndicator(for: DiagnosticMapper.range(column: column, start: highlighter.lineRange(max(0, min(line - 1, highlighter.lineCount - 1))).location,
                                                               end: NSMaxRange(highlighter.lineRange(max(0, min(line - 1, highlighter.lineCount - 1)))), in: storageString))
    }

    public func select(_ range: NSRange) {
        guard NSMaxRange(range) <= storageString.length else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performTextFinderAction(item)
    }

    public func showFind(replace: Bool) {
        textView.window?.makeFirstResponder(textView)
        find(replace ? .showReplaceInterface : .showFindInterface)
    }

    /// Bottom-left of a character, in this view's coordinates: where a completion list or hover card hangs.
    func anchor(forCharacterAt index: Int) -> CGPoint {
        guard let lm = textView.layoutManager else { return .zero }
        let length = storageString.length
        var rect: NSRect
        if length == 0 || (index >= length && storageString.character(at: length - 1) == 10) {
            rect = lm.extraLineFragmentRect
        } else {
            let i = min(index, length - 1)
            let glyph = lm.glyphIndexForCharacter(at: i)
            rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = lm.location(forGlyphAt: glyph).x
            rect.origin.x += x
            if index >= length { rect.origin.x += lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textView.textContainer!).width }
        }
        let origin = textView.textContainerOrigin
        let p = convert(NSPoint(x: rect.minX + origin.x, y: rect.maxY + origin.y), from: textView)
        return CGPoint(x: p.x, y: p.y)
    }
}

// MARK: - SwiftUI

struct CodeEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage
    var diagnostics: [EditorDiagnostic]
    var hovers: [EditorHover]
    var controller: CodeEditorController
    var isEditable: Bool

    @MainActor final class Coordinator {
        var shownDiagnostics: [EditorDiagnostic] = []
        var shownHovers: [EditorHover] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CodeEditorContainer {
        let view = CodeEditorContainer(language: language)
        view.controller = controller
        controller.container = view
        view.loadText(text)
        let binding = $text
        view.onTextChange = { new in if binding.wrappedValue != new { binding.wrappedValue = new } }
        return view
    }

    func updateNSView(_ view: CodeEditorContainer, context: Context) {
        if view.controller !== controller { view.controller = controller }
        if controller.container !== view { controller.container = view }
        let binding = $text
        view.onTextChange = { new in if binding.wrappedValue != new { binding.wrappedValue = new } }
        view.language = language
        view.textView.isEditable = isEditable
        if view.textView.string != text { view.loadText(text) }
        if context.coordinator.shownDiagnostics != diagnostics {
            context.coordinator.shownDiagnostics = diagnostics
            view.setDiagnostics(diagnostics)
        }
        if context.coordinator.shownHovers != hovers {
            context.coordinator.shownHovers = hovers
            view.hovers = hovers
        }
    }
}

/// A native code editor. The text is the binding; everything else goes through the controller.
public struct CodeEditor: View {
    @Binding var text: String
    var language: CodeLanguage
    var diagnostics: [EditorDiagnostic]
    var hovers: [EditorHover]
    var controller: CodeEditorController
    var isEditable: Bool

    public init(text: Binding<String>, language: CodeLanguage, diagnostics: [EditorDiagnostic] = [], hovers: [EditorHover] = [],
                controller: CodeEditorController, isEditable: Bool = true) {
        _text = text; self.language = language; self.diagnostics = diagnostics; self.hovers = hovers
        self.controller = controller; self.isEditable = isEditable
    }

    public var body: some View {
        GeometryReader { geo in
            CodeEditorRepresentable(text: $text, language: language, diagnostics: diagnostics, hovers: hovers, controller: controller, isEditable: isEditable)
                .overlay(alignment: .topLeading) {
                    if let session = controller.completion {
                        let height = CompletionList.height(for: session)
                        let below = session.anchor.y + 4 + height <= geo.size.height
                        CompletionList(session: session) { controller.acceptCompletion($0) }
                            .offset(x: max(4, min(session.anchor.x, geo.size.width - CompletionList.width - 8)),
                                    y: below ? session.anchor.y + 4 : max(4, session.anchor.y - 22 - height))
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hover = controller.hover, controller.completion == nil {
                        HoverCardView(text: hover.text)
                            .offset(x: max(4, min(hover.anchor.x, geo.size.width - 380)), y: min(hover.anchor.y + 4, max(4, geo.size.height - 120)))
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct CompletionList: View {
    let session: CompletionSession
    let onPick: (Int) -> Void
    static let width: CGFloat = 430
    static let rowHeight: CGFloat = 24
    static func height(for session: CompletionSession) -> CGFloat {
        CGFloat(min(session.items.count, 8)) * rowHeight + 8 + (session.items[safe: session.selected]?.documentation.isEmpty == false ? 44 : 0)
    }

    private func symbol(_ kind: CompletionItem.Kind) -> String {
        switch kind {
        case .tool: return "wrench.and.screwdriver"
        case .argument: return "slider.horizontal.3"
        case .step: return "smallcircle.filled.circle"
        case .function: return "function"
        case .variable: return "curlybraces"
        case .keyword: return "bolt"
        case .key: return "key"
        case .value: return "textformat"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(session.items.enumerated()), id: \.element.id) { i, item in
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: symbol(item.kind)).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.violet).frame(width: 16)
                                Text(item.label).font(Theme.Font.mono).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer(minLength: Theme.Space.s)
                                Text(item.detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            .padding(.horizontal, Theme.Space.s)
                            .frame(height: Self.rowHeight)
                            .background(i == session.selected ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(i) }
                            .id(i)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(i == session.selected ? .isSelected : [])
                        }
                    }
                    .padding(4)
                }
                .frame(height: CGFloat(min(session.items.count, 8)) * Self.rowHeight + 8)
                .onChange(of: session.selected) { _, new in proxy.scrollTo(new) }
            }
            if let doc = session.items[safe: session.selected]?.documentation, !doc.isEmpty {
                Divider()
                Text(doc).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, 7)
            }
        }
        .frame(width: Self.width)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.strokeStrong))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .accessibilityIdentifier("code.completion")
        .accessibilityLabel(Text("Completions"))
    }
}

struct HoverCardView: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).lineLimit(12)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Theme.Space.m)
            .frame(maxWidth: 370, alignment: .leading)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.strokeStrong))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .allowsHitTesting(false)
    }
}
