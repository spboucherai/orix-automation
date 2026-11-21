// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Sources/orix-preview-manage/main.swift
// Description: Renders every screen of the management sections (Settings, Permissions, Agents, Skills, Onboarding, Watch & Learn) to PNG files on a throwaway data folder.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import ORIXFeatureManage
import SwiftUI

/// An obviously fake key, stored only in the preview Keychain service while the provider screens render, then deleted.
let previewKey = "sk-test-0000000000000000"

@MainActor
func shot<V: View>(_ name: String, _ view: V, _ model: AppModel, to dir: URL, size: CGSize = CGSize(width: 1100, height: 760), settle: Double = 1.4) async throws {
    for dark in [true, false] {
        let url = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try await ShotRenderer.render(view.environment(model), size: size, dark: dark, settle: settle, to: url)
        print("SHOT \(url.path)")
    }
}

/// Synthetic actions for the review screen. The view labels them as a sample.
func sampleRecording() -> [RecordedAction] {
    let notes = "com.apple.Notes"
    return [
        RecordedAction(sequence: 1, kind: .recordingStarted, summary: "Recording started for \(notes)"),
        RecordedAction(sequence: 2, kind: .appActivated, bundleID: notes, appName: "Notes", summary: "Switched to Notes"),
        RecordedAction(sequence: 3, kind: .menuItemSelected, bundleID: notes, appName: "Notes", role: "AXMenuItem", title: "New Note", summary: "chose menu item \"New Note\""),
        RecordedAction(sequence: 4, kind: .windowFocused, bundleID: notes, appName: "Notes", role: "AXWindow", title: "Notes", summary: "window \"Notes\" came to the front"),
        RecordedAction(sequence: 5, kind: .focusChanged, bundleID: notes, appName: "Notes", role: "AXTextField", title: "Search", summary: "focused AXTextField \"Search\""),
        RecordedAction(sequence: 6, kind: .valueChanged, bundleID: notes, appName: "Notes", role: "AXTextField", title: "Search", summary: "typed text of length 14 in field \"Search\"", coalesced: 14),
        RecordedAction(sequence: 7, kind: .valueChanged, bundleID: notes, appName: "Notes", role: "AXCheckBox", title: "Pin note", summary: "set AXCheckBox \"Pin note\" to true", value: true),
        RecordedAction(sequence: 8, kind: .valueChanged, bundleID: notes, appName: "Notes", role: "AXSecureTextField", title: "Password", summary: "edited secure field \"Password\" (content and length not recorded)"),
        RecordedAction(sequence: 9, kind: .selectionChanged, bundleID: notes, appName: "Notes", role: "AXOutline", title: "Folders", summary: "selection changed in AXOutline \"Folders\""),
        RecordedAction(sequence: 10, kind: .recordingStopped, summary: "Recording stopped"),
    ]
}

@MainActor
func seed(_ model: AppModel) async throws {
    let s = model.services
    // A user agent with an evaluation case.
    let agent = AgentProfile(id: "sample-agent", name: "sample-report-writer", role: "specialist",
                             instructions: "Sample agent. Read the documents in the workspace and write a one-page summary in report.md. Quote figures exactly.",
                             model: ModelRef(provider: .anthropic, model: ""), toolPatterns: ["filesystem.list", "filesystem.read", "filesystem.write", "documents.*"],
                             memoryScopes: ["session", "user"])
    try await s.agents.save(agent)
    // Memory records, one of them waiting for approval.
    await s.memory.save(MemoryRecord(scope: .user, kind: "preference", text: "Sample · Write reports in Canadian French.", provenance: "run sample-1", approved: false))
    await s.memory.save(MemoryRecord(scope: .user, kind: "convention", text: "Sample · Dates are written YYYY-MM-DD.", provenance: "user", approved: true))
    await s.memory.save(MemoryRecord(scope: .workflow("system-health-report"), kind: "fix", text: "Sample · diskUsage needs the volume path, not the device name.", provenance: "run sample-4"))
    // One revoked grant so the history is visible, and one workflow-scoped acceptance.
    let extra = PermissionGrant(capability: .fileWrite(path: NSHomeDirectory() + "/Documents/Reports"), scope: .persistent, maxTier: .reversibleWrite, note: "Sample grant")
    await s.policy.add(extra)
    await s.policy.revoke(id: extra.id)
    if let wf = await s.workflows.list().first { try? await s.workflows.acceptPermissions(workflowID: wf.id) }
    // A real skill: proposed, analysed, tested and installed through the services.
    let built = try SkillFormPreview.wordCount()
    let draft = try await s.skills.propose(manifest: built.manifest, sources: built.sources, source: "user")
    if draft.installable {
        _ = try await s.skills.install(draftID: draft.id)
        await s.refreshSkillTools()
    } else {
        print("NOTE the word-count skill could not be installed here: \(draft.tests.map(\.detail)) \(draft.findings.map(\.message))")
    }
    // A draft the review blocks: it uses the network without declaring a host.
    var bad = built.manifest
    bad.id = "skill.fetchTitle"; bad.name = "Fetch title"; bad.summary = "Sample · Downloads a page and returns its title."
    _ = try await s.skills.propose(manifest: bad, sources: ["main.py": "import json, sys, urllib.request\n\nargs = json.load(sys.stdin)\npage = urllib.request.urlopen(\"https://example.com\").read()\nprint(json.dumps({\"words\": len(page.split()), \"lines\": 1}))\n"], source: "import:sample-folder")
    await model.refreshShared()
}

/// The word-count skill used by the preview, as a manifest and sources.
enum SkillFormPreview {
    static func wordCount() throws -> (manifest: SkillManifest, sources: [String: String]) {
        let source = "import json, sys\n\nargs = json.load(sys.stdin)\nwith open(args[\"path\"], \"r\", encoding=\"utf-8\") as handle:\n    text = handle.read()\nprint(json.dumps({\"words\": len(text.split()), \"lines\": len(text.splitlines())}))\n"
        let manifest = SkillManifest(
            id: "skill.wordCount", name: "Word count", summary: "Counts the words and lines of a text file.",
            inputSchema: .object(["path": .string("Text file to count.")], required: ["path"]),
            outputSchema: .object(["words": .integer(), "lines": .integer()], required: ["words", "lines"], additional: true),
            permissions: SkillPermissions(fileRead: ["$input.path"]), author: "ORIX preview",
            tests: [SkillTestCase(name: "counts a small file", input: ["path": "$fixture/sample.txt"], files: ["sample.txt": "one two three\nfour five\n"],
                                  expectOutput: ["words": 5, "lines": 2])])
        return (manifest, ["main.py": source])
    }
}

@MainActor
func run(_ dir: URL) async throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let model = try await PreviewEnvironment.make()
    try await seed(model)
    let tall = CGSize(width: 1100, height: 1500)

    // Settings. The fake key exists only while the Providers pane renders.
    try await model.services.providers.setKey(previewKey, for: .anthropic)
    await model.refreshShared()
    do {
        try await shot("settings-providers", SettingsView(tab: .providers, expandCatalogFor: .anthropic), model, to: dir, size: CGSize(width: 1100, height: 2000), settle: 3.0)
        try await shot("settings-providers-compact", SettingsView(tab: .providers), model, to: dir, size: CGSize(width: 1100, height: 700), settle: 2.0)
        try await shot("onboarding-2-provider", OnboardingView(step: 1) {}, model, to: dir, size: CGSize(width: 1100, height: 900), settle: 3.0)
    } catch {
        try? await model.services.providers.removeKey(for: .anthropic)
        throw error
    }
    try await model.services.providers.removeKey(for: .anthropic)
    Redactor.shared.unregister(secret: previewKey)
    await model.refreshShared()
    print("KEY preview key removed: \(await model.services.providers.keySource(for: .anthropic) == .none)")

    try await shot("settings-general", SettingsView(tab: .general), model, to: dir, size: CGSize(width: 1100, height: 1100))
    try await shot("settings-privacy", SettingsView(tab: .privacy), model, to: dir, size: tall)
    try await shot("settings-storage", SettingsView(tab: .storage), model, to: dir, size: tall, settle: 2.0)
    try await shot("settings-diagnostics", SettingsView(tab: .diagnostics), model, to: dir, size: CGSize(width: 1100, height: 1000), settle: 2.0)
    try await shot("settings-updates", SettingsView(tab: .updates), model, to: dir)

    // Permissions
    try await shot("permissions-macos", PermissionsView(tab: .macOS), model, to: dir, size: CGSize(width: 1100, height: 1300), settle: 2.0)
    try await shot("permissions-grants", PermissionsView(tab: .grants), model, to: dir, size: CGSize(width: 1100, height: 1100))
    try await shot("permissions-grants-add", PermissionsView(tab: .grants, showAddForm: true), model, to: dir, size: CGSize(width: 1100, height: 900))
    try await shot("permissions-approval", PermissionsView(tab: .approval), model, to: dir, size: CGSize(width: 1100, height: 1000))
    try await shot("permissions-audit", PermissionsView(tab: .audit), model, to: dir)

    // Agents
    try await shot("agents-list", AgentsView(tab: .profiles), model, to: dir, size: CGSize(width: 1100, height: 760))
    try await shot("agents-editor", AgentsView(tab: .profiles, selectAgentNamed: "sample-report-writer", expandedFamilies: ["filesystem"]), model, to: dir, size: CGSize(width: 1100, height: 2300))
    try await shot("agents-memory", AgentsView(tab: .memory), model, to: dir)

    // Skills
    try await shot("skills-installed", SkillsView(tab: .installed), model, to: dir)
    try await shot("skills-drafts", SkillsView(tab: .drafts), model, to: dir, size: CGSize(width: 1100, height: 1000))
    try await shot("skills-catalog", SkillsView(tab: .catalog, selectTool: "filesystem.move"), model, to: dir, size: CGSize(width: 1100, height: 900))
    try await shot("skills-author", SkillsView(tab: .author), model, to: dir, size: CGSize(width: 1100, height: 1700))
    if let draft = await model.services.skills.allDrafts().first {
        try await shot("skills-install-confirmation", InstallConfirmationPreview(draft: draft), model, to: dir, size: CGSize(width: 560, height: 520))
    }

    // Onboarding
    try await shot("onboarding-1-welcome", OnboardingView(step: 0) {}, model, to: dir)
    try await shot("onboarding-3-workspace", OnboardingView(step: 2) {}, model, to: dir, size: CGSize(width: 1100, height: 860))
    try await shot("onboarding-4-permissions", OnboardingView(step: 3) {}, model, to: dir, size: CGSize(width: 1100, height: 860), settle: 2.0)
    try await shot("onboarding-5-done", OnboardingView(step: 4) {}, model, to: dir)

    // Watch & Learn
    try await shot("watch-idle", WatchAndLearnView(), model, to: dir, size: CGSize(width: 1100, height: 1000))
    try await shot("watch-review-sample", WatchAndLearnView(sampleRecording: sampleRecording()), model, to: dir, size: CGSize(width: 1100, height: 1150))
    try await shot("watch-proposal-sample", WatchAndLearnView(sampleRecording: sampleRecording(), showProposal: true), model, to: dir, size: CGSize(width: 1100, height: 1150), settle: 2.0)

    await model.services.shutdown()
    try? FileManager.default.removeItem(at: model.services.paths.root)
}

_ = NSApplication.shared
let arguments = CommandLine.arguments
guard let i = arguments.firstIndex(of: "--shot"), arguments.count > i + 1 else {
    print("usage: orix-preview-manage --shot <directory>")
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[i + 1])
Task { @MainActor in
    do { try await run(directory); exit(0) } catch {
        print("FAILED \(error)")
        exit(1)
    }
}
RunLoop.main.run()
