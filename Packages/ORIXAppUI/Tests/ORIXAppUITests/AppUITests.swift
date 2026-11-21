// ORIX OS Automation
// File: Packages/ORIXAppUI/Tests/ORIXAppUITests/AppUITests.swift
// Description: Renders the shared approval card off screen and checks the app model wiring against real services in a temp folder.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import SwiftUI
import Testing
@testable import ORIXAppUI

@Suite("Integration · app model") @MainActor struct AppUITests {
    @Test func modelLoadsSeededStateAndRendersTheApprovalCard() async throws {
        let model = try await PreviewEnvironment.make()
        #expect(model.settings.onboardingCompleted)
        #expect(try await model.services.store.runs(limit: 50).count == 6)
        let access = AccessRequest(runID: "r", callID: "c", toolID: "filesystem.move", capabilities: [.fileWrite(path: "/Users/x/Downloads/Sorted")],
                                   tier: .reversibleWrite, sideEffect: .write, mode: .guided, summary: "Move 14 files from ~/Downloads to ~/Downloads/Sorted",
                                   argumentsPreview: ["source": "~/Downloads", "destination": "~/Downloads/Sorted"])
        let req = ApprovalRequest(access: access, missing: access.capabilities, reason: "No grant covers writing to this folder.")
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("orix-approval-card.png")
        try await ShotRenderer.render(ApprovalCard(request: req) { _ in }.padding(24).environment(model), size: CGSize(width: 560, height: 420), to: out)
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        #expect(size > 10_000)
        print("SHOT \(out.path)")
    }
}
