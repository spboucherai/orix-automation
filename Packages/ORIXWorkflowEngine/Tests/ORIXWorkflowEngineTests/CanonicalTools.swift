// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Tests/ORIXWorkflowEngineTests/CanonicalTools.swift
// Description: Test catalogue of the canonical tool identifiers of module-contracts.md, with permissive schemas (the real manifests live in the tool packages).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
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
