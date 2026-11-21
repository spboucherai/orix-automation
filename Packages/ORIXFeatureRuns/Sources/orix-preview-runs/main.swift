// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureRuns/Sources/orix-preview-runs/main.swift
// Description      : Renders every screen of the Runs feature package to PNG on
//                    a throwaway data folder: `swift run orix-preview-runs
//                    --shot <dir>`.
// Module           : orix-preview-runs
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
import CryptoKit
import ORIXAppUI
@_spi(Preview) import ORIXFeatureRuns
import SwiftUI

/// Runs a short real bash script through the tool executor (policy, approval, confinement and all), streaming its
/// output to the live hub the console listens to. Approvals are answered automatically: this is a development harness.
@MainActor
func runRealScript(_ model: AppModel, console: ConsoleModel) async throws -> String {
    let s = model.services
    let runID = UUID().uuidString
    let artifacts = s.paths.artifacts.appendingPathComponent(runID)
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    var record = RunRecord(id: runID, kind: "script", title: "Sample · Disk and folder report (real shell.script run)", trigger: "manual", mode: .guided,
                           status: .running, startedAt: Date())
    try await s.store.saveRun(record)
    await console.start(runID: runID, services: s)

    let approver = Task {
        for await pending in s.approvals.updates() { for r in pending { await s.approvals.resolve(id: r.id, response: .approveOnce) } }
    }
    let script = """
    echo "Checking the workspace"
    for i in 1 2 3 4 5; do echo "step $i of 5: $(date +%H:%M:%S)"; sleep 0.15; done
    echo "a warning written to standard error" >&2
    ls -1 /usr/share/dict | head -5
    df -h / | tail -1
    echo "done"
    """
    let hub = s.runs.live
    hub.publish(runID, .status(.running))
    let call = ToolCall(toolID: "shell.script", arguments: ["script": .string(script)])
    hub.publish(runID, .toolStarted(call))
    let context = InvocationContext(runID: runID, mode: .guided, workingDirectory: s.paths.scratch, artifactsDirectory: artifacts,
                                    progress: { callID, p in hub.publish(runID, .toolProgress(callID: callID, p)) })
    let result = await s.executor.invoke(call, context: context)
    hub.publish(runID, .toolFinished(call, result))
    approver.cancel()

    // A real artifact with a real checksum, and a check that is actually performed.
    let report = artifacts.appendingPathComponent("report.txt")
    try Data((result.output["stdout"]?.stringValue ?? result.summary).utf8).write(to: report)
    let data = try Data(contentsOf: report)
    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let exists = FileManager.default.fileExists(atPath: report.path)
    record.status = result.status == .succeeded ? .succeeded : .failed
    record.endedAt = Date(); record.usage.toolCalls = 1
    record.errorSummary = result.failure?.message
    try await s.store.saveRun(record)
    try await s.store.saveReceipt(RunReceipt(
        runID: runID, title: record.title, status: record.status, objective: "Run a short bash script and keep its output as a report.", model: nil,
        startedAt: record.startedAt ?? Date(), endedAt: record.endedAt ?? Date(), usage: record.usage,
        toolCalls: [ToolCallRecord(id: call.id, toolID: call.toolID, arguments: ["script": "(bash, 6 lines)"], status: result.status, summary: result.summary,
                                   durationMs: result.durationMs, tier: .consequential)],
        approvals: ["Approved once by the preview harness"], permissionsUsed: ["shell.script (bash)"],
        artifacts: [Artifact(path: report.path, kind: "report", bytes: data.count, sha256: sha),
                    Artifact(path: artifacts.appendingPathComponent("removed-later.log").path, kind: "log", bytes: 120, note: "Deleted after the run")],
        verifications: [VerificationResult(assertion: "report.txt exists in the run's artifacts folder", kind: "file_exists", passed: exists, evidence: exists ? "found, \(data.count) bytes" : "not found")],
        agentSummary: "", limitations: ["The script ran confined: it could not write outside its artifacts folder."]))
    hub.publish(runID, .finished(record.status))
    hub.finish(runID)
    try? await Task.sleep(nanoseconds: 400_000_000)
    await console.refreshPersisted()
    return runID
}

@MainActor
func shoot<V: View>(_ name: String, _ view: V, _ model: AppModel, size: CGSize, dir: URL, settle: Double = 1.4) async {
    for dark in [true, false] {
        let url = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        do { try await ShotRenderer.render(view.environment(model), size: size, dark: dark, settle: settle, to: url); print("SHOT \(url.path)") }
        catch { print("FAILED \(name): \(error)") }
    }
}

@MainActor
func main() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--shot"), args.count > i + 1 else { print("usage: orix-preview-runs --shot <dir>"); exit(2) }
    let dir = URL(fileURLWithPath: args[i + 1])
    do {
        let model = try await PreviewEnvironment.make()
        let s = model.services
        let wide = CGSize(width: 1280, height: 820)

        // Console: real output streamed while the model listens.
        let console = ConsoleModel()
        let scriptRun = try await runRealScript(model, console: console)
        await shoot("console-live", RunsPreviewScreens.console(console).padding(16), model, size: CGSize(width: 1100, height: 560), dir: dir)
        console.query = "step"
        await shoot("console-search", RunsPreviewScreens.console(console).padding(16), model, size: CGSize(width: 1100, height: 560), dir: dir)
        console.stop()

        // A run that needs recovery, and richer usage on one sample, so those states are visible.
        if var r = try await s.store.run(id: "sample-5") {
            r.usage.tokens = TokenUsage(inputTokens: 36_000, outputTokens: 1_500, cacheReadTokens: 12_000, cacheWriteTokens: 4_000)
            r.usage.costIsComplete = false
            try await s.store.saveRun(r)
        }
        try await s.store.saveRun(RunRecord(id: "sample-recovery", kind: "agent", title: "Sample · Rename scanned invoices", trigger: "manual", mode: .guided,
                                            status: .recoveryRequired, model: ModelRef(provider: .anthropic, model: "claude-haiku-5-5"),
                                            startedAt: Date().addingTimeInterval(-900), endedAt: Date().addingTimeInterval(-840)))

        // A checkpoint with an action in flight, written the way the runtime stores it, so the recovery choices show.
        let task = AgentTask(objective: "Rename the scanned invoices in ~/Documents/Invoices by date", workingDirectory: s.paths.scratch.path)
        let inFlight = ToolCall(toolID: "filesystem.move", arguments: ["source": "scan-014.pdf", "destination": "2026-11-03-invoice.pdf"])
        let checkpoint: JSONValue = ["runID": "sample-recovery", "task": try JSONValue.encoding(task), "profile": try JSONValue.encoding(BuiltInAgents.all[0]),
                                     "messages": [], "usage": try JSONValue.encoding(RunUsage()), "toolCalls": [], "turn": 4,
                                     "inFlightCall": try JSONValue.encoding(inFlight), "savedAt": try JSONValue.encoding(Date()), "modelVersion": 1]
        if let cp = try? checkpoint.decode(AgentCheckpoint.self) {
            try await s.store.put(cp, collection: Collections.agentCheckpoints, id: "sample-recovery")
        } else { print("NOTE: could not build a sample checkpoint; the recovery sheet shows its no-checkpoint state") }

        // Two real schedules, created through services.
        let workflows = await s.workflows.list()
        if workflows.count >= 2 {
            try await s.workflows.saveSchedule(Schedule(workflowID: workflows[0].id, name: workflows[0].name, trigger: .cron(expression: "0 9 * * MON", timezone: "America/Toronto"),
                                                        enabled: true, missedRunPolicy: .runOnce, concurrency: .skipIfRunning, maxRetries: 2))
            try await s.workflows.saveSchedule(Schedule(workflowID: workflows[1].id, name: workflows[1].name,
                                                        trigger: .fileChange(path: NSHomeDirectory() + "/Documents/Research", recursive: true, glob: "*.pdf", debounceSeconds: 5),
                                                        enabled: true, concurrency: .queue))
            try await s.workflows.saveSchedule(Schedule(workflowID: workflows[1].id, name: workflows[1].name, trigger: .cron(expression: "30 7,18 * * *", timezone: "Europe/Paris"), enabled: true))
        }
        await model.refreshShared()

        await shoot("dashboard", DashboardView(), model, size: CGSize(width: 1280, height: 1560), dir: dir, settle: 2.0)
        await shoot("dashboard-compact", DashboardView(), model, size: CGSize(width: 1100, height: 700), dir: dir, settle: 2.0)
        model.selectedRunID = "sample-0"
        await shoot("runs-timeline", RunsPreviewScreens.runs(tab: "timeline"), model, size: wide, dir: dir)
        model.selectedRunID = scriptRun
        await shoot("runs-receipt", RunsPreviewScreens.runs(tab: "receipt"), model, size: CGSize(width: 1280, height: 1100), dir: dir)
        await shoot("runs-console", RunsPreviewScreens.runs(tab: "console"), model, size: wide, dir: dir)
        model.selectedRunID = "sample-5"
        await shoot("runs-usage", RunsPreviewScreens.runs(tab: "usage"), model, size: CGSize(width: 1280, height: 1000), dir: dir)
        model.selectedRunID = "sample-recovery"
        await shoot("runs-recovery", RunsPreviewScreens.runs(tab: "timeline"), model, size: wide, dir: dir)
        if let r = try await s.store.run(id: "sample-recovery") {
            await shoot("recovery-sheet", RunsPreviewScreens.recovery(r), model, size: CGSize(width: 560, height: 520), dir: dir)
        }
        await shoot("scheduler-list", RunsPreviewScreens.scheduler(tab: "schedules"), model, size: wide, dir: dir)
        await shoot("scheduler-agenda", RunsPreviewScreens.scheduler(tab: "agenda"), model, size: CGSize(width: 1280, height: 1000), dir: dir)
        await shoot("scheduler-queue", RunsPreviewScreens.scheduler(tab: "queue"), model, size: wide, dir: dir)
        let schedules = await s.workflows.schedules()
        await shoot("schedule-editor", RunsPreviewScreens.scheduleEditor(existing: schedules.first { $0.enabled }, workflows: workflows), model,
                    size: CGSize(width: 640, height: 720), dir: dir)

        let empty = try await PreviewEnvironment.make(seed: false)
        await shoot("dashboard-empty", DashboardView(), empty, size: wide, dir: dir)
        await shoot("runs-empty", RunsView(), empty, size: wide, dir: dir)
        await shoot("scheduler-empty", SchedulerView(), empty, size: wide, dir: dir)
        try? FileManager.default.removeItem(at: s.paths.root)
        try? FileManager.default.removeItem(at: empty.services.paths.root)
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }
    exit(0)
}

setvbuf(stdout, nil, _IONBF, 0)
_ = NSApplication.shared
Task { await main() }
RunLoop.main.run()
