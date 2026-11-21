// ORIX OS Automation
// File: Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/DiffView.swift
// Description: Diff viewer: side-by-side or unified line diff with added/removed marks and counts, and the list of semantic workflow changes above it with permission changes flagged.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

public enum DiffMode: String, Sendable, CaseIterable { case sideBySide, unified }

public struct DiffView: View {
    let old: String
    let new: String
    let oldTitle: String
    let newTitle: String
    let changes: [WorkflowChange]
    @State private var mode: DiffMode
    @State private var diff: LineDiff?

    public init(old: String, new: String, oldTitle: String, newTitle: String, changes: [WorkflowChange] = [], mode: DiffMode = .sideBySide) {
        self.old = old; self.new = new; self.oldTitle = oldTitle; self.newTitle = newTitle; self.changes = changes
        _mode = State(initialValue: mode)
    }

    private struct Key: Hashable { let old: String; let new: String }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                if let diff {
                    Label("\(diff.added) added", systemImage: "plus").font(Theme.Font.captionStrong).foregroundStyle(Theme.success)
                    Label("\(diff.removed) removed", systemImage: "minus").font(Theme.Font.captionStrong).foregroundStyle(Theme.danger)
                }
                Spacer()
                Picker("Layout", selection: $mode) {
                    Text("Side by side").tag(DiffMode.sideBySide)
                    Text("Unified").tag(DiffMode.unified)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("code.diff.mode")
            }
            if !changes.isEmpty { changeList }
            if let diff {
                if diff.isEmpty {
                    EmptyState(symbol: "equal.circle", title: "No differences", message: "Both versions have the same text.")
                } else {
                    table(diff)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) { SkeletonLine(width: 260); SkeletonLine(width: 340); SkeletonLine(width: 200) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task(id: Key(old: old, new: new)) {
            let o = old, n = new
            diff = await Task.detached { LineDiff(old: o, new: n) }.value
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Differences"))
    }

    private var changeList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("What changed").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: change.isSecurityRelevant ? "lock.trianglebadge.exclamationmark" : "circle.fill")
                        .font(.system(size: change.isSecurityRelevant ? 11 : 4)).foregroundStyle(change.isSecurityRelevant ? Theme.warning : Theme.textTertiary)
                        .frame(width: 14)
                    Text(change.summary).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    if change.isSecurityRelevant { Pill(text: String(localized: "Review permissions"), symbol: "lock.shield", color: Theme.warning) }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func table(_ diff: LineDiff) -> some View {
        let rows = mode == .unified ? DiffRow.unified(diff) : DiffRow.sideBySide(diff)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(oldTitle).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if mode == .sideBySide {
                    Text(newTitle).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(newTitle).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
            .background(Theme.surfaceRaised)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .line(let l): unifiedRow(l)
                        case .pair(_, let left, let right):
                            HStack(alignment: .top, spacing: 0) {
                                half(left, number: left?.oldNumber, removedSide: true)
                                Rectangle().fill(Theme.stroke).frame(width: 1)
                                half(right, number: right?.newNumber, removedSide: false)
                            }
                        case .gap(_, let count):
                            Text("\(count) unchanged lines").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity).padding(.vertical, 3).background(Theme.surfaceSunken)
                        }
                    }
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func number(_ n: Int?) -> some View {
        Text(verbatim: n.map(String.init) ?? "").font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).frame(width: 34, alignment: .trailing)
    }

    private func background(_ kind: DiffLine.Kind?) -> Color {
        switch kind {
        case .added: return Theme.success.opacity(0.14)
        case .removed: return Theme.danger.opacity(0.14)
        default: return .clear
        }
    }

    private func marker(_ kind: DiffLine.Kind?) -> some View {
        Text(verbatim: kind == .added ? "+" : (kind == .removed ? "−" : " ")).font(Theme.Font.mono)
            .foregroundStyle(kind == .added ? Theme.success : Theme.danger).frame(width: 12)
    }

    private func unifiedRow(_ l: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            number(l.oldNumber); number(l.newNumber); marker(l.kind)
            Text(verbatim: l.text.isEmpty ? " " : l.text).font(Theme.Font.mono).foregroundStyle(Theme.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1).padding(.trailing, Theme.Space.s)
        .background(background(l.kind))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: (l.kind == .added ? "+ " : (l.kind == .removed ? "- " : "")) + l.text))
    }

    private func half(_ l: DiffLine?, number n: Int?, removedSide: Bool) -> some View {
        // An unchanged line shows on both sides; a changed one only on its own side.
        let kind: DiffLine.Kind? = l.map { $0.kind == .same ? .same : (removedSide ? .removed : .added) }
        return HStack(alignment: .top, spacing: 6) {
            number(n); marker(kind)
            Text(verbatim: (l?.text.isEmpty ?? true) ? " " : l!.text).font(Theme.Font.mono).foregroundStyle(Theme.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1).padding(.trailing, Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(l == nil ? Theme.surfaceSunken.opacity(0.6) : background(kind))
    }
}
