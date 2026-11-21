// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/ClipboardTools.swift
// Description      : clipboard.read (text and file URLs only, concealed entries
//                    withheld) and clipboard.write.
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
import Foundation
import ORIXCore

enum Clipboard {
    /// Marker password managers put on entries that must not be read by other software (nspasteboard.org).
    static let concealedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword", "org.nspasteboard.TransientType"]

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

public struct ClipboardReadTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "clipboard.read", name: "Read the clipboard",
                     summary: "Reads the text and the file paths currently on the clipboard. Other kinds of content are only named, and entries marked as concealed by a password manager are withheld.",
                     family: "system",
                     inputSchema: .object(["maxBytes": .integer("Maximum text size returned (default 100000).", minimum: 1, maximum: 1_000_000)]),
                     outputSchema: outputObject(["text": .any, "fileURLs": .array(of: .string()), "types": .array(of: .string()), "changeCount": .integer(), "concealed": .boolean()],
                                                required: ["fileURLs", "types", "changeCount", "concealed"]),
                     // A read by nature; each call is nevertheless tier 1 (see requirements) because it exposes user data.
                     sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 10, idempotent: true, outputIsUntrusted: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [.clipboardRead], tier: .reversibleWrite, summary: "Read the text and file paths on the clipboard")
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let maxBytes = input.int("maxBytes", default: 100_000)
        return try await runBlocking {
            let pb = NSPasteboard.general
            let types = (pb.types ?? []).map(\.rawValue)
            let concealed = !Clipboard.concealedTypes.isDisjoint(with: types)
            var out: [String: JSONValue] = ["types": .array(types.prefix(40).map(JSONValue.string)), "changeCount": .int(pb.changeCount), "concealed": .bool(concealed),
                                            "fileURLs": [], "text": .null]
            var truncated = false
            if concealed {
                out["note"] = "The clipboard entry is marked as concealed (password manager); its content is not read."
            } else {
                out["fileURLs"] = .array(Clipboard.fileURLs(pb).prefix(500).map { .string($0.path) })
                if let text = pb.string(forType: .string) {
                    let (cut, t) = text.truncated(maxBytes: maxBytes)
                    out["text"] = .string(cut); truncated = t
                }
            }
            let hasText = out["text"]?.stringValue != nil
            var result = ToolResult.success(.object(out), summary: concealed ? "Clipboard content is concealed and was not read"
                                            : (hasText ? "Read text from the clipboard" : "The clipboard holds no text"))
            result.truncated = truncated
            result.untrusted = true
            return result
        }
    }
}

public struct ClipboardWriteTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "clipboard.write", name: "Write the clipboard",
                     summary: "Replaces the clipboard with text, or with a list of files (as if copied in Finder).",
                     family: "system",
                     inputSchema: .object(["content": .string("Text to place on the clipboard."),
                                           "paths": .array(of: .string(), "Files to place on the clipboard instead of text.")]),
                     outputSchema: outputObject(["written": .boolean(), "kind": .string(), "changeCount": .integer()], required: ["written", "kind", "changeCount"]),
                     sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 10, supportsDryRun: true, idempotent: true)
    }

    func plan(_ input: ToolInput, context: ToolExecutionContext) throws -> (text: String?, paths: [String]) {
        let paths = try input.strings("paths").map { try PathResolver.canonical($0, relativeTo: context.workingDirectory) }
        let text = input.optionalString("content")
        guard (text != nil) != !paths.isEmpty else { throw ToolError.invalidInput("Give either content or paths") }
        if let text, text.utf8.count > 10_000_000 { throw ToolError.invalidInput("content is larger than 10 MB") }
        return (text, paths)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input, context: context)
        var caps: [Capability] = [.clipboardWrite]
        caps += p.paths.map { .fileRead(path: $0) }
        return ToolRequirements(capabilities: caps, tier: .reversibleWrite,
                                summary: p.text.map { "Replace the clipboard with \($0.count) characters of text" } ?? "Replace the clipboard with \(p.paths.count) file(s)")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input, context: context)
        let kind = p.text != nil ? "text" : "files"
        if input.dryRun {
            return .simulated(["written": false, "kind": .string(kind), "changeCount": .int(NSPasteboard.general.changeCount)], summary: "Would replace the clipboard with \(kind)")
        }
        for path in p.paths where !FileManager.default.fileExists(atPath: path) { throw ToolError.notFound("No file at \(path)") }
        return try await runBlocking {
            let pb = NSPasteboard.general
            pb.clearContents()
            let ok: Bool
            if let text = p.text { ok = pb.setString(text, forType: .string) }
            else { ok = pb.writeObjects(p.paths.map { URL(fileURLWithPath: $0) as NSURL }) }
            guard ok else { throw ToolError.io("The clipboard refused the new content") }
            return .success(["written": true, "kind": .string(kind), "changeCount": .int(pb.changeCount)], summary: "Replaced the clipboard with \(kind)")
        }
    }
}
