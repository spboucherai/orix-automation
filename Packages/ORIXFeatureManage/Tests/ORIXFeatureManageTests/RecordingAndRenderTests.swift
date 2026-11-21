// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Tests/ORIXFeatureManageTests/RecordingAndRenderTests.swift
// Description: Conversion of synthetic recordings to workflows validated against the real tool manifests, the Watch & Learn model, onboarding completion, and one render test per screen.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import SwiftUI
import Testing
@testable import ORIXFeatureManage
import ORIXAppUI

func syntheticRecording() -> [RecordedAction] {
    let app = "com.example.Editor"
    return [
        RecordedAction(sequence: 1, kind: .recordingStarted, summary: "Recording started"),
        RecordedAction(sequence: 2, kind: .limitation, summary: "Button clicks have no Accessibility notification"),
        RecordedAction(sequence: 3, kind: .appLaunched, bundleID: app, appName: "Editor", summary: "Launched Editor"),
        RecordedAction(sequence: 4, kind: .appActivated, bundleID: app, appName: "Editor", summary: "Switched to Editor"),
        RecordedAction(sequence: 5, kind: .menuItemSelected, bundleID: app, appName: "Editor", role: "AXMenuItem", title: "New Document", summary: "chose menu item"),
        RecordedAction(sequence: 6, kind: .windowCreated, bundleID: app, appName: "Editor", role: "AXWindow", title: "Untitled", summary: "window opened"),
        RecordedAction(sequence: 7, kind: .focusChanged, bundleID: app, appName: "Editor", role: "AXTextField", title: "Title", identifier: "title-field", summary: "focused"),
        RecordedAction(sequence: 8, kind: .valueChanged, bundleID: app, appName: "Editor", role: "AXTextField", title: "Title", summary: "typed text of length 9 in field \"Title\"", coalesced: 9),
        RecordedAction(sequence: 9, kind: .valueChanged, bundleID: app, appName: "Editor", role: "AXCheckBox", title: "Shared", summary: "set AXCheckBox to true", value: true),
        RecordedAction(sequence: 10, kind: .valueChanged, bundleID: app, appName: "Editor", role: "AXTextField", title: "Author", summary: "typed \"Ada\"", value: "Ada"),
        RecordedAction(sequence: 11, kind: .valueChanged, bundleID: app, appName: "Editor", role: "AXSecureTextField", title: "Password", summary: "edited secure field"),
        RecordedAction(sequence: 12, kind: .focusChanged, bundleID: app, appName: "Editor", role: "AXGroup", summary: "focused AXGroup"),
        RecordedAction(sequence: 13, kind: .selectionChanged, bundleID: app, appName: "Editor", role: "AXOutline", title: "Files", summary: "selection changed"),
        RecordedAction(sequence: 14, kind: .appTerminated, bundleID: app, appName: "Editor", summary: "Quit Editor"),
        RecordedAction(sequence: 15, kind: .recordingStopped, summary: "Recording stopped"),
    ]
}

func toolSteps(_ doc: WorkflowDocument) -> [(id: String, tool: String, args: [String: JSONValue])] {
    doc.spec.steps.compactMap { s in if case .tool(let t) = s.kind { return (s.id, t.tool, t.arguments) }; return nil }
}

@Suite("Unit · recording to workflow") struct RecordingToWorkflowTests {
    @Test func actionsBecomeSemanticStepsWithPostconditions() {
        let reviewed = syntheticRecording().map { ReviewedAction(action: $0, variable: $0.sequence == 10 ? "Author Name" : nil) }
        let p = RecordingToWorkflow.convert(reviewed, name: "Create a document")
        let steps = toolSteps(p.document)
        #expect(p.document.metadata.id == "create-a-document")
        // Launch + activation collapse into one step; quit maps to quitApp.
        #expect(steps.filter { $0.tool == "system.launchApp" }.count == 1 && steps.first?.tool == "system.launchApp")
        #expect(steps.last?.tool == "system.quitApp")
        // Menu → find + press; focus → find + focus + waitFor; values → find + setValue + waitFor.
        #expect(steps.filter { $0.tool == "accessibility.press" }.count == 1)
        #expect(steps.filter { $0.tool == "accessibility.focus" }.count == 1)
        #expect(steps.filter { $0.tool == "accessibility.setValue" }.count == 3)
        #expect(steps.filter { $0.tool == "accessibility.waitFor" }.count == 1 + 1 + 3)
        // Every action step addresses the element found by role/title, never a coordinate.
        for s in steps where ["accessibility.press", "accessibility.focus", "accessibility.setValue"].contains(s.tool) {
            #expect(s.args["element"]?.stringValue?.hasPrefix("${{ steps.find") == true)
        }
        for s in steps { #expect(Set(s.args.keys).isDisjoint(with: ["x", "y", "point", "position", "frame", "coordinates"])) }
        for s in steps where s.tool == "accessibility.find" { #expect(s.args["role"] != nil && (s.args["title"] != nil || s.args["identifier"] != nil)) }
        // The chain is linear.
        for (i, s) in p.document.spec.steps.enumerated() { #expect(s.needs == (i == 0 ? [] : [p.document.spec.steps[i - 1].id])) }
        // Unrecorded text → required parameter; labelled value → named parameter with the recorded default; plain value kept.
        let params = p.document.spec.parameters
        #expect(params.map(\.name) == ["title", "authorName"])
        #expect(params[0].required && params[0].defaultValue == nil)
        #expect(params[1].defaultValue == "Ada" && !params[1].required)
        #expect(steps.contains { $0.tool == "accessibility.setValue" && $0.args["value"] == true })
        #expect(steps.contains { $0.tool == "accessibility.setValue" && $0.args["value"] == "${{ params.authorName }}" })
        // Secure fields, unlabelled elements and selection changes are left out, with a reason.
        #expect(!p.yaml.contains("Password") && !p.yaml.contains("AXSecureTextField"))
        #expect(p.notes.count == 4)
        #expect(p.convertedActions == 8)
        // Permissions: only the recorded application, nothing else.
        let perms = p.document.spec.permissions
        #expect(perms.apps.accessibility == ["com.example.Editor"] && perms.apps.control == ["com.example.Editor"] && perms.apps.automation.isEmpty)
        var onlyApps = WorkflowPermissions(); onlyApps.apps = perms.apps
        #expect(perms == onlyApps)
        #expect(Set(p.capabilities) == [.accessibility(bundleID: "com.example.Editor"), .appControl(bundleID: "com.example.Editor")])
    }

    @Test func redactionDropsValuesAndTitles() {
        let actions = syntheticRecording()
        let reviewed = actions.map { ReviewedAction(action: $0, redacted: $0.sequence == 10 || $0.sequence == 6) }
        let p = RecordingToWorkflow.convert(reviewed, name: "")
        #expect(!p.yaml.contains("Ada") && !p.yaml.contains("Untitled"))
        #expect(p.document.metadata.name == "Recorded workflow")
        #expect(p.notes.contains { $0.contains("Action 6") } && p.notes.contains { $0.contains("Action 10") })
        let empty = RecordingToWorkflow.convert([], name: "x")
        #expect(empty.document.spec.steps.isEmpty && empty.notes.count == 1 && empty.capabilities.isEmpty)
    }

    @Test func parameterNamesAreValidIdentifiers() {
        #expect(RecordingToWorkflow.parameterName("Author Name") == "authorName")
        #expect(RecordingToWorkflow.parameterName("  2nd e-mail! ") == "v2ndEMail")
        #expect(RecordingToWorkflow.parameterName("§§") == "value")
        #expect(RecordingToWorkflow.parameterName("Word count") == "wordCount")
    }
}

@Suite("Integration · watch and learn, onboarding") @MainActor struct WatchAndOnboardingTests {
    @Test func proposedWorkflowValidatesAgainstRealManifestsAndSavesOnlyOnApproval() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let reviewed = syntheticRecording().map { ReviewedAction(action: $0) }
        let p = RecordingToWorkflow.convert(reviewed, name: "Recorded editor task")
        let result = await model.services.workflows.diagnose(p.yaml)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors)")
        #expect(result.document == p.document)                     // YAML round trip keeps the document

        let w = WatchModel(services: model.services)
        w.beginReview(syntheticRecording(), sample: true)
        #expect(w.phase == .review && w.isSample)
        #expect(w.items.count == 12)                                // markers and limitations are not review items
        w.remove(try #require(w.items.first { $0.action.kind == .selectionChanged }).id)
        w.workflowName = "Recorded editor task"
        await w.propose()
        #expect(w.phase == .proposal && !w.hasErrors)
        #expect(await model.services.workflows.list().isEmpty)     // nothing is written before approval
        await w.save()
        let id = try #require(w.savedWorkflowID)
        #expect(await model.services.workflows.list().map(\.id) == [id])
        let review = try await model.services.workflows.permissionReview(workflowID: id, parameters: ["title": "Report"])
        #expect(!review.accepted && review.proposed.count == 2)    // saved, not granted
        w.discard()
        #expect(w.phase == .idle && w.items.isEmpty && w.actions.isEmpty && !RecordingStatus.shared.isRecording)
    }

    @Test func recorderRefusesToStartWithoutAnApplication() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let w = WatchModel(services: model.services)
        w.refreshApps()
        #expect(w.selected.isEmpty)                                 // nothing is preselected
        w.start()
        #expect(w.phase == .idle && w.error != nil && !RecordingStatus.shared.isRecording)
    }

    @Test func onboardingFinishMarksCompletion() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        model.settings.onboardingCompleted = false
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("orix-manage-onboarding-\(UUID().uuidString.prefix(6)).png")
        defer { try? FileManager.default.removeItem(at: out) }
        for step in 0..<5 {
            try await ShotRenderer.render(OnboardingView(step: step) {}.environment(model), size: CGSize(width: 1000, height: 720), settle: 0.5, to: out)
            #expect(((try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0) > 20_000)
        }
        #expect(model.settings.onboardingCompleted == false)        // rendering never completes onboarding by itself
    }
}

@Suite("Render · every screen") @MainActor struct RenderTests {
    func render<V: View>(_ name: String, _ view: V, _ model: AppModel, size: CGSize = CGSize(width: 1100, height: 760)) async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("orix-manage-test-\(name)-\(UUID().uuidString.prefix(6)).png")
        defer { try? FileManager.default.removeItem(at: out) }
        try await ShotRenderer.render(view.environment(model), size: size, settle: 0.7, to: out)
        let bytes = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        #expect(bytes > 25_000, "\(name) rendered only \(bytes) bytes")
    }

    @Test func settingsPanes() async throws {
        let model = try await PreviewEnvironment.make()
        for tab in SettingsTab.allCases { try await render("settings-\(tab.rawValue)", SettingsView(tab: tab), model) }
        try await render("settings-default", SettingsView(), model)
    }

    @Test func permissionsTabs() async throws {
        let model = try await PreviewEnvironment.make()
        for tab in PermissionsTab.allCases { try await render("permissions-\(tab.rawValue)", PermissionsView(tab: tab, showAddForm: tab == .grants), model) }
        try await render("permissions-default", PermissionsView(), model)
    }

    @Test func agentsTabs() async throws {
        let model = try await PreviewEnvironment.make()
        try await render("agents", AgentsView(), model)
        try await render("agents-editor", AgentsView(tab: .profiles, selectAgentNamed: "verifier", expandedFamilies: ["git"]), model, size: CGSize(width: 1100, height: 1200))
        try await render("agents-memory", AgentsView(tab: .memory), model)
    }

    @Test func skillsTabs() async throws {
        let model = try await PreviewEnvironment.make()
        let built = try SkillForm.wordCountTemplate.build()
        let draft = try await model.services.skills.propose(manifest: built.manifest, sources: built.sources, source: "user")
        try await render("skills-default", SkillsView(), model)
        for tab in SkillsTab.allCases { try await render("skills-\(tab.rawValue)", SkillsView(tab: tab, selectTool: "git.status"), model) }
        try await render("skills-install", InstallConfirmationPreview(draft: draft), model, size: CGSize(width: 560, height: 520))
    }

    @Test func watchAndLearnPhases() async throws {
        let model = try await PreviewEnvironment.make()
        try await render("watch-idle", WatchAndLearnView(), model)
        try await render("watch-review", WatchAndLearnView(sampleRecording: syntheticRecording()), model)
        try await render("watch-proposal", WatchAndLearnView(sampleRecording: syntheticRecording(), showProposal: true), model, size: CGSize(width: 1100, height: 1000))
    }
}
