// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/InputRecorder.swift
// Description      : Watch & Learn recorder: explicit start/pause/stop,
//                    semantic events only (app activations, Accessibility
//                    notifications of chosen apps), never keystrokes, never
//                    secure-field values.
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
import ApplicationServices
import Foundation
import ORIXCore

/// One semantic step observed while recording. Coordinates and keystrokes are never part of it.
public struct RecordedAction: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case recordingStarted, recordingPaused, recordingResumed, recordingStopped
        /// Something the recorder could not observe, and why.
        case limitation
        case appActivated, appLaunched, appTerminated
        case focusChanged, valueChanged, selectionChanged, menuItemSelected, windowCreated, windowFocused
    }
    public var id: String
    public var sequence: Int
    public var timestamp: Date
    public var kind: Kind
    public var bundleID: String?
    public var appName: String?
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var identifier: String?
    /// Semantic description, for example `typed text of length 12 in field "Subject"`. Never the text itself unless opted in.
    public var summary: String
    /// The new value: non-text values (checkbox, slider), or text only for fields the caller opted in. Never for secure fields.
    public var value: JSONValue?
    /// How many raw notifications were merged into this action (typing produces one per keystroke).
    public var coalesced: Int

    public init(id: String = UUID().uuidString, sequence: Int = 0, timestamp: Date = Date(), kind: Kind, bundleID: String? = nil, appName: String? = nil,
                role: String? = nil, subrole: String? = nil, title: String? = nil, identifier: String? = nil, summary: String, value: JSONValue? = nil, coalesced: Int = 1) {
        self.id = id; self.sequence = sequence; self.timestamp = timestamp; self.kind = kind; self.bundleID = bundleID; self.appName = appName
        self.role = role; self.subrole = subrole; self.title = title; self.identifier = identifier; self.summary = summary; self.value = value; self.coalesced = coalesced
    }
}

/// Opt-in recorder for the Watch & Learn milestone. Off until `start`, limited to the bundle identifiers given to `start`.
/// It never installs an event tap: what it sees are NSWorkspace notifications and, when Accessibility is trusted,
/// AX notifications from the chosen applications.
@MainActor
public final class InputRecorder {
    public enum State: String, Sendable { case idle, recording, paused, stopped }

    public struct Options: Sendable {
        /// Titles or accessibility identifiers of text fields whose text may be recorded. Empty: text is only ever described by its length.
        public var captureTextForFields: Set<String>
        public var maxActions: Int
        public init(captureTextForFields: Set<String> = [], maxActions: Int = 5000) {
            self.captureTextForFields = captureTextForFields; self.maxActions = maxActions
        }
    }

    public private(set) var state: State = .idle
    public private(set) var actions: [RecordedAction] = []
    public private(set) var targetBundleIDs: Set<String> = []
    /// What this recording cannot observe (for example: Accessibility not enabled).
    public private(set) var limitations: [String] = []
    /// Called on the main actor for every new or updated action.
    public var onAction: ((RecordedAction) -> Void)?

    private let options: Options
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObservers: [pid_t: (observer: AXObserver, element: AXUIElement, context: Unmanaged<CallbackContext>, bundleID: String, name: String)] = [:]
    private var lastValueElement: AXUIElement?

    static let axNotifications: [String] = [
        kAXFocusedUIElementChangedNotification, kAXValueChangedNotification, kAXMenuItemSelectedNotification,
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification,
    ]

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Starts recording the given applications. Returns the limitations of this recording (empty when everything is observable).
    @discardableResult
    public func start(targetBundleIDs: [String]) throws -> [String] {
        guard state == .idle || state == .stopped else { throw ToolError.invalidInput("The recorder is already \(state.rawValue)") }
        let targets = Set(try targetBundleIDs.map { try AppResolver.validatedBundleID($0) })
        guard !targets.isEmpty else { throw ToolError.invalidInput("Choose at least one application to record") }
        self.targetBundleIDs = targets
        actions = []
        limitations = []
        lastValueElement = nil
        state = .recording
        append(RecordedAction(kind: .recordingStarted, summary: "Recording started for \(targets.sorted().joined(separator: ", "))"))

        let center = NSWorkspace.shared.notificationCenter
        let watched: [(NSNotification.Name, RecordedAction.Kind)] = [
            (NSWorkspace.didActivateApplicationNotification, .appActivated),
            (NSWorkspace.didLaunchApplicationNotification, .appLaunched),
            (NSWorkspace.didTerminateApplicationNotification, .appTerminated),
        ]
        for (name, kind) in watched {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier, appName = app?.localizedName, pid = app?.processIdentifier
                MainActor.assumeIsolated { self?.workspaceEvent(kind, bundleID: bundleID, name: appName, pid: pid) }
            })
        }

        if AXIsProcessTrusted() {
            for id in targets.sorted() {
                let running = AppResolver.running(id)
                if running.isEmpty { note("\(id) is not running: its interface events are recorded once it launches.", limitation: false) }
                for app in running { attach(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id) }
            }
            limit("Button clicks have no Accessibility notification: they are visible only through their effects (focus, value, selection, menu and window events).")
        } else {
            limit("Accessibility is not enabled for this app: only application activations, launches and quits are recorded. Focus, value, menu and window events inside the applications are not observable.")
        }
        limit("Keystrokes and pointer positions are never recorded; text is described by its length unless a field was opted in, and secure fields are never described.")
        return limitations
    }

    public func pause() {
        guard state == .recording else { return }
        append(RecordedAction(kind: .recordingPaused, summary: "Recording paused"))
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        state = .recording
        lastValueElement = nil
        append(RecordedAction(kind: .recordingResumed, summary: "Recording resumed"))
    }

    /// Stops, removes every observer and returns the ordered actions.
    @discardableResult
    public func stop() -> [RecordedAction] {
        guard state == .recording || state == .paused else { return actions }
        state = .recording
        append(RecordedAction(kind: .recordingStopped, summary: "Recording stopped"), force: true)
        state = .stopped
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObservers = []
        for pid in Array(axObservers.keys) { detach(pid: pid) }
        lastValueElement = nil
        return actions
    }

    /// The recording as JSON (ISO 8601 dates), ready to hand to the workflow inference step.
    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(actions)
    }

    // MARK: Semantics (pure)

    /// Describes a value change without leaking content. Text is reduced to its length unless `captureText` is true;
    /// a secure field yields no value and no length.
    public nonisolated static func describeValueChange(role: String, subrole: String?, title: String?, value: JSONValue?, captureText: Bool) -> (summary: String, value: JSONValue?) {
        let field = (title?.isEmpty == false) ? " \"\(title!)\"" : ""
        if AX.isSecure(role: role, subrole: subrole) { return ("edited secure field\(field) (content and length not recorded)", nil) }
        switch value {
        case .string(let s):
            if captureText { return ("typed \"\(s.prefix(200))\" in field\(field)", .string(String(s.prefix(2000)))) }
            return ("typed text of length \(s.count) in field\(field)", nil)
        case .bool(let b): return ("set \(role)\(field) to \(b)", value)
        case .int, .number: return ("set \(role)\(field) to \(value!.displayString)", value)
        default: return ("changed the value of \(role)\(field)", nil)
        }
    }

    // MARK: Internals

    private func limit(_ text: String) { note(text, limitation: true) }

    private func note(_ text: String, limitation: Bool) {
        if limitation { limitations.append(text) }
        append(RecordedAction(kind: .limitation, summary: text))
    }

    private func append(_ action: RecordedAction, force: Bool = false) {
        guard state == .recording else { return }
        guard force || actions.count < options.maxActions else {
            if actions.last?.kind != .limitation || actions.last?.summary.hasPrefix("The recording reached") != true {
                var last = RecordedAction(kind: .limitation, summary: "The recording reached its limit of \(options.maxActions) actions; later events are not recorded.")
                last.sequence = actions.count + 1
                actions.append(last)
                limitations.append(last.summary)
            }
            return
        }
        var a = action
        a.sequence = actions.count + 1
        actions.append(a)
        onAction?(a)
    }

    private func workspaceEvent(_ kind: RecordedAction.Kind, bundleID: String?, name: String?, pid: pid_t?) {
        guard let bundleID, let match = targetBundleIDs.first(where: { $0.lowercased() == bundleID.lowercased() }) else { return }
        // Observers follow the application's life even while paused, so resuming needs no re-scan.
        if let pid, state == .recording || state == .paused {
            if kind == .appLaunched, AXIsProcessTrusted() { attach(pid: pid, bundleID: match, name: name ?? match) }
            if kind == .appTerminated { detach(pid: pid) }
        }
        lastValueElement = nil
        let verb = kind == .appActivated ? "Switched to" : (kind == .appLaunched ? "Launched" : "Quit")
        append(RecordedAction(kind: kind, bundleID: match, appName: name, summary: "\(verb) \(name ?? match)"))
    }

    private final class CallbackContext {
        weak var recorder: InputRecorder?
        let pid: pid_t
        init(recorder: InputRecorder, pid: pid_t) { self.recorder = recorder; self.pid = pid }
    }

    private func attach(pid: pid_t, bundleID: String, name: String) {
        guard axObservers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let context = Unmanaged<CallbackContext>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            // The observer's run loop source is on the main run loop: this runs on the main thread.
            MainActor.assumeIsolated { context.recorder?.accessibilityEvent(name, element: element, pid: context.pid) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            limit("Could not observe the interface of \(name) (\(bundleID)).")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 2)
        let context = Unmanaged.passRetained(CallbackContext(recorder: self, pid: pid))
        var registered = 0
        for notification in Self.axNotifications where AXObserverAddNotification(observer, element, notification as CFString, context.toOpaque()) == .success {
            registered += 1
        }
        guard registered > 0 else {
            context.release()
            limit("\(name) (\(bundleID)) does not publish Accessibility notifications: only its activation is recorded.")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObservers[pid] = (observer, element, context, bundleID, name)
    }

    private func detach(pid: pid_t) {
        guard let entry = axObservers.removeValue(forKey: pid) else { return }
        for notification in Self.axNotifications { AXObserverRemoveNotification(entry.observer, entry.element, notification as CFString) }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
        entry.context.release()
    }

    private func accessibilityEvent(_ notification: String, element: AXUIElement, pid: pid_t) {
        guard state == .recording, let entry = axObservers[pid] else { return }
        // Role first: nothing else is read from a secure field.
        let role = AX.role(element), subrole = AX.string(element, kAXSubroleAttribute)
        let secure = AX.isSecure(role: role, subrole: subrole)
        let title = AX.string(element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? AX.string(element, kAXDescriptionAttribute)
        let identifier = AX.string(element, kAXIdentifierAttribute)
        var action = RecordedAction(kind: .focusChanged, bundleID: entry.bundleID, appName: entry.name, role: role, subrole: subrole, title: title, identifier: identifier, summary: "")
        let label = (title?.isEmpty == false) ? " \"\(title!)\"" : ""

        switch notification {
        case kAXFocusedUIElementChangedNotification:
            action.kind = .focusChanged
            action.summary = "focused \(secure ? "secure field" : role)\(label)"
        case kAXValueChangedNotification:
            let optedIn = [title, identifier].compactMap { $0 }.contains { options.captureTextForFields.contains($0) }
            let value = secure ? nil : AX.value(element, secure: false, maxLength: 2000)
            let described = Self.describeValueChange(role: role, subrole: subrole, title: title, value: value, captureText: optedIn)
            action.kind = .valueChanged
            action.summary = described.summary
            action.value = described.value
            // Typing fires once per keystroke: keep one action per edited element.
            if let last = actions.last, last.kind == .valueChanged, let previous = lastValueElement, CFEqual(previous, element) {
                action.id = last.id; action.sequence = last.sequence; action.coalesced = last.coalesced + 1
                actions[actions.count - 1] = action
                onAction?(action)
                return
            }
            append(action)
            lastValueElement = element
            return
        case kAXMenuItemSelectedNotification:
            action.kind = .menuItemSelected
            action.summary = "chose menu item\(label)"
        case kAXWindowCreatedNotification:
            action.kind = .windowCreated
            action.summary = "window\(label) opened"
        case kAXFocusedWindowChangedNotification:
            action.kind = .windowFocused
            action.summary = "window\(label) came to the front"
        case kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification:
            action.kind = .selectionChanged
            action.summary = "selection changed in \(role)\(label)"
        default:
            return
        }
        lastValueElement = nil
        append(action)
    }
}
