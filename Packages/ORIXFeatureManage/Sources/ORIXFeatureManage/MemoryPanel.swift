// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/MemoryPanel.swift
// Description: What agents remember: every memory record with scope, kind, provenance and date; approve, delete, export as JSON, delete all.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class MemoryModel {
    let services: ORIXServices
    private(set) var records: [MemoryRecord] = []
    private(set) var loaded = false

    init(services: ORIXServices) { self.services = services }

    func reload() async {
        records = await services.memory.all().sorted { $0.createdAt > $1.createdAt }
        loaded = true
    }

    func approve(_ id: String) async { await services.memory.approve(id: id); await reload() }
    func delete(_ id: String) async { await services.memory.remove(id: id); await reload() }

    func deleteAll() async {
        for r in await services.memory.all() { await services.memory.remove(id: r.id) }
        await reload()
    }

    /// Every record as pretty JSON with ISO 8601 dates.
    func exportJSON() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(records)
    }

    static func scopeLabel(_ s: MemoryRecord.Scope) -> (text: String, symbol: String) {
        switch s {
        case .session: return (String(localized: "One conversation"), "bubble.left")
        case .workflow(let w): return (String(localized: "Workflow \(w)"), "point.3.connected.trianglepath.dotted")
        case .agent(let a): return (String(localized: "Agent \(a)"), "person")
        case .user: return (String(localized: "All your runs"), "person.crop.circle")
        }
    }

    /// A user-scope record that nobody approved yet is stored but never given to a model.
    static func isPending(_ r: MemoryRecord) -> Bool { r.scope == .user && !r.approved }
}

struct MemoryPanel: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var memory: MemoryModel?
    @State private var confirmDeleteAll = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Banner(kind: .info, text: String(localized: "Memory is advice for the agent, never permission. A remembered preference or approval grants nothing: every action is still checked against your grants."))
            if let error { Banner(kind: .error, text: error) }
            if let memory, memory.loaded {
                HStack(spacing: Theme.Space.s) {
                    Text("\(String(memory.records.count)) record(s)").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    let pending = memory.records.filter(MemoryModel.isPending).count
                    if pending > 0 { StatePill(text: String(localized: "\(String(pending)) waiting for your approval"), symbol: "hourglass", color: Theme.warning) }
                    Spacer()
                    Button { export(memory) } label: { Label("Export as JSON…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(SecondaryButtonStyle()).disabled(memory.records.isEmpty).accessibilityIdentifier("memory.export")
                    Button(role: .destructive) { confirmDeleteAll = true } label: { Label("Delete all", systemImage: "trash") }
                        .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).disabled(memory.records.isEmpty).accessibilityIdentifier("memory.deleteAll")
                }
                if memory.records.isEmpty {
                    if compact {
                        Text("Nothing is remembered. Agents propose memories during runs; preferences for all your runs wait for your approval here.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    } else {
                        EmptyState(symbol: "tray", title: "Nothing is remembered",
                                   message: "Agents propose memories during runs. Preferences meant for all your runs wait for your approval here before any model sees them.")
                            .frame(minHeight: 260)
                    }
                } else {
                    LazyVStack(spacing: Theme.Space.s) {
                        ForEach(memory.records) { r in row(r, memory) }
                    }
                }
            } else {
                SkeletonLine(width: 260); SkeletonLine(width: 180)
            }
        }
        .task { if memory == nil { memory = MemoryModel(services: model.services) } }
        .task(id: model.revision) { await memory?.reload() }
        .confirmationDialog("Delete every memory record?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { Task { await memory?.deleteAll() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Agents lose every remembered preference, fix and fact. Run history and workflows are not affected. This cannot be undone.") }
    }

    private func row(_ r: MemoryRecord, _ memory: MemoryModel) -> some View {
        let scope = MemoryModel.scopeLabel(r.scope)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                Pill(text: scope.text, symbol: scope.symbol, color: Theme.violet)
                Pill(text: r.kind, symbol: "tag")
                if MemoryModel.isPending(r) { StatePill(text: String(localized: "Waiting for approval"), symbol: "hourglass", color: Theme.warning) }
                else if r.scope == .user { StatePill(text: String(localized: "Approved"), symbol: "checkmark.circle.fill", color: Theme.success) }
                Spacer()
                Text(Format.dateTime(r.createdAt)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            Text(r.text).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Text("From \(r.provenance)").font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if MemoryModel.isPending(r) {
                    Button("Approve") { Task { await memory.approve(r.id) } }.buttonStyle(.link).accessibilityIdentifier("memory.approve.\(r.id)")
                }
                Button("Delete", role: .destructive) { Task { await memory.delete(r.id) } }.buttonStyle(.link).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("memory.delete.\(r.id)")
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
        .accessibilityElement(children: .contain)
    }

    private func export(_ memory: MemoryModel) {
        guard let url = FilePanels.saveFile(name: "orix-memory.json", message: String(localized: "Choose where to write the memory export"), types: [.json]) else { return }
        do { try memory.exportJSON().write(to: url, options: .atomic); error = nil } catch { self.error = ManageText.describe(error) }
    }
}
