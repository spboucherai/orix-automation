// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Tests/ORIXFeatureCodeTests/DiffAndConsoleTests.swift
// Description      : Unit tests of the line diff (property: applying a diff
//                    reproduces the target) and of the console buffer (ANSI
//                    parsing, bounded scrollback).
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

import Foundation
import Testing
@testable import ORIXFeatureCode

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Suite("Unit · line diff") struct LineDiffTests {
    @Test func identicalTextsHaveNoChange() {
        let d = LineDiff(old: "a\nb\nc\n", new: "a\nb\nc\n")
        #expect(d.isEmpty)
        #expect(d.lines.count == 3)
        #expect(DiffRow.unified(d).count == 3)
    }

    @Test func countsAndNumbers() {
        let d = LineDiff(old: "a\nb\nc\nd\n", new: "a\nB\nc\nd\ne\n")
        #expect(d.added == 2)
        #expect(d.removed == 1)
        let removed = d.lines.first { $0.kind == .removed }
        #expect(removed?.text == "b")
        #expect(removed?.oldNumber == 2)
        #expect(d.lines.last?.newNumber == 5)
    }

    @Test func applyingADiffReproducesTheTarget() {
        var rng = SeededGenerator(state: 42)
        let alphabet = ["alpha", "beta", "gamma", "delta", "", "  indented", "x", "y", "z"]
        for round in 0..<400 {
            let n = Int.random(in: 0...40, using: &rng)
            let old = (0..<n).map { _ in alphabet.randomElement(using: &rng)! }
            var new = old
            for _ in 0..<Int.random(in: 0...12, using: &rng) {
                switch Int.random(in: 0...2, using: &rng) {
                case 0: new.insert(alphabet.randomElement(using: &rng)! + "\(round)", at: Int.random(in: 0...new.count, using: &rng))
                case 1: if !new.isEmpty { new.remove(at: Int.random(in: 0..<new.count, using: &rng)) }
                default: if !new.isEmpty { new[Int.random(in: 0..<new.count, using: &rng)] = alphabet.randomElement(using: &rng)! }
                }
            }
            let d = LineDiff(old: old, new: new)
            #expect(d.apply(to: old) == new)
            #expect(d.lines.filter { $0.kind != .added }.map(\.text) == old)
            #expect(d.lines.filter { $0.kind != .removed }.map(\.text) == new)
            #expect(d.added == d.lines.filter { $0.kind == .added }.count)
            // Side-by-side rows carry every line exactly once per side.
            let rows = DiffRow.sideBySide(d, context: 1000)
            let left = rows.compactMap { r -> String? in if case .pair(_, let l, _) = r { return l?.text }; return nil }
            let right = rows.compactMap { r -> String? in if case .pair(_, _, let rr) = r { return rr?.text }; return nil }
            #expect(left == old)
            #expect(right == new)
        }
    }

    @Test func theDiffIsMinimalOnSmallInputs() {
        // One line replaced in the middle: exactly one removal and one addition.
        let old = (1...200).map { "line \($0)" }
        var new = old; new[100] = "changed"
        let d = LineDiff(old: old, new: new)
        #expect(d.added == 1 && d.removed == 1)
        // Context collapsing leaves a gap on each side.
        let rows = DiffRow.unified(d, context: 3)
        #expect(rows.filter { if case .gap = $0 { return true }; return false }.count == 2)
        #expect(rows.count == 2 + 3 + 2 + 3)
    }

    @Test func hugeUnrelatedInputsFallBackButStayCorrect() {
        let old = (0..<3000).map { "old \($0)" }, new = (0..<3000).map { "new \($0)" }
        let d = LineDiff(old: old, new: new)
        #expect(d.apply(to: old) == new)
        #expect(d.added == 3000 && d.removed == 3000)
    }
}

@Suite("Unit · console") @MainActor struct ConsoleTests {
    @Test func ansiColoursAreRenderedAndOtherSequencesRemoved() {
        var p = ANSIParser()
        let lines = p.feed("plain \u{1B}[31mred \u{1B}[1mbold\u{1B}[0m back\u{1B}[2K\u{1B}]0;title\u{07}\n\u{1B}[38;5;2mgreen\u{1B}[39m \u{1B}[38;2;1;2;3mrgb\u{1B}[0m\n")
        #expect(lines.count == 2)
        #expect(lines[0].map(\.text) == ["plain ", "red ", "bold", " back"])
        #expect(lines[0].map(\.color) == [nil, 1, 1, nil])
        #expect(lines[0].map(\.bold) == [false, false, true, false])
        #expect(lines[1].first?.color == 2)
        #expect(lines[1].map(\.text).joined() == "green rgb")
    }

    @Test func escapeSequencesSplitAcrossChunksAndCarriageReturns() {
        var p = ANSIParser()
        #expect(p.feed("ab\u{1B}[3").isEmpty)
        let lines = p.feed("2mgreen\u{1B}[0m\r\nprogress 10%\rprogress 100%\n")
        #expect(lines.count == 2)
        #expect(lines[0].map(\.text) == ["ab", "green"])
        #expect(lines[0][1].color == 2)
        #expect(lines[1].map(\.text).joined() == "progress 100%")
        #expect(p.feed("tail without newline").isEmpty)
        #expect(p.finish()?.map(\.text).joined() == "tail without newline")
    }

    @Test func scrollbackIsBoundedAndSaysSo() {
        let buffer = ConsoleBuffer(capacity: 100)
        buffer.append((0..<250).map { "line \($0)\n" }.joined())
        #expect(buffer.lines.count == 100)
        #expect(buffer.dropped == 150)
        #expect(buffer.lines.first?.text == "line 150")
        #expect(buffer.lines.last?.text == "line 249")
        buffer.append("partial", stream: .stderr)
        #expect(buffer.lines.count == 100)
        buffer.flush()
        #expect(buffer.lines.last?.text == "partial")
        #expect(buffer.lines.last?.stream == .stderr)
        #expect(buffer.dropped == 151)
        #expect(ConsoleBuffer.capacity == 20_000)
        buffer.clear()
        #expect(buffer.lines.isEmpty && buffer.dropped == 0)
    }
}
