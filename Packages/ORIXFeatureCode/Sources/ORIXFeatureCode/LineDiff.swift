// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/LineDiff.swift
// Description      : Line diff (Myers O(ND) with common prefix/suffix trimming
//                    and a bounded fallback), plus the row models for unified
//                    and side-by-side display with collapsed context.
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

import Foundation

public struct DiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case same, added, removed }
    public var kind: Kind
    public var text: String
    /// 1-based line numbers in the old and new text.
    public var oldNumber: Int?
    public var newNumber: Int?
    public var id: Int
}

public struct LineDiff: Sendable, Hashable {
    public var lines: [DiffLine]
    public var added: Int
    public var removed: Int
    public var isEmpty: Bool { added == 0 && removed == 0 }

    public static func split(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }   // a trailing newline does not make an extra line
        return parts
    }

    public init(old: String, new: String) { self.init(old: Self.split(old), new: Self.split(new)) }

    public init(old: [String], new: [String]) {
        var out: [DiffLine] = []
        out.reserveCapacity(max(old.count, new.count))
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let a = Array(old[prefix..<(old.count - suffix)]), b = Array(new[prefix..<(new.count - suffix)])
        var added = 0, removed = 0
        func push(_ kind: DiffLine.Kind, _ text: String, _ o: Int?, _ n: Int?) {
            out.append(DiffLine(kind: kind, text: text, oldNumber: o, newNumber: n, id: out.count))
        }
        for i in 0..<prefix { push(.same, old[i], i + 1, i + 1) }
        var i = 0, j = 0
        for op in Self.myers(a, b) {
            switch op {
            case .same: push(.same, a[i], prefix + i + 1, prefix + j + 1); i += 1; j += 1
            case .removed: push(.removed, a[i], prefix + i + 1, nil); i += 1; removed += 1
            case .added: push(.added, b[j], nil, prefix + j + 1); j += 1; added += 1
            }
        }
        for k in 0..<suffix { push(.same, old[old.count - suffix + k], old.count - suffix + k + 1, new.count - suffix + k + 1) }
        lines = out; self.added = added; self.removed = removed
    }

    /// Rebuilds the new text's lines from the old ones: equal lines are taken from `old`, added lines from the diff.
    public func apply(to old: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        for l in lines {
            switch l.kind {
            case .same: out.append(old[i]); i += 1
            case .removed: i += 1
            case .added: out.append(l.text)
            }
        }
        return out
    }

    /// Largest edit distance explored before falling back to "replace the whole middle".
    static let maxDistance = 2_000

    static func myers(_ a: [String], _ b: [String]) -> [DiffLine.Kind] {
        let n = a.count, m = b.count
        if n == 0 { return [DiffLine.Kind](repeating: .added, count: m) }
        if m == 0 { return [DiffLine.Kind](repeating: .removed, count: n) }
        // Compare integers instead of strings.
        var ids: [String: Int32] = [:]
        func id(_ s: String) -> Int32 { if let v = ids[s] { return v }; let v = Int32(ids.count); ids[s] = v; return v }
        let x = a.map(id), y = b.map(id)
        let limit = min(n + m, maxDistance)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var found = -1
        search: for d in 0...limit {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))   // only the diagonals this round can read
            var k = -d
            while k <= d {
                var i = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var j = i - k
                while i < n, j < m, x[i] == y[j] { i += 1; j += 1 }
                v[offset + k] = i
                if i >= n, j >= m { found = d; break search }
                k += 2
            }
        }
        guard found >= 0 else {
            return [DiffLine.Kind](repeating: .removed, count: n) + [DiffLine.Kind](repeating: .added, count: m)
        }
        var ops: [DiffLine.Kind] = []
        var i = n, j = m
        var d = found
        while d > 0 {
            let vd = trace[d]
            let o = d + 1
            let k = i - j
            let prevK = (k == -d || (k != d && vd[o + k - 1] < vd[o + k + 1])) ? k + 1 : k - 1
            let prevI = vd[o + prevK]
            let prevJ = prevI - prevK
            while i > prevI, j > prevJ { ops.append(.same); i -= 1; j -= 1 }
            if i == prevI { ops.append(.added); j -= 1 } else { ops.append(.removed); i -= 1 }
            d -= 1
        }
        while i > 0, j > 0 { ops.append(.same); i -= 1; j -= 1 }
        return ops.reversed()
    }
}

/// One row of a diff display.
public enum DiffRow: Identifiable, Hashable, Sendable {
    /// Unified: one line.
    case line(DiffLine)
    /// Side by side: what is on the left (old) and on the right (new).
    case pair(id: Int, left: DiffLine?, right: DiffLine?)
    /// A run of unchanged lines that is not shown.
    case gap(id: Int, count: Int)

    public var id: Int {
        switch self {
        case .line(let l): return l.id
        case .pair(let id, _, _): return id
        case .gap(let id, _): return -id - 1
        }
    }

    /// Unified rows with at most `context` unchanged lines around each change.
    public static func unified(_ diff: LineDiff, context: Int = 3) -> [DiffRow] {
        let lines = diff.lines
        guard !diff.isEmpty else { return lines.map { .line($0) } }
        var keep = [Bool](repeating: false, count: lines.count)
        for (i, l) in lines.enumerated() where l.kind != .same {
            for k in max(0, i - context)...min(lines.count - 1, i + context) { keep[k] = true }
        }
        var out: [DiffRow] = []
        var i = 0
        while i < lines.count {
            if keep[i] { out.append(.line(lines[i])); i += 1; continue }
            var j = i
            while j < lines.count, !keep[j] { j += 1 }
            out.append(.gap(id: i, count: j - i))
            i = j
        }
        return out
    }

    /// Side-by-side rows: a block of removals is paired line by line with the additions that follow it.
    public static func sideBySide(_ diff: LineDiff, context: Int = 3) -> [DiffRow] {
        var out: [DiffRow] = []
        var pendingRemoved: [DiffLine] = [], pendingAdded: [DiffLine] = []
        func flush() {
            for k in 0..<max(pendingRemoved.count, pendingAdded.count) {
                let l = pendingRemoved[safe: k], r = pendingAdded[safe: k]
                out.append(.pair(id: (l ?? r)!.id, left: l, right: r))
            }
            pendingRemoved = []; pendingAdded = []
        }
        for row in unified(diff, context: context) {
            switch row {
            case .line(let l):
                switch l.kind {
                case .removed: if !pendingAdded.isEmpty { flush() }; pendingRemoved.append(l)
                case .added: pendingAdded.append(l)
                case .same: flush(); out.append(.pair(id: l.id, left: l, right: l))
                }
            case .gap: flush(); out.append(row)
            case .pair: break
            }
        }
        flush()
        return out
    }
}
