// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureChat/Sources/orix-preview-chat/main.swift
// Description      : Renders the Agent section to PNG files on a throwaway data
//                    folder: empty state, and a conversation after a real agent
//                    run when a provider key is available.
// Module           : orix-preview-chat
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
