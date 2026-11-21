// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : UITests/ORIXAutomationUITests.swift
// Description      : Drives the real app: first-run onboarding, navigation
//                    through every section, and persistence of a setting across
//                    a relaunch. Uses a throwaway data folder and a test
//                    Keychain service.
// Module           : UITests
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

import XCTest

final class ORIXAutomationUITests: XCTestCase {
    var dataDir = ""

    override func setUp() {
        continueAfterFailure = false
        dataDir = NSTemporaryDirectory() + "orix-uitest-" + UUID().uuidString.prefix(8)
    }

    func launch(skipOnboarding: Bool, section: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ORIXDataDir", dataDir, "-ORIXUITest", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
        if skipOnboarding { app.launchArguments += ["-ORIXSkipOnboarding", "YES"] }
        if let section { app.launchArguments += ["-ORIXSection", section] }
        app.launch()
        return app
    }

    func testFirstLaunchShowsOnboardingAndEverySectionOpens() {
        let first = launch(skipOnboarding: false)
        XCTAssertTrue(first.sheets.firstMatch.waitForExistence(timeout: 20), "the welcome guide should appear on first launch")
        first.terminate()

        let app = launch(skipOnboarding: true)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        // Navigation goes through the command palette (keyboard only), so the test does not depend on where the window sits.
        let expected: [(String, String)] = [
            ("Go to Dashboard", "Dashboard"), ("Go to Agent", "Say what you want done"), ("Go to Workflow Studio", "Workflows"), ("Go to Code Studio", "Code Studio"),
            ("Go to Runs", "Runs"), ("Go to Scheduler", "Scheduler"), ("Go to Agents", "Agents"), ("Go to Skills", "Skills"), ("Go to Watch", "Watch & Learn"),
            ("Go to Permissions", "Permissions"), ("Go to Settings", "Settings"),
        ]
        for (command, text) in expected {
            app.typeKey("k", modifierFlags: .command)
            let field = app.textFields["palette.search"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "palette for \(command)")
            field.typeText(command + "\n")
            let label = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 10), "\(command) should show “\(text)”")
            XCTAssertTrue(app.descendants(matching: .any)["sidebar.dashboard"].firstMatch.exists)
        }
        XCTAssertTrue(app.descendants(matching: .any)["app.emergencyStop"].firstMatch.exists)
        app.terminate()
    }

    func testCommandPaletteOpensAndNavigates() {
        let app = launch(skipOnboarding: true)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["palette.search"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.typeText("Go to Runs\n")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Runs' OR value CONTAINS[c] 'Runs'")).firstMatch.waitForExistence(timeout: 10))
        app.terminate()
    }
}
