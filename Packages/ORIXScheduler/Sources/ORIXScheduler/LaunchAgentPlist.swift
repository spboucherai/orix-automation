// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXScheduler/Sources/ORIXScheduler/LaunchAgentPlist.swift
// Description      : Generates and validates the property list of the per-user
//                    LaunchAgent that hosts the background scheduler.
//                    Registration is done by the app.
// Module           : ORIXScheduler
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

/// Builds the launchd property list for a per-user agent.
///
/// The app bundles the file as `Contents/Library/LaunchAgents/<label>.plist` and registers it with
/// `SMAppService.agent(plistName:)` after the user opts in. This type only generates and validates; it never talks to
/// launchd.
public enum LaunchAgentPlist {
    public struct Configuration: Sendable, Hashable {
        /// Reverse-DNS job label, for example `ai.orix.automation.agent`.
        public var label: String
        /// Executable path relative to the app bundle (`Contents/MacOS/ORIXBackgroundAgent`), as `SMAppService` expects.
        /// When set it becomes `BundleProgram` and `programArguments[0]` is only the process name.
        public var bundleProgram: String?
        /// argv. Without `bundleProgram` the first element must be an absolute path.
        public var programArguments: [String]
        public var runAtLoad: Bool
        /// Restart the agent when it exits with a non-zero status or crashes (`KeepAlive = { SuccessfulExit = false }`).
        /// A clean exit (status 0) is respected, so the agent can be stopped on purpose.
        public var keepAliveOnFailure: Bool
        /// launchd `ProcessType`: `Background`, `Standard`, `Adaptive` or `Interactive`.
        public var processType: String
        public var standardOutPath: String?
        public var standardErrorPath: String?
        public var environment: [String: String]
        /// Minimum seconds between two launches.
        public var throttleIntervalSeconds: Int?
        /// Bundle identifiers shown as the owner of the login item in System Settings.
        public var associatedBundleIdentifiers: [String]

        public init(label: String, bundleProgram: String? = nil, programArguments: [String], runAtLoad: Bool = true,
                    keepAliveOnFailure: Bool = true, processType: String = "Background", standardOutPath: String? = nil,
                    standardErrorPath: String? = nil, environment: [String: String] = [:], throttleIntervalSeconds: Int? = nil,
                    associatedBundleIdentifiers: [String] = []) {
            self.label = label; self.bundleProgram = bundleProgram; self.programArguments = programArguments
            self.runAtLoad = runAtLoad; self.keepAliveOnFailure = keepAliveOnFailure; self.processType = processType
            self.standardOutPath = standardOutPath; self.standardErrorPath = standardErrorPath; self.environment = environment
            self.throttleIntervalSeconds = throttleIntervalSeconds; self.associatedBundleIdentifiers = associatedBundleIdentifiers
        }
    }

    public struct ValidationError: Error, Sendable, Hashable, LocalizedError {
        public let problems: [String]
        public var errorDescription: String? { "Invalid LaunchAgent configuration: " + problems.joined(separator: "; ") }
    }

    /// The file name `SMAppService.agent(plistName:)` expects: `<label>.plist`.
    public static func plistName(for configuration: Configuration) -> String { configuration.label + ".plist" }

    /// Problems that make the configuration unusable. Empty means valid.
    public static func problems(_ c: Configuration) -> [String] {
        var out: [String] = []
        if c.label.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) == nil {
            out.append("label must be a reverse-DNS identifier such as ai.orix.automation.agent (got '\(c.label)')")
        }
        if c.programArguments.isEmpty { out.append("programArguments is empty") }
        if c.programArguments.contains(where: { $0.contains("\0") }) { out.append("programArguments contains a NUL byte") }
        if let bundleProgram = c.bundleProgram {
            if bundleProgram.isEmpty || bundleProgram.hasPrefix("/") || bundleProgram.split(separator: "/").contains("..") {
                out.append("bundleProgram must be a path relative to the app bundle without '..' (got '\(bundleProgram)')")
            }
        } else if let first = c.programArguments.first, !first.hasPrefix("/") {
            out.append("programArguments[0] must be an absolute path when bundleProgram is not set (got '\(first)')")
        }
        if !["Background", "Standard", "Adaptive", "Interactive"].contains(c.processType) {
            out.append("processType must be Background, Standard, Adaptive or Interactive (got '\(c.processType)')")
        }
        for (name, path) in [("standardOutPath", c.standardOutPath), ("standardErrorPath", c.standardErrorPath)] {
            if let path, !path.hasPrefix("/") { out.append("\(name) must be an absolute path (launchd does not expand ~): '\(path)'") }
        }
        if let t = c.throttleIntervalSeconds, t < 1 { out.append("throttleIntervalSeconds must be at least 1") }
        for key in c.environment.keys where key.isEmpty || key.contains("=") { out.append("environment key '\(key)' is not valid") }
        return out
    }

    /// The property list as a dictionary. Throws `ValidationError` when the configuration is not valid.
    public static func propertyList(_ c: Configuration) throws -> [String: Any] {
        let found = problems(c)
        guard found.isEmpty else { throw ValidationError(problems: found) }
        var plist: [String: Any] = [
            "Label": c.label,
            "ProgramArguments": c.programArguments,
            "RunAtLoad": c.runAtLoad,
            "ProcessType": c.processType,
        ]
        if let bundleProgram = c.bundleProgram { plist["BundleProgram"] = bundleProgram }
        if c.keepAliveOnFailure { plist["KeepAlive"] = ["SuccessfulExit": false] }
        if let path = c.standardOutPath { plist["StandardOutPath"] = path }
        if let path = c.standardErrorPath { plist["StandardErrorPath"] = path }
        if !c.environment.isEmpty { plist["EnvironmentVariables"] = c.environment }
        if let t = c.throttleIntervalSeconds { plist["ThrottleInterval"] = t }
        if !c.associatedBundleIdentifiers.isEmpty { plist["AssociatedBundleIdentifiers"] = c.associatedBundleIdentifiers }
        return plist
    }

    /// The property list serialized as XML.
    public static func xmlData(_ c: Configuration) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: try propertyList(c), format: .xml, options: 0)
    }

    /// Writes the XML property list to `url` atomically.
    public static func write(_ c: Configuration, to url: URL) throws {
        try xmlData(c).write(to: url, options: .atomic)
    }

    /// Checks an existing property list file against what launchd needs from an ORIX agent. Empty means valid.
    public static func problems(inPlistAt url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return ["cannot read \(url.path)"] }
        guard let any = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = any as? [String: Any] else { return ["not a property list dictionary"] }
        var out: [String] = []
        guard let label = plist["Label"] as? String, !label.isEmpty else { return ["Label is missing"] }
        if url.deletingPathExtension().lastPathComponent != label { out.append("file name must be \(label).plist") }
        let args = plist["ProgramArguments"] as? [String] ?? []
        if args.isEmpty && plist["Program"] == nil && plist["BundleProgram"] == nil { out.append("no program to run (ProgramArguments, Program or BundleProgram)") }
        if let keepAlive = plist["KeepAlive"] as? Bool, keepAlive { out.append("KeepAlive = true restarts the agent even after a deliberate clean exit; use SuccessfulExit = false") }
        return out
    }
}
