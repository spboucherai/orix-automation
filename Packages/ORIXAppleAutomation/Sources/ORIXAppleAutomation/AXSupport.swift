// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/AXSupport.swift
// Description      : Accessibility (AXUIElement) plumbing: attribute reading
//                    that never touches secure fields, stable element paths,
//                    bounded tree walks, frontmost and focus checks.
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
import Foundation
import ORIXCore

/// Synchronous Accessibility helpers. Callers run them off the cooperative pool (`runBlocking`); nothing here is cached,
/// so every call sees the live UI.
enum AX {
    static let securePlaceholder = "«secure»"
    static let rootPath = "AXApplication"

    struct Info {
        var role = ""
        var subrole: String?
        var title: String?
        var label: String?
        var identifier: String?
        var enabled: Bool?
        var focused: Bool?
        var frame: CGRect?
        var childCount = 0
        var value: JSONValue?
        var secure: Bool { AX.isSecure(role: role, subrole: subrole) }

        func json(path: String, depth: Int) -> JSONValue {
            var o: [String: JSONValue] = ["path": .string(path), "depth": .int(depth), "role": .string(role), "childCount": .int(childCount)]
            if let subrole { o["subrole"] = .string(subrole) }
            if let title, !title.isEmpty { o["title"] = .string(title) }
            if let label, !label.isEmpty { o["description"] = .string(label) }
            if let identifier, !identifier.isEmpty { o["identifier"] = .string(identifier) }
            if let enabled { o["enabled"] = .bool(enabled) }
            if let focused { o["focused"] = .bool(focused) }
            if let frame { o["frame"] = rectJSON(frame) }
            if let value { o["value"] = value }
            if secure { o["secure"] = true }
            return .object(o)
        }
    }

    static func isSecure(role: String, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    // MARK: Attributes

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? { (attribute(element, name) as? NSNumber)?.boolValue }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(element, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let v = attribute(element, kAXChildrenAttribute), let array = v as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    static func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "AXUnknown" }

    static func isSecure(_ element: AXUIElement) -> Bool {
        isSecure(role: role(element), subrole: string(element, kAXSubroleAttribute))
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = attribute(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// The element's value as JSON. Secure fields are never queried: the placeholder is returned without an AX call.
    static func value(_ element: AXUIElement, secure: Bool, maxLength: Int = 500) -> JSONValue? {
        if secure { return .string(securePlaceholder) }
        guard let v = attribute(element, kAXValueAttribute) else { return nil }
        if let s = v as? String { return .string(s.count > maxLength ? String(s.prefix(maxLength)) + "…" : s) }
        if CFGetTypeID(v) == CFBooleanGetTypeID(), let b = v as? Bool { return .bool(b) }
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d.rounded() == d && abs(d) < 9e15 ? .int(n.intValue) : .number(d)
        }
        return nil
    }

    static func info(_ element: AXUIElement, includeValue: Bool = true) -> Info {
        var i = Info()
        i.role = role(element)
        i.subrole = string(element, kAXSubroleAttribute)
        i.title = string(element, kAXTitleAttribute)
        i.label = string(element, kAXDescriptionAttribute)
        i.identifier = string(element, kAXIdentifierAttribute)
        i.enabled = bool(element, kAXEnabledAttribute)
        i.focused = bool(element, kAXFocusedAttribute)
        i.frame = frame(element)
        var count: CFIndex = 0
        if AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success { i.childCount = count }
        if includeValue { i.value = value(element, secure: i.secure) }
        return i
    }

    // MARK: Applications

    struct App {
        let element: AXUIElement
        let pid: pid_t
        let name: String
    }

    static func requireTrust() throws {
        guard AXIsProcessTrusted() else {
            throw ToolError.tccBlocked(.accessibility, "Accessibility access is not enabled for this app. " + MacPermissions.howToEnable(.accessibility))
        }
    }

    static func app(bundleID: String) throws -> App {
        try requireTrust()
        guard let running = AppResolver.running(bundleID).first else {
            throw TypedFailure(code: "app_not_running", message: "\(AppResolver.displayName(bundleID)) (\(bundleID)) is not running.",
                               recovery: "Launch it with system.launchApp, then call again.", retryable: true)
        }
        let element = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 3)
        return App(element: element, pid: running.processIdentifier, name: running.localizedName ?? bundleID)
    }

    /// PID of the application that has keyboard focus, read live from the Accessibility server (not a cached property).
    static func frontmostPID() -> pid_t? {
        if AXIsProcessTrusted() {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 2)
            if let app = element(system, kAXFocusedApplicationAttribute) {
                var pid: pid_t = 0
                if AXUIElementGetPid(app, &pid) == .success { return pid }
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    // MARK: Paths

    /// Resolves `AXApplication/AXWindow[0]/AXButton[2]` from the live tree. Indices count siblings of the same role.
    static func resolve(_ path: String, in app: App) throws -> AXUIElement {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.first == rootPath else { throw ToolError.invalidInput("element must be a path returned by accessibility.tree or accessibility.find (it starts with \(rootPath))") }
        parts.removeFirst()
        var current = app.element
        for part in parts {
            guard let g = regexGroups(#"^([A-Za-z0-9_]+)\[(\d+)\]$"#, in: part, options: []).first, let role = g[1], let index = g[2].flatMap({ Int($0) }) else {
                throw ToolError.invalidInput("Malformed element path component \"\(part)\"")
            }
            let sameRole = children(current).filter { AX.role($0) == role }
            guard sameRole.indices.contains(index) else {
                throw TypedFailure(code: "element_not_found", message: "No element at \(path): \(part) no longer exists in \(app.name). The interface changed.",
                                   recovery: "Call accessibility.find again to get a current path.", retryable: true)
            }
            current = sameRole[index]
        }
        return current
    }

    /// Re-resolves and checks the optional expected title, so an action never lands on a different element that took the same position.
    static func resolve(_ path: String, in app: App, expectedTitle: String?) throws -> (AXUIElement, Info) {
        let element = try resolve(path, in: app)
        let info = AX.info(element)
        if let expectedTitle, !expectedTitle.isEmpty, info.title != expectedTitle, info.label != expectedTitle {
            throw TypedFailure(code: "element_changed", message: "The element at \(path) is now \"\(info.title ?? info.label ?? "")\", not \"\(expectedTitle)\".",
                               recovery: "Call accessibility.find again to get a current path.", retryable: true, output: info.json(path: path, depth: 0))
        }
        return (element, info)
    }

    // MARK: Walk

    struct WalkResult { var visited = 0; var truncated = false; var depthLimited = false }

    /// Depth-first, pre-order walk bounded by `maxDepth` and `maxNodes`. `visit` returns false to stop.
    static func walk(from root: AXUIElement, path rootPath: String, maxDepth: Int, maxNodes: Int, includeMenuBar: Bool,
                     includeValues: Bool = true, visit: (AXUIElement, String, Int, Info) -> Bool) -> WalkResult {
        var result = WalkResult()
        var stop = false
        func descend(_ element: AXUIElement, _ path: String, _ depth: Int) {
            if stop { return }
            if result.visited >= maxNodes { result.truncated = true; stop = true; return }
            result.visited += 1
            let info = AX.info(element, includeValue: includeValues)
            if !visit(element, path, depth, info) { stop = true; return }
            guard depth < maxDepth else { if info.childCount > 0 { result.depthLimited = true }; return }
            var counts: [String: Int] = [:]
            for child in children(element) {
                let r = role(child)
                let index = counts[r, default: 0]
                counts[r] = index + 1
                if depth == 0, r == "AXMenuBar", !includeMenuBar { continue }
                descend(child, "\(path)/\(r)[\(index)]", depth + 1)
                if stop { return }
            }
        }
        descend(root, rootPath, 0)
        return result
    }

    struct Filter: Sendable {
        var role: String?
        var title: String?
        var identifier: String?
        var value: String?

        var isEmpty: Bool { role == nil && title == nil && identifier == nil && value == nil }

        init(_ input: ToolInput) {
            func clean(_ k: String) -> String? { input.optionalString(k).flatMap { $0.isEmpty ? nil : $0 } }
            role = clean("role"); title = clean("title"); identifier = clean("identifier"); value = clean("value")
        }

        func matches(_ info: Info) -> Bool {
            if let role, info.role != role, info.subrole != role { return false }
            if let identifier, info.identifier != identifier { return false }
            if let title {
                let t = title.lowercased()
                guard (info.title?.lowercased().contains(t) ?? false) || (info.label?.lowercased().contains(t) ?? false) else { return false }
            }
            if let value {
                // A secure field never matches a value filter: its value is not read.
                guard !info.secure, let v = info.value?.displayString, v.lowercased().contains(value.lowercased()) else { return false }
            }
            return true
        }

        var description: String {
            [role.map { "role \($0)" }, title.map { "title containing \"\($0)\"" }, identifier.map { "identifier \($0)" }, value.map { "value containing \"\($0)\"" }]
                .compactMap { $0 }.joined(separator: ", ")
        }

        static let schema: [String: JSONSchema] = [
            "role": .string("Accessibility role or subrole, for example AXButton, AXTextField, AXMenuItem."),
            "title": .string("Case-insensitive substring of the element's title or description."),
            "identifier": .string("Exact accessibility identifier."),
            "value": .string("Case-insensitive substring of the element's value (never matches secure fields)."),
        ]
    }
}
