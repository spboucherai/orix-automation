// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : App/Sources/App/main.swift
// Description      : Entry point. The same signed executable is the app and,
//                    when launchd starts it with --background-agent, the
//                    headless scheduler.
// Module           : App
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

if CommandLine.arguments.contains("--background-agent") {
    BackgroundAgent.runForever()
} else {
    ORIXApp.main()
}

/// The headless half of the product. No window, nobody to answer approvals: anything not already granted parks as
/// WAITING_APPROVAL and a notification says so.
enum BackgroundAgent {
    static func runForever() -> Never {
        // An accessory app: no Dock icon, but a main run loop for workspace, power and file-system observers.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                var options = ServiceOptions()
                options.interactive = false
                let services = try await ORIXServices.bootstrap(options: options)
                let settings = await services.runs.settings()
                guard settings.backgroundAgentEnabled else { exit(0) }   // disabled in Settings: leave quietly, launchd does not restart a clean exit
                _ = await services.runs.recoverInterrupted(startedAt: services.processStart)
                await services.workflows.startScheduler(owner: "agent-\(ProcessInfo.processInfo.processIdentifier)")
                AgentNotifier.shared.start(services: services)
            } catch {
                NSLog("ORIX background agent could not start: %@", error.localizedDescription)
                exit(1)
            }
        }
        app.run()
        exit(0)
    }
}
