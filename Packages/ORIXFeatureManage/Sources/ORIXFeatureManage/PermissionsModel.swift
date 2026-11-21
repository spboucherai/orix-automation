// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/PermissionsModel.swift
// Description: View model of the permission centre: macOS permission status, grants with filtering and grouping, manual grant creation with validation, revocation, and the audit trail.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import Foundation
import Observation
import SwiftUI
import ORIXAppUI

/// The kinds of grant a person can add by hand. Secrets, clipboard and single-call scopes are not offered here.
enum ManualGrantKind: String, CaseIterable, Identifiable, Sendable {
    case fileRead, fileWrite, fileDelete, network, browser, appControl, appAutomation, accessibility, processExec, scriptRuntime
    var id: String { rawValue }

    enum Input: Sendable { case folder, host, app, program, runtime }

    var input: Input {
        switch self {
        case .fileRead, .fileWrite, .fileDelete: return .folder
        case .network, .browser: return .host
        case .appControl, .appAutomation, .accessibility: return .app
        case .processExec: return .program
        case .scriptRuntime: return .runtime
        }
    }

    var title: String {
        switch self {
        case .fileRead: return String(localized: "Read a folder")
        case .fileWrite: return String(localized: "Create or change files in a folder")
        case .fileDelete: return String(localized: "Move to the Trash in a folder")
        case .network: return String(localized: "Connect to a host")
        case .browser: return String(localized: "Open pages on a host")
        case .appControl: return String(localized: "Open or quit an app")
        case .appAutomation: return String(localized: "Send commands to an app")
        case .accessibility: return String(localized: "Operate an app's interface")
        case .processExec: return String(localized: "Run a program")
        case .scriptRuntime: return String(localized: "Run scripts in a language")
        }
    }

    static let runtimes = ["bash", "python", "swift", "javascript", "applescript", "jxa"]

    func capability(_ value: String) -> Capability {
        switch self {
        case .fileRead: return .fileRead(path: value)
        case .fileWrite: return .fileWrite(path: value)
        case .fileDelete: return .fileDelete(path: value)
        case .network: return .network(host: value)
        case .browser: return .browser(host: value)
        case .appControl: return .appControl(bundleID: value)
        case .appAutomation: return .appAutomation(bundleID: value)
        case .accessibility: return .accessibility(bundleID: value)
        case .processExec: return .processExec(executable: value)
        case .scriptRuntime: return .scriptRuntime(name: value)
        }
    }

    /// The lowest tier at which a grant of this kind is useful, and the default in the form.
    var defaultTier: ApprovalTier { WorkflowDocument.proposedTier(for: capability("x")) }
}

enum GrantState: Sendable { case active, revoked, expired }

enum GrantGroup: String, CaseIterable, Identifiable, Sendable {
    case persistent, workflow, run, once
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .persistent: return "Until revoked"
        case .workflow: return "For one workflow"
        case .run: return "For one run"
        case .once: return "For one call"
        }
    }
    var explanation: String {
        switch self {
        case .persistent: return String(localized: "Valid for every run until you revoke them.")
        case .workflow: return String(localized: "Declared by a workflow and accepted by you; valid for that workflow only.")
        case .run: return String(localized: "Given when a run started or approved during it; they end with the run.")
        case .once: return String(localized: "Approved for a single tool call and consumed by it.")
        }
    }
    static func of(_ scope: GrantScope) -> GrantGroup {
        switch scope {
        case .persistent: return .persistent
        case .workflow: return .workflow
        case .run: return .run
        case .once: return .once
        }
    }
}

struct GrantRefusal: Error, LocalizedError, Sendable, Hashable {
    let reason: String
    var errorDescription: String? { reason }
}

@MainActor
@Observable
final class PermissionsModel {
    let services: ORIXServices
    private(set) var snapshot: [MacPermission: PermissionStatus] = [:]
    private(set) var toolsByPermission: [MacPermission: [String]] = [:]
    private(set) var grants: [PermissionGrant] = []
    private(set) var workflowNames: [String: String] = [:]
    private(set) var audit: [AuditEntry] = []
    private(set) var requesting: MacPermission?
    private(set) var loaded = false
    var activeOnly = true
    var search = ""

    init(services: ORIXServices) { self.services = services }

    func reload() async {
        await refreshStatus()
        grants = await services.policy.grants()
        workflowNames = Dictionary(uniqueKeysWithValues: await services.workflows.list().map { ($0.id, $0.name) })
        var tools: [MacPermission: [String]] = [:]
        for m in await services.registry.manifests() { for p in m.macPermissions { tools[p, default: []].append(m.identifier) } }
        toolsByPermission = tools.mapValues { $0.sorted() }
        audit = Array(await services.audit.entries(limit: 400).reversed()).filter(ManageText.isConsequential)
        loaded = true
    }

    /// Reads the live status off the main thread (the notification probe can wait on the system).
    func refreshStatus() async {
        snapshot = await Task.detached { MacPermissions.snapshot() }.value
    }

    /// True when macOS has a standard prompt this app can trigger for the permission.
    static func canRequest(_ p: MacPermission) -> Bool {
        switch p {
        case .accessibility, .screenRecording: return true
        case .notifications: return MacPermissions.hasAppBundle
        case .fullDiskAccess, .appleEvents: return false
        }
    }

    /// Shows the system prompt where there is one. The result is whatever macOS reports afterwards.
    func request(_ p: MacPermission) async {
        requesting = p
        _ = await MacPermissions.request(p)
        await refreshStatus()
        requesting = nil
    }

    static func state(_ g: PermissionGrant, now: Date = Date()) -> GrantState {
        if g.revokedAt != nil { return .revoked }
        if let e = g.expiresAt, e <= now { return .expired }
        return .active
    }

    func scopeDetail(_ g: PermissionGrant) -> String? {
        switch g.scope {
        case .workflow(let id): return workflowNames[id] ?? id
        case .run(let id): return String(localized: "run \(String(id.prefix(8)))")
        case .once(let id): return String(localized: "call \(String(id.prefix(8)))")
        case .persistent: return nil
        }
    }

    /// Grants after the active-only filter and the search, newest first.
    var visible: [PermissionGrant] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return grants.filter { g in
            if activeOnly && Self.state(g) != .active { return false }
            guard !q.isEmpty else { return true }
            return g.capability.displayString.lowercased().contains(q) || g.capability.humanDescription.lowercased().contains(q)
                || g.source.lowercased().contains(q) || g.note.lowercased().contains(q) || (scopeDetail(g)?.lowercased().contains(q) ?? false)
        }
    }

    func visible(in group: GrantGroup) -> [PermissionGrant] { visible.filter { GrantGroup.of($0.scope) == group } }

    var activeCount: Int { grants.filter { Self.state($0) == .active }.count }

    // MARK: Changes

    /// Checks and normalises the value of a manual grant. Throws `GrantRefusal` with a reason a person can act on.
    static func validated(kind: ManualGrantKind, value raw: String) throws -> Capability {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw GrantRefusal(reason: String(localized: "Choose what the grant applies to.")) }
        switch kind.input {
        case .folder:
            let path: String
            do { path = try PathResolver.canonical(value, relativeTo: URL(fileURLWithPath: NSHomeDirectory())) }
            catch { throw GrantRefusal(reason: String(localized: "That is not a usable folder path.")) }
            guard !PathResolver.isProtected(path) else {
                throw GrantRefusal(reason: String(localized: "\(PathResolver.display(path)) is a protected location (credentials or system security data). No grant can cover it."))
            }
            guard path != "/" else { throw GrantRefusal(reason: String(localized: "The whole disk cannot be granted. Choose a folder.")) }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                throw GrantRefusal(reason: String(localized: "\(PathResolver.display(path)) is not an existing folder."))
            }
            return kind.capability(path)
        case .host:
            let host = value.lowercased()
            guard host != "*", host.range(of: #"^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil else {
                throw GrantRefusal(reason: String(localized: "Enter a host name such as api.example.com, or *.example.com for its subdomains. A bare * is not accepted."))
            }
            return kind.capability(host)
        case .app:
            guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
                throw GrantRefusal(reason: String(localized: "Choose an application, or enter its bundle identifier (for example com.apple.finder)."))
            }
            return kind.capability(value)
        case .program:
            guard !value.contains(" "), value != "sudo", !value.hasSuffix("/sudo") else {
                throw GrantRefusal(reason: String(localized: "Enter one program name or path, without arguments. sudo is never allowed."))
            }
            return kind.capability(value)
        case .runtime:
            guard ManualGrantKind.runtimes.contains(value) else { throw GrantRefusal(reason: String(localized: "Choose one of the supported script languages.")) }
            return kind.capability(value)
        }
    }

    /// Adds a persistent grant made by the user. Tier is capped at consequential: tier 3 always needs a fresh approval.
    @discardableResult
    func addPersistentGrant(kind: ManualGrantKind, value: String, tier: ApprovalTier, note: String) async throws -> PermissionGrant {
        let capability = try Self.validated(kind: kind, value: value)
        let grant = PermissionGrant(capability: capability, scope: .persistent, maxTier: min(tier, .consequential), source: "user",
                                    note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        guard await services.policy.add(grant) else {
            throw GrantRefusal(reason: String(localized: "The policy engine refused this grant: it targets a protected location."))
        }
        await reload()
        return grant
    }

    func revoke(_ id: String) async { await services.policy.revoke(id: id); await reload() }
    func revokeAll() async { await services.runs.revokeAllGrants(); await reload() }
}

struct RunningAppInfo: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    /// Regular applications that are running now, without this app, sorted by name.
    @MainActor
    static func current() -> [RunningAppInfo] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app -> RunningAppInfo? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
            return RunningAppInfo(bundleID: id, name: app.localizedName ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @MainActor
    static func icon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
