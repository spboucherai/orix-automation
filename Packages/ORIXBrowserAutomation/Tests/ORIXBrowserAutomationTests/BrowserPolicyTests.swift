// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXBrowserAutomation/Tests/ORIXBrowserAutomationTests/BrowserPolicyTests.swift
// Description      : Unit tests for the pure URL and host rules, the tool
//                    manifests and the tools' requirements (no web view
//                    involved).
// Module           : ORIXBrowserAutomationTests
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
import ORIXTestingSupport
import Testing
@testable import ORIXBrowserAutomation

@Suite("Browser URL policy (unit)")
struct BrowserURLPolicyTests {
    @Test func loopbackDetection() {
        for host in ["localhost", "LOCALHOST", "app.localhost", "127.0.0.1", "127.8.9.10", "::1"] { #expect(BrowserURLPolicy.isLoopback(host), "\(host)") }
        for host in ["example.com", "localhost.example.com", "127.0.0.1.example.com", "128.0.0.1", "127.0.0", "127.0.0.256", "10.0.0.1", "0.0.0.0", ""] {
            #expect(!BrowserURLPolicy.isLoopback(host), "\(host)")
        }
    }

    @Test func schemesAndShapes() throws {
        func verdict(_ text: String) -> Result<String, NavigationBlock> { BrowserURLPolicy.validate(URL(string: text)!) }
        #expect(try verdict("https://Example.COM/path?q=1").get() == "example.com")
        #expect(try verdict("http://127.0.0.1:8080/").get() == "127.0.0.1")
        #expect(try verdict("http://localhost/").get() == "localhost")
        #expect(try verdict("http://[::1]:9000/").get() == "::1")
        #expect(try verdict("https://xn--bcher-kva.example/").get() == "xn--bcher-kva.example")
        let refused: [(String, String)] = [
            ("http://example.com/", "scheme_not_allowed"), ("file:///etc/hosts", "scheme_not_allowed"), ("data:text/html,x", "scheme_not_allowed"),
            ("javascript:alert(1)", "scheme_not_allowed"), ("blob:https://example.com/1", "scheme_not_allowed"), ("ftp://example.com/", "scheme_not_allowed"),
            ("about:blank", "scheme_not_allowed"), ("https://user:pw@example.com/", "invalid_url"), ("https://user@example.com/", "invalid_url"),
            ("relative/path", "invalid_url"),
        ]
        for (url, reason) in refused {
            guard case .failure(let block) = verdict(url) else { Issue.record("\(url) should be refused"); continue }
            #expect(block.reason == reason, "\(url): \(block.reason)")
            #expect(!block.url.contains("pw"))
        }
    }

    @Test func hostAllowlistMatchesLikeAGrant() throws {
        #expect(BrowserURLPolicy.host("example.com", isCoveredBy: ["example.com"]))
        #expect(BrowserURLPolicy.host("EXAMPLE.com", isCoveredBy: ["Example.Com"]))
        #expect(BrowserURLPolicy.host("docs.example.com", isCoveredBy: ["*.example.com"]))
        #expect(!BrowserURLPolicy.host("example.com", isCoveredBy: ["*.example.com"]))
        #expect(!BrowserURLPolicy.host("docs.example.com", isCoveredBy: ["example.com"]))
        #expect(!BrowserURLPolicy.host("evilexample.com", isCoveredBy: ["*.example.com", "example.com"]))
        #expect(!BrowserURLPolicy.host("localhost", isCoveredBy: ["127.0.0.1"]))
        #expect(!BrowserURLPolicy.host("example.com", isCoveredBy: []))

        let url = URL(string: "https://other.example.org/x")!
        guard case .failure(let block) = BrowserURLPolicy.check(url, allowedHosts: ["example.com"]) else { Issue.record("should be blocked"); return }
        #expect(block.reason == "host_not_allowed" && block.host == "other.example.org")
        let result = block.toolResult
        #expect(result.status == .denied && result.failure?.code == "navigation_blocked" && result.failure?.message.contains("other.example.org") == true)
        #expect(try BrowserURLPolicy.check(url, allowedHosts: ["*.example.org"]).get() == "other.example.org")
        // Scheme rules win over a host grant.
        guard case .failure(let scheme) = BrowserURLPolicy.check(URL(string: "http://example.com/")!, allowedHosts: ["example.com"]) else { Issue.record("should be blocked"); return }
        #expect(scheme.reason == "scheme_not_allowed")
    }
}

@Suite("Browser tool manifests and requirements (unit)")
struct BrowserToolManifestTests {
    @Test func everyCanonicalToolIsPresentAndValid() {
        let tools = ORIXBrowserAutomationTools.all(manager: BrowserSessionManager())
        #expect(tools.map(\.identifier) == ["browser.open", "browser.read", "browser.fill", "browser.click", "browser.waitFor",
                                            "browser.screenshot", "browser.download", "browser.close"])
        for tool in tools {
            let m = tool.manifest
            #expect(m.problems().isEmpty, "\(m.identifier): \(m.problems())")
            #expect(m.family == "browser" && m.concurrency == .serial)
            #expect(m.examples.allSatisfy { m.inputSchema.validate($0).isEmpty }, "\(m.identifier) examples")
            #expect(m.inputSchema.raw["additionalProperties"] == false)
        }
        let byID = Dictionary(tools.map { ($0.identifier, $0.manifest) }, uniquingKeysWith: { a, _ in a })
        #expect(byID["browser.open"]?.defaultTier == .reversibleWrite && byID["browser.read"]?.defaultTier == .readOnly)
        #expect(byID["browser.fill"]?.defaultTier == .consequential && byID["browser.click"]?.defaultTier == .consequential)
        #expect(byID["browser.waitFor"]?.defaultTier == .readOnly && byID["browser.download"]?.defaultTier == .consequential)
        for id in ["browser.open", "browser.read", "browser.click", "browser.waitFor", "browser.download"] { #expect(byID[id]?.outputIsUntrusted == true, "\(id)") }
    }

    @Test func requirementsArePureAndNameExactCapabilities() throws {
        let dir = try TempDirectory(prefix: "orix-browser-req")
        defer { dir.remove() }
        let context = dir.toolContext()
        let tools = Dictionary(ORIXBrowserAutomationTools.all(manager: BrowserSessionManager()).map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        func requirements(_ id: String, _ arguments: JSONValue) throws -> ToolRequirements {
            try tools[id]!.requirements(for: ToolInput(arguments: arguments), context: context)
        }
        let open = try requirements("browser.open", ["url": "https://Docs.Example.com/a?b=c"])
        #expect(open.capabilities == [.browser(host: "docs.example.com")] && open.summary.contains("https://Docs.Example.com/a?b=c"))

        // Without an open page there is no host to name; execution then fails with a typed error.
        #expect(try requirements("browser.read", [:]).capabilities.isEmpty)
        #expect(try requirements("browser.fill", ["selector": "#a", "secretRef": "k"]).capabilities == [.secret(reference: "k")])
        #expect(try requirements("browser.close", [:]).capabilities.isEmpty)

        let download = try requirements("browser.download", ["url": "https://example.com/files/Report%20Q3.pdf?token=abc"])
        #expect(download.capabilities == [.browser(host: "example.com"), .fileWrite(path: dir.url.path + "/artifacts/downloads/Report_Q3.pdf")])
        // Odd file names cannot escape the downloads folder.
        for url in ["https://example.com/", "https://example.com/..", "https://example.com/a/%2E%2E%2Fx", "https://example.com/.hidden"] {
            let caps = try requirements("browser.download", ["url": .string(url)]).capabilities
            guard case .fileWrite(let path) = caps[1] else { Issue.record("no path"); continue }
            #expect(path.hasPrefix(dir.url.path + "/artifacts/downloads/") && !path.contains(".."), "\(url) → \(path)")
            #expect(!(path as NSString).lastPathComponent.hasPrefix("."), "\(url) → \(path)")
        }
        // An explicit path is canonicalised against the working directory, traversal included.
        let explicit = try requirements("browser.download", ["url": "https://example.com/f", "path": "out/../../escape.bin"])
        #expect(explicit.capabilities[1] == .fileWrite(path: (dir.url.path as NSString).deletingLastPathComponent + "/escape.bin"))
        let shot = try requirements("browser.screenshot", ["path": "~/Pictures/page.png"])
        #expect(shot.capabilities == [.fileWrite(path: NSHomeDirectory() + "/Pictures/page.png")] && shot.tier == .reversibleWrite)

        #expect(throws: ToolError.self) { try requirements("browser.open", ["url": "file:///etc/hosts"]) }
        #expect(throws: ToolError.self) { try requirements("browser.fill", ["selector": "#a", "value": "x", "secretRef": "k"]) }
        #expect(throws: ToolError.self) { try requirements("browser.waitFor", [:]) }
    }
}
