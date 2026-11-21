// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppUI/Sources/ORIXAppUI/Sheets.swift
// Description      : The approval card (what will happen, capabilities, tier,
//                    redacted arguments, scoped choices), plan review and
//                    question cards, shown wherever a run waits for a person.
// Module           : ORIXAppUI
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

import ORIXAgentRuntime
import ORIXCore
import ORIXServices
import SwiftUI

public extension Capability {
    var symbol: String {
        switch self {
        case .fileRead: return "doc.text.magnifyingglass"
        case .fileWrite: return "square.and.pencil"
        case .fileDelete: return "trash"
        case .processExec: return "terminal"
        case .scriptRuntime: return "scroll"
        case .appAutomation: return "applescript"
        case .accessibility: return "accessibility"
        case .screenCapture: return "camera.viewfinder"
        case .network: return "network"
        case .browser: return "safari"
        case .secret: return "key"
        case .clipboardRead, .clipboardWrite: return "doc.on.clipboard"
        case .notify: return "bell"
        case .externalSend: return "paperplane"
        case .appControl: return "macwindow"
        case .skill: return "puzzlepiece.extension"
        }
    }

    /// A sentence fragment a person can judge: "Read files in ~/Documents/Research".
    var humanDescription: String {
        switch self {
        case .fileRead(let p): return String(localized: "Read \(PathResolver.display(p))")
        case .fileWrite(let p): return String(localized: "Create or change files in \(PathResolver.display(p))")
        case .fileDelete(let p): return String(localized: "Delete or move to the Trash in \(PathResolver.display(p))")
        case .processExec(let e): return String(localized: "Run the program \(e)")
        case .scriptRuntime(let n): return String(localized: "Run a \(n) script")
        case .appAutomation(let b): return String(localized: "Send commands to \(b)")
        case .accessibility(let b): return String(localized: "Read and operate the interface of \(b)")
        case .screenCapture(let s): return String(localized: "Capture the screen (\(s))")
        case .network(let h): return String(localized: "Connect to \(h)")
        case .browser(let h): return String(localized: "Open pages on \(h)")
        case .secret(let r): return String(localized: "Use the secret “\(r)” (its value stays hidden)")
        case .clipboardRead: return String(localized: "Read the clipboard")
        case .clipboardWrite: return String(localized: "Replace the clipboard")
        case .notify: return String(localized: "Post a notification")
        case .externalSend(let c): return String(localized: "Send outside this Mac (\(c))")
        case .appControl(let b): return String(localized: "Open or quit \(b)")
        case .skill(let i): return String(localized: "Use the skill \(i)")
        }
    }
}

public struct CapabilityRow: View {
    let capability: Capability
    public init(_ capability: Capability) { self.capability = capability }
    public var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: capability.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.violet).frame(width: 18)
            Text(capability.humanDescription).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One pending approval. The sentence comes from the tool's own code, never from the model.
public struct ApprovalCard: View {
    let request: ApprovalRequest
    let onResolve: (ApprovalResponse) -> Void
    @State private var showArguments = false
    @State private var confirmText = ""

    public init(request: ApprovalRequest, onResolve: @escaping (ApprovalResponse) -> Void) { self.request = request; self.onResolve = onResolve }

    private var isHighRisk: Bool { request.access.tier == .highRisk }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.violet)
                Text("Approval needed").font(Theme.Font.heading)
                Spacer()
                TierBadge(tier: request.access.tier)
            }
            Text(request.access.summary).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Pill(text: request.access.toolID, symbol: "wrench.and.screwdriver")
                Pill(text: request.access.sideEffect.rawValue, symbol: "bolt")
                if request.access.dryRun { Pill(text: String(localized: "dry run"), symbol: "eye", color: Theme.info) }
            }
            if !request.missing.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("It needs permission to").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    ForEach(Array(request.missing.enumerated()), id: \.offset) { _, c in CapabilityRow(c) }
                }
            }
            Text(request.reason).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showArguments) {
                ScrollView {
                    Text(request.access.argumentsPreview.serialized(pretty: true)).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.s)
                }
                .frame(maxHeight: 160)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            } label: { Text("Arguments (secrets hidden)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }

            if isHighRisk {
                Banner(kind: .warning, text: String(localized: "This cannot be undone. It is approved for this one call only. Type APPROVE to enable the button."))
                TextField(String(localized: "Type APPROVE"), text: $confirmText).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .accessibilityIdentifier("approval.confirmField")
            }
            HStack(spacing: Theme.Space.s) {
                Button(role: .cancel) { onResolve(.deny(reason: "")) } label: { Text("Deny") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("approval.deny")
                Spacer()
                if !isHighRisk {
                    Menu {
                        Button("Allow for the rest of this run") { onResolve(.approveForRun) }
                        if request.access.tier < .consequential || request.missing.allSatisfy({ if case .fileRead = $0 { return true }; return false }) {
                            Button("Always allow (until revoked in Permissions)") { onResolve(.approvePersistent) }
                        }
                    } label: { Text("More") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Button { onResolve(.approveOnce) } label: { Text("Allow once") }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(isHighRisk && confirmText != "APPROVE")
                    .accessibilityIdentifier("approval.allowOnce")
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.violet.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Approval request"))
    }
}

public struct PlanReviewCard: View {
    let pending: PendingPlan
    let onDecision: (PlanReview) -> Void
    @State private var feedback = ""
    public init(pending: PendingPlan, onDecision: @escaping (PlanReview) -> Void) { self.pending = pending; self.onDecision = onDecision }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "list.bullet.clipboard").foregroundStyle(Theme.violet)
                Text("Review the plan").font(Theme.Font.heading)
                Spacer()
                Pill(text: String(localized: "revision \(pending.plan.revision)"))
            }
            Text("Nothing is changed until you approve. Reading and inspecting may already have happened.")
                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(pending.plan.steps.enumerated()), id: \.element.id) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text("\(i + 1)").font(Theme.Font.captionStrong).foregroundStyle(Theme.violet).frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(Theme.Font.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                            if let a = step.expectedArtifact, !a.isEmpty { Text(a).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary) }
                        }
                    }
                }
            }
            TextField(String(localized: "Ask for changes (optional)"), text: $feedback, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
            HStack {
                Button { onDecision(.rejected) } label: { Text("Reject and stop") }.buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
                Spacer()
                Button { onDecision(.revise(feedback: feedback)) } label: { Text("Send back") }.buttonStyle(SecondaryButtonStyle())
                    .disabled(feedback.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { onDecision(.approved) } label: { Text("Approve plan") }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("plan.approve")
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.violet.opacity(0.45)))
    }
}

public struct QuestionCard: View {
    let pending: PendingQuestion
    let onAnswer: (String?) -> Void
    @State private var answer = ""
    public init(pending: PendingQuestion, onAnswer: @escaping (String?) -> Void) { self.pending = pending; self.onAnswer = onAnswer }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label("The agent has a question", systemImage: "questionmark.bubble").font(Theme.Font.heading)
            Text(pending.question).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Your answer"), text: $answer, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                .onSubmit { if !answer.isEmpty { onAnswer(answer) } }
            HStack {
                Button { onAnswer(nil) } label: { Text("Skip") }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button { onAnswer(answer) } label: { Text("Answer") }.buttonStyle(PrimaryButtonStyle()).disabled(answer.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.blue.opacity(0.45)))
    }
}

/// Everything a run is waiting on from a person, stacked. Features embed it; the app also shows it as a global overlay.
public struct AttentionStack: View {
    @Environment(AppModel.self) private var model
    /// Limit to one run, or nil for everything.
    let runID: String?
    public init(runID: String? = nil) { self.runID = runID }

    public var body: some View {
        let approvals = model.pendingApprovals.filter { runID == nil || $0.access.runID == runID }
        let items = model.pendingInteractions.filter { item in
            guard let runID else { return true }
            switch item { case .question(let q): return q.runID == runID; case .plan(let p): return p.runID == runID }
        }
        VStack(spacing: Theme.Space.m) {
            ForEach(approvals) { r in ApprovalCard(request: r) { model.resolve(r, $0) }.id(r.id) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .plan(let p): PlanReviewCard(pending: p) { model.review(p, $0) }
                case .question(let q): QuestionCard(pending: q) { model.answer(q, $0) }
                }
            }
        }
    }
}
