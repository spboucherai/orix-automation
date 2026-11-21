// ORIX OS Automation
// File: Packages/ORIXAppUI/Sources/ORIXAppUI/Preview.swift
// Description: Development harness: renders a SwiftUI view to a PNG off screen, and builds an app model on a throwaway data folder with clearly labelled sample records.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXCore
import ORIXPersistence
import ORIXServices
import SwiftUI

/// Renders views to image files so a layout can be checked without opening the app.
@MainActor
public enum ShotRenderer {
    /// Lays the view out in an off-screen window, waits `settle` seconds for async loading, and writes a PNG at 2×.
    public static func render<V: View>(_ view: V, size: CGSize, dark: Bool = true, settle: Double = 1.2, to url: URL) async throws {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Theme.canvas)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        window.orderOut(nil)
    }
}

/// An app model on a temporary data folder. Records created by `seed` are titled "Sample · …" so they can never be
/// mistaken for real activity; the app itself never calls this.
@MainActor
public enum PreviewEnvironment {
    public static func make(seed: Bool = true) async throws -> AppModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orix-preview-\(UUID().uuidString.prefix(8))")
        var options = ServiceOptions()
        options.keychainService = "ai.spboucher.orix.automation.preview"
        let services = try await ORIXServices.bootstrap(paths: ORIXPaths(root: root), options: options)
        if seed { try await seedSamples(services) }
        let model = AppModel(services: services)
        await model.start()
        model.showOnboarding = false
        return model
    }

    static func seedSamples(_ s: ORIXServices) async throws {
        let model = ModelRef(provider: .anthropic, model: "claude-haiku-5-5")
        let now = Date()
        let samples: [(String, RunStatus, String, Double)] = [
            ("Sample · Organise Downloads", .succeeded, "agent", 3600), ("Sample · Weekly research digest", .succeeded, "workflow", 7200),
            ("Sample · Folder backup", .partiallySucceeded, "workflow", 20_000), ("Sample · CSV cleanup", .failed, "workflow", 30_000),
            ("Sample · Health report", .succeeded, "workflow", 90_000), ("Sample · Review repository", .budgetExceeded, "agent", 100_000),
        ]
        for (i, (title, status, kind, ago)) in samples.enumerated() {
            var r = RunRecord(id: "sample-\(i)", kind: kind, title: title, trigger: i % 2 == 0 ? "manual" : "schedule", mode: .guided, status: status,
                              model: kind == "agent" ? model : nil, startedAt: now.addingTimeInterval(-ago), endedAt: now.addingTimeInterval(-ago + 42))
            r.usage.turns = 4 + i; r.usage.toolCalls = 6 + i * 2
            r.usage.tokens = TokenUsage(inputTokens: 21_000 + i * 3000, outputTokens: 900 + i * 120)
            r.usage.costUSD = 0.004 + Double(i) * 0.003
            if status == .failed { r.errorSummary = "documents.csvRead: file not found" }
            try await s.store.saveRun(r)
            for (j, (kind, text)) in [(RunEvent.Kind.statusChanged, "RUNNING"), (.userMessage, title), (.assistantText, "Listing the folder first."),
                                      (.toolFinished, "filesystem.list — 14 entries"), (.verification, "PASS report.md exists"), (.statusChanged, status.rawValue)].enumerated() {
                await s.store.emit(RunEvent(runID: r.id, timestamp: now.addingTimeInterval(-ago + Double(j) * 4), kind: kind, text: text,
                                            data: kind == .toolFinished ? ["toolID": "filesystem.list", "status": "succeeded", "durationMs": 12, "summary": "14 entries", "tier": 0] : .null))
            }
            try await s.store.saveReceipt(RunReceipt(runID: r.id, title: title, status: status, objective: title, model: r.model, startedAt: r.startedAt ?? now,
                                                    endedAt: r.endedAt ?? now, usage: r.usage,
                                                    toolCalls: [ToolCallRecord(id: "c\(i)", toolID: "filesystem.list", arguments: ["path": "~/Downloads"], status: .succeeded, summary: "14 entries", durationMs: 12, tier: .readOnly)],
                                                    verifications: [VerificationResult(assertion: "report.md exists", kind: "file_exists", passed: status == .succeeded, evidence: status == .succeeded ? "found" : "not found")]))
        }
        for slug in ["system-health-report", "smart-downloads-organizer", "folder-backup-and-verify"] { _ = try? await s.workflows.installBuiltIn(slug: slug) }
        await s.policy.add(PermissionGrant(capability: .fileRead(path: NSHomeDirectory() + "/Documents/Research"), scope: .persistent, maxTier: .readOnly, note: "Sample grant"))
        await s.policy.add(PermissionGrant(capability: .network(host: "example.com"), scope: .persistent, maxTier: .consequential, note: "Sample grant"))
        var settings = AppSettings(); settings.onboardingCompleted = true; settings.defaultModel = model
        try await s.runs.save(settings)
    }
}
