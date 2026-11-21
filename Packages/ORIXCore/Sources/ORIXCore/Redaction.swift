// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXCore/Sources/ORIXCore/Redaction.swift
// Description      : Secret redaction for logs, events, tool output and
//                    anything sent back to a model: known-secret literals plus
//                    credential-shaped patterns.
// Module           : ORIXCore
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

/// Thread-safe redactor. Register every secret the process loads (provider keys, resolved secret references) so the exact
/// value is scrubbed wherever it appears, in addition to pattern-based detection of credential-shaped strings.
public final class Redactor: @unchecked Sendable {
    public static let shared = Redactor()
    public static let placeholder = "«redacted»"

    private let lock = NSLock()
    private var literals: Set<String> = []
    private let patterns: [NSRegularExpression]

    public init() {
        let sources = [
            #"sk-ant-[A-Za-z0-9_\-]{20,}"#,                       // Anthropic
            #"sk-or-v1-[A-Za-z0-9]{20,}"#,                         // OpenRouter
            #"sk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{20,}"#,         // OpenAI
            #"xai-[A-Za-z0-9]{20,}"#,
            #"gh[pousr]_[A-Za-z0-9]{30,}"#,                        // GitHub
            #"AKIA[0-9A-Z]{16}"#,                                  // AWS access key id
            #"xox[abprs]-[A-Za-z0-9\-]{10,}"#,                     // Slack
            #"(?i)bearer\s+[A-Za-z0-9._~+/\-]{20,}=*"#,
            #"(?i)(authorization|x-api-key|api[_-]?key|secret|password|passwd|token)("?\s*[:=]\s*"?)[^\s"',;]{8,}"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
            #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, // JWT
        ]
        patterns = sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// Registers an exact secret value. Values shorter than 8 characters are ignored (too many false positives).
    public func register(secret: String) {
        guard secret.count >= 8 else { return }
        lock.lock(); literals.insert(secret); lock.unlock()
    }

    public func unregister(secret: String) {
        lock.lock(); literals.remove(secret); lock.unlock()
    }

    public func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        lock.lock(); let known = literals; lock.unlock()
        var out = text
        for s in known where out.contains(s) { out = out.replacingOccurrences(of: s, with: Self.placeholder) }
        for (i, re) in patterns.enumerated() {
            let range = NSRange(out.startIndex..., in: out)
            // Pattern 8 keeps the key name and separator, hiding only the value.
            let template = i == 8 ? "$1$2\(Self.placeholder)" : Self.placeholder
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }

    public func redact(_ value: JSONValue, keys: Set<String> = []) -> JSONValue {
        switch value {
        case .string(let s): return .string(redact(s))
        case .array(let a): return .array(a.map { redact($0, keys: []) })
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                if keys.contains(k) || Self.sensitiveKey(k) { out[k] = .string(Self.placeholder) }
                else { out[k] = redact(v, keys: []) }
            }
            return .object(out)
        default: return value
        }
    }

    static func sensitiveKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return ["password", "passwd", "secret", "token", "api_key", "apikey", "authorization", "private_key"].contains { k.contains($0) }
    }
}

public extension String {
    /// Cuts a string to at most `maxBytes` UTF-8 bytes on a character boundary and says so.
    func truncated(maxBytes: Int) -> (text: String, truncated: Bool) {
        guard utf8.count > maxBytes else { return (self, false) }
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while end > utf8.startIndex, String.Index(end, within: self) == nil { end = utf8.index(before: end) }
        let cut = String(self[..<end])
        return (cut + "\n… [output truncated: \(utf8.count - maxBytes) more bytes]", true)
    }
}
