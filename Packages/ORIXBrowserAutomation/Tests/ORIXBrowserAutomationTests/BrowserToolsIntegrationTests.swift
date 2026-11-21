// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXBrowserAutomation/Tests/ORIXBrowserAutomationTests/BrowserToolsIntegrationTests.swift
// Description      : Integration tests of the browser.* tools: a real WKWebView
//                    driving the loopback test site (structure, data entry,
//                    secrets, navigation policy, dialogs, waits, screenshots,
//                    downloads).
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

import AppKit
import Foundation
import ORIXCore
import ORIXTestingSupport
import Testing
@testable import ORIXBrowserAutomation

struct MapSecrets: SecretResolving {
    let values: [String: String]
    func secret(reference: String) async throws -> String {
        guard let v = values[reference] else { throw ToolError.notFound("No secret named \(reference).") }
        return v
    }
}

/// The site, a session manager, the tools and a miniature of the executor's pipeline (schema validation, capability
/// check against a fixed grant list, typed-error conversion, output-schema validation).
final class BrowserHarness: @unchecked Sendable {
    static let password = "S3cure-Horse-Battery-42"
    static let card = "4111111111111111"

    let site: TestSite
    let dir: TempDirectory
    let manager: BrowserSessionManager
    let tools: [String: any ORIXTool]
    var grants: [Capability]
    var secrets: (any SecretResolving)? = MapSecrets(values: ["site/password": BrowserHarness.password, "site/card": BrowserHarness.card])
    private(set) var lastRequirements: ToolRequirements?

    init() async throws {
        site = try TestSite()
        try await site.start()
        dir = try TempDirectory(prefix: "orix-browser")
        manager = BrowserSessionManager()
        tools = Dictionary(ORIXBrowserAutomationTools.all(manager: manager).map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        grants = [.browser(host: "127.0.0.1"), .secret(reference: "site/password"), .secret(reference: "site/card")]
    }

    func tearDown() async {
        await manager.closeAll()
        site.stop()
        dir.remove()
    }

    func context(runID: String = "run-1", timeout: Double = 20) -> ToolExecutionContext {
        let hosts = grants.compactMap { cap -> String? in if case .browser(let h) = cap { return h }; return nil }
        return ToolExecutionContext(runID: runID, callID: "call-\(UUID().uuidString.prefix(8))", mode: .guided, workingDirectory: dir.url,
                                    artifactsDirectory: dir.url.appendingPathComponent("artifacts"), timeoutSeconds: timeout,
                                    confinement: Confinement(browserHosts: hosts), secrets: secrets)
    }

    @discardableResult
    func call(_ id: String, _ arguments: JSONValue = [:], runID: String = "run-1", timeout: Double = 20) async -> ToolResult {
        guard let tool = tools[id] else { return .failure(.failed, ToolFailure(code: "not_found", message: "Unknown tool \(id)")) }
        let violations = tool.manifest.inputSchema.validate(arguments)
        guard violations.isEmpty else {
            return .failure(.invalidInput, ToolFailure(code: "invalid_input", message: violations.map(\.description).joined(separator: "; ")))
        }
        let input = ToolInput(arguments: arguments)
        let ctx = context(runID: runID, timeout: timeout)
        do {
            let requirements = try tool.requirements(for: input, context: ctx)
            lastRequirements = requirements
            let artifacts = try PathResolver.canonical(ctx.artifactsDirectory.path, relativeTo: ctx.workingDirectory)
            for capability in requirements.capabilities {
                if case .fileWrite(let path) = capability, path.hasPrefix(artifacts + "/") { continue }
                guard grants.contains(where: { $0.covers(capability) }) else {
                    return .failure(.denied, ToolFailure(code: "permission_denied", message: "No grant covers \(capability.displayString)"))
                }
            }
            let result = try await tool.execute(input: input, context: ctx)
            if result.status == .succeeded {
                let problems = tool.manifest.outputSchema.validate(result.output)
                if !problems.isEmpty {
                    return .failure(.failed, ToolFailure(code: "output_invalid", message: problems.map(\.description).joined(separator: "; ")))
                }
            }
            return result
        } catch let error as ToolError {
            return ToolResult(status: error.status, summary: error.failure.message, failure: error.failure)
        } catch {
            return .failure(.failed, ToolFailure(code: "internal", message: "\(error)"))
        }
    }

    /// Runs a snippet in the page (test-only inspection of real DOM state).
    @MainActor
    func pageValue(_ expression: String, runID: String = "run-1") async throws -> String {
        guard let session = await manager.session(runID: runID) else { return "" }
        // In the page's own world (not ORIX's isolated one), so the page's globals are visible.
        let r = try await session.webView.callAsyncJavaScript("return String(\(expression));", arguments: [:], in: nil, contentWorld: .page)
        return r as? String ?? ""
    }
}

func withBrowser(_ body: (BrowserHarness) async throws -> Void) async throws {
    let harness = try await BrowserHarness()
    do { try await body(harness) } catch {
        await harness.tearDown()
        throw error
    }
    await harness.tearDown()
}

@Suite("Browser tools (integration: real WKWebView against a loopback test site)", .serialized)
struct BrowserToolsIntegrationTests {
    @Test func openReportsFinalURLStatusAndTitle() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            let opened = await h.call("browser.open", ["url": .string(h.site.origin + "/")])
            #expect(opened.status == .succeeded, "\(opened.failure?.message ?? "")")
            #expect(opened.output["url"]?.stringValue == h.site.origin + "/")
            #expect(opened.output["status"]?.intValue == 200)
            #expect(opened.output["title"]?.stringValue == "ORIX Test Site")
            #expect(opened.output["redirected"]?.boolValue == false)
            #expect(opened.untrusted)
            #expect(h.lastRequirements?.capabilities == [.browser(host: "127.0.0.1")] && h.lastRequirements?.tier == .reversibleWrite)
            #expect(h.manager.currentHost(runID: "run-1") == "127.0.0.1")

            // A same-host server redirect is followed and reported.
            let redirected = await h.call("browser.open", ["url": .string(h.site.origin + "/redirect-home")])
            #expect(redirected.output["url"]?.stringValue == h.site.origin + "/" && redirected.output["redirected"]?.boolValue == true)

            // An HTTP error page is still a page: the status says so.
            let missing = await h.call("browser.open", ["url": .string(h.site.origin + "/missing")])
            #expect(missing.status == .succeeded && missing.output["status"]?.intValue == 404)

            // Nothing listening: a typed, retryable network failure.
            h.grants.append(.browser(host: "localhost"))
            let refused = await h.call("browser.open", ["url": "http://localhost:1/"])
            #expect(refused.status == .failed && refused.failure?.code == "network" && refused.failure?.retryable == true)
        }
    }

    @Test func readReturnsTheStructureOfThePage() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/")])
            let read = await h.call("browser.read")
            #expect(read.status == .succeeded, "\(read.failure?.message ?? "")")
            #expect(h.lastRequirements?.capabilities == [.browser(host: "127.0.0.1")] && h.lastRequirements?.tier == .readOnly)
            let page = read.output
            #expect(page["title"]?.stringValue == "ORIX Test Site" && page["url"]?.stringValue == h.site.origin + "/")
            let text = page["text"]?.stringValue ?? ""
            #expect(text.contains("Plain visible paragraph.") && !text.contains("hidden-text-should-not-be-visible"))
            #expect(page["headings"] == [["level": 1, "text": "Welcome to the test site"], ["level": 2, "text": "Navigation"], ["level": 2, "text": "Inventory"]])

            let links = page["links"]?.arrayValue ?? []
            #expect(links.count == 7)
            let form = try #require(links.first { $0["text"]?.stringValue == "Data entry form" })
            #expect(form["href"]?.stringValue == h.site.origin + "/form" && form["selector"]?.stringValue == "#to-form")
            // A link without an id still gets a selector that resolves to exactly that element.
            let slow = try #require(links.first { $0["text"]?.stringValue == "Slow page" })
            let slowSelector = try #require(slow["selector"]?.stringValue)
            #expect(try await h.pageValue("document.querySelectorAll(\(JSONValue.string(slowSelector).serialized())).length") == "1")
            #expect(try await h.pageValue("document.querySelector(\(JSONValue.string(slowSelector).serialized())).textContent") == "Slow page")

            let table = try #require(page["tables"]?.arrayValue?.first)
            #expect(table["selector"]?.stringValue == "#inventory" && table["caption"]?.stringValue == "Stock")
            #expect(table["headers"] == ["Item", "Quantity", "Price"])
            #expect(table["rows"] == [["Widget", "12", "4.50"], ["Gadget", "3", "19.99"]])
            #expect(table["rowCount"]?.intValue == 2)

            let buttons = page["buttons"]?.arrayValue ?? []
            #expect(buttons.map { $0["selector"]?.stringValue } == ["#ghost", "#locked", "#counter"])
            #expect(buttons[0]["visible"]?.boolValue == false && buttons[1]["disabled"]?.boolValue == true && buttons[2]["text"]?.stringValue == "Count")
            #expect(page["forms"]?.arrayValue?.isEmpty == true && page["truncated"]?.boolValue == false)
        }
    }

    @Test func promptInjectionOnThePageArrivesFlaggedUntrusted() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/")])
            let read = await h.call("browser.read")
            // The hostile text is delivered as data, in a result marked untrusted by both the result and the manifest.
            #expect(read.output["text"]?.stringValue?.contains(TestSite.injection) == true)
            #expect(read.untrusted)
            #expect(h.tools["browser.read"]?.manifest.outputIsUntrusted == true)
            // Reading it changed nothing: no request left for the host the text names, and no file was read.
            #expect(h.site.requests.allSatisfy { $0.path != "/collect" })
            #expect(h.manager.currentHost(runID: "run-1") == "127.0.0.1")
        }
    }

    @Test func readIsBoundedAndSaysWhenItTruncates() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/")])
            let small = await h.call("browser.read", ["maxBytes": 1000, "maxItems": 2])
            #expect(small.status == .succeeded && small.truncated && small.output["truncated"]?.boolValue == true)
            #expect(small.output["links"]?.arrayValue?.count == 2 && small.output["buttons"]?.arrayValue?.count == 2)
            #expect(await h.call("browser.read", ["maxBytes": 10]).status == .invalidInput)
        }
    }

    @Test func multiStepDataEntrySubmitsAndShowsTheValues() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/form")])
            let before = await h.call("browser.read")
            let form = try #require(before.output["forms"]?.arrayValue?.first)
            #expect(form["selector"]?.stringValue == "#entry" && form["method"]?.stringValue == "post")
            #expect(form["action"]?.stringValue == h.site.origin + "/submit")
            let fields = form["fields"]?.arrayValue ?? []
            #expect(fields.map { $0["name"]?.stringValue } == ["fullname", "color", "subscribe", "plan", "plan", "notes", "password", "card", "csrf", "frozen"])
            let name = fields[0]
            #expect(name["label"]?.stringValue == "Full name" && name["placeholder"]?.stringValue == "Ada Lovelace" && name["type"]?.stringValue == "text")
            #expect(name["required"]?.boolValue == true && name["value"]?.stringValue == "")
            #expect(fields[1]["options"]?.arrayValue?.map { $0["text"]?.stringValue } == ["Red", "Green", "Blue"] && fields[1]["value"]?.stringValue == "r")
            #expect(fields[2]["checked"]?.boolValue == false && fields[3]["checked"]?.boolValue == true)
            #expect(before.output["fields"]?.arrayValue?.first?["label"]?.stringValue == "Search the site")
            let proRadio = try #require(fields[4]["selector"]?.stringValue)

            // Fill every kind of control, using the selectors browser.read returned.
            let filled = await h.call("browser.fill", ["selector": name["selector"] ?? "", "value": "Ada Lovelace"])
            #expect(filled.status == .succeeded && filled.output["valueLength"]?.intValue == 12 && filled.output["secure"]?.boolValue == false)
            #expect(h.lastRequirements?.tier == .consequential && h.lastRequirements?.capabilities == [.browser(host: "127.0.0.1")])
            #expect(await h.call("browser.fill", ["selector": "#color", "value": "Blue"]).status == .succeeded)
            #expect(await h.call("browser.fill", ["selector": "#subscribe", "checked": true]).output["checked"]?.boolValue == true)
            #expect(await h.call("browser.fill", ["selector": .string(proRadio), "checked": true]).status == .succeeded)
            #expect(await h.call("browser.fill", ["selector": "#notes", "value": "Line one\nLine <two> & more"]).status == .succeeded)
            let secret = await h.call("browser.fill", ["selector": "#pw", "secretRef": "site/password"])
            #expect(secret.status == .succeeded && secret.output["secure"]?.boolValue == true)
            #expect(h.lastRequirements?.capabilities == [.browser(host: "127.0.0.1"), .secret(reference: "site/password")])
            #expect(await h.call("browser.fill", ["selector": "#card", "secretRef": "site/card"]).status == .succeeded)

            // The page's own listeners saw real input and change events.
            #expect(try await h.pageValue("window.events.join('|')") == "input:Ada Lovelace")
            #expect(try await h.pageValue("document.title") == "changed:Ada Lovelace")

            let click = await h.call("browser.click", ["selector": "#send"])
            #expect(click.status == .succeeded, "\(click.failure?.message ?? "")")
            #expect(click.output["navigated"]?.boolValue == true && click.output["url"]?.stringValue == h.site.origin + "/submit")
            #expect(click.output["status"]?.intValue == 200 && click.output["title"]?.stringValue == "Submission received")
            #expect(click.output["element"]?["text"]?.stringValue == "Send")

            let waited = await h.call("browser.waitFor", ["selector": "#result", "state": "visible", "text": "Submission received", "urlMatches": "/submit$"])
            #expect(waited.status == .succeeded && waited.output["matched"]?.boolValue == true)

            let after = await h.call("browser.read")
            let text = after.output["text"]?.stringValue ?? ""
            for expected in ["Ada Lovelace", "Line one Line <two> & more", "received \(BrowserHarness.password.count) characters", "received 16 digits"] {
                #expect(text.contains(expected), "result page lacks “\(expected)”: \(text)")
            }
            #expect(try await h.pageValue("document.getElementById('r-color').textContent") == "b")
            #expect(try await h.pageValue("document.getElementById('r-subscribe').textContent") == "yes")
            #expect(try await h.pageValue("document.getElementById('r-plan').textContent") == "pro")

            // What the server actually received, including the secret that never appeared in any tool output.
            let posted = try #require(h.site.requests(to: "/submit").last?.form)
            #expect(posted["fullname"] == "Ada Lovelace" && posted["color"] == "b" && posted["subscribe"] == "yes" && posted["plan"] == "pro")
            #expect(posted["notes"] == "Line one\r\nLine <two> & more" && posted["csrf"] == "t0k3n" && posted["frozen"] == "fixed")
            #expect(posted["password"] == BrowserHarness.password && posted["card"] == BrowserHarness.card)
            for result in [secret, click, after] { #expect(!result.output.serialized().contains(BrowserHarness.password)) }
        }
    }

    @Test func passwordAndCardValuesNeverAppearInReadOutput() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/form")])
            let fill = await h.call("browser.fill", ["selector": "#pw", "secretRef": "site/password"])
            await h.call("browser.fill", ["selector": "#card", "secretRef": "site/card"])
            // A secret typed into an ordinary field is masked from then on as well.
            await h.call("browser.fill", ["selector": "#notes", "secretRef": "site/password"])
            #expect(try await h.pageValue("document.getElementById('pw').value") == BrowserHarness.password)

            let read = await h.call("browser.read")
            let serialized = read.output.serialized() + fill.output.serialized() + fill.summary + read.summary
            #expect(!serialized.contains(BrowserHarness.password) && !serialized.contains(BrowserHarness.card))
            let fields = read.output["forms"]?.arrayValue?.first?["fields"]?.arrayValue ?? []
            let byName = Dictionary(fields.map { ($0["name"]?.stringValue ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            for name in ["password", "card", "notes"] {
                #expect(byName[name]?["value"]?.stringValue == "«secure»" && byName[name]?["secure"]?.boolValue == true, "\(name)")
            }
            #expect(byName["fullname"]?["secure"]?.boolValue == false && byName["csrf"]?["value"]?.stringValue == "t0k3n")
            #expect(fill.output["valueLength"]?.isNull == true)

            // Even after the page turns the password field into a text field ("show password").
            _ = try await h.pageValue("document.getElementById('pw').type = 'text'")
            let again = await h.call("browser.read")
            #expect(!again.output.serialized().contains(BrowserHarness.password))
        }
    }

    @Test func fillingASecureFieldWithoutSecretRefIsRefused() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/form")])
            for selector in ["#pw", "#card"] {
                let refused = await h.call("browser.fill", ["selector": .string(selector), "value": "typed-by-a-model"])
                #expect(refused.status == .denied && refused.failure?.code == "secret_required", "\(selector): \(refused.status)")
                #expect(refused.failure?.recovery?.contains("secretRef") == true)
            }
            let typed = try await h.pageValue("document.getElementById('pw').value + document.getElementById('card').value")
            #expect(typed.isEmpty)

            // A secret the run was not granted is stopped by the capability check, before the tool runs.
            let notGranted = await h.call("browser.fill", ["selector": "#pw", "secretRef": "other/secret"])
            #expect(notGranted.status == .denied && notGranted.failure?.code == "permission_denied")
            // A granted reference that does not exist, and a run with no secret store at all: typed failures, field untouched.
            h.grants.append(.secret(reference: "other/secret"))
            #expect(await h.call("browser.fill", ["selector": "#pw", "secretRef": "other/secret"]).failure?.code == "not_found")
            h.secrets = nil
            #expect(await h.call("browser.fill", ["selector": "#pw", "secretRef": "site/password"]).status == .denied)
            let stillEmpty = try await h.pageValue("document.getElementById('pw').value")
            #expect(stillEmpty.isEmpty)

            // Argument and element errors.
            #expect(await h.call("browser.fill", ["selector": "#fullname"]).status == .invalidInput)
            #expect(await h.call("browser.fill", ["selector": "#fullname", "value": "a", "checked": true]).status == .invalidInput)
            #expect(await h.call("browser.fill", ["selector": "#nope", "value": "a"]).failure?.code == "not_found")
            #expect(await h.call("browser.fill", ["selector": "((", "value": "a"]).status == .invalidInput)
            #expect(await h.call("browser.fill", ["selector": "#color", "value": "Purple"]).status == .invalidInput)
            #expect(await h.call("browser.fill", ["selector": "#frozen", "value": "x"]).failure?.code == "not_interactable")
            #expect(await h.call("browser.fill", ["selector": "input[name=\"csrf\"]", "value": "x"]).status == .unsupported)
            #expect(await h.call("browser.fill", ["selector": "#send", "value": "x"]).status == .unsupported)
        }
    }

    @Test func openingANonGrantedHostIsBlocked() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            // `localhost` and `127.0.0.1` reach the same server but are two different hosts for the policy.
            let direct = await h.call("browser.open", ["url": .string(h.site.foreignOrigin + "/")])
            #expect(direct.status == .denied)
            #expect(h.lastRequirements?.capabilities == [.browser(host: "localhost")])
            #expect(h.site.requests.isEmpty)

            // A granted page that answers with a server redirect to the other host.
            let redirect = await h.call("browser.open", ["url": .string(h.site.origin + "/redirect-foreign")])
            #expect(redirect.status == .denied && redirect.failure?.code == "navigation_blocked")
            #expect(redirect.failure?.message.contains("localhost") == true)
            #expect(redirect.output["blocked"]?["host"]?.stringValue == "localhost" && redirect.output["blocked"]?["reason"]?.stringValue == "host_not_allowed")

            // A granted page whose script sends the browser to the other host.
            let script = await h.call("browser.open", ["url": .string(h.site.origin + "/js-redirect")])
            #expect(script.status == .denied && script.failure?.code == "navigation_blocked" && script.failure?.message.contains("localhost") == true)
            #expect(h.manager.currentURL(runID: "run-1")?.absoluteString == h.site.origin + "/js-redirect")

            // The server never saw a request addressed to the foreign host.
            #expect(h.site.requests.allSatisfy { ($0.headers["host"] ?? "").hasPrefix("127.0.0.1") })
            #expect(h.site.requests(to: "/").isEmpty)

            // Granting the host makes the same navigation work.
            h.grants.append(.browser(host: "localhost"))
            let allowed = await h.call("browser.open", ["url": .string(h.site.origin + "/redirect-foreign")])
            #expect(allowed.status == .succeeded && allowed.output["url"]?.stringValue == h.site.foreignOrigin + "/")
        }
    }

    @Test func clickingALinkToANonGrantedHostIsBlocked() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/")])
            let before = h.site.requests.count
            for selector in ["#foreign-link", "#foreign-window"] {
                let click = await h.call("browser.click", ["selector": .string(selector)])
                #expect(click.status == .denied && click.failure?.code == "navigation_blocked", "\(selector): \(click.status) \(click.failure?.message ?? "")")
                #expect(click.failure?.message.contains("localhost") == true && click.output["clicked"]?.boolValue == true)
            }
            let local = await h.call("browser.click", ["selector": "#file-link"])
            // WebKit itself refuses to follow a file: link from a web page; when it does ask, the policy refuses.
            #expect(local.status == .denied || local.output["navigated"]?.boolValue == false, "\(local.status) \(local.output.serialized())")
            // Still on the granted page, and nothing was requested.
            #expect(h.manager.currentURL(runID: "run-1")?.absoluteString == h.site.origin + "/")
            #expect(h.site.requests.count == before)

            // A form that posts to the other host: the submission is stopped before it is sent.
            await h.call("browser.open", ["url": .string(h.site.origin + "/form-foreign")])
            let post = await h.call("browser.click", ["selector": "#send"])
            #expect(post.status == .denied && post.failure?.code == "navigation_blocked" && post.failure?.message.contains("localhost") == true)
            #expect(h.site.requests(to: "/submit").isEmpty)
            await h.call("browser.open", ["url": .string(h.site.origin + "/")])

            // A new-window link to a granted host loads in the same view.
            let sameView = await h.call("browser.click", ["selector": "#new-window"])
            #expect(sameView.status == .succeeded && sameView.output["url"]?.stringValue == h.site.origin + "/form")
            #expect(await h.manager.activeRunIDs == ["run-1"])
        }
    }

    @Test func nonWebSchemesAreRefused() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            h.grants.append(.browser(host: "example.com"))
            for url in ["file:///etc/hosts", "file://localhost/etc/passwd", "data:text/html,<h1>x</h1>", "javascript:alert(1)", "ftp://example.com/x", "http://example.com/"] {
                let result = await h.call("browser.open", ["url": .string(url)])
                #expect(result.status == .unsupported && result.failure?.code == "unsupported", "\(url): \(result.status)")
            }
            #expect(await h.call("browser.open", ["url": "file:///etc/hosts"]).failure?.message.contains("file:") == true)
            for url in ["not a url", "/relative/path", "https://user:pw@example.com/", "https:///nohost"] {
                #expect(await h.call("browser.open", ["url": .string(url)]).status == .invalidInput, "\(url)")
            }
            #expect(await h.call("browser.download", ["url": "file:///etc/hosts"]).status == .unsupported)
            #expect(await h.manager.activeRunIDs.isEmpty)
            #expect(h.site.requests.isEmpty)
        }
    }

    @Test func javaScriptDialogsAreDismissedAndReported() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            let start = Date()
            let opened = await h.call("browser.open", ["url": .string(h.site.origin + "/alert")])
            #expect(opened.status == .succeeded, "\(opened.failure?.message ?? "")")
            #expect(Date().timeIntervalSince(start) < 10)
            #expect(opened.output["dialogs"] == [
                ["kind": "alert", "message": "hello from the page", "response": "dismissed"],
                ["kind": "confirm", "message": "delete everything?", "response": "canceled"],
                ["kind": "prompt", "message": "your name?", "response": "canceled"],
            ])
            // The script ran to the end with the refusals as answers.
            #expect(opened.output["title"]?.stringValue == "confirm=false prompt=null")
            #expect(await h.call("browser.read").output["text"]?.stringValue?.contains("script finished") == true)
        }
    }

    @Test func waitForObservesTheDOMAndTimesOutWithATypedFailure() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/slow")])
            #expect(try await h.pageValue("!!document.getElementById('late')") == "false")
            let late = await h.call("browser.waitFor", ["selector": "#late", "timeoutSeconds": 10])
            #expect(late.status == .succeeded && late.output["matched"]?.boolValue == true, "\(late.failure?.message ?? "")")
            #expect((late.output["elapsedMs"]?.intValue ?? 0) < 9000)
            #expect(h.lastRequirements?.tier == .readOnly)
            #expect(await h.call("browser.waitFor", ["selector": "#spinner", "state": "absent", "text": "Late content has arrived"]).status == .succeeded)
            #expect(await h.call("browser.waitFor", ["urlMatches": "stage=done$", "timeoutSeconds": 10]).status == .succeeded)

            let start = Date()
            let never = await h.call("browser.waitFor", ["selector": "#never", "timeoutSeconds": 0.6])
            let elapsed = Date().timeIntervalSince(start)
            #expect(never.status == .timedOut && never.failure?.code == "timeout" && never.failure?.retryable == true)
            #expect(never.failure?.message.contains("#never") == true)
            #expect(elapsed >= 0.55 && elapsed < 5, "elapsed \(elapsed)")
            #expect(await h.call("browser.waitFor", ["text": "text that never shows up", "timeoutSeconds": 0.3]).status == .timedOut)
            #expect(await h.call("browser.waitFor", ["urlMatches": "/elsewhere", "timeoutSeconds": 0.3]).status == .timedOut)

            #expect(await h.call("browser.waitFor", [:]).status == .invalidInput)
            #expect(await h.call("browser.waitFor", ["state": "absent"]).status == .invalidInput)
            #expect(await h.call("browser.waitFor", ["urlMatches": "("]).status == .invalidInput)
            #expect(await h.call("browser.waitFor", ["selector": "((", "timeoutSeconds": 1]).status == .invalidInput)
            #expect(await h.call("browser.waitFor", ["selector": "#late", "state": "sideways"]).status == .invalidInput)
        }
    }

    @Test func clickVerifiesTheElementAndReportsWhatFollowed() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/")])
            let ghost = await h.call("browser.click", ["selector": "#ghost"])
            #expect(ghost.status == .failed && ghost.failure?.code == "not_interactable" && ghost.failure?.message.contains("not visible") == true)
            let locked = await h.call("browser.click", ["selector": "#locked"])
            #expect(locked.failure?.code == "not_interactable" && locked.failure?.message.contains("disabled") == true)
            #expect(await h.call("browser.click", ["selector": "#nope"]).failure?.code == "not_found")
            #expect(await h.call("browser.click", ["selector": "(("]).status == .invalidInput)
            #expect(await h.call("browser.click", ["selector": ""]).status == .invalidInput)

            let counted = await h.call("browser.click", ["selector": "#counter"])
            #expect(counted.status == .succeeded && counted.output["navigated"]?.boolValue == false && counted.output["status"]?.isNull == true)
            await h.call("browser.click", ["selector": "#counter"])
            #expect(try await h.pageValue("document.getElementById('counter').textContent") == "Clicked 2")

            let link = await h.call("browser.click", ["selector": "#to-form"])
            #expect(link.output["navigated"]?.boolValue == true && link.output["url"]?.stringValue == h.site.origin + "/form")
            #expect(link.output["element"]?["href"]?.stringValue == h.site.origin + "/form" && link.untrusted)
        }
    }

    @Test func screenshotWritesARealPNGOfTheViewport() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/")])
            let shot = await h.call("browser.screenshot")
            #expect(shot.status == .succeeded, "\(shot.failure?.message ?? "")")
            #expect(h.lastRequirements?.tier == .readOnly)
            let path = try #require(shot.output["path"]?.stringValue)
            #expect(path.hasPrefix(h.dir.url.path + "/artifacts/screenshots/") && path.hasSuffix(".png"))
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(data.count > 2000 && data.count == shot.output["bytes"]?.intValue)
            #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            // IHDR: width and height as big-endian 32-bit integers at offsets 16 and 20.
            let width = data[16..<20].reduce(0) { $0 << 8 | Int($1) }, height = data[20..<24].reduce(0) { $0 << 8 | Int($1) }
            #expect(width == 1280 && height == 800)
            #expect(shot.output["width"]?.intValue == 1280 && shot.output["height"]?.intValue == 800)
            #expect(shot.artifacts.first?.kind == "screenshot" && shot.artifacts.first?.path == path)
            #expect(shot.artifacts.first?.sha256 == shot.output["sha256"]?.stringValue && shot.output["sha256"]?.stringValue?.count == 64)

            // The page was really rendered: dark text on a white background, not a blank image.
            let rep = try #require(NSBitmapImageRep(data: data))
            var dark = 0, light = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let luminance = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                    if luminance < 0.4 { dark += 1 } else if luminance > 0.9 { light += 1 }
                }
            }
            #expect(dark > 200 && light > 50_000, "dark \(dark) light \(light)")

            // An explicit path outside the artifacts folder needs a file-write grant and is a tier 1 write.
            let outside = h.dir.file("shots/page.png").path
            #expect(await h.call("browser.screenshot", ["path": .string(outside)]).status == .denied)
            #expect(h.lastRequirements?.tier == .reversibleWrite)
            #expect(h.lastRequirements?.capabilities == [.browser(host: "127.0.0.1"), .fileWrite(path: outside)])
            h.grants.append(.fileWrite(path: h.dir.url.path))
            #expect(await h.call("browser.screenshot", ["path": "shots/page.png"]).output["path"]?.stringValue == outside)
            #expect(await h.call("browser.screenshot", ["path": "shots/page.png"]).failure?.code == "io")
            #expect(await h.call("browser.screenshot", ["path": "shots/page.png", "overwrite": true]).status == .succeeded)
            #expect(await h.call("browser.screenshot", ["path": "shots/page.jpg"]).status == .invalidInput)
        }
    }

    @Test func downloadSavesTheFileWithItsChecksum() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            let result = await h.call("browser.download", ["url": .string(h.site.origin + "/file.bin")])
            #expect(result.status == .succeeded, "\(result.failure?.message ?? "")")
            #expect(h.lastRequirements?.tier == .consequential)
            let path = h.dir.url.path + "/artifacts/downloads/file.bin"
            #expect(h.lastRequirements?.capabilities == [.browser(host: "127.0.0.1"), .fileWrite(path: path)])
            #expect(result.output["path"]?.stringValue == path && result.output["bytes"]?.intValue == 65_536)
            #expect(result.output["sha256"]?.stringValue == TestSite.fileSHA256)
            #expect(result.output["status"]?.intValue == 200 && result.output["mimeType"]?.stringValue == "application/octet-stream")
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == TestSite.fileBytes)
            #expect(result.artifacts.first?.sha256 == TestSite.fileSHA256 && result.artifacts.first?.bytes == 65_536 && result.artifacts.first?.kind == "file")

            // Existing file: refused unless overwrite is asked for.
            #expect(await h.call("browser.download", ["url": .string(h.site.origin + "/file.bin")]).failure?.code == "io")
            #expect(await h.call("browser.download", ["url": .string(h.site.origin + "/file.bin"), "overwrite": true]).status == .succeeded)

            // Size cap, HTTP errors and foreign redirects leave nothing behind.
            let folder = h.dir.url.appendingPathComponent("artifacts/downloads")
            let capped = await h.call("browser.download", ["url": .string(h.site.origin + "/file.bin"), "path": "artifacts/downloads/capped.bin", "maxBytes": 1000])
            #expect(capped.status == .failed && capped.failure?.code == "too_large")
            let missing = await h.call("browser.download", ["url": .string(h.site.origin + "/missing")])
            #expect(missing.status == .failed && missing.failure?.code == "http_error" && missing.failure?.message.contains("404") == true)
            let foreign = await h.call("browser.download", ["url": .string(h.site.origin + "/file-redirect-foreign")])
            #expect(foreign.status == .denied && foreign.failure?.code == "navigation_blocked" && foreign.failure?.message.contains("localhost") == true,
                    "\(foreign.status) \(foreign.failure?.code ?? "") \(foreign.failure?.message ?? "") \(foreign.output.serialized())")
            let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            #expect(left == ["file.bin"])
            // The redirect was refused before any request reached the foreign host.
            #expect(h.site.requests.allSatisfy { ($0.headers["host"] ?? "").hasPrefix("127.0.0.1") })

            // A destination outside the artifacts folder needs a file-write grant.
            #expect(await h.call("browser.download", ["url": .string(h.site.origin + "/file.bin"), "path": "elsewhere/f.bin"]).status == .denied)
        }
    }

    @Test func downloadsUseTheSessionCookiesAndPagesCannotStartThem() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            // Without the session cookie the server refuses.
            #expect(await h.call("browser.download", ["url": .string(h.site.origin + "/private.bin")], runID: "anonymous").failure?.code == "http_error")
            // Logged-in session: the cookie set by the page is sent with the download.
            await h.call("browser.open", ["url": .string(h.site.origin + "/login")])
            let authed = await h.call("browser.download", ["url": .string(h.site.origin + "/private.bin")])
            #expect(authed.status == .succeeded, "\(authed.failure?.message ?? "")")
            #expect(try String(contentsOfFile: authed.output["path"]?.stringValue ?? "", encoding: .utf8) == "private payload")
            // Sessions are isolated: another run does not have that cookie.
            #expect(await h.call("browser.download", ["url": .string(h.site.origin + "/private.bin"), "overwrite": true], runID: "other-run").failure?.code == "http_error")

            // Navigating to something the server offers as a download is refused; nothing is written anywhere.
            let implicit = await h.call("browser.open", ["url": .string(h.site.origin + "/attachment")])
            #expect(implicit.status == .denied && implicit.failure?.code == "download_refused")
            let binary = await h.call("browser.open", ["url": .string(h.site.origin + "/file.bin")])
            #expect(binary.status == .denied && binary.failure?.code == "download_refused")
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            #expect(downloads.map { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("report.txt").path) } ?? true)
        }
    }

    @Test func sessionsAreKeyedByRunAndCloseReleasesThem() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            // No page yet: every page tool fails with a typed error naming the remedy.
            for (tool, arguments) in [("browser.read", [:]), ("browser.click", ["selector": "#x"]), ("browser.fill", ["selector": "#x", "value": "v"]),
                                      ("browser.waitFor", ["selector": "#x"]), ("browser.screenshot", [:])] as [(String, JSONValue)] {
                let result = await h.call(tool, arguments)
                #expect(result.status == .failed && result.failure?.code == "not_found" && result.failure?.message.contains("browser.open") == true, "\(tool)")
            }
            #expect(await h.manager.view(for: "run-1") == nil)

            await h.call("browser.open", ["url": .string(h.site.origin + "/")], runID: "run-1")
            await h.call("browser.open", ["url": .string(h.site.origin + "/form")], runID: "run-2")
            #expect(await h.manager.activeRunIDs == ["run-1", "run-2"])
            #expect(await h.call("browser.read", runID: "run-1").output["title"]?.stringValue == "ORIX Test Site")
            #expect(await h.call("browser.read", runID: "run-2").output["title"]?.stringValue == "Data entry")
            let view = await h.manager.view(for: "run-2")
            #expect(await view?.url?.path == "/form")
            let persistent = await view?.configuration.websiteDataStore.isPersistent
            #expect(persistent == false)

            let closed = await h.call("browser.close", runID: "run-1")
            #expect(closed.status == .succeeded && closed.output["closed"]?.boolValue == true)
            #expect(await h.call("browser.close", runID: "run-1").output["closed"]?.boolValue == false)
            #expect(await h.manager.activeRunIDs == ["run-2"] && h.manager.currentURL(runID: "run-1") == nil)
            #expect(await h.call("browser.read", runID: "run-1").failure?.code == "not_found")
            await h.manager.closeAll()
            #expect(await h.manager.activeRunIDs.isEmpty)
            #expect(await h.manager.close(runID: "run-2") == false)
        }
    }

    @Test func slowLoadsTimeOutAndCallsCanBeCanceled() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            // A server that accepts the request and never answers.
            let start = Date()
            let hung = await h.call("browser.open", ["url": .string(h.site.origin + "/hang"), "timeoutSeconds": 1])
            #expect(hung.status == .timedOut && hung.failure?.code == "timeout" && hung.failure?.retryable == true, "\(hung.status)")
            #expect(Date().timeIntervalSince(start) < 6)
            // The session is still usable afterwards.
            #expect(await h.call("browser.open", ["url": .string(h.site.origin + "/")]).status == .succeeded)

            // Canceling the calling task ends a long wait promptly with a typed result.
            let waiting = Task { await h.call("browser.waitFor", ["selector": "#never", "timeoutSeconds": 15]) }
            try await Task.sleep(nanoseconds: 400_000_000)
            let canceledAt = Date()
            waiting.cancel()
            let canceled = await waiting.value
            #expect(canceled.status == .canceled && canceled.failure?.code == "canceled", "\(canceled.status)")
            #expect(Date().timeIntervalSince(canceledAt) < 3)

            let loading = Task { await h.call("browser.open", ["url": .string(h.site.origin + "/hang"), "timeoutSeconds": 15]) }
            try await Task.sleep(nanoseconds: 400_000_000)
            loading.cancel()
            #expect(await loading.value.status == .canceled)
            #expect(await h.call("browser.read").status == .succeeded)
        }
    }

    @Test func theOffscreenViewLaysOutAndRunsTimers() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/visibility")])
            #expect(await h.call("browser.waitFor", ["urlMatches": "/visibility$", "selector": "h1", "state": "visible"]).status == .succeeded)
            #expect(try await h.pageValue("window.innerWidth + 'x' + window.innerHeight") == "1280x800")
            // The 50 ms timer of the page fired; report what WebKit says about visibility and how late the timer was.
            var title = ""
            for _ in 0..<100 {
                title = try await h.pageValue("document.title")
                if title.contains(":") { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            print("INFO offscreen WKWebView visibilityState:timerDelayMs = \(title)")
            #expect(title.contains(":"))
        }
    }

    @Test func concurrentCallsOnOneSessionAreSerialised() async throws {
        try await withBrowser { (h: BrowserHarness) async throws -> Void in
            await h.call("browser.open", ["url": .string(h.site.origin + "/slow")])
            async let wait = h.call("browser.waitFor", ["selector": "#late", "timeoutSeconds": 10])
            async let read = h.call("browser.read")
            async let shot = h.call("browser.screenshot")
            let results = await [wait, read, shot]
            #expect(results.allSatisfy { $0.status == .succeeded }, "\(results.map(\.status))")
        }
    }
}
