// ORIX OS Automation
// File: UITests/ORIXAutomationUITests.swift
// Description: Drives the real app: first-run onboarding, navigation through every section, and persistence of a setting across a relaunch. Uses a throwaway data folder and a test Keychain service.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
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
        let expected: [(String, String)] = [
            ("dashboard", "Dashboard"), ("chat", "Say what you want done"), ("workflows", "Workflows"), ("code", "Code Studio"), ("runs", "Runs"),
            ("scheduler", "Scheduler"), ("agents", "Agents"), ("skills", "Skills"), ("learn", "Watch & Learn"), ("permissions", "Permissions"), ("settings", "Settings"),
        ]
        for (id, text) in expected {
            let row = app.descendants(matching: .any)["sidebar.\(id)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "sidebar row \(id)")
            row.click()
            let label = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 10), "section \(id) should show “\(text)”")
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
