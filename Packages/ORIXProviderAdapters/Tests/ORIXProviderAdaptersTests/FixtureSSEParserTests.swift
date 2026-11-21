// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXProviderAdapters/Tests/ORIXProviderAdaptersTests/FixtureSSEParserTests.swift
// Description      : Unit tests of the incremental SSE parser: line endings,
//                    comments, multi-line data, arbitrary chunk boundaries.
// Module           : ORIXProviderAdaptersTests
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

import Testing
import Foundation
@testable import ORIXProviderAdapters

@Suite("Fixture SSE parser (unit)")
struct FixtureSSEParserTests {
    @Test func basicEventWithName() {
        var p = SSEParser()
        let events = p.feed("event: message_start\ndata: {\"a\":1}\n\n")
        #expect(events == [SSEEvent(event: "message_start", data: "{\"a\":1}")])
    }

    @Test func multiLineDataIsJoinedWithNewlines() {
        var p = SSEParser()
        let events = p.feed("data: line one\ndata: line two\ndata:\ndata: line four\n\n")
        #expect(events.map(\.data) == ["line one\nline two\n\nline four"])
    }

    @Test func commentsAndKeepAlivesAreIgnored() {
        var p = SSEParser()
        let events = p.feed(": OPENROUTER PROCESSING\n\n: ping\ndata: x\n: inside\n\n:\n\n")
        #expect(events == [SSEEvent(data: "x")])
    }

    @Test func crlfAndLoneCRLineEndings() {
        var p = SSEParser()
        #expect(p.feed("event: a\r\ndata: 1\r\n\r\n").map(\.data) == ["1"])
        #expect(p.feed("data: 2\rdata: 3\r\r").map(\.data) == ["2\n3"])
        // CR then LF arriving in different chunks is one line ending, not two (no phantom dispatch).
        #expect(p.feed("data: 4\r").isEmpty)
        #expect(p.feed("\ndata: 5\r").isEmpty)
        #expect(p.feed("\n\r\n").map(\.data) == ["4\n5"])
    }

    @Test func anyChunkBoundaryGivesTheSameEvents() {
        let transcript = "event: delta\r\ndata: {\"text\":\"héllo — 日本語 🚀\"}\r\n\r\n: keep-alive\n\ndata: a\ndata: b\n\nevent: end\ndata: [DONE]\n\n"
        var whole = SSEParser()
        let expected = whole.feed(transcript)
        #expect(expected.count == 3)
        let bytes = Array(transcript.utf8)
        for size in [1, 2, 3, 5, 7, 11, 64] {
            var p = SSEParser()
            var got: [SSEEvent] = []
            for start in stride(from: 0, to: bytes.count, by: size) { got += p.feed(bytes[start..<min(start + size, bytes.count)]) }
            #expect(got == expected, "chunk size \(size)")
        }
        #expect(expected[0].data.contains("日本語 🚀"))
    }

    @Test func eventWithoutTrailingBlankLineIsNotDispatched() {
        var p = SSEParser()
        #expect(p.feed("data: complete\n\ndata: cut off").map(\.data) == ["complete"])
        p.finish()
        #expect(p.feed("\n\n").isEmpty)
    }

    @Test func eventNameWithoutDataIsDroppedAndDoesNotLeak() {
        var p = SSEParser()
        let events = p.feed("event: ping\n\ndata: x\n\n")
        #expect(events == [SSEEvent(event: nil, data: "x")])
    }

    @Test func fieldFormsIdRetryAndBOM() {
        var p = SSEParser()
        let events = p.feed("\u{FEFF}data:no-space\nid: 7\nretry: 1500\nunknown: y\ndata\n\ndata:  two spaces\n\n")
        #expect(events.count == 2)
        #expect(events[0] == SSEEvent(data: "no-space\n", id: "7", retry: 1500))
        #expect(events[1] == SSEEvent(data: " two spaces", id: "7"))
    }
}
