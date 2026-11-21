// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/SystemTools.swift
// Description: system.apps, system.frontmost, system.windows, system.launchApp and system.quitApp: running applications, on-screen windows and polite application control.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ORIXCore

/// On-screen windows from the window server, front to back.
enum WindowList {
    struct Entry: Sendable {
        var id: CGWindowID
        var pid: pid_t
        var owner: String
        var title: String?
        var bounds: CGRect
        var layer: Int
    }

    static func onScreen() -> [Entry] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { w in
            guard let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value, let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            var bounds = CGRect.zero
            if let b = w[kCGWindowBounds as String] as? NSDictionary { CGRectMakeWithDictionaryRepresentation(b, &bounds) }
            return Entry(id: id, pid: pid, owner: w[kCGWindowOwnerName as String] as? String ?? "", title: w[kCGWindowName as String] as? String,
                         bounds: bounds, layer: (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0)
        }
    }
}

private func appJSON(_ app: NSRunningApplication, frontPID: pid_t?) -> JSONValue {
    var o: [String: JSONValue] = [
        "name": .string(app.localizedName ?? ""), "pid": .int(Int(app.processIdentifier)),
        "active": .bool(frontPID.map { $0 == app.processIdentifier } ?? app.isActive), "hidden": .bool(app.isHidden),
    ]
    if let id = app.bundleIdentifier { o["bundleID"] = .string(id) }
    if let path = app.bundleURL?.path { o["path"] = .string(path) }
    return .object(o)
}

// MARK: system.apps

public struct SystemAppsTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "system.apps", name: "Running applications",
                     summary: "Lists running applications with name, bundle identifier, process id and whether each is active or hidden.",
                     family: "system",
                     inputSchema: .object(["includeBackground": .boolean("Also list background agents and menu-bar-only apps (default false).")]),
                     outputSchema: outputObject(["applications": .array(of: outputObject(["name": .string(), "pid": .integer(), "active": .boolean(), "hidden": .boolean()],
                                                                                         required: ["name", "pid", "active", "hidden"]))], required: ["applications"]),
                     sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 10, idempotent: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "List running applications")
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let all = input.bool("includeBackground", default: false)
        let front = AX.frontmostPID()
        let apps = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && (all || $0.activationPolicy == .regular) }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        return .success(["applications": .array(apps.map { appJSON($0, frontPID: front) })], summary: "\(apps.count) running application(s)")
    }
}

// MARK: system.frontmost

public struct SystemFrontmostTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "system.frontmost", name: "Frontmost application",
                     summary: "Reports the frontmost application and, when Accessibility or Screen Recording access allows it, the title of its focused window. Says which source was used and why a title is missing.",
                     family: "system", inputSchema: .object([:]),
                     outputSchema: outputObject(["application": .any, "windowTitle": .any, "titleSource": .string()], required: ["titleSource"]),
                     sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 10, idempotent: true, outputIsUntrusted: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "Identify the frontmost application")
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        try await runBlocking {
            let pid = AX.frontmostPID()
            guard let pid, let app = NSRunningApplication(processIdentifier: pid) ?? NSWorkspace.shared.frontmostApplication else {
                return .success(["application": .null, "windowTitle": .null, "titleSource": "none", "note": "No frontmost application could be determined."],
                                summary: "No frontmost application")
            }
            var title: String?
            var source = "none"
            var note: String?
            if AXIsProcessTrusted() {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(element, 2)
                if let window = AX.element(element, kAXFocusedWindowAttribute) { title = AX.string(window, kAXTitleAttribute); source = "accessibility" }
                else { note = "The application has no focused window." ; source = "accessibility" }
            } else if CGPreflightScreenCaptureAccess() {
                title = WindowList.onScreen().first { $0.pid == app.processIdentifier && $0.layer == 0 }?.title
                source = "windowList"
            } else {
                note = "Window titles need Accessibility or Screen Recording access; neither is enabled for this app."
            }
            var out: [String: JSONValue] = ["application": appJSON(app, frontPID: app.processIdentifier), "windowTitle": title.map(JSONValue.string) ?? .null, "titleSource": .string(source)]
            if let note { out["note"] = .string(note) }
            var result = ToolResult.success(.object(out), summary: "Frontmost: \(app.localizedName ?? "unknown")" + (title.map { " — \($0)" } ?? ""))
            result.untrusted = true
            return result
        }
    }
}

// MARK: system.windows

public struct SystemWindowsTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "system.windows", name: "On-screen windows",
                     summary: "Lists on-screen windows front to back: owner application, bounds, layer and display. Window titles are included only when Screen Recording access is enabled; the output says whether they are.",
                     family: "system",
                     inputSchema: .object(["bundleID": .string("Only windows of this application."),
                                           "includeAllLayers": .boolean("Include menu bar, Dock and overlay layers (default false: normal windows only)."),
                                           "maxWindows": .integer("Maximum windows returned (default 200).", minimum: 1, maximum: 2000)]),
                     outputSchema: outputObject(["windows": .array(of: outputObject(["windowID": .integer(), "owner": .string(), "pid": .integer(), "bounds": .any, "layer": .integer()],
                                                                                    required: ["windowID", "owner", "pid", "bounds", "layer"])),
                                                 "titlesAvailable": .boolean(), "displays": .array(of: .any)], required: ["windows", "titlesAvailable"]),
                     sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 10, idempotent: true, outputIsUntrusted: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        if input.optionalString("bundleID") != nil { _ = try input.bundleID() }
        return ToolRequirements(capabilities: [], tier: .readOnly, summary: "List on-screen windows")
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let only = try input.optionalString("bundleID").map { _ in try input.bundleID().lowercased() }
        let allLayers = input.bool("includeAllLayers", default: false), limit = input.int("maxWindows", default: 200)
        let titles = CGPreflightScreenCaptureAccess()
        var bundleIDs: [pid_t: String] = [:]
        var windows: [JSONValue] = []
        var total = 0
        for w in WindowList.onScreen() where allLayers || w.layer == 0 {
            if bundleIDs[w.pid] == nil { bundleIDs[w.pid] = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier ?? "" }
            let id = bundleIDs[w.pid] ?? ""
            if let only, id.lowercased() != only { continue }
            total += 1
            guard windows.count < limit else { continue }
            var o: [String: JSONValue] = ["windowID": .int(Int(w.id)), "owner": .string(w.owner), "pid": .int(Int(w.pid)), "bounds": rectJSON(w.bounds), "layer": .int(w.layer)]
            if !id.isEmpty { o["bundleID"] = .string(id) }
            if let d = Displays.index(containing: w.bounds) { o["display"] = .int(d) }
            if titles, let t = w.title { o["title"] = .string(t) }
            windows.append(.object(o))
        }
        let displays = Displays.active().enumerated().map { i, id -> JSONValue in
            ["index": .int(i), "bounds": rectJSON(CGDisplayBounds(id)), "scale": .number(Displays.scale(id)), "main": .bool(CGDisplayIsMain(id) != 0)]
        }
        var result = ToolResult.success([
            "windows": .array(windows), "titlesAvailable": .bool(titles), "displays": .array(displays),
            "note": .string(titles ? "Window titles are included." : "Window titles are omitted: Screen Recording access is not enabled for this app."),
        ], summary: "\(total) window(s) on screen" + (titles ? "" : " (titles unavailable without Screen Recording access)"))
        result.truncated = total > windows.count
        result.untrusted = true
        return result
    }
}

// MARK: system.launchApp

public struct SystemLaunchAppTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "system.launchApp", name: "Launch an application",
                     summary: "Launches an application by bundle identifier or path (or brings it forward if it is running) and waits until it reports that it finished launching.",
                     family: "system",
                     inputSchema: .object(["bundleID": bundleIDSchema, "path": .string("Path of the application bundle, as an alternative to bundleID."),
                                           "activate": .boolean("Bring the application to the front (default true)."),
                                           "timeoutSeconds": .number("How long to wait for the launch to finish (default 30).")]),
                     outputSchema: outputObject(["bundleID": .string(), "pid": .integer(), "alreadyRunning": .boolean(), "finishedLaunching": .boolean()],
                                                required: ["bundleID", "alreadyRunning", "finishedLaunching"]),
                     sideEffect: .write, defaultTier: .consequential, defaultTimeoutSeconds: 90, supportsDryRun: true, idempotent: true)
    }

    func target(_ input: ToolInput, context: ToolExecutionContext) throws -> (bundleID: String, url: URL) {
        if let raw = input.optionalString("path"), !raw.isEmpty {
            let path = try PathResolver.canonical(raw, relativeTo: context.workingDirectory)
            guard path.hasSuffix(".app"), let id = AppResolver.bundleID(forAppAt: path) else { throw ToolError.invalidInput("\(path) is not an application bundle with a bundle identifier") }
            return (id, URL(fileURLWithPath: path))
        }
        guard input.optionalString("bundleID") != nil else { throw ToolError.invalidInput("bundleID or path is required") }
        let id = try input.bundleID()
        guard let url = AppResolver.url(forBundleID: id) else { throw ToolError.notFound("No installed application has the bundle identifier \(id)") }
        return (id, url)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let t = try target(input, context: context)
        return ToolRequirements(capabilities: [.appControl(bundleID: t.bundleID)], tier: .consequential,
                                summary: "Launch \(t.url.deletingPathExtension().lastPathComponent) (\(t.bundleID))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let t = try target(input, context: context)
        let name = t.url.deletingPathExtension().lastPathComponent
        let already = !AppResolver.running(t.bundleID).isEmpty
        if input.dryRun {
            return .simulated(["bundleID": .string(t.bundleID), "alreadyRunning": .bool(already), "finishedLaunching": .bool(already)],
                              summary: already ? "Would bring \(name) forward (already running)" : "Would launch \(name)")
        }
        let timeout = input.timeout(default: 30, context: context)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = input.bool("activate", default: true)
        configuration.addsToRecentItems = false
        let pid: pid_t
        do { pid = try await NSWorkspace.shared.openApplication(at: t.url, configuration: configuration).processIdentifier }
        catch { throw ToolError.io("macOS could not launch \(name): \(error.localizedDescription)") }
        // Observable postcondition: the application says it finished launching (a fresh lookup each time, no cached state).
        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while true {
            try Task.checkCancellation()
            if let app = AppResolver.running(t.bundleID).first(where: { $0.processIdentifier == pid }) ?? NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching {
                finished = true; break
            }
            if kill(pid, 0) != 0, errno == ESRCH {
                throw TypedFailure(code: "launch_failed", message: "\(name) exited before it finished launching.", retryable: true)
            }
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return .success(["bundleID": .string(t.bundleID), "pid": .int(Int(pid)), "name": .string(name), "alreadyRunning": .bool(already), "finishedLaunching": .bool(finished)],
                        summary: finished ? (already ? "\(name) was already running" : "Launched \(name)") : "\(name) was started but did not report a finished launch within \(Int(timeout)) s")
    }
}

// MARK: system.quitApp

public struct SystemQuitAppTool: ORIXTool {
    public init() {}
    public var manifest: ToolManifest {
        ToolManifest(identifier: "system.quitApp", name: "Quit an application",
                     summary: "Asks an application to quit the normal way (it may ask the user to save) and reports whether it did. Never force-quits.",
                     family: "system",
                     inputSchema: .object(["bundleID": bundleIDSchema, "timeoutSeconds": .number("How long to wait for the application to quit (default 10).")], required: ["bundleID"]),
                     outputSchema: outputObject(["bundleID": .string(), "wasRunning": .boolean(), "terminated": .boolean(), "refused": .boolean()],
                                                required: ["bundleID", "wasRunning", "terminated", "refused"]),
                     sideEffect: .write, defaultTier: .consequential, defaultTimeoutSeconds: 60, supportsDryRun: true, idempotent: true)
    }
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let id = try input.bundleID()
        if id.lowercased() == Bundle.main.bundleIdentifier?.lowercased() { throw ToolError.unsupported("ORIX OS Automation does not quit itself through a tool.") }
        return ToolRequirements(capabilities: [.appControl(bundleID: id)], tier: .consequential, summary: "Quit \(AppResolver.displayName(id)) (\(id))")
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let id = try input.bundleID()
        let name = AppResolver.displayName(id)
        let own = ProcessInfo.processInfo.processIdentifier
        let apps = AppResolver.running(id).filter { $0.processIdentifier != own }
        if input.dryRun {
            return .simulated(["bundleID": .string(id), "wasRunning": .bool(!apps.isEmpty), "terminated": false, "refused": false],
                              summary: apps.isEmpty ? "\(name) is not running; nothing would happen" : "Would ask \(name) to quit")
        }
        guard !apps.isEmpty else {
            return .success(["bundleID": .string(id), "wasRunning": false, "terminated": true, "refused": false], summary: "\(name) was not running")
        }
        let timeout = input.timeout(default: 10, context: context)
        let pids = apps.map(\.processIdentifier)
        let sent = apps.map { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        func alive() -> [pid_t] { pids.filter { kill($0, 0) == 0 || errno != ESRCH } }
        while !alive().isEmpty, Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let remaining = alive()
        let terminated = remaining.isEmpty
        var out: [String: JSONValue] = ["bundleID": .string(id), "wasRunning": true, "terminated": .bool(terminated), "refused": .bool(!terminated),
                                        "requestDelivered": .bool(sent.contains(true))]
        if !terminated {
            out["note"] = "The application is still running. It may be waiting for the user (unsaved changes) or it declined to quit. It was not forced."
            out["remainingPIDs"] = .array(remaining.map { .int(Int($0)) })
        }
        return .success(.object(out), summary: terminated ? "\(name) quit" : "\(name) did not quit within \(Int(timeout)) s (not forced)")
    }
}
