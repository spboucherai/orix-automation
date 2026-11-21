// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppUI/Sources/ORIXAppUI/Theme.swift
// Description      : Design tokens: adaptive graphite surfaces, violet/blue
//                    accents, status colours, spacing, radii, type scale and
//                    motion that respects Reduce Motion.
// Module           : ORIXAppUI
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
import ORIXCore
import SwiftUI

public extension Color {
    /// A colour that follows the window's appearance (light, dark, high contrast).
    public init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        })
    }
    fileprivate static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
}

public enum Theme {
    // Surfaces
    public static let canvas = Color(light: Color.hex(0xF4F4F7), dark: Color.hex(0x0E0E12))
    public static let surface = Color(light: Color.hex(0xFFFFFF), dark: Color.hex(0x17171D))
    public static let surfaceRaised = Color(light: Color.hex(0xFAFAFC), dark: Color.hex(0x1E1E26))
    public static let surfaceSunken = Color(light: Color.hex(0xECECF1), dark: Color.hex(0x0A0A0D))
    public static let stroke = Color(light: Color.hex(0x000000, 0.10), dark: Color.hex(0xFFFFFF, 0.09))
    public static let strokeStrong = Color(light: Color.hex(0x000000, 0.20), dark: Color.hex(0xFFFFFF, 0.18))

    // Text
    public static let text = Color(light: Color.hex(0x15151A), dark: Color.hex(0xF2F2F7))
    public static let textSecondary = Color(light: Color.hex(0x55555F), dark: Color.hex(0xA3A3B2))
    public static let textTertiary = Color(light: Color.hex(0x8A8A96), dark: Color.hex(0x6E6E7C))

    // Accents
    public static let violet = Color(light: Color.hex(0x6B45F5), dark: Color.hex(0x8E6BFF))
    public static let blue = Color(light: Color.hex(0x2F6BFF), dark: Color.hex(0x5B8CFF))
    public static let accentGradient = LinearGradient(colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let accentSoft = Color(light: Color.hex(0x6B45F5, 0.10), dark: Color.hex(0x8E6BFF, 0.16))

    // Status
    public static let success = Color(light: Color.hex(0x1F9D55), dark: Color.hex(0x3DD68C))
    public static let warning = Color(light: Color.hex(0xB7791F), dark: Color.hex(0xF5B841))
    public static let danger = Color(light: Color.hex(0xD43A3A), dark: Color.hex(0xFF6B6B))
    public static let info = blue
    public static let neutral = textTertiary

    public enum Space { public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 36 }
    public enum Radius { public static let s: CGFloat = 6, m: CGFloat = 10, l: CGFloat = 14, xl: CGFloat = 20 }

    public enum Font {
        public static let display = SwiftUI.Font.system(size: 28, weight: .semibold, design: .rounded)
        public static let title = SwiftUI.Font.system(size: 20, weight: .semibold)
        public static let heading = SwiftUI.Font.system(size: 15, weight: .semibold)
        public static let body = SwiftUI.Font.system(size: 13)
        public static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .medium)
        public static let caption = SwiftUI.Font.system(size: 11)
        public static let captionStrong = SwiftUI.Font.system(size: 11, weight: .semibold)
        public static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
        public static let monoSmall = SwiftUI.Font.system(size: 11, design: .monospaced)
        public static let metric = SwiftUI.Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// Spring used for state changes; collapses to no animation under Reduce Motion.
    public static func spring(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)
    }
}

/// Presentation of a run status: colour, symbol and words. Never colour alone.
public struct StatusStyle {
    public let color: Color
    public let symbol: String
    public let label: LocalizedStringKey
    public let isActive: Bool

    public static func of(_ s: RunStatus) -> StatusStyle {
        switch s {
        case .queued: return .init(color: Theme.neutral, symbol: "clock", label: "Queued", isActive: false)
        case .running: return .init(color: Theme.blue, symbol: "play.circle.fill", label: "Running", isActive: true)
        case .paused: return .init(color: Theme.warning, symbol: "pause.circle.fill", label: "Paused", isActive: false)
        case .recovering: return .init(color: Theme.warning, symbol: "arrow.triangle.2.circlepath", label: "Recovering", isActive: true)
        case .waitingApproval: return .init(color: Theme.violet, symbol: "hand.raised.fill", label: "Waiting for approval", isActive: true)
        case .succeeded: return .init(color: Theme.success, symbol: "checkmark.circle.fill", label: "Succeeded", isActive: false)
        case .partiallySucceeded: return .init(color: Theme.warning, symbol: "checkmark.circle.trianglebadge.exclamationmark", label: "Partially succeeded", isActive: false)
        case .failed: return .init(color: Theme.danger, symbol: "xmark.octagon.fill", label: "Failed", isActive: false)
        case .canceled: return .init(color: Theme.neutral, symbol: "stop.circle.fill", label: "Canceled", isActive: false)
        case .timedOut: return .init(color: Theme.danger, symbol: "clock.badge.exclamationmark", label: "Timed out", isActive: false)
        case .blockedPermission: return .init(color: Theme.danger, symbol: "lock.trianglebadge.exclamationmark", label: "Blocked by a permission", isActive: false)
        case .budgetExceeded: return .init(color: Theme.warning, symbol: "gauge.with.dots.needle.100percent", label: "Budget exceeded", isActive: false)
        case .recoveryRequired: return .init(color: Theme.warning, symbol: "bandage.fill", label: "Needs recovery", isActive: false)
        }
    }

    public static func of(_ s: ToolStatus) -> StatusStyle {
        switch s {
        case .succeeded: return .init(color: Theme.success, symbol: "checkmark.circle.fill", label: "Succeeded", isActive: false)
        case .simulated: return .init(color: Theme.info, symbol: "eye.circle.fill", label: "Simulated", isActive: false)
        case .failed: return .init(color: Theme.danger, symbol: "xmark.octagon.fill", label: "Failed", isActive: false)
        case .denied: return .init(color: Theme.danger, symbol: "nosign", label: "Denied by policy", isActive: false)
        case .notApproved: return .init(color: Theme.warning, symbol: "hand.raised.slash.fill", label: "Not approved", isActive: false)
        case .blockedPermission: return .init(color: Theme.danger, symbol: "lock.trianglebadge.exclamationmark", label: "macOS permission missing", isActive: false)
        case .timedOut: return .init(color: Theme.danger, symbol: "clock.badge.exclamationmark", label: "Timed out", isActive: false)
        case .canceled: return .init(color: Theme.neutral, symbol: "stop.circle.fill", label: "Canceled", isActive: false)
        case .invalidInput: return .init(color: Theme.warning, symbol: "exclamationmark.triangle.fill", label: "Invalid arguments", isActive: false)
        case .unsupported: return .init(color: Theme.neutral, symbol: "questionmark.circle.fill", label: "Unsupported", isActive: false)
        }
    }

    public static func tier(_ t: ApprovalTier) -> (Color, LocalizedStringKey, String) {
        switch t {
        case .readOnly: return (Theme.success, "Tier 0 · Read-only", "eye")
        case .reversibleWrite: return (Theme.blue, "Tier 1 · Reversible", "pencil")
        case .consequential: return (Theme.warning, "Tier 2 · Consequential", "exclamationmark.triangle")
        case .highRisk: return (Theme.danger, "Tier 3 · High-risk", "flame")
        }
    }
}
