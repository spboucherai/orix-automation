// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/Tools.swift
// Description: The package's tool list.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public enum ORIXAppleAutomationTools {
    /// Every tool of this package. `additionalSensitiveBundleIDs` extends the list of applications `screen.capture` never shows.
    public static func all(additionalSensitiveBundleIDs: Set<String> = []) -> [any ORIXTool] {
        [
            ScriptRunTool(language: .applescript),
            ScriptRunTool(language: .jxa),
            ScriptingDictionaryTool(),
            AccessibilityStatusTool(),
            AccessibilityTreeTool(),
            AccessibilityFindTool(),
            AccessibilityPressTool(),
            AccessibilitySetValueTool(),
            AccessibilityFocusTool(),
            AccessibilityTypeTextTool(),
            AccessibilityWaitForTool(),
            ScreenCaptureTool(additionalSensitiveBundleIDs: additionalSensitiveBundleIDs),
            ScreenOCRTool(),
            ScreenCompareTool(),
            SystemAppsTool(),
            SystemFrontmostTool(),
            SystemWindowsTool(),
            SystemLaunchAppTool(),
            SystemQuitAppTool(),
            ClipboardReadTool(),
            ClipboardWriteTool(),
            NotificationsPostTool(),
        ]
    }

    /// The canonical identifiers this package owns (module-contracts.md).
    public static let identifiers: [String] = [
        "applescript.run", "jxa.run", "applescript.dictionary",
        "accessibility.status", "accessibility.tree", "accessibility.find", "accessibility.press", "accessibility.setValue",
        "accessibility.focus", "accessibility.typeText", "accessibility.waitFor",
        "screen.capture", "screen.ocr", "screen.compare",
        "system.apps", "system.frontmost", "system.windows", "system.launchApp", "system.quitApp",
        "clipboard.read", "clipboard.write", "notifications.post",
    ]
}
