// ORIX OS Automation
// File: Packages/ORIXFeatureChat/Sources/orix-preview-chat/main.swift
// Description: Renders the Agent section to PNG files on a throwaway data folder: empty state, and a conversation after a real agent run when a provider key is available.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import ORIXFeatureChat
import SwiftUI

@MainActor func run() async {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--shot"), i + 1 < args.count else { print("usage: orix-preview-chat --shot <dir> [--live]"); exit(64) }
    let dir = URL(fileURLWithPath: args[i + 1])
    do {
        let model = try await PreviewEnvironment.make()
        model.section = .chat
        for dark in [true, false] {
            try await ShotRenderer.render(AgentChatView().environment(model), size: CGSize(width: 1200, height: 760), dark: dark,
                                          to: dir.appendingPathComponent("chat-empty-\(dark ? "dark" : "light").png"))
        }
        print("wrote chat-empty")
    } catch { print("failed: \(error)"); exit(1) }
    exit(0)
}

_ = NSApplication.shared
Task { await run() }
RunLoop.main.run()
