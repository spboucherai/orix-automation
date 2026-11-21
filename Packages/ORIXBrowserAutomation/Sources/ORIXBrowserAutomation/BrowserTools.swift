// ORIX OS Automation
// File: Packages/ORIXBrowserAutomation/Sources/ORIXBrowserAutomation/BrowserTools.swift
// Description: The browser.* tools: open, read, fill, click, waitFor, screenshot, download, close. Each declares its exact capabilities and acts only through the session's policy-checked web view.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

/// Entry point: every browser tool, bound to one session manager.
public enum ORIXBrowserAutomationTools {
    public static func all(manager: BrowserSessionManager) -> [any ORIXTool] {
        [
            BrowserOpenTool(manager: manager), BrowserReadTool(manager: manager), BrowserFillTool(manager: manager),
            BrowserClickTool(manager: manager), BrowserWaitForTool(manager: manager), BrowserScreenshotTool(manager: manager),
            BrowserDownloadTool(manager: manager), BrowserCloseTool(manager: manager),
        ]
    }
}

// MARK: - Shared helpers

enum BrowserSupport {
    static let noPage = "No browser page is open for this run. Call browser.open first."

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONSchema {
        JSONSchema(raw: ["type": "object", "properties": .object(properties),
                         "required": .array(required.sorted().map(JSONValue.string)), "additionalProperties": true])
    }

    static let nullableInteger: JSONValue = ["type": ["integer", "null"]]
    static let dialogsSchema: JSONValue = ["type": "array", "items": ["type": "object"]]

    /// The time one call may take: the caller's `timeoutSeconds` argument when smaller than the context's.
    static func limit(_ input: ToolInput, _ context: ToolExecutionContext, default d: Double? = nil) -> Double {
        let ceiling = max(1, context.timeoutSeconds)
        let asked = input.arguments["timeoutSeconds"]?.doubleValue ?? d ?? ceiling
        return max(0.05, min(asked, ceiling))
    }

    /// Hosts main-frame navigations may reach during a call: the run's granted hosts plus the host this call was
    /// approved for.
    static func allowedHosts(_ context: ToolExecutionContext, callHost: String?) -> [String] {
        context.confinement.browserHosts + (callHost.map { [$0] } ?? [])
    }

    /// Capabilities for a call that acts on the page currently shown.
    static func pageCapabilities(_ manager: BrowserSessionManager, _ context: ToolExecutionContext) -> [Capability] {
        manager.currentHost(runID: context.runID).map { [.browser(host: $0)] } ?? []
    }

    static func pageLabel(_ manager: BrowserSessionManager, _ context: ToolExecutionContext) -> String {
        manager.currentHost(runID: context.runID) ?? "the current page"
    }

    static func existingSession(_ manager: BrowserSessionManager, _ context: ToolExecutionContext) async throws -> BrowserSession {
        guard let session = await manager.session(runID: context.runID) else { throw ToolError.notFound(noPage) }
        return session
    }

    static func dialogs(_ list: [BrowserDialog]) -> JSONValue {
        .array(list.map { ["kind": .string($0.kind), "message": .string($0.message), "response": .string($0.response)] })
    }

    static func selector(_ input: ToolInput) throws -> String {
        let s = try input.string("selector").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ToolError.invalidInput("selector is empty") }
        guard s.utf8.count <= 2000 else { throw ToolError.invalidInput("selector is longer than 2000 bytes") }
        return s
    }

    static func parseURL(_ input: ToolInput) throws -> (url: URL, host: String) {
        let text = try input.string("url").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme != nil else { throw ToolError.invalidInput("url is not a valid absolute URL") }
        switch BrowserURLPolicy.validate(url) {
        case .success(let host): return (url, host)
        case .failure(let block):
            if block.reason == "scheme_not_allowed" { throw ToolError.unsupported(block.message) }
            throw ToolError.invalidInput(block.message)
        }
    }

    static func isUnderArtifacts(_ path: String, _ context: ToolExecutionContext) -> Bool {
        guard let root = try? PathResolver.canonical(context.artifactsDirectory.path, relativeTo: context.workingDirectory) else { return false }
        return path == root || path.hasPrefix(root + "/")
    }

    @MainActor
    static func script(_ session: BrowserSession, _ body: String, _ arguments: [String: Any]) async throws -> JSONValue {
        do { return try await session.evaluate(body, arguments: arguments) } catch is BrowserSession.PageScriptError {
            throw ToolError.io("The page changed while ORIX was working on it. Wait for it to settle (browser.waitFor) and try again.")
        }
    }

    static func timedOut(_ seconds: Double, _ what: String) -> ToolResult {
        .failure(.timedOut, ToolFailure(code: "timeout", message: "Timed out after \(format(seconds)) s \(what).", retryable: true))
    }

    static func format(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }

    static func selectorFailure(code: String, selector: String) -> ToolResult? {
        switch code {
        case "not_visible":
            return .failure(.failed, ToolFailure(code: "not_interactable", message: "The element \(selector) exists but is not visible.",
                                                 recovery: "Wait for it with browser.waitFor (state: visible) or pick another element from browser.read."))
        case "disabled":
            return .failure(.failed, ToolFailure(code: "not_interactable", message: "The element \(selector) is disabled or read-only.",
                                                 recovery: "Complete the fields the page requires first, then read the page again."))
        default: return nil
        }
    }
}

// MARK: - browser.open

public struct BrowserOpenTool: ORIXTool {
    let manager: BrowserSessionManager
    public let manifest = ToolManifest(
        identifier: "browser.open", name: "Open page",
        summary: "Open a URL in the ORIX browser (a private WebKit view with no access to Safari's cookies) and wait for the page to load. Returns the final URL, HTTP status and title. Only https, or http on this Mac's loopback.",
        family: "browser",
        inputSchema: .object(["url": .string("Absolute https URL."), "timeoutSeconds": .number("Give up after this many seconds.")], required: ["url"]),
        outputSchema: BrowserSupport.schema(["url": ["type": "string"], "status": BrowserSupport.nullableInteger, "title": ["type": "string"],
                                             "redirected": ["type": "boolean"], "dialogs": BrowserSupport.dialogsSchema],
                                            required: ["url", "title", "redirected", "dialogs"]),
        sideEffect: .external, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 60, concurrency: .serial,
        outputIsUntrusted: true, examples: [["url": "https://example.com/"]])

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let (url, host) = try BrowserSupport.parseURL(input)
        return ToolRequirements(capabilities: [.browser(host: host)], tier: .reversibleWrite, summary: "Open \(url.absoluteString.prefix(200)) in the ORIX browser")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let (url, host) = try BrowserSupport.parseURL(input)
        let limit = BrowserSupport.limit(input, context)
        let session = await manager.openSession(runID: context.runID)
        return try await session.withExclusiveAccess { @MainActor in
            session.setAllowedHosts(BrowserSupport.allowedHosts(context, callHost: host))
            _ = session.takeDialogs()
            let outcome = try await session.load(url, timeoutSeconds: limit)
            let dialogs = session.takeDialogs()
            if let block = outcome.blocked {
                var result = block.toolResult
                result.output["dialogs"] = BrowserSupport.dialogs(dialogs)
                return result
            }
            if outcome.timedOut { return BrowserSupport.timedOut(limit, "loading \(host)") }
            if let error = outcome.error { throw ToolError.network("Could not load \(url.absoluteString.prefix(200)): \(error)", retryable: true) }
            var result = ToolResult.success([
                "url": .string(outcome.url), "status": outcome.httpStatus.map(JSONValue.int) ?? .null, "title": .string(outcome.title),
                "redirected": .bool(outcome.url != url.absoluteString), "dialogs": BrowserSupport.dialogs(dialogs),
            ], summary: "Opened \(outcome.url.prefix(200))" + (outcome.httpStatus.map { " (HTTP \($0))" } ?? ""))
            result.untrusted = true
            return result
        }
    }
}

// MARK: - browser.read

public struct BrowserReadTool: ORIXTool {
    let manager: BrowserSessionManager
    public let manifest = ToolManifest(
        identifier: "browser.read", name: "Read page",
        summary: "Read the page currently open in the ORIX browser as structured data: title, URL, visible text, headings, links, forms with their fields, buttons and tables. Every interactive element comes with a CSS selector that browser.fill, browser.click and browser.waitFor accept. Password and payment-card values are never returned.",
        family: "browser",
        inputSchema: .object(["maxBytes": .integer("Upper bound for the visible text, in bytes.", minimum: 1000, maximum: 200_000),
                              "maxItems": .integer("Upper bound for each list (links, fields, buttons…).", minimum: 1, maximum: 1000)]),
        outputSchema: BrowserSupport.schema(["title": ["type": "string"], "url": ["type": "string"], "text": ["type": "string"],
                                             "headings": ["type": "array"], "links": ["type": "array"], "forms": ["type": "array"],
                                             "fields": ["type": "array"], "buttons": ["type": "array"], "tables": ["type": "array"],
                                             "truncated": ["type": "boolean"], "dialogs": BrowserSupport.dialogsSchema],
                                            required: ["title", "url", "text", "headings", "links", "forms", "buttons", "tables", "truncated"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 20, concurrency: .serial, idempotent: true,
        outputIsUntrusted: true, examples: [[:]])

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: BrowserSupport.pageCapabilities(manager, context), tier: .readOnly,
                         summary: "Read the page open on \(BrowserSupport.pageLabel(manager, context))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let maxBytes = input.int("maxBytes", default: 40_000)
        let maxItems = input.int("maxItems", default: 200)
        let session = try await BrowserSupport.existingSession(manager, context)
        return try await session.withExclusiveAccess { @MainActor in
            session.setAllowedHosts(BrowserSupport.allowedHosts(context, callHost: session.currentHost))
            var page = try await BrowserSupport.script(session, PageScripts.read, [
                "maxTextChars": maxBytes, "maxItems": maxItems, "maxTableRows": 50, "maxTableColumns": 20,
            ])
            guard page.objectValue != nil else { throw ToolError.io("The page returned no readable structure.") }
            var truncated = page["truncated"]?.boolValue ?? false
            let cut = (page["text"]?.stringValue ?? "").truncated(maxBytes: maxBytes)
            if cut.truncated { truncated = true }
            page["text"] = .string(cut.text)
            page["truncated"] = .bool(truncated)
            page["dialogs"] = BrowserSupport.dialogs(session.takeDialogs())
            let counts = "\(page["links"]?.arrayValue?.count ?? 0) links, \(page["forms"]?.arrayValue?.count ?? 0) forms, \(page["buttons"]?.arrayValue?.count ?? 0) buttons"
            var result = ToolResult.success(page, summary: "Read \((page["url"]?.stringValue ?? "").prefix(200)): \(counts)")
            result.truncated = truncated
            result.untrusted = true
            return result
        }
    }
}

// MARK: - browser.fill

public struct BrowserFillTool: ORIXTool {
    let manager: BrowserSessionManager
    public let manifest = ToolManifest(
        identifier: "browser.fill", name: "Fill field",
        summary: "Set the value of a form control on the open page (text field, textarea, select by option value or label, checkbox or radio) and dispatch input/change events. Password and payment-card fields only accept secretRef, the name of a stored secret, so the value never passes through a model.",
        family: "browser",
        inputSchema: .object(["selector": .string("CSS selector of the field, as returned by browser.read."),
                              "value": .string("Text to enter, or the option to select."),
                              "secretRef": .string("Reference name of a stored secret to enter instead of a value."),
                              "checked": .boolean("For a checkbox or radio button: the state to set.")], required: ["selector"]),
        outputSchema: BrowserSupport.schema(["filled": ["type": "boolean"], "selector": ["type": "string"], "tag": ["type": "string"],
                                             "type": ["type": "string"], "secure": ["type": "boolean"], "valueLength": BrowserSupport.nullableInteger],
                                            required: ["filled", "selector", "tag", "type", "secure"]),
        sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 20, concurrency: .serial,
        examples: [["selector": "#email", "value": "ada@example.com"], ["selector": "#password", "secretRef": "example.com/password"]])

    private func mode(_ input: ToolInput) throws -> (value: String?, secretRef: String?, checked: Bool?) {
        let value = input.optionalString("value"), secretRef = input.optionalString("secretRef"), checked = input.arguments["checked"]?.boolValue
        let given = [value != nil, secretRef != nil, checked != nil].filter { $0 }.count
        guard given == 1 else { throw ToolError.invalidInput("give exactly one of value, secretRef or checked") }
        if let secretRef, secretRef.trimmingCharacters(in: .whitespaces).isEmpty { throw ToolError.invalidInput("secretRef is empty") }
        return (value, secretRef, checked)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let selector = try BrowserSupport.selector(input)
        let m = try mode(input)
        var capabilities = BrowserSupport.pageCapabilities(manager, context)
        if let ref = m.secretRef { capabilities.append(.secret(reference: ref)) }
        let what = m.secretRef.map { "the secret \($0)" } ?? (m.checked.map { $0 ? "checked" : "unchecked" } ?? "a value of \(m.value?.count ?? 0) characters")
        return ToolRequirements(capabilities: capabilities, tier: .consequential,
                                summary: "Fill \(selector.prefix(120)) on \(BrowserSupport.pageLabel(manager, context)) with \(what)")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let selector = try BrowserSupport.selector(input)
        let m = try mode(input)
        let session = try await BrowserSupport.existingSession(manager, context)
        var value: String? = m.value
        if let ref = m.secretRef {
            guard let resolver = context.secrets else {
                throw ToolError.permissionDenied("No secret store is available to this run, so \(ref) cannot be used.")
            }
            do { value = try await resolver.secret(reference: ref) } catch let error as ToolError { throw error } catch {
                throw ToolError.notFound("The secret \(ref) could not be read from the secret store.")
            }
        }
        let resolved = value
        return try await session.withExclusiveAccess { @MainActor in
            session.setAllowedHosts(BrowserSupport.allowedHosts(context, callHost: session.currentHost))
            let outcome = try await BrowserSupport.script(session, PageScripts.fill, [
                "selector": selector, "value": resolved as Any? ?? NSNull(), "checked": m.checked as Any? ?? NSNull(), "secret": m.secretRef != nil,
            ])
            if outcome["ok"]?.boolValue != true {
                let code = outcome["code"]?.stringValue ?? "unknown"
                if let failure = BrowserSupport.selectorFailure(code: code, selector: selector) { return failure }
                switch code {
                case "not_found": throw ToolError.notFound("No element matches \(selector) on the page.")
                case "invalid_selector": throw ToolError.invalidInput("\(selector) is not a valid CSS selector.")
                case "secret_required":
                    return .failure(.denied, ToolFailure(
                        code: "secret_required",
                        message: "\(selector) is a password or payment-card field: it can only be filled with secretRef, from a stored secret.",
                        recovery: "Ask the user to store the secret, then call browser.fill with secretRef. Never type such a value directly."))
                case "no_such_option": throw ToolError.invalidInput("The select \(selector) has no option with that value or label.")
                case "radio_cannot_uncheck": throw ToolError.invalidInput("A radio button cannot be unchecked; check another one of its group.")
                case "not_fillable": throw ToolError.unsupported("\(selector) is a \(outcome["type"]?.stringValue ?? "control") that cannot be filled.")
                default: throw ToolError.internalError("browser.fill failed with code \(code).")
                }
            }
            let secure = outcome["secure"]?.boolValue ?? false
            var output: JSONValue = [
                "filled": true, "selector": .string(selector), "tag": outcome["tag"] ?? "", "type": outcome["type"] ?? "",
                "secure": .bool(secure), "valueLength": secure ? .null : (outcome["valueLength"] ?? .null),
            ]
            if let checked = outcome["checked"], !checked.isNull { output["checked"] = checked }
            return .success(output, summary: "Filled \(selector.prefix(120))" + (secure ? " from a stored secret" : ""))
        }
    }
}

// MARK: - browser.click

public struct BrowserClickTool: ORIXTool {
    let manager: BrowserSessionManager
    public let manifest = ToolManifest(
        identifier: "browser.click", name: "Click element",
        summary: "Click an element of the open page by CSS selector, after checking that it exists, is visible and is enabled. Waits for any navigation that follows and reports it. A navigation to a host the run was not granted is blocked.",
        family: "browser",
        inputSchema: .object(["selector": .string("CSS selector of the element, as returned by browser.read."),
                              "timeoutSeconds": .number("Give up waiting for a navigation after this many seconds.")], required: ["selector"]),
        outputSchema: BrowserSupport.schema(["clicked": ["type": "boolean"], "selector": ["type": "string"], "navigated": ["type": "boolean"],
                                             "url": ["type": "string"], "title": ["type": "string"], "status": BrowserSupport.nullableInteger,
                                             "dialogs": BrowserSupport.dialogsSchema],
                                            required: ["clicked", "selector", "navigated", "url", "title", "dialogs"]),
        sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 60, concurrency: .serial,
        outputIsUntrusted: true, examples: [["selector": "button[type=\"submit\"]"]])

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let selector = try BrowserSupport.selector(input)
        return ToolRequirements(capabilities: BrowserSupport.pageCapabilities(manager, context), tier: .consequential,
                                summary: "Click \(selector.prefix(120)) on \(BrowserSupport.pageLabel(manager, context))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let selector = try BrowserSupport.selector(input)
        let limit = BrowserSupport.limit(input, context)
        let session = try await BrowserSupport.existingSession(manager, context)
        return try await session.withExclusiveAccess { @MainActor in
            session.setAllowedHosts(BrowserSupport.allowedHosts(context, callHost: session.currentHost))
            _ = session.takeDialogs()
            let marker = session.marker()
            let clicked = try await BrowserSupport.script(session, PageScripts.click, ["selector": selector])
            if clicked["ok"]?.boolValue != true {
                let code = clicked["code"]?.stringValue ?? "unknown"
                if let failure = BrowserSupport.selectorFailure(code: code, selector: selector) { return failure }
                switch code {
                case "not_found": throw ToolError.notFound("No element matches \(selector) on the page.")
                case "invalid_selector": throw ToolError.invalidInput("\(selector) is not a valid CSS selector.")
                default: throw ToolError.internalError("browser.click failed with code \(code).")
                }
            }
            let outcome = try await session.settle(since: marker, requireActivity: false, timeoutSeconds: limit)
            let dialogs = session.takeDialogs()
            if let block = outcome.blocked {
                var result = block.toolResult
                result.output["clicked"] = true
                result.output["dialogs"] = BrowserSupport.dialogs(dialogs)
                return result
            }
            if outcome.timedOut { return BrowserSupport.timedOut(limit, "waiting for the navigation that followed the click") }
            if let error = outcome.error { throw ToolError.network("The click started a navigation that failed: \(error)", retryable: false) }
            var result = ToolResult.success([
                "clicked": true, "selector": .string(selector), "element": ["tag": clicked["tag"] ?? "", "text": clicked["text"] ?? "", "href": clicked["href"] ?? ""],
                "navigated": .bool(outcome.navigated), "url": .string(outcome.url), "title": .string(outcome.title),
                "status": outcome.httpStatus.map(JSONValue.int) ?? .null, "dialogs": BrowserSupport.dialogs(dialogs),
            ], summary: "Clicked \(selector.prefix(120))" + (outcome.navigated ? ", now on \(outcome.url.prefix(200))" : ""))
            result.untrusted = true
            return result
        }
    }
}

// MARK: - browser.waitFor

public struct BrowserWaitForTool: ORIXTool {
    let manager: BrowserSessionManager
    public let manifest = ToolManifest(
        identifier: "browser.waitFor", name: "Wait for page state",
        summary: "Wait until the open page reaches a state: an element matching a selector is present, visible or absent, the page text contains a string, and/or the URL matches a regular expression. Returns as soon as all given conditions hold; fails with a timeout otherwise.",
        family: "browser",
        inputSchema: .object(["selector": .string("CSS selector to watch."),
                              "state": .string("What the selector must be.", enum: ["present", "visible", "absent"]),
                              "text": .string("Text the page must contain."),
                              "urlMatches": .string("Regular expression the page URL must match."),
                              "timeoutSeconds": .number("How long to wait. Default 10.")]),
        outputSchema: BrowserSupport.schema(["matched": ["type": "boolean"], "elapsedMs": ["type": "integer"], "url": ["type": "string"],
                                             "title": ["type": "string"], "dialogs": BrowserSupport.dialogsSchema],
                                            required: ["matched", "elapsedMs", "url", "title"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 120, concurrency: .serial, idempotent: true,
        outputIsUntrusted: true, examples: [["selector": "#results", "state": "visible", "timeoutSeconds": 15]])

    private struct Conditions {
        var selector: String?
        var state: String
        var text: String?
        var url: NSRegularExpression?
        var description: String
    }

    private func conditions(_ input: ToolInput) throws -> Conditions {
        let selector = input.optionalString("selector").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let text = input.optionalString("text")
        let pattern = input.optionalString("urlMatches")
        let state = input.optionalString("state") ?? "present"
        if let selector, selector.isEmpty { throw ToolError.invalidInput("selector is empty") }
        if let text, text.isEmpty { throw ToolError.invalidInput("text is empty") }
        guard selector != nil || text != nil || pattern != nil else {
            throw ToolError.invalidInput("give at least one of selector, text or urlMatches")
        }
        if input.arguments["state"] != nil && selector == nil { throw ToolError.invalidInput("state needs a selector") }
        var regex: NSRegularExpression?
        if let pattern {
            do { regex = try NSRegularExpression(pattern: pattern) } catch { throw ToolError.invalidInput("urlMatches is not a valid regular expression") }
        }
        if let t = input.arguments["timeoutSeconds"]?.doubleValue, t <= 0 { throw ToolError.invalidInput("timeoutSeconds must be positive") }
        var parts: [String] = []
        if let selector { parts.append("\(selector.prefix(120)) to be \(state)") }
        if let text { parts.append("the text “\(text.prefix(80))”") }
        if let pattern { parts.append("the URL to match \(pattern.prefix(120))") }
        return Conditions(selector: selector, state: state, text: text, url: regex, description: parts.joined(separator: ", "))
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let c = try conditions(input)
        return ToolRequirements(capabilities: BrowserSupport.pageCapabilities(manager, context), tier: .readOnly,
                                summary: "Wait on \(BrowserSupport.pageLabel(manager, context)) for \(c.description)")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let c = try conditions(input)
        let limit = BrowserSupport.limit(input, context, default: 10)
        let session = try await BrowserSupport.existingSession(manager, context)
        return try await session.withExclusiveAccess { @MainActor in
            session.setAllowedHosts(BrowserSupport.allowedHosts(context, callHost: session.currentHost))
            let start = Date()
            let deadline = start.addingTimeInterval(limit)
            let needsDOM = c.selector != nil || c.text != nil
            while true {
                if Task.isCancelled { throw ToolError.canceled }
                if session.isClosed { throw ToolError.notFound(BrowserSupport.noPage) }
                let url = session.currentURL?.absoluteString ?? ""
                let urlOK = c.url.map { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil } ?? true
                let remaining = deadline.timeIntervalSinceNow
                var domOK = !needsDOM
                if needsDOM {
                    // One slice of in-page waiting (MutationObserver). A navigation ends the slice early; the loop then
                    // re-arms on the new document. When only the URL is still pending, the slice is a short poll.
                    let slice = max(1, Int(min(max(remaining, 0), urlOK ? 0.5 : 0.1) * 1000))
                    do {
                        let r = try await session.evaluate(PageScripts.wait, arguments: [
                            "selector": c.selector as Any? ?? NSNull(), "state": c.state, "text": c.text as Any? ?? NSNull(), "sliceMs": slice,
                        ])
                        if r["error"]?.stringValue == "invalid_selector" { throw ToolError.invalidInput("\(c.selector ?? "") is not a valid CSS selector.") }
                        domOK = r["matched"]?.boolValue ?? false
                    } catch is BrowserSession.PageScriptError {
                        domOK = false
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                } else if !urlOK {
                    try? await Task.sleep(nanoseconds: UInt64(min(max(remaining, 0.001), 0.05) * 1_000_000_000))
                }
                if domOK {
                    let now = session.currentURL?.absoluteString ?? ""
                    if c.url.map({ $0.firstMatch(in: now, range: NSRange(now.startIndex..., in: now)) != nil }) ?? true {
                        var result = ToolResult.success([
                            "matched": true, "elapsedMs": .int(Int(Date().timeIntervalSince(start) * 1000)), "url": .string(now),
                            "title": .string(session.title), "dialogs": BrowserSupport.dialogs(session.takeDialogs()),
                        ], summary: "Condition met: \(c.description)")
                        result.untrusted = true
                        return result
                    }
                }
                if Date() >= deadline { return BrowserSupport.timedOut(limit, "waiting for \(c.description)") }
            }
        }
    }
}

// MARK: - browser.screenshot

public struct BrowserScreenshotTool: ORIXTool {
    let manager: BrowserSessionManager
    public let manifest = ToolManifest(
        identifier: "browser.screenshot", name: "Screenshot page",
        summary: "Save a PNG picture of the visible part of the open page. Without a path the file goes to the run's artifacts folder.",
        family: "browser",
        inputSchema: .object(["path": .string("Where to save the PNG. Default: the run's artifacts folder."),
                              "overwrite": .boolean("Replace an existing file. Default false.")]),
        outputSchema: BrowserSupport.schema(["path": ["type": "string"], "width": ["type": "integer"], "height": ["type": "integer"],
                                             "bytes": ["type": "integer"], "sha256": ["type": "string"], "url": ["type": "string"]],
                                            required: ["path", "width", "height", "bytes", "sha256"]),
        sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 30, concurrency: .serial,
        outputIsUntrusted: true, examples: [[:]])

    private func destination(_ input: ToolInput, _ context: ToolExecutionContext) throws -> String {
        if let path = input.optionalString("path") {
            let canonical = try PathResolver.canonical(path, relativeTo: context.workingDirectory)
            guard canonical.lowercased().hasSuffix(".png") else { throw ToolError.invalidInput("path must end in .png") }
            return canonical
        }
        let safeID = context.callID.replacingOccurrences(of: #"[^A-Za-z0-9_-]"#, with: "_", options: .regularExpression)
        return try PathResolver.canonical("screenshots/browser-\(safeID).png", relativeTo: context.artifactsDirectory)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try destination(input, context)
        let inArtifacts = BrowserSupport.isUnderArtifacts(path, context)
        return ToolRequirements(capabilities: BrowserSupport.pageCapabilities(manager, context) + [.fileWrite(path: path)],
                                tier: inArtifacts ? .readOnly : .reversibleWrite,
                                summary: "Save a screenshot of \(BrowserSupport.pageLabel(manager, context)) to \(PathResolver.display(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try destination(input, context)
        let overwrite = input.bool("overwrite", default: false)
        let session = try await BrowserSupport.existingSession(manager, context)
        let shot = try await session.withExclusiveAccess { @MainActor in
            (try await session.snapshotPNG(), session.currentURL?.absoluteString ?? "")
        }
        let (png, url) = shot
        let fm = FileManager.default
        if fm.fileExists(atPath: path) && !overwrite { throw ToolError.io("\(PathResolver.display(path)) already exists; pass overwrite: true to replace it.") }
        do {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try png.data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch { throw ToolError.io("Could not write \(PathResolver.display(path)): \(error.localizedDescription)") }
        let digest = try BrowserSession.sha256(of: URL(fileURLWithPath: path))
        let artifact = Artifact(path: path, kind: "screenshot", bytes: png.data.count, sha256: digest, note: "Browser screenshot of \(url.prefix(200))")
        var result = ToolResult.success([
            "path": .string(path), "width": .int(png.width), "height": .int(png.height), "bytes": .int(png.data.count),
            "sha256": .string(digest), "url": .string(url),
        ], summary: "Saved a \(png.width)×\(png.height) screenshot to \(PathResolver.display(path))", artifacts: [artifact])
        result.untrusted = true
        return result
    }
}

// MARK: - browser.download

public struct BrowserDownloadTool: ORIXTool {
    let manager: BrowserSessionManager
    static let defaultMaxBytes = 50 * 1024 * 1024
    static let hardMaxBytes = 2 * 1024 * 1024 * 1024

    public let manifest = ToolManifest(
        identifier: "browser.download", name: "Download file",
        summary: "Download a file with the ORIX browser's session (its cookies apply) into the run's artifacts folder or a given path, with a size cap. Returns the path, size and SHA-256. Pages never start downloads on their own.",
        family: "browser",
        inputSchema: .object(["url": .string("Absolute https URL of the file."),
                              "path": .string("Where to save it. Default: downloads/<file name> in the run's artifacts folder."),
                              "maxBytes": .integer("Refuse anything larger. Default 52428800 (50 MB).", minimum: 1, maximum: hardMaxBytes),
                              "overwrite": .boolean("Replace an existing file. Default false."),
                              "timeoutSeconds": .number("Give up after this many seconds.")], required: ["url"]),
        outputSchema: BrowserSupport.schema(["path": ["type": "string"], "bytes": ["type": "integer"], "sha256": ["type": "string"],
                                             "url": ["type": "string"], "status": BrowserSupport.nullableInteger,
                                             "mimeType": ["type": ["string", "null"]], "suggestedFilename": ["type": "string"]],
                                            required: ["path", "bytes", "sha256", "url"]),
        sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 600, concurrency: .serial,
        outputIsUntrusted: true, examples: [["url": "https://example.com/report.pdf"]])

    private func destination(_ input: ToolInput, _ url: URL, _ context: ToolExecutionContext) throws -> String {
        if let path = input.optionalString("path") { return try PathResolver.canonical(path, relativeTo: context.workingDirectory) }
        var name = url.lastPathComponent.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression)
        name = String(name.drop(while: { $0 == "." }).prefix(120))
        if name.isEmpty || name == "_" { name = "download.bin" }
        return try PathResolver.canonical("downloads/\(name)", relativeTo: context.artifactsDirectory)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let (url, host) = try BrowserSupport.parseURL(input)
        let path = try destination(input, url, context)
        return ToolRequirements(capabilities: [.browser(host: host), .fileWrite(path: path)], tier: .consequential,
                                summary: "Download \(url.absoluteString.prefix(200)) to \(PathResolver.display(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let (url, host) = try BrowserSupport.parseURL(input)
        let path = try destination(input, url, context)
        let maxBytes = min(Self.hardMaxBytes, max(1, input.int("maxBytes", default: Self.defaultMaxBytes)))
        let overwrite = input.bool("overwrite", default: false)
        let limit = BrowserSupport.limit(input, context)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            guard overwrite else { throw ToolError.io("\(PathResolver.display(path)) already exists; pass overwrite: true to replace it.") }
        }
        do { try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) } catch {
            throw ToolError.io("Could not create the destination folder: \(error.localizedDescription)")
        }
        let session = await manager.openSession(runID: context.runID)
        do {
            let file = try await session.withExclusiveAccess { @MainActor () async throws -> DownloadedFile in
                session.setAllowedHosts(BrowserSupport.allowedHosts(context, callHost: host))
                // Download next to the destination, then replace it, so a failed download never destroys the old file.
                let staging = URL(fileURLWithPath: path + ".orix-new-\(UUID().uuidString.prefix(8))")
                var file = try await session.download(url, to: staging, maxBytes: maxBytes, timeoutSeconds: limit)
                do {
                    if FileManager.default.fileExists(atPath: path) { _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: staging) }
                    else { try FileManager.default.moveItem(at: staging, to: URL(fileURLWithPath: path)) }
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw ToolError.io("Could not move the download to \(PathResolver.display(path)): \(error.localizedDescription)")
                }
                file.path = path
                return file
            }
            let artifact = Artifact(path: file.path, kind: "file", bytes: file.bytes, sha256: file.sha256, note: "Downloaded from \(url.absoluteString.prefix(200))")
            var result = ToolResult.success([
                "path": .string(file.path), "bytes": .int(file.bytes), "sha256": .string(file.sha256), "url": .string(file.finalURL.isEmpty ? url.absoluteString : file.finalURL),
                "status": file.httpStatus.map(JSONValue.int) ?? .null, "mimeType": file.mimeType.map(JSONValue.string) ?? .null,
                "suggestedFilename": .string(file.suggestedFilename),
            ], summary: "Downloaded \(file.bytes) bytes to \(PathResolver.display(file.path))", artifacts: [artifact])
            result.untrusted = true
            return result
        } catch let failure as DownloadFailure {
            switch failure {
            case .blocked(let block): return block.toolResult
            case .httpStatus(let status):
                return .failure(.failed, ToolFailure(code: "http_error", message: "The server answered HTTP \(status) for \(url.absoluteString.prefix(200)); nothing was saved.", retryable: status >= 500))
            case .tooLarge(let size):
                return .failure(.failed, ToolFailure(code: "too_large", message: "The file is larger than the cap of \(maxBytes) bytes (at least \(size) bytes); nothing was saved.",
                                                     recovery: "Raise maxBytes if the user agrees to a file of that size."))
            case .timeout(let seconds): return BrowserSupport.timedOut(seconds, "downloading from \(host)")
            case .canceled: throw ToolError.canceled
            case .network(let message): throw ToolError.network("The download failed: \(message)", retryable: true)
            }
        }
    }
}

// MARK: - browser.close

public struct BrowserCloseTool: ORIXTool {
    let manager: BrowserSessionManager
    public let manifest = ToolManifest(
        identifier: "browser.close", name: "Close browser",
        summary: "Close the ORIX browser session of this run and discard its cookies and page state.",
        family: "browser",
        inputSchema: .object([:]),
        outputSchema: BrowserSupport.schema(["closed": ["type": "boolean"]], required: ["closed"]),
        sideEffect: .write, defaultTier: .readOnly, defaultTimeoutSeconds: 10, concurrency: .serial, idempotent: true, examples: [[:]])

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "Close the ORIX browser session of this run")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let closed = await manager.close(runID: context.runID)
        return .success(["closed": .bool(closed)], summary: closed ? "Closed the browser session" : "No browser session was open")
    }
}
