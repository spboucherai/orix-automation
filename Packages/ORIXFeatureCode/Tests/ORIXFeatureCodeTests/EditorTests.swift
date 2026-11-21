// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Tests/ORIXFeatureCodeTests/EditorTests.swift
// Description      : Tests of the editor component without a window:
//                    incremental highlighting equals a full pass, diagnostics
//                    map to ranges, typing behaviours (soft tabs, auto-indent,
//                    pairing, comment toggle, snippets, undo), completion
//                    through the controller, and measured typing latency on a 5
//                    000-line file.
// Module           : ORIXFeatureCodeTests
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
import Foundation
import Testing
@testable import ORIXFeatureCode

@MainActor func makeEditor(_ text: String, _ language: CodeLanguage = .yaml) -> (CodeEditorContainer, CodeEditorController) {
    let editor = CodeEditorContainer(language: language)
    let controller = CodeEditorController()
    editor.controller = controller
    controller.container = editor
    editor.loadText(text)
    return (editor, controller)
}

@MainActor func type(_ editor: CodeEditorContainer, _ text: String) {
    for ch in text {
        if ch == "\n" { editor.textView.insertNewline(nil) }
        else if ch == "\t" { editor.textView.insertTab(nil) }
        else { editor.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }
}

func bigWorkflow(lines target: Int) -> String {
    var out = "apiVersion: orix.ai/v1\nkind: Automation\nmetadata:\n  id: big\n  name: Big\nspec:\n  steps:\n"
    var i = 0
    while out.split(separator: "\n", omittingEmptySubsequences: false).count < target {
        out += "    - id: step\(i)\n      name: \"Step number \(i)\"   # comment \(i)\n      tool: filesystem.list\n      with:\n        path: ${{ params.folder }}/item-\(i)\n        script: |\n          echo \"block \(i)\"\n      timeoutSeconds: \(i % 90 + 1)\n"
        i += 1
    }
    return out
}

@Suite("Unit · highlighter and diagnostics") struct HighlighterTests {
    @Test func incrementalUpdatesEqualAFullPass() {
        var rng = SeededGenerator(state: 7)
        let fragments = ["\n", "  key: value", "|", "\"", "#", "${{ a }}", "- ", ":", "x", "\n\n", "'''", "/*", "*/", "<<EOF\n", "EOF", "`"]
        for language in CodeLanguage.allCases {
            let text = NSMutableString(string: language == .yaml ? bigWorkflow(lines: 120) : ScriptTemplates.templates(.python)[0].body + ScriptTemplates.templates(.bash)[0].body)
            var incremental = SyntaxHighlighter(language: language)
            incremental.reset(text)
            for _ in 0..<150 {
                let location = Int.random(in: 0...text.length, using: &rng)
                let length = Bool.random(using: &rng) ? 0 : Int.random(in: 0...min(12, text.length - location), using: &rng)
                let replacement = Bool.random(using: &rng) ? fragments.randomElement(using: &rng)! : ""
                text.replaceCharacters(in: NSRange(location: location, length: length), with: replacement)
                let inserted = (replacement as NSString).length
                let dirty = incremental.update(text, editedRange: NSRange(location: location, length: inserted), changeInLength: inserted - length)
                var full = SyntaxHighlighter(language: language)
                full.reset(text)
                #expect(incremental.lineStarts == full.lineStarts)
                let all = 0...(full.lineCount - 1)
                #expect(incremental.tokens(text, lines: all) == full.tokens(text, lines: all), "\(language) diverged")
                #expect(dirty.lowerBound <= incremental.lineIndex(at: location))
            }
        }
    }

    @Test func anEditOnlyRetokenizesWhatItCanAffect() {
        let text = NSMutableString(string: bigWorkflow(lines: 2000))
        var h = SyntaxHighlighter(language: .yaml)
        h.reset(text)
        let location = h.lineStarts[1000] + 4
        text.insert("x", at: location)
        let dirty = h.update(text, editedRange: NSRange(location: location, length: 1), changeInLength: 1)
        #expect(dirty.count <= 2)
        // Opening a block scalar changes the state of the following lines until it converges.
        let keyLine = (text as NSString).range(of: "name: \"Step number 3\"")
        text.replaceCharacters(in: keyLine, with: "name: |")
        let wide = h.update(text, editedRange: NSRange(location: keyLine.location, length: 7), changeInLength: 7 - keyLine.length)
        #expect(wide.count >= 2 && wide.count < 20)
    }

    @Test func diagnosticsMapToTheTokenAtTheirPosition() {
        let text = "metadata:\n  id: demo\n  name: \"Two words\"  # c\n  tags: [a, bbb]\n\n  émoji: 😀 value\nlast" as NSString
        func piece(_ line: Int, _ column: Int) -> String { text.substring(with: DiagnosticMapper.range(line: line, column: column, in: text)) }
        #expect(piece(1, 1) == "metadata")
        #expect(piece(2, 3) == "id")
        #expect(piece(2, 7) == "demo")
        #expect(piece(3, 9) == "\"Two words\"")
        #expect(piece(4, 10) == "a")
        #expect(piece(4, 13) == "bbb")
        #expect(piece(6, 12) == "value")                          // columns count scalars, not UTF-16 units
        #expect(piece(7, 1) == "last")
        #expect(piece(2, 99) == "o")                               // past the end: last character of the line
        #expect(DiagnosticMapper.range(line: 5, column: 1, in: text).length == 0)   // empty line
        #expect(DiagnosticMapper.range(line: 0, column: 0, in: text) == NSRange(location: 0, length: 0))
        #expect(DiagnosticMapper.range(line: 40, column: 1, in: text).length == 0)
        #expect(piece(2, 1) == "id")                               // leading spaces are skipped
    }
}

@Suite("Unit · editor behaviour") @MainActor struct EditorBehaviourTests {
    @Test func softTabsAndAutoIndent() {
        let (yaml, _) = makeEditor("", .yaml)
        type(yaml, "spec:\nsteps:\n- id: a\nwith:\npath: y\n\tz")
        #expect(yaml.textView.string == "spec:\n  steps:\n    - id: a\n      with:\n        path: y\n          z")
        let (py, _) = makeEditor("", .python)
        type(py, "def f():\nreturn 1\n\tx")
        #expect(py.textView.string == "def f():\n    return 1\n        x")
        // Tab aligns to the next stop; backspace in leading spaces removes one stop.
        let (b, _) = makeEditor("ab", .python)
        b.textView.setSelectedRange(NSRange(location: 2, length: 0))
        b.textView.insertTab(nil)
        #expect(b.textView.string == "ab  ")
        let (d, _) = makeEditor("        x", .python)
        d.textView.setSelectedRange(NSRange(location: 8, length: 0))
        d.textView.deleteBackward(nil)
        #expect(d.textView.string == "    x")
        #expect(CodeLanguage.yaml.indentWidth == 2 && CodeLanguage.json.indentWidth == 2)
        #expect(CodeLanguage.python.indentWidth == 4 && CodeLanguage.swift.indentWidth == 4)
    }

    @Test func bracketAndQuotePairing() {
        let (e, _) = makeEditor("", .json)
        type(e, "{")
        #expect(e.textView.string == "{}")
        type(e, "\n")
        #expect(e.textView.string == "{\n  \n}")
        type(e, "\"k\": [1")
        #expect(e.textView.string == "{\n  \"k\": [1]\n}")
        type(e, "]")                                               // types over the closer
        #expect(e.textView.string == "{\n  \"k\": [1]\n}")
        // Deleting between a pair removes both.
        let (p, _) = makeEditor("", .python)
        type(p, "(")
        p.textView.deleteBackward(nil)
        #expect(p.textView.string == "")
        // An apostrophe inside a word is not paired; a selection is wrapped.
        type(p, "don't")
        #expect(p.textView.string == "don't")
        let (w, _) = makeEditor("value", .python)
        w.textView.setSelectedRange(NSRange(location: 0, length: 5))
        type(w, "\"")
        #expect(w.textView.string == "\"value\"")
        #expect(w.textView.selectedRange() == NSRange(location: 1, length: 5))
    }

    @Test func commentToggleAndBlockIndent() {
        let (e, _) = makeEditor("steps:\n  - id: a\n    tool: x\n\n  - id: b\n", .yaml)
        e.textView.setSelectedRange(NSRange(location: 8, length: 30))
        e.textView.toggleComment()
        #expect(e.textView.string == "steps:\n  # - id: a\n  #   tool: x\n\n  # - id: b\n")
        e.textView.toggleComment()
        #expect(e.textView.string == "steps:\n  - id: a\n    tool: x\n\n  - id: b\n")
        e.textView.insertTab(nil)
        #expect(e.textView.string == "steps:\n    - id: a\n      tool: x\n\n    - id: b\n")
        e.textView.insertBacktab(nil)
        e.textView.insertBacktab(nil)
        #expect(e.textView.string == "steps:\n- id: a\n  tool: x\n\n- id: b\n")
        let (s, _) = makeEditor("let a = 1", .swift)
        s.textView.toggleComment()
        #expect(s.textView.string == "// let a = 1")
        let (a, _) = makeEditor("set x to 1", .applescript)
        a.textView.toggleComment()
        #expect(a.textView.string == "-- set x to 1")
        #expect(CodeLanguage.json.lineComment == nil)
    }

    @Test func undoRestoresEveryProgrammaticEdit() {
        let (e, c) = makeEditor("one\n", .yaml)
        c.replaceAll(with: "two\nthree\n")
        #expect(e.textView.string == "two\nthree\n")
        e.textView.undoManager?.undo()
        #expect(e.textView.string == "one\n")
        e.textView.undoManager?.redo()
        #expect(e.textView.string == "two\nthree\n")
    }

    @Test func snippetsTakeTheIndentationOfTheCursor() {
        let base = "spec:\n  steps:\n    - id: a\n      delay: 1\n    "
        let (e, c) = makeEditor(base, .yaml)
        e.textView.setSelectedRange(NSRange(location: (base as NSString).length, length: 0))
        c.insertSnippet("- id: b\n  tool: x\n  with:\n    path: y\n")
        #expect(e.textView.string == "spec:\n  steps:\n    - id: a\n      delay: 1\n    - id: b\n      tool: x\n      with:\n        path: y\n")
        // In the middle of a line the snippet starts on its own line.
        #expect(CodeEditorController.indented("- id: c", forInsertionAt: 20, in: "  steps:\n    - id: a  # x" as NSString) == "\n    - id: c")
    }

    @Test func everyWorkflowSnippetParsesInsideAStepList() throws {
        for snippet in WorkflowSnippets.stepKinds + WorkflowSnippets.patterns {
            let base = "apiVersion: orix.ai/v1\nkind: Automation\nmetadata:\n  id: t\n  name: T\nspec:\n  steps:\n    "
            let (e, c) = makeEditor(base, .yaml)
            e.textView.setSelectedRange(NSRange(location: (base as NSString).length, length: 0))
            c.insertSnippet(snippet.body + "\n")
            let doc = try WorkflowCodec.parse(e.textView.string)
            #expect(!doc.spec.steps.isEmpty, "snippet \(snippet.id)")
        }
        let starter = WorkflowCodec.diagnose(source: WorkflowSnippets.starter, tools: [])
        #expect(starter.document != nil)
        #expect(Set(WorkflowSnippets.stepKinds.map(\.id)) == Set(CompletionEngine.stepKinds.map(\.0)))
    }

    @Test func squigglesFollowDiagnosticsAndEdits() {
        let (e, _) = makeEditor("a: 1\ntool: nope\nz: 3\n", .yaml)
        e.setDiagnostics([EditorDiagnostic(severity: .error, code: "unknown-tool", message: "unknown tool", line: 2, column: 7),
                          EditorDiagnostic(severity: .warning, message: "no position")])
        #expect(e.markRanges == [NSRange(location: 11, length: 4)])
        #expect(e.gutter.markers[1]?.0 == .error)
        #expect(e.textView.hoverText(at: 12) == "unknown tool")
        #expect(e.textView.hoverText(at: 1) == nil)
        // Typing above shifts the squiggle; typing inside it removes it until the next validation.
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type(e, "xy")
        #expect(e.markRanges == [NSRange(location: 13, length: 4)])
        e.textView.setSelectedRange(NSRange(location: 14, length: 0))
        type(e, "q")
        #expect(e.markRanges.isEmpty)
    }

    @Test func completionThroughTheController() {
        let (e, c) = makeEditor("steps:\n  - id: a\n    tool: ", .yaml)
        c.completionProvider = { text, cursor, explicit in
            let r = CompletionAnalyzer.analyze(text: text, cursor: cursor)
            guard explicit || r.automatic else { return nil }
            let items = CompletionEngine.candidates(r.context, catalog: CompletionCatalog(tools: sampleTools))
            return items.isEmpty ? nil : CompletionResult(items: items, replaceRange: r.replaceRange)
        }
        e.textView.setSelectedRange(NSRange(location: (e.textView.string as NSString).length, length: 0))
        type(e, "file")                                             // opens automatically while typing after `tool: `
        #expect(c.completion?.items.map(\.label) == ["filesystem.list", "filesystem.write"])
        c.moveCompletion(1)
        c.moveCompletion(1)
        c.moveCompletion(-1)
        #expect(c.completion?.selected == 1)
        c.acceptCompletion()
        #expect(e.textView.string == "steps:\n  - id: a\n    tool: filesystem.write")
        #expect(c.completion == nil)
        // Key positions need an explicit request.
        type(e, "\n")
        #expect(c.completion == nil)
        c.triggerCompletion(explicit: true)
        #expect(c.completion?.items.contains { $0.label == "with" } == true)
        c.dismissTransient()
        #expect(c.completion == nil)
        #expect(c.cursorLine == 4 && c.cursorColumn == 5)
    }

    @Test func goToLineAndOffsets() {
        let (e, c) = makeEditor("first\nsecond line\nthird\n", .yaml)
        c.goTo(line: 2, column: 8)
        #expect(e.textView.selectedRange() == NSRange(location: 13, length: 0))
        #expect(c.cursorLine == 2 && c.cursorColumn == 8)
        c.goTo(line: 99)
        #expect(c.cursorLine == 4)
        #expect(e.offset(line: 3, column: 1) == 18)
    }

    @Test func typingLatencyOnAFiveThousandLineFile() {
        let text = bigWorkflow(lines: 5000)
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(lineCount >= 5000)
        let loadStart = CFAbsoluteTimeGetCurrent()
        let (e, _) = makeEditor(text, .yaml)
        let load = CFAbsoluteTimeGetCurrent() - loadStart
        e.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        e.layoutSubtreeIfNeeded()
        let middle = e.offset(line: 2500, column: 12)
        e.textView.setSelectedRange(NSRange(location: middle, length: 0))
        var samples: [Double] = []
        for i in 0..<400 {
            let key = i % 40 == 39 ? "\n" : String("abcdefghij: ".randomElement()!)
            let started = CFAbsoluteTimeGetCurrent()
            if key == "\n" { e.textView.insertNewline(nil) } else { e.textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            e.textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: e.textView.selectedRange().location, length: 0))
            samples.append(CFAbsoluteTimeGetCurrent() - started)
        }
        samples.sort()
        let mean = samples.reduce(0, +) / Double(samples.count) * 1000
        let p95 = samples[Int(Double(samples.count) * 0.95)] * 1000
        let worst = (samples.last ?? 0) * 1000
        print(String(format: "LATENCY 5000-line YAML (%d lines, %d UTF-16 units): load+highlight %.1f ms; per keystroke mean %.3f ms, p95 %.3f ms, max %.3f ms (edit + incremental highlight + colour application, no window)",
                     lineCount, (text as NSString).length, load * 1000, mean, p95, worst))
        #expect(p95 < 16, "a keystroke must fit in one frame")
        #expect(e.textView.string.count >= text.count + 400)
        // The result is still coloured exactly like a full pass.
        var full = SyntaxHighlighter(language: .yaml)
        let ns = e.textView.string as NSString
        full.reset(ns)
        #expect(e.highlighter.tokens(ns, lines: 2490...2520) == full.tokens(ns, lines: 2490...2520))
    }
}
