// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/ReceiptView.swift
// Description      : The execution receipt of a run: runtime verification
//                    results with evidence, tool calls, approvals, permissions
//                    used, artifacts with Finder and Quick Look, limitations,
//                    errors, and the agent's closing statement shown apart as a
//                    claim.
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
import Quartz
import SwiftUI

/// Shows files in the system Quick Look panel.
@MainActor
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()
    private var urls: [URL] = []

    func show(_ url: URL) {
        urls = [url]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { urls.count } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

/// One artifact path with what can still be done with it. Says so when the file is no longer there.
struct ArtifactPathRow: View {
    let path: String
    var bytes: Int?
    var sha256: String?
    var note: String = ""

    var body: some View {
        let exists = FileManager.default.fileExists(atPath: path)
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: exists ? "doc" : "doc.badge.ellipsis").foregroundStyle(exists ? Theme.textSecondary : Theme.warning).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(PathResolver.display(path)).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                HStack(spacing: Theme.Space.s) {
                    if let bytes { Text(Format.bytes(bytes)) }
                    if let sha256 {
                        Text(verbatim: "SHA-256 \(sha256.prefix(16))…").font(Theme.Font.monoSmall)
                        CopyButton(value: sha256, label: "Copy the full SHA-256")
                    }
                    if !note.isEmpty { Text(note) }
                }
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                if !exists {
                    Label("This file is no longer at this location.", systemImage: "exclamationmark.triangle").font(Theme.Font.caption).foregroundStyle(Theme.warning)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if exists {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Text("Reveal in Finder") }
                    .buttonStyle(.link).font(Theme.Font.caption).accessibilityIdentifier("runs.receipt.reveal")
                Button { QuickLookPresenter.shared.show(URL(fileURLWithPath: path)) } label: { Text("Quick Look") }
                    .buttonStyle(.link).font(Theme.Font.caption).accessibilityIdentifier("runs.receipt.quickLook")
            }
        }
        .padding(.vertical, 3)
    }
}

struct ReceiptTab: View {
    let run: RunRecord
    let receipt: RunReceipt?
    @State private var showAllCalls = false
    static let callPreview = 40

    var body: some View {
        if let receipt {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    summary(receipt)
                    verification(receipt)
                    toolCalls(receipt)
                    if !receipt.approvals.isEmpty { listCard("Approvals", symbol: "hand.raised", receipt.approvals) }
                    if !receipt.permissionsUsed.isEmpty { listCard("Permissions used", symbol: "lock.open", receipt.permissionsUsed) }
                    artifacts(receipt)
                    if !receipt.limitations.isEmpty { listCard("Limitations", symbol: "exclamationmark.bubble", receipt.limitations, tint: Theme.warning) }
                    if !receipt.errors.isEmpty { listCard("Errors", symbol: "xmark.octagon", receipt.errors, tint: Theme.danger) }
                    if !receipt.agentSummary.isEmpty { claim(receipt) }
                }
                .padding(Theme.Space.l)
            }
        } else {
            EmptyState(symbol: "doc.text", title: "No receipt",
                       message: run.status.isTerminal ? "This run ended without writing a receipt. Its timeline shows what was recorded."
                                                      : "The receipt is written when the run ends.")
        }
    }

    private func summary(_ r: RunReceipt) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack { CardTitle("Execution receipt", symbol: "doc.text.fill"); StatusBadge(r.status) }
                Text(r.objective).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("The status above comes from what ORIX checked, not from what the model said.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func verification(_ r: RunReceipt) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardTitle("Verification", symbol: "checkmark.seal") {
                    Pill(text: String(localized: "Checked by ORIX, not by the model"), symbol: "cpu", color: Theme.success)
                }
                if r.verifications.isEmpty {
                    Text("No check was declared or possible for this run, so nothing here proves the result.")
                        .font(Theme.Font.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(r.verifications) { v in
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Label(v.passed ? "PASS" : "FAIL", systemImage: v.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(Theme.Font.captionStrong).foregroundStyle(v.passed ? Theme.success : Theme.danger)
                            .frame(width: 62, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.assertion).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text("Evidence: \(v.evidence)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: "\(v.kind) · \(Format.dateTime(v.checkedAt))").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func toolCalls(_ r: RunReceipt) -> some View {
        let calls = showAllCalls ? r.toolCalls : Array(r.toolCalls.prefix(Self.callPreview))
        return Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardTitle("Tool calls", symbol: "wrench.and.screwdriver") { Text("\(r.toolCalls.count)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                if r.toolCalls.isEmpty { Text("This run called no tool.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                else {
                    Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: 6) {
                        GridRow { Text("Tool"); Text("Result"); Text("Time").gridColumnAlignment(.trailing); Text("Tier"); Text("Summary") }
                            .font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(calls) { c in
                            GridRow(alignment: .firstTextBaseline) {
                                Text(c.toolID).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).lineLimit(1)
                                StatusBadge(tool: c.status)
                                Text(Format.duration(Double(c.durationMs) / 1000)).font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
                                Text(c.tier.map { String(localized: "Tier \($0.rawValue)") } ?? "—").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                Text(c.summary).font(Theme.Font.caption).foregroundStyle(Theme.text).lineLimit(2).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if r.toolCalls.count > Self.callPreview {
                        Button { showAllCalls.toggle() } label: { Text(showAllCalls ? "Show fewer" : "Show all \(r.toolCalls.count) calls") }.buttonStyle(.link).font(Theme.Font.caption)
                    }
                }
            }
        }
    }

    private func artifacts(_ r: RunReceipt) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardTitle("Artifacts", symbol: "shippingbox") { Text("\(r.artifacts.count)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                if r.artifacts.isEmpty { Text("This run produced no file.").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                ForEach(r.artifacts) { a in ArtifactPathRow(path: a.path, bytes: a.bytes, sha256: a.sha256, note: a.note) }
            }
        }
    }

    private func listCard(_ title: LocalizedStringKey, symbol: String, _ items: [String], tint: Color = Theme.textSecondary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardTitle(title, symbol: symbol)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(tint)
                        Text(item).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The model's own words, kept visibly apart from everything the runtime checked.
    private func claim(_ r: RunReceipt) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "quote.opening").foregroundStyle(Theme.textSecondary)
                Text("The agent's closing statement").font(Theme.Font.heading).foregroundStyle(Theme.text)
                Pill(text: String(localized: "A claim, not evidence"), symbol: "exclamationmark.circle", color: Theme.warning)
            }
            Text(r.agentSummary).font(Theme.Font.body).italic().foregroundStyle(Theme.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Written by the model. Rely on the verification section above for what actually happened.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .accessibilityElement(children: .combine)
    }
}
