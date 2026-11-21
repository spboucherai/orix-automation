// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/SeatbeltProfile.swift
// Description      : Generates the Seatbelt (sandbox-exec) profile that
//                    confines subprocesses: writes only inside granted roots,
//                    no network unless granted, credential stores unreadable.
// Module           : ORIXToolRegistry
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

/// The envelope applied to a subprocess through `/usr/bin/sandbox-exec -p`.
///
/// Rules, in evaluation order (the last matching Seatbelt rule wins):
/// 1. everything is allowed by default (processes must be able to load the system);
/// 2. every file write is denied, then re-allowed under `writeRoots`, the per-process temp directory and a few devices;
/// 3. all networking (including local sockets, hence DNS) is denied unless `allowsNetwork`;
/// 4. credential stores are unreadable and unwritable whatever the roots say; `/System` and `/private/var/db` are never writable.
///
/// Seatbelt cannot filter by host name: when `allowsNetwork` is true the process may reach any host.
public struct SeatbeltProfile: Sendable, Hashable {
    public static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// Canonical directories (or files) the process may write below.
    public var writeRoots: [String]
    public var allowsNetwork: Bool

    public init(writeRoots: [String], allowsNetwork: Bool) {
        self.writeRoots = Self.normalise(writeRoots)
        self.allowsNetwork = allowsNetwork
    }

    /// Builds the profile for a run's `Confinement`, plus roots the calling tool was itself authorised for.
    public init(confinement: Confinement, extraWriteRoots: [String] = [], allowNetwork: Bool? = nil) {
        self.init(writeRoots: confinement.writeRoots + extraWriteRoots, allowsNetwork: allowNetwork ?? confinement.allowsNetwork)
    }

    public static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: sandboxExecPath) }

    /// Credential stores and security state: neither readable nor writable from a confined process.
    public static var deniedRoots: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Keychains", home + "/.ssh", home + "/.gnupg", home + "/.aws", home + "/.config/gcloud",
            home + "/Library/Application Support/com.apple.TCC", "/Library/Application Support/com.apple.TCC",
            "/Library/Keychains", "/private/etc/sudoers", "/private/etc/sudoers.d",
            home + "/Library/Cookies", home + "/.netrc", home + "/.docker/config.json", home + "/.kube",
        ]
    }

    /// Protected locations every process must be able to read (dyld, frameworks, time zones, the Xcode selection link)
    /// but that no confined process may write.
    public static let writeDeniedRoots: [String] = ["/System", "/private/var/db"]

    /// The SBPL source. `tempDirectory` is the per-process scratch directory (always writable).
    public func source(tempDirectory: String? = nil) -> String {
        var roots = writeRoots
        if let tempDirectory { roots.append(PathResolver.resolveSymlinks(tempDirectory)) }
        var lines: [String] = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write* (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\")"
                + " (literal \"/dev/stdout\") (literal \"/dev/stderr\") (regex #\"^/dev/fd/\") (regex #\"^/dev/ttys[0-9]+$\"))",
        ]
        if !roots.isEmpty {
            lines.append("(allow file-write* " + roots.map { "(subpath \(Self.quote($0)))" }.joined(separator: " ") + ")")
        }
        if !allowsNetwork { lines.append("(deny network*)") }
        lines.append("(deny file-read* file-write* " + Self.deniedRoots.map { "(subpath \(Self.quote($0)))" }.joined(separator: " ") + ")")
        lines.append("(deny file-write* " + Self.writeDeniedRoots.map { "(subpath \(Self.quote($0)))" }.joined(separator: " ") + ")")
        return lines.joined(separator: "\n")
    }

    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func normalise(_ roots: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for r in roots where r.hasPrefix("/") {
            let c = PathResolver.resolveSymlinks(r)
            if seen.insert(c).inserted { out.append(c) }
        }
        return out
    }
}
