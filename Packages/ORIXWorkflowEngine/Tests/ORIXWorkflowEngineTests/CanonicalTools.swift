// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/CanonicalTools.swift
// Description      : Test catalogue of the canonical tool identifiers of
//                    module-contracts.md, with permissive schemas (the real
//                    manifests live in the tool packages).
// Module           : ORIXWorkflowEngineTests
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

enum CanonicalTools {
    private static let families: [(String, [String])] = [
        ("filesystem", ["list", "search", "read", "write", "mkdir", "copy", "move", "metadata", "checksum", "compare", "trash", "delete",
                        "archive", "unarchive", "waitForChange"]),
        ("shell", ["run", "script"]),
        ("git", ["status", "diff", "log", "branches", "commit", "createPatch", "push"]),
        ("http", ["request"]),
        ("documents", ["csvRead", "csvWrite", "jsonQuery", "pdfText", "pdfInfo", "renderPDF", "imageInfo", "imageConvert", "xlsxRead", "textStats"]),
        ("python", ["run", "envInfo"]),
        ("script", ["swift", "javascript"]),
        ("system", ["info", "processes", "diskUsage", "powerState", "networkState", "apps", "frontmost", "windows", "launchApp", "quitApp"]),
        ("clipboard", ["read", "write"]),
        ("notifications", ["post"]),
        ("applescript", ["run", "dictionary"]),
        ("jxa", ["run"]),
        ("accessibility", ["status", "tree", "find", "press", "setValue", "focus", "typeText", "waitFor"]),
        ("screen", ["capture", "ocr", "compare"]),
        ("browser", ["open", "read", "fill", "click", "waitFor", "screenshot", "download", "close"]),
    ]

    static let identifiers: [String] = families.flatMap { family, actions in actions.map { "\(family).\($0)" } }

    private static let reads: Set<String> = [
        "filesystem.list", "filesystem.search", "filesystem.read", "filesystem.metadata", "filesystem.checksum", "filesystem.compare",
        "filesystem.waitForChange", "git.status", "git.diff", "git.log", "git.branches", "documents.csvRead", "documents.jsonQuery",
        "documents.pdfText", "documents.pdfInfo", "documents.imageInfo", "documents.xlsxRead", "documents.textStats", "python.envInfo",
        "system.info", "system.processes", "system.diskUsage", "system.powerState", "system.networkState", "system.apps", "system.frontmost",
        "system.windows", "clipboard.read", "applescript.dictionary", "accessibility.status", "accessibility.tree", "accessibility.find",
        "accessibility.waitFor", "screen.ocr", "screen.compare", "browser.read", "browser.waitFor",
    ]
    private static let reversibleWrites: Set<String> = [
        "filesystem.write", "filesystem.mkdir", "filesystem.copy", "filesystem.move", "filesystem.trash", "filesystem.archive",
        "filesystem.unarchive", "documents.csvWrite", "documents.renderPDF", "documents.imageConvert", "git.commit", "git.createPatch",
        "clipboard.write", "notifications.post", "screen.capture", "browser.screenshot", "browser.close",
    ]
    private static let dryRunnable: Set<String> = [
        "filesystem.write", "filesystem.mkdir", "filesystem.copy", "filesystem.move", "filesystem.trash", "filesystem.delete",
        "filesystem.archive", "filesystem.unarchive",
    ]
    private static let external: Set<String> = ["http.request", "git.push", "browser.open", "browser.fill", "browser.click", "browser.download"]

    static func manifests() -> [ToolManifest] {
        identifiers.map { id in
            let family = String(id.split(separator: ".")[0])
            let sideEffect: SideEffect
            let tier: ApprovalTier
            if reads.contains(id) { sideEffect = .read; tier = .readOnly }
            else if id == "filesystem.delete" { sideEffect = .destructive; tier = .highRisk }
            else if reversibleWrites.contains(id) { sideEffect = .write; tier = .reversibleWrite }
            else if external.contains(id) { sideEffect = .external; tier = .consequential }
            else { sideEffect = .write; tier = .consequential }
            return ToolManifest(identifier: id, name: id, summary: "Canonical tool \(id) (test catalogue entry).", family: family,
                                inputSchema: .object([:], additional: true), sideEffect: sideEffect, defaultTier: tier,
                                supportsDryRun: dryRunnable.contains(id),
                                idempotent: reads.contains(id) || id == "filesystem.mkdir" || id == "browser.close")
        }
    }
}
