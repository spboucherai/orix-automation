// ORIX OS Automation
// File: Packages/ORIXFeatureChat/Tests/ORIXFeatureChatTests/ChatTests.swift
// Description: Chat logic against real services with a scripted (mock) provider: transcript building, a full send → tool → verified outcome cycle, steering, session persistence, rendering.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import SwiftUI
import Testing
@testable import ORIXFeatureChat
import ORIXAppUI
import ORIXTestingSupport

@Suite("Unit · transcript") struct TranscriptTests {
    @Test func eventsBecomeItemsAndOnlyTheLatestPlanIsShown() throws {
        let plan1 = try JSONValue.encoding(AgentPlan(objective: "o", steps: [PlanStep(id: "a", title: "one")], revision: 1))
        let plan2 = try JSONValue.encoding(AgentPlan(objective: "o", steps: [PlanStep(id: "a", title: "two")], revision: 2))
        let events = [
            RunEvent(runID: "r", kind: .userMessage, text: "Do it"), RunEvent(runID: "r", kind: .planUpdated, data: plan1),
            RunEvent(runID: "r", kind: .assistantText, text: "Looking"),
            RunEvent(runID: "r", kind: .toolFinished, data: ["callID": "c1", "toolID": "filesystem.list", "status": "succeeded", "summary": "3 entries", "durationMs": 4, "tier": 0]),
            RunEvent(runID: "r", kind: .planUpdated, data: plan2), RunEvent(runID: "r", kind: .usage), RunEvent(runID: "r", kind: .statusChanged, text: "SUCCEEDED"),
            RunEvent(runID: "r", kind: .verification, text: "PASS a.txt exists", data: ["passed": true]),
        ]
        let live = ["c1": ToolActivity(id: "c1", toolID: "filesystem.list", arguments: .null, status: nil, summary: "", durationMs: nil, tier: nil, liveOutput: ""),
                    "c2": ToolActivity(id: "c2", toolID: "shell.run", arguments: .null, status: nil, summary: "", durationMs: nil, tier: nil, liveOutput: "building")]
        let items = ChatModel.items(from: events, live: live)
        #expect(items.count == 6)
        let plans = items.compactMap { if case .plan(_, let p) = $0 { return p }; return nil }
        #expect(plans.count == 1 && plans[0].revision == 2)
        let tools = items.compactMap { if case .tool(let t) = $0 { return t }; return nil }
        #expect(tools.map(\.id) == ["c1", "c2"])           // finished call shown once, running call appended
        #expect(tools[0].status == .succeeded && tools[1].status == nil)
    }
}

@Suite("Integration · chat on real services (mock provider)") @MainActor struct ChatIntegrationTests {
    @Test func sendRunsToolsVerifiesAndPersistsTheSession() async throws {
        let app = try await PreviewEnvironment.make(seed: false)
        let work = try TempDirectory(prefix: "orix-chat"); defer { work.remove() }
        try work.write("notes.txt", "alpha\nbeta\n")
        let provider = ScriptedProvider(turns: [
            ScriptedProvider.tool("filesystem.read", ["path": "notes.txt"]),
            ScriptedProvider.tool("filesystem.write", ["path": "summary.txt", "content": "2 lines"]),
            ScriptedProvider.tool("task.complete", ["summary": "Wrote the summary.", "artifacts": [.string(work.file("summary.txt").path)]]),
        ])
        await app.services.providers.register(provider)
        var settings = AppSettings(); settings.onboardingCompleted = true; settings.defaultModel = ModelRef(provider: provider.id, model: "scripted-1")
        try await app.services.runs.save(settings); app.settings = settings

        let chat = ChatModel(app: app)
        await chat.load()
        chat.workspace = work.url.path; chat.access = .readWrite; chat.mode = .autonomous
        chat.draft = "Summarise notes.txt into summary.txt"
        await chat.send()
        #expect(chat.isRunning)
        let runID = try #require(chat.activeRunID)
        let final = await app.services.runs.wait(runID: runID)
        #expect(final?.status == .succeeded)
        try await Task.sleep(nanoseconds: 300_000_000)
        await chat.rebuild()
        #expect(!chat.isRunning)
        #expect(try String(contentsOf: work.file("summary.txt"), encoding: .utf8) == "2 lines")
        let tools = chat.items.compactMap { if case .tool(let t) = $0 { return t.toolID }; return nil }
        #expect(tools == ["filesystem.read", "filesystem.write"])
        #expect(chat.items.contains { if case .outcome(let o) = $0 { return o.status == .succeeded && o.artifacts.count == 1 }; return false })
        #expect(chat.items.contains { if case .verification(_, true, _) = $0 { return true }; return false })

        // The session is stored and a second model sees it after a relaunch.
        let again = ChatModel(app: app)
        await again.load()
        #expect(again.sessions.count == 1 && again.sessions[0].runIDs == [runID])
        #expect(again.items.count == chat.items.count)

        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orix-chat-conversation.png")
        try await ShotRenderer.render(AgentChatView().environment(app), size: CGSize(width: 1200, height: 760), to: out)
        #expect(((try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0) > 20_000)
        print("SHOT \(out.path)")
    }

    @Test func writeOutsideTheGrantWaitsForApprovalAndDenyLeavesNoFile() async throws {
        let app = try await PreviewEnvironment.make(seed: false)
        let work = try TempDirectory(prefix: "orix-chat"); defer { work.remove() }
        let provider = ScriptedProvider(turns: [ScriptedProvider.tool("filesystem.write", ["path": "x.txt", "content": "x"]), ScriptedProvider.text("I could not write the file.")])
        await app.services.providers.register(provider)
        var settings = AppSettings(); settings.defaultModel = ModelRef(provider: provider.id, model: "scripted-1")
        try await app.services.runs.save(settings); app.settings = settings
        let chat = ChatModel(app: app)
        await chat.load()
        chat.workspace = work.url.path; chat.access = .read; chat.mode = .autonomous   // read only: the write must ask
        chat.draft = "Write x.txt"
        await chat.send()
        let runID = try #require(chat.activeRunID)
        var waited = 0
        while app.pendingApprovals.isEmpty && waited < 100 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        let request = try #require(app.pendingApprovals.first)
        #expect(request.access.toolID == "filesystem.write" && request.access.tier == .reversibleWrite)
        #expect(request.missing == [.fileWrite(path: work.url.path + "/x.txt")])
        app.resolve(request, .deny(reason: "no"))
        let final = await app.services.runs.wait(runID: runID)
        #expect(final?.status != .succeeded)
        #expect(!FileManager.default.fileExists(atPath: work.file("x.txt").path))
    }
}
