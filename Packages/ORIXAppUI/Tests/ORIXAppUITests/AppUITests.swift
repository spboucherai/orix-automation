// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppUI/Tests/ORIXAppUITests/AppUITests.swift
// Description      : Renders the shared approval card off screen and checks the
//                    app model wiring against real services in a temp folder.
// Module           : ORIXAppUITests
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
