// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/SSEParser.swift
// Description      : Incremental Server-Sent Events parser (multi-line data,
//                    comments, CR/LF/CRLF, chunks split anywhere, including
//                    inside a UTF-8 scalar).
// Module           : ORIXProviderAdapters
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

/// One dispatched server-sent event.
public struct SSEEvent: Sendable, Hashable {
    /// The `event:` field, when the server sent one.
    public var event: String?
    /// All `data:` lines of the event joined with `\n`.
    public var data: String
    public var id: String?
    /// The `retry:` field in milliseconds, when present and numeric.
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event; self.data = data; self.id = id; self.retry = retry
    }
}

/// Byte-oriented incremental parser following the WHATWG event-stream rules: lines end with LF, CR or CRLF; a line starting
/// with `:` is a comment; `data` lines accumulate; a blank line dispatches the event if it carries data. Bytes can be fed in
/// chunks of any size: a line is decoded as UTF-8 only once complete, so a scalar split across two chunks is never corrupted.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var hasData = false
    private var eventName: String?
    private var lastID: String?
    private var retry: Int?
    private var skipNextLF = false
    private var atStreamStart = true

    public init() {}

    /// Feeds one byte; returns an event when this byte completes one.
    public mutating func consume(_ byte: UInt8) -> SSEEvent? {
        if skipNextLF {
            skipNextLF = false
            if byte == 0x0A { return nil }
        }
        switch byte {
        case 0x0A: return endLine()
        case 0x0D: skipNextLF = true; return endLine()
        default: line.append(byte); return nil
        }
    }

    /// Feeds a chunk; returns every event completed by it, in order.
    public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8 {
        var out: [SSEEvent] = []
        for b in bytes { if let e = consume(b) { out.append(e) } }
        return out
    }

    public mutating func feed(_ text: String) -> [SSEEvent] { feed(Array(text.utf8)) }

    /// Call at end of stream. Per the specification an event not terminated by a blank line is discarded, so this returns
    /// nothing; it only resets the parser. Kept explicit so callers do not invent a trailing event.
    public mutating func finish() {
        line.removeAll(); dataLines.removeAll(); hasData = false; eventName = nil; retry = nil; skipNextLF = false
    }

    private mutating func endLine() -> SSEEvent? {
        var bytes = line
        line.removeAll(keepingCapacity: true)
        if atStreamStart {
            atStreamStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        if bytes.isEmpty { return dispatch() }
        if bytes[0] == 0x3A { return nil } // comment / keep-alive
        let field: String, value: String
        if let colon = bytes.firstIndex(of: 0x3A) {
            field = String(decoding: bytes[..<colon], as: UTF8.self)
            var rest = bytes[(colon + 1)...]
            if rest.first == 0x20 { rest = rest.dropFirst() }
            value = String(decoding: rest, as: UTF8.self)
        } else {
            field = String(decoding: bytes, as: UTF8.self); value = ""
        }
        switch field {
        case "data": dataLines.append(value); hasData = true
        case "event": eventName = value
        case "id": if !value.contains("\0") { lastID = value }
        case "retry": if let ms = Int(value) { retry = ms }
        default: break // unknown fields are ignored
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer { dataLines.removeAll(keepingCapacity: true); hasData = false; eventName = nil; retry = nil }
        guard hasData else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastID, retry: retry)
    }
}
