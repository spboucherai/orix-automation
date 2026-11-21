// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/AccessibilityTools.swift
// Description: accessibility.* tools: status, tree, find, press, setValue, focus, typeText, waitFor. Elements are re-resolved from their path before every action; secure fields are never read or written.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import ORIXCore

private let elementSchema = JSONSchema.string("Element path returned by accessibility.tree or accessibility.find, for example AXApplication/AXWindow[0]/AXButton[2].")
private let expectedTitleSchema = JSONSchema.string("Optional title or description the element must still have; the action is refused if it changed.")
private let nodeSchema = outputObject(["path": .string(), "role": .string()], required: ["path", "role"])

private func axRequirements(_ input: ToolInput, tier: ApprovalTier, _ summary: (String) -> String) throws -> ToolRequirements {
    let id = try input.bundleID()
    return ToolRequirements(capabilities: [.accessibility(bundleID: id)], tier: tier, summary: summary(AppResolver.displayName(id)))
}

private func focusChanged(_ message: String, output: JSONValue = .null) -> TypedFailure {
    TypedFailure(code: "focus_changed", message: message, recovery: "Bring the application and the element back into focus (accessibility.focus), then call again.",
                 retryable: true, output: output)
}

// MARK: status

public struct AccessibilityStatusTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "accessibility.status", name: "Accessibility status",
                     summary: "Reports whether this app is trusted for Accessibility control and how the user can enable it. Never prompts.",
                     family: "accessibility", inputSchema: .object([:]),
                     outputSchema: outputObject(["trusted": .boolean(), "howToEnable": .string(), "settingsURL": .string()], required: ["trusted", "howToEnable", "settingsURL"]),
                     sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 5, idempotent: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "Check whether Accessibility access is enabled")
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let trusted = AXIsProcessTrusted()
        return .success(["trusted": .bool(trusted), "howToEnable": .string(MacPermissions.howToEnable(.accessibility)),
                         "settingsURL": .string(MacPermissions.settingsURL(for: .accessibility).absoluteString),
                         "secureInputActive": .bool(IsSecureEventInputEnabled())],
                        summary: trusted ? "Accessibility access is enabled" : "Accessibility access is not enabled")
    }
}

// MARK: tree

public struct AccessibilityTreeTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "accessibility.tree", name: "Accessibility tree",
                     summary: "Lists the interface elements of a running application (role, title, value, enabled, frame, stable path). Values of secure text fields are replaced by «secure».",
                     family: "accessibility",
                     inputSchema: .object([
                        "bundleID": bundleIDSchema,
                        "element": .string("Optional path of the element to start from (default: the application)."),
                        "maxDepth": .integer("How deep to go below the start element (default 6).", minimum: 0, maximum: 40),
                        "maxNodes": .integer("Maximum elements returned (default 300).", minimum: 1, maximum: 5000),
                        "includeMenuBar": .boolean("Include the menu bar (default false)."),
                     ], required: ["bundleID"]),
                     outputSchema: outputObject(["application": .string(), "nodes": .array(of: nodeSchema), "truncated": .boolean()], required: ["application", "nodes", "truncated"]),
                     sideEffect: .read, defaultTier: .readOnly, macPermissions: [.accessibility], defaultTimeoutSeconds: 60, idempotent: true, outputIsUntrusted: true,
                     examples: [["bundleID": "com.apple.finder", "maxDepth": 4]])
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        try axRequirements(input, tier: .readOnly) { "Read the interface elements of \($0)" }
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let bundleID = try input.bundleID()
        let start = input.optionalString("element")
        let maxDepth = input.int("maxDepth", default: 6), maxNodes = input.int("maxNodes", default: 300)
        let menuBar = input.bool("includeMenuBar", default: false)
        return try await catchingTypedFailures {
            let (name, nodes, walk) = try await runBlocking { () -> (String, [JSONValue], AX.WalkResult) in
                let app = try AX.app(bundleID: bundleID)
                let root = try start.map { try AX.resolve($0, in: app) } ?? app.element
                var nodes: [JSONValue] = []
                let walk = AX.walk(from: root, path: start ?? AX.rootPath, maxDepth: maxDepth, maxNodes: maxNodes, includeMenuBar: menuBar) { _, path, depth, info in
                    nodes.append(info.json(path: path, depth: depth))
                    return !Task.isCancelled
                }
                return (app.name, nodes, walk)
            }
            try Task.checkCancellation()
            var result = ToolResult.success(["application": .string(name), "bundleID": .string(bundleID), "nodes": .array(nodes),
                                             "truncated": .bool(walk.truncated), "depthLimited": .bool(walk.depthLimited)],
                                            summary: "\(nodes.count) elements of \(name)" + (walk.truncated ? " (truncated)" : ""))
            result.truncated = walk.truncated
            result.untrusted = true
            return result
        }
    }
}

// MARK: find

public struct AccessibilityFindTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        var props = AX.Filter.schema
        props["bundleID"] = bundleIDSchema
        props["maxResults"] = .integer("Maximum matches returned (default 20).", minimum: 1, maximum: 500)
        props["maxDepth"] = .integer("Search depth (default 30).", minimum: 0, maximum: 60)
        props["includeMenuBar"] = .boolean("Search the menu bar too (default false).")
        return ToolManifest(identifier: "accessibility.find", name: "Find interface elements",
                            summary: "Finds interface elements of a running application by role, title, identifier or value and returns their stable paths for the action tools.",
                            family: "accessibility", inputSchema: .object(props, required: ["bundleID"]),
                            outputSchema: outputObject(["matches": .array(of: nodeSchema), "searched": .integer(), "truncated": .boolean()], required: ["matches", "searched", "truncated"]),
                            sideEffect: .read, defaultTier: .readOnly, macPermissions: [.accessibility], defaultTimeoutSeconds: 60, idempotent: true, outputIsUntrusted: true,
                            examples: [["bundleID": "com.apple.TextEdit", "role": "AXButton", "title": "Save"]])
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        guard !AX.Filter(input).isEmpty else { throw ToolError.invalidInput("Give at least one of role, title, identifier, value") }
        let filter = AX.Filter(input)
        return try axRequirements(input, tier: .readOnly) { "Find elements with \(filter.description) in \($0)" }
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let bundleID = try input.bundleID()
        let filter = AX.Filter(input)
        guard !filter.isEmpty else { throw ToolError.invalidInput("Give at least one of role, title, identifier, value") }
        let maxResults = input.int("maxResults", default: 20), maxDepth = input.int("maxDepth", default: 30)
        let menuBar = input.bool("includeMenuBar", default: false)
        return try await catchingTypedFailures {
            let (matches, walk) = try await runBlocking { () -> ([JSONValue], AX.WalkResult) in
                let app = try AX.app(bundleID: bundleID)
                var matches: [JSONValue] = []
                let walk = AX.walk(from: app.element, path: AX.rootPath, maxDepth: maxDepth, maxNodes: 20_000, includeMenuBar: menuBar) { _, path, depth, info in
                    if filter.matches(info) { matches.append(info.json(path: path, depth: depth)) }
                    return matches.count < maxResults && !Task.isCancelled
                }
                return (matches, walk)
            }
            try Task.checkCancellation()
            let capped = matches.count >= maxResults || walk.truncated
            var result = ToolResult.success(["matches": .array(matches), "searched": .int(walk.visited), "truncated": .bool(capped)],
                                            summary: "\(matches.count) element(s) with \(filter.description)")
            result.untrusted = true
            return result
        }
    }
}

// MARK: press

public struct AccessibilityPressTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "accessibility.press", name: "Press an element",
                     summary: "Presses a button, menu item or other pressable element of a running application through the Accessibility API (no pointer movement). The element is re-resolved from its path right before the action.",
                     family: "accessibility",
                     inputSchema: .object(["bundleID": bundleIDSchema, "element": elementSchema, "expectedTitle": expectedTitleSchema], required: ["bundleID", "element"]),
                     outputSchema: outputObject(["pressed": .boolean(), "element": nodeSchema], required: ["pressed", "element"]),
                     sideEffect: .write, defaultTier: .consequential, macPermissions: [.accessibility], defaultTimeoutSeconds: 15,
                     concurrency: .exclusive, supportsDryRun: true, outputIsUntrusted: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let element = try input.nonEmptyString("element")
        let title = input.optionalString("expectedTitle").map { " \"\($0)\"" } ?? ""
        return try axRequirements(input, tier: .consequential) { "Press\(title) (\(element.split(separator: "/").last ?? "")) in \($0)" }
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let bundleID = try input.bundleID(), path = try input.nonEmptyString("element")
        let expected = input.optionalString("expectedTitle"), dryRun = input.dryRun
        return try await catchingTypedFailures {
            try await runBlocking {
                let app = try AX.app(bundleID: bundleID)
                let (element, info) = try AX.resolve(path, in: app, expectedTitle: expected)
                let node = info.json(path: path, depth: 0)
                if info.enabled == false {
                    throw TypedFailure(code: "element_disabled", message: "\(info.role) \"\(info.title ?? info.label ?? "")\" is disabled.", retryable: true, output: node)
                }
                var names: CFArray?
                AXUIElementCopyActionNames(element, &names)
                let actions = (names as? [String]) ?? []
                guard actions.contains(kAXPressAction) else {
                    throw ToolError.unsupported("\(info.role) at \(path) has no press action (available: \(actions.joined(separator: ", ").isEmpty ? "none" : actions.joined(separator: ", "))).")
                }
                if dryRun { return .simulated(["pressed": false, "element": node], summary: "Would press \(info.role) \"\(info.title ?? info.label ?? "")\" in \(app.name)") }
                let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
                // kAXErrorCannotComplete is common when the press opens a modal dialog: the action was delivered.
                guard error == .success || error == .cannotComplete else {
                    throw TypedFailure(code: "action_failed", message: "The press was refused by \(app.name) (AXError \(error.rawValue)).", retryable: true, output: node)
                }
                var result = ToolResult.success(["pressed": true, "element": node, "delivery": .string(error == .success ? "confirmed" : "sent")],
                                                summary: "Pressed \(info.role) \"\(info.title ?? info.label ?? "")\" in \(app.name)")
                result.untrusted = true
                return result
            }
        }
    }
}

// MARK: setValue

public struct AccessibilitySetValueTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "accessibility.setValue", name: "Set an element's value",
                     summary: "Sets the value of a text field, checkbox, slider or similar element of a running application, then reads it back. Secure text fields are refused.",
                     family: "accessibility",
                     inputSchema: .object(["bundleID": bundleIDSchema, "element": elementSchema, "expectedTitle": expectedTitleSchema,
                                           "value": JSONSchema(raw: ["type": ["string", "number", "boolean"], "description": "New value."])],
                                          required: ["bundleID", "element", "value"]),
                     outputSchema: outputObject(["set": .boolean(), "verified": .boolean(), "element": nodeSchema], required: ["set", "verified", "element"]),
                     sideEffect: .write, defaultTier: .consequential, macPermissions: [.accessibility], defaultTimeoutSeconds: 15,
                     concurrency: .exclusive, supportsDryRun: true, redactedInputKeys: [], outputIsUntrusted: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let element = try input.nonEmptyString("element")
        guard let value = input.arguments["value"], !value.isNull else { throw ToolError.invalidInput("value is required") }
        let shown = String(value.displayString.prefix(60))
        return try axRequirements(input, tier: .consequential) { "Set \(element.split(separator: "/").last ?? "") to \"\(shown)\" in \($0)" }
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let bundleID = try input.bundleID(), path = try input.nonEmptyString("element")
        let expected = input.optionalString("expectedTitle"), dryRun = input.dryRun
        guard let value = input.arguments["value"], !value.isNull else { throw ToolError.invalidInput("value is required") }
        return try await catchingTypedFailures {
            try await runBlocking {
                let app = try AX.app(bundleID: bundleID)
                let (element, info) = try AX.resolve(path, in: app, expectedTitle: expected)
                guard !info.secure else { throw ToolError.permissionDenied("Refusing to write into a secure text field (\(path)). Passwords are entered by the user, never by automation.") }
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                guard settable.boolValue else { throw ToolError.unsupported("The value of \(info.role) at \(path) cannot be set through Accessibility.") }
                if dryRun { return .simulated(["set": false, "verified": false, "element": info.json(path: path, depth: 0)], summary: "Would set \(info.role) in \(app.name)") }
                let cf: CFTypeRef
                switch value {
                case .string(let s): cf = s as CFString
                case .bool(let b): cf = (b ? kCFBooleanTrue : kCFBooleanFalse)!
                case .int(let i): cf = NSNumber(value: i)
                case .number(let d): cf = NSNumber(value: d)
                default: throw ToolError.invalidInput("value must be a string, a number or a boolean")
                }
                let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, cf)
                guard error == .success else {
                    throw TypedFailure(code: "action_failed", message: "\(app.name) refused the new value (AXError \(error.rawValue)).", retryable: true, output: info.json(path: path, depth: 0))
                }
                // Postcondition: read the value back from a freshly resolved element.
                let after = AX.info(try AX.resolve(path, in: app))
                let verified = after.value?.displayString == value.displayString
                var result = ToolResult.success(["set": true, "verified": .bool(verified), "element": after.json(path: path, depth: 0)],
                                                summary: verified ? "Set and verified the value of \(info.role) in \(app.name)" : "Value sent to \(info.role) in \(app.name); the element now reports a different value")
                result.untrusted = true
                return result
            }
        }
    }
}

// MARK: focus

public struct AccessibilityFocusTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "accessibility.focus", name: "Focus an element",
                     summary: "Brings a running application to the front and gives keyboard focus to one of its elements, then verifies both. Call before accessibility.typeText.",
                     family: "accessibility",
                     inputSchema: .object(["bundleID": bundleIDSchema, "element": elementSchema, "expectedTitle": expectedTitleSchema,
                                           "activate": .boolean("Bring the application to the front first (default true).")], required: ["bundleID", "element"]),
                     outputSchema: outputObject(["focused": .boolean(), "frontmost": .boolean(), "element": nodeSchema], required: ["focused", "frontmost", "element"]),
                     sideEffect: .write, defaultTier: .consequential, macPermissions: [.accessibility], defaultTimeoutSeconds: 15,
                     concurrency: .exclusive, idempotent: true, outputIsUntrusted: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let element = try input.nonEmptyString("element")
        return try axRequirements(input, tier: .consequential) { "Bring \($0) to the front and focus \(element.split(separator: "/").last ?? "")" }
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let bundleID = try input.bundleID(), path = try input.nonEmptyString("element")
        let expected = input.optionalString("expectedTitle"), activate = input.bool("activate", default: true)
        return try await catchingTypedFailures {
            if activate {
                let pid = try await runBlocking { try AX.app(bundleID: bundleID).pid }
                if AX.frontmostPID() != pid {
                    AppResolver.running(bundleID).first?.activate()
                    // Observable postcondition: wait until the Accessibility server reports the app in front.
                    let deadline = Date().addingTimeInterval(3)
                    while AX.frontmostPID() != pid, Date() < deadline {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            }
            return try await runBlocking {
                let app = try AX.app(bundleID: bundleID)
                guard AX.frontmostPID() == app.pid else { throw focusChanged("\(app.name) is not the frontmost application; focus was not changed.") }
                let (element, info) = try AX.resolve(path, in: app, expectedTitle: expected)
                if info.role == "AXWindow" {
                    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                } else {
                    let error = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                    guard error == .success else { throw ToolError.unsupported("\(info.role) at \(path) cannot take keyboard focus (AXError \(error.rawValue)).") }
                }
                let after = AX.info(try AX.resolve(path, in: app))
                let focused = info.role == "AXWindow" ? (AX.bool(element, kAXMainAttribute) ?? false) : (after.focused ?? false)
                guard AX.frontmostPID() == app.pid else { throw focusChanged("Another application came to the front while focusing \(app.name).") }
                var result = ToolResult.success(["focused": .bool(focused), "frontmost": true, "element": after.json(path: path, depth: 0)],
                                                summary: focused ? "Focused \(info.role) in \(app.name)" : "\(app.name) is in front but \(info.role) did not take focus")
                result.untrusted = true
                return result
            }
        }
    }
}

// MARK: typeText

public struct AccessibilityTypeTextTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "accessibility.typeText", name: "Type text",
                     summary: "Types text as keyboard events into one element of the frontmost application. Refused unless that application is in front and that element has keyboard focus (checked again before every chunk), and always refused for secure text fields.",
                     family: "accessibility",
                     inputSchema: .object(["bundleID": bundleIDSchema, "element": elementSchema, "expectedTitle": expectedTitleSchema,
                                           "text": .string("Text to type. Newlines press Return, tabs press Tab.")], required: ["bundleID", "element", "text"]),
                     outputSchema: outputObject(["typedCharacters": .integer(), "element": nodeSchema], required: ["typedCharacters", "element"]),
                     sideEffect: .write, defaultTier: .consequential, macPermissions: [.accessibility], defaultTimeoutSeconds: 60,
                     concurrency: .exclusive, supportsDryRun: true, outputIsUntrusted: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let text = try input.string("text")
        guard !text.isEmpty, text.utf16.count <= 20_000 else { throw ToolError.invalidInput("text must contain 1 to 20000 characters") }
        let element = try input.nonEmptyString("element")
        return try axRequirements(input, tier: .consequential) { "Type \(text.count) characters into \(element.split(separator: "/").last ?? "") of \($0)" }
    }

    /// Splits text into keyboard steps: unicode chunks of at most 16 UTF-16 units, Return and Tab as real key presses.
    enum Step: Equatable { case text(String), key(CGKeyCode) }
    static func steps(for text: String) -> [Step] {
        var steps: [Step] = []
        var chunk = ""
        func flush() { if !chunk.isEmpty { steps.append(.text(chunk)); chunk = "" } }
        for ch in text.replacingOccurrences(of: "\r\n", with: "\n") {
            if ch == "\n" || ch == "\r" { flush(); steps.append(.key(CGKeyCode(kVK_Return))) }
            else if ch == "\t" { flush(); steps.append(.key(CGKeyCode(kVK_Tab))) }
            else {
                if chunk.utf16.count + String(ch).utf16.count > 16 { flush() }
                chunk.append(ch)
            }
        }
        flush()
        return steps
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let bundleID = try input.bundleID(), path = try input.nonEmptyString("element"), text = try input.string("text")
        let expected = input.optionalString("expectedTitle"), dryRun = input.dryRun
        let steps = Self.steps(for: text)
        return try await catchingTypedFailures {
            try await runBlocking {
                let app = try AX.app(bundleID: bundleID)
                var typed = 0
                /// The gate in front of every keyboard event: right app in front, right element focused, nothing secure.
                func verify() throws -> AX.Info {
                    guard AX.frontmostPID() == app.pid else {
                        throw focusChanged("\(app.name) is no longer the frontmost application; typing stopped after \(typed) characters.", output: ["typedCharacters": .int(typed)])
                    }
                    let (element, info) = try AX.resolve(path, in: app, expectedTitle: expected)
                    guard !info.secure else { throw ToolError.permissionDenied("Refusing to type into a secure text field (\(path)). Passwords are entered by the user, never by automation.") }
                    guard !IsSecureEventInputEnabled() else { throw ToolError.permissionDenied("Secure keyboard input is active (a password field has focus somewhere); typing is refused.") }
                    guard let focused = AX.element(app.element, kAXFocusedUIElementAttribute), CFEqual(focused, element) else {
                        throw focusChanged("The keyboard focus in \(app.name) is not on \(path); typing stopped after \(typed) characters.", output: ["typedCharacters": .int(typed)])
                    }
                    guard !AX.isSecure(focused) else { throw ToolError.permissionDenied("Refusing to type into a secure text field.") }
                    return info
                }
                let info = try verify()
                if dryRun { return .simulated(["typedCharacters": 0, "element": info.json(path: path, depth: 0)], summary: "Would type \(text.count) characters into \(info.role) of \(app.name)") }
                guard CGPreflightPostEventAccess() else {
                    throw ToolError.tccBlocked(.accessibility, "macOS does not allow this app to post keyboard events. " + MacPermissions.howToEnable(.accessibility))
                }
                let source = CGEventSource(stateID: .combinedSessionState)
                for step in steps {
                    if Task.isCancelled { throw ToolError.canceled }
                    _ = try verify()
                    switch step {
                    case .text(let chunk):
                        let units = Array(chunk.utf16)
                        for down in [true, false] {
                            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { throw ToolError.internalError("Could not create a keyboard event") }
                            event.flags = []
                            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                            event.postToPid(app.pid)
                        }
                        typed += chunk.count
                    case .key(let code):
                        for down in [true, false] {
                            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { throw ToolError.internalError("Could not create a keyboard event") }
                            event.flags = []
                            event.postToPid(app.pid)
                        }
                        typed += 1
                    }
                    usleep(12_000) // pacing so the target's event queue keeps order
                }
                usleep(60_000)
                let after = AX.info(try AX.resolve(path, in: app))
                var result = ToolResult.success(["typedCharacters": .int(typed), "element": after.json(path: path, depth: 0)],
                                                summary: "Typed \(typed) characters into \(info.role) of \(app.name)")
                result.untrusted = true
                return result
            }
        }
    }
}

// MARK: waitFor

public struct AccessibilityWaitForTool: ORIXTool {
    public init() {}
    static let conditions = ["exists", "absent", "enabled", "focused", "valueEquals", "valueContains"]
    public var manifest: ToolManifest {
        var props = AX.Filter.schema
        props["bundleID"] = bundleIDSchema
        props["element"] = .string("Element path to watch, as an alternative to the role/title/identifier/value filters.")
        props["condition"] = .string("What to wait for (default exists).", enum: Self.conditions)
        props["expected"] = .string("Expected value for valueEquals / valueContains.")
        props["timeoutSeconds"] = .number("How long to wait (default 10).")
        props["pollIntervalMs"] = .integer("Polling interval (default 200).", minimum: 50, maximum: 5000)
        return ToolManifest(identifier: "accessibility.waitFor", name: "Wait for an interface state",
                            summary: "Polls a running application's interface until an element exists, disappears, becomes enabled or focused, or shows a given value. Use it to confirm the effect of an action instead of sleeping.",
                            family: "accessibility", inputSchema: .object(props, required: ["bundleID"]),
                            outputSchema: outputObject(["satisfied": .boolean(), "elapsedMs": .integer(), "condition": .string()], required: ["satisfied", "elapsedMs", "condition"]),
                            sideEffect: .read, defaultTier: .readOnly, macPermissions: [.accessibility], defaultTimeoutSeconds: 120, idempotent: true, outputIsUntrusted: true)
    }

    struct Plan: Sendable { var bundleID: String; var path: String?; var filter: AX.Filter; var condition: String; var expected: String? }

    func plan(_ input: ToolInput) throws -> Plan {
        let p = Plan(bundleID: try input.bundleID(), path: input.optionalString("element").flatMap { $0.isEmpty ? nil : $0 }, filter: AX.Filter(input),
                     condition: input.optionalString("condition") ?? "exists", expected: input.optionalString("expected"))
        guard Self.conditions.contains(p.condition) else { throw ToolError.invalidInput("condition must be one of \(Self.conditions.joined(separator: ", "))") }
        guard p.path != nil || !p.filter.isEmpty else { throw ToolError.invalidInput("Give element or at least one of role, title, identifier, value") }
        if p.condition.hasPrefix("value"), p.expected == nil { throw ToolError.invalidInput("expected is required for \(p.condition)") }
        return p
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input)
        let what = p.path.map { String($0.split(separator: "/").last ?? "") } ?? p.filter.description
        return try axRequirements(input, tier: .readOnly) { "Wait until \(what) is \(p.condition) in \($0)" }
    }

    /// One observation of the live interface. Returns the matched node when the condition holds.
    static func check(_ p: Plan) throws -> (Bool, JSONValue) {
        let app = try AX.app(bundleID: p.bundleID)
        var found: (AX.Info, String)?
        if let path = p.path {
            do { found = (AX.info(try AX.resolve(path, in: app)), path) } catch let f as TypedFailure where f.code == "element_not_found" { found = nil }
        } else {
            _ = AX.walk(from: app.element, path: AX.rootPath, maxDepth: 40, maxNodes: 20_000, includeMenuBar: false) { _, path, _, info in
                if p.filter.matches(info) { found = (info, path); return false }
                return true
            }
        }
        let node = found.map { $0.0.json(path: $0.1, depth: 0) } ?? .null
        guard let (info, _) = found else { return (p.condition == "absent", node) }
        switch p.condition {
        case "exists": return (true, node)
        case "absent": return (false, node)
        case "enabled": return (info.enabled == true, node)
        case "focused": return (info.focused == true, node)
        case "valueEquals": return (!info.secure && info.value?.displayString == p.expected, node)
        case "valueContains": return (!info.secure && (info.value?.displayString.contains(p.expected ?? "") ?? false), node)
        default: return (false, node)
        }
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input)
        let timeout = input.timeout(default: 10, context: context)
        let interval = UInt64(input.int("pollIntervalMs", default: 200)) * 1_000_000
        let started = Date()
        return try await catchingTypedFailures {
            var last: JSONValue = .null
            while true {
                try Task.checkCancellation()
                let (ok, node) = try await runBlocking { try Self.check(p) }
                last = node
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                if ok {
                    var result = ToolResult.success(["satisfied": true, "elapsedMs": .int(elapsed), "condition": .string(p.condition), "element": node],
                                                    summary: "Condition \(p.condition) met after \(elapsed) ms")
                    result.untrusted = true
                    return result
                }
                if Date().timeIntervalSince(started) >= timeout {
                    throw TypedFailure(status: .timedOut, code: "timeout", message: "Condition \(p.condition) was not met within \(Int(timeout)) s.", retryable: true,
                                       output: ["satisfied": false, "elapsedMs": .int(elapsed), "condition": .string(p.condition), "element": last])
                }
                try await Task.sleep(nanoseconds: interval)
            }
        }
    }
}
