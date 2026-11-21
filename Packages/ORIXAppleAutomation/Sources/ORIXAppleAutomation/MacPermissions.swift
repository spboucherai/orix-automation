// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/MacPermissions.swift
// Description      : Non-prompting macOS privacy (TCC) status checks, the
//                    standard system prompts where macOS offers one, and System
//                    Settings deep links. Never grants or bypasses anything.
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

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ORIXCore
@preconcurrency import UserNotifications

public enum PermissionStatus: String, Codable, Sendable, CaseIterable {
    case granted
    /// Not granted. For Accessibility, Screen Recording and Full Disk Access macOS does not let a process tell
    /// "refused" from "never asked": both are reported as `denied`.
    case denied
    case notDetermined
    /// Cannot be evaluated here (no app bundle, target application not running, permission needs a target).
    case unknown
}

public enum MacPermissions {
    /// True when the process is an application bundle with an identifier. Notifications need one.
    public static var hasAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Current status, without ever showing a prompt. `.appleEvents` is per target: use `automationStatus(bundleID:)`.
    public static func status(_ permission: MacPermission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .fullDiskAccess:
            return fullDiskAccessStatus()
        case .notifications:
            return notificationStatus()
        case .appleEvents:
            return .unknown
        }
    }

    public static func snapshot() -> [MacPermission: PermissionStatus] {
        Dictionary(uniqueKeysWithValues: MacPermission.allCases.map { ($0, status($0)) })
    }

    /// Apple Events consent for one target application. `.unknown` when the target is not running (macOS cannot say).
    public static func automationStatus(bundleID: String) -> PermissionStatus {
        automation(bundleID: bundleID, askUserIfNeeded: false)
    }

    /// Shows the **standard system prompt** where macOS has one, and returns the status afterwards.
    /// Accessibility and Screen Recording only open the system dialog pointing at System Settings: the returned status
    /// is still `denied` until the user enables the switch there. Full Disk Access has no prompt at all
    /// (open `settingsURL(for:)`); Apple Events needs a target (`requestAutomation(bundleID:)`).
    public static func request(_ permission: MacPermission) async -> PermissionStatus {
        switch permission {
        case .accessibility:
            // Literal value of kAXTrustedCheckOptionPrompt (an unsafe global under strict concurrency).
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options) ? .granted : .denied
        case .screenRecording:
            return CGRequestScreenCaptureAccess() ? .granted : .denied
        case .notifications:
            guard hasAppBundle else { return .unknown }
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            return granted ? .granted : status(.notifications)
        case .fullDiskAccess, .appleEvents:
            return status(permission)
        }
    }

    /// Lets macOS ask the user whether this app may control `bundleID` (the standard Automation consent dialog).
    public static func requestAutomation(bundleID: String) async -> PermissionStatus {
        (try? await runBlocking { automation(bundleID: bundleID, askUserIfNeeded: true) }) ?? .unknown
    }

    /// Deep link to the matching pane of System Settings › Privacy & Security.
    public static func settingsURL(for permission: MacPermission) -> URL {
        let raw: String
        switch permission {
        case .accessibility: raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording: raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .appleEvents: raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .fullDiskAccess: raw = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .notifications: raw = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
        return URL(string: raw)!
    }

    /// One sentence telling the user where the switch is.
    public static func howToEnable(_ permission: MacPermission) -> String {
        switch permission {
        case .accessibility: return "Open System Settings › Privacy & Security › Accessibility and enable ORIX OS Automation."
        case .screenRecording: return "Open System Settings › Privacy & Security › Screen & System Audio Recording and enable ORIX OS Automation, then relaunch it."
        case .appleEvents: return "Open System Settings › Privacy & Security › Automation and enable the target application under ORIX OS Automation."
        case .fullDiskAccess: return "Open System Settings › Privacy & Security › Full Disk Access and enable ORIX OS Automation."
        case .notifications: return "Open System Settings › Notifications › ORIX OS Automation and allow notifications."
        }
    }

    // MARK: Probes

    /// Harmless probes: locations only readable with Full Disk Access are opened and closed at once, never read.
    /// The first one that exists decides; `unknown` when none exists on this macOS version.
    private static func fullDiskAccessStatus() -> PermissionStatus {
        let probes = [
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Safari",
        ]
        for path in probes {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { close(fd); return .granted }
            if errno == EPERM || errno == EACCES { return .denied }
        }
        return .unknown
    }

    private static func notificationStatus() -> PermissionStatus {
        guard hasAppBundle else { return .unknown }
        let box = LockedBox<PermissionStatus>(.unknown)
        let done = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            box.set(map(settings.authorizationStatus))
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        return box.get()
    }

    static func map(_ status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        default: return .unknown
        }
    }

    private static func automation(bundleID: String, askUserIfNeeded: Bool) -> PermissionStatus {
        guard AppResolver.isValidBundleID(bundleID), !AppResolver.running(bundleID).isEmpty else { return .unknown }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let wildcard: OSType = 0x2A2A_2A2A // typeWildCard '****'
        let status = AEDeterminePermissionToAutomateTarget(desc, wildcard, wildcard, askUserIfNeeded)
        switch status {
        case 0: return .granted
        case -1743: return .denied          // errAEEventNotPermitted
        case -1744: return .notDetermined   // errAEEventWouldRequireUserConsent
        default: return .unknown            // -600 procNotFound and friends
        }
    }
}
