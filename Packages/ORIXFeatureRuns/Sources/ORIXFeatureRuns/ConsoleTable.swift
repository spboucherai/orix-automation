// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/ConsoleTable.swift
// Description      : The console's line list as an AppKit table: only the rows
//                    on screen exist, so twenty thousand lines scroll and
//                    update smoothly; handles selection, copy, follow-the-tail
//                    and jumping to a search match.
// Module           : ORIXFeatureRuns
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

/// A table that answers ⌘C with the selected lines.
final class ConsoleNSTableView: NSTableView {
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) ? numberOfRows > 0 : super.validateUserInterfaceItem(item)
    }
}

struct ConsoleTable: NSViewRepresentable {
    let console: ConsoleModel
    /// Read in `body` so SwiftUI calls `updateNSView` when lines, matches or follow mode change.
    let version: Int
    let follow: Bool
    let currentMatchID: Int?
    @Binding var selection: Set<Int>
    let onCopy: () -> Void

    static let rowHeight: CGFloat = 17

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ConsoleNSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.onCopy = onCopy
        table.setAccessibilityLabel(String(localized: "Log lines"))
        table.setAccessibilityIdentifier("console.lines")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.table = table
        context.coordinator.scroll = scroll
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        (scroll.documentView as? ConsoleNSTableView)?.onCopy = onCopy
        c.apply()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { NotificationCenter.default.removeObserver(coordinator) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: ConsoleTable
        weak var table: ConsoleNSTableView?
        weak var scroll: NSScrollView?
        private var lines: [ConsoleLine] = []
        private var query = ""
        private var matchSet: Set<Int> = []
        private var shownVersion = -1
        private var shownMatch: Int?
        private var wasFollowing = true
        private var programmatic = false
        private var applyingSelection = false

        init(_ parent: ConsoleTable) { self.parent = parent }

        /// Brings the table in line with the model. Cheap: the table only asks again for the rows on screen.
        func apply() {
            guard let table, let scroll else { return }
            let console = parent.console
            if shownVersion != parent.version {
                shownVersion = parent.version
                // When the reader has scrolled up, keep the line they are on in place while older lines are dropped above it.
                let anchor: (id: Int, offset: CGFloat)? = parent.follow ? nil : {
                    let y = scroll.contentView.bounds.minY
                    let row = max(0, Int(y / ConsoleTable.rowHeight))
                    return lines.indices.contains(row) ? (lines[row].id, y - CGFloat(row) * ConsoleTable.rowHeight) : nil
                }()
                lines = console.visible
                query = console.query
                matchSet = console.matchSet
                table.reloadData()
                restoreSelection()
                if let anchor, let row = lines.firstIndex(where: { $0.id >= anchor.id }) {
                    scrollTo(y: CGFloat(row) * ConsoleTable.rowHeight + anchor.offset)
                }
            }
            if parent.follow, !lines.isEmpty { scrollToRow(lines.count - 1, center: false) }
            else if shownMatch != parent.currentMatchID, let id = parent.currentMatchID, let row = lines.firstIndex(where: { $0.id == id }) {
                scrollToRow(row, center: true)
            }
            if shownMatch != parent.currentMatchID { shownMatch = parent.currentMatchID; table.reloadData(forRowIndexes: visibleRows(), columnIndexes: [0]) }
            wasFollowing = parent.follow
        }

        private func visibleRows() -> IndexSet {
            guard let table, let r = Range(table.rows(in: table.visibleRect)) else { return [] }
            return IndexSet(integersIn: r)
        }

        private func restoreSelection() {
            guard let table else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            let wanted = parent.selection
            guard !wanted.isEmpty else { table.deselectAll(nil); return }
            var rows = IndexSet()
            for (i, l) in lines.enumerated() where wanted.contains(l.id) { rows.insert(i) }
            table.selectRowIndexes(rows, byExtendingSelection: false)
        }

        private func scrollToRow(_ row: Int, center: Bool) {
            guard let scroll else { return }
            let visible = scroll.contentView.bounds.height
            let content = CGFloat(lines.count) * ConsoleTable.rowHeight
            let y = center ? CGFloat(row) * ConsoleTable.rowHeight - visible / 2 : content - visible
            scrollTo(y: y)
        }

        private func scrollTo(y: CGFloat) {
            guard let scroll else { return }
            let content = CGFloat(lines.count) * ConsoleTable.rowHeight
            let clamped = max(0, min(y, content - scroll.contentView.bounds.height))
            guard abs(scroll.contentView.bounds.minY - clamped) > 0.5 else { return }
            programmatic = true
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: clamped))
            scroll.reflectScrolledClipView(scroll.contentView)
            programmatic = false
        }

        /// The user moved the view: away from the end pauses following, back at the end resumes it.
        @objc func scrolled() {
            guard !programmatic, let scroll else { return }
            let distance = CGFloat(lines.count) * ConsoleTable.rowHeight - scroll.contentView.bounds.maxY
            let console = parent.console
            if distance > 3 * ConsoleTable.rowHeight, console.follow { DispatchQueue.main.async { console.follow = false } }
            else if distance < 2, !console.follow { DispatchQueue.main.async { console.follow = true } }
        }

        // MARK: Table

        func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("cell")
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField { field = reused }
            else {
                field = NSTextField(labelWithString: "")
                field.identifier = id
                field.lineBreakMode = .byTruncatingTail
                field.maximumNumberOfLines = 1
                field.cell?.usesSingleLineMode = true
                field.allowsExpansionToolTips = true
            }
            guard lines.indices.contains(row) else { return field }
            let line = lines[row]
            field.attributedStringValue = Self.attributed(line, query: matchSet.contains(line.id) ? query : "", isCurrent: parent.currentMatchID == line.id)
            return field
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { lines.indices.contains($0) ? lines[$0].id : nil })
            let binding = parent.$selection
            if binding.wrappedValue != ids { DispatchQueue.main.async { binding.wrappedValue = ids } }
        }

        // MARK: Drawing a line

        private static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private static let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

        static func attributed(_ line: ConsoleLine, query: String, isCurrent: Bool) -> NSAttributedString {
            let out = NSMutableAttributedString(string: "  " + ConsoleBuffer.timestamp(line.time) + "  ", attributes: [.font: font, .foregroundColor: NSColor(Theme.textTertiary)])
            // The tag names the stream in words (OUT, ERR, …): colour only reinforces it.
            out.append(NSAttributedString(string: line.level.tag.padding(toLength: 7, withPad: " ", startingAt: 0), attributes: [.font: bold, .foregroundColor: NSColor(line.level.tint)]))
            let body = NSMutableAttributedString(string: line.text.isEmpty ? " " : line.text,
                                                 attributes: [.font: font, .foregroundColor: NSColor(line.level == .stderr || line.level == .error ? Theme.danger : Theme.text)])
            if !query.isEmpty {
                let text = body.string as NSString
                var range = NSRange(location: 0, length: text.length)
                while range.length > 0 {
                    let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                    guard found.location != NSNotFound else { break }
                    body.addAttributes([.backgroundColor: NSColor(Theme.warning).withAlphaComponent(isCurrent ? 0.6 : 0.3), .underlineStyle: NSUnderlineStyle.single.rawValue], range: found)
                    range = NSRange(location: found.upperBound, length: text.length - found.upperBound)
                }
            }
            out.append(body)
            if isCurrent { out.append(NSAttributedString(string: "  ◀ " + String(localized: "current match"), attributes: [.font: bold, .foregroundColor: NSColor(Theme.warning)])) }
            return out
        }
    }
}
