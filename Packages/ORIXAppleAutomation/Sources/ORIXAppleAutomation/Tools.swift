// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/Tools.swift
// Description      : The package's tool list.
// Module           : ORIXAppleAutomation
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
