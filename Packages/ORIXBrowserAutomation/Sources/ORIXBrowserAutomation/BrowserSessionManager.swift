// ORIX OS Automation
// File: Packages/ORIXBrowserAutomation/Sources/ORIXBrowserAutomation/BrowserSessionManager.swift
// Description: Owns the browser sessions, one per run, and keeps a synchronously readable index of each session's current URL for the tools' pure requirements.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import WebKit

/// Sessions keyed by run id. A session is created by `browser.open` (or `browser.download`) and lives until
/// `browser.close`, `close(runID:)` or `closeAll()`.
public actor BrowserSessionManager {
    public nonisolated let configuration: BrowserConfiguration
    private var sessions: [String: BrowserSession] = [:]
    private nonisolated let index = URLIndex()

    public init(configuration: BrowserConfiguration = BrowserConfiguration()) {
        self.configuration = configuration
    }

    /// The session of a run, when one is open.
    public func session(runID: String) -> BrowserSession? { sessions[runID] }

    /// The session of a run, created when there is none.
    public func openSession(runID: String) async -> BrowserSession {
        if let existing = sessions[runID] { return existing }
        let configuration = self.configuration
        let index = self.index
        let created = await MainActor.run { () -> BrowserSession in
            let s = BrowserSession(runID: runID, configuration: configuration)
            s.onURLChange = { url in index.set(runID, url) }
            return s
        }
        // Another call may have created one while this one was on the main actor.
        if let raced = sessions[runID] {
            await created.close()
            return raced
        }
        sessions[runID] = created
        return created
    }

    /// Closes the session of a run. Returns false when there was none.
    @discardableResult
    public func close(runID: String) async -> Bool {
        guard let session = sessions.removeValue(forKey: runID) else { return false }
        await session.close()
        index.set(runID, nil)
        return true
    }

    /// Closes every session (emergency stop, app termination).
    public func closeAll() async {
        let all = sessions
        sessions = [:]
        for (runID, session) in all {
            await session.close()
            index.set(runID, nil)
        }
    }

    /// Run ids with an open session.
    public var activeRunIDs: [String] { sessions.keys.sorted() }

    /// The web view of a run, for the app to show it in a window of its own.
    public func view(for runID: String) async -> WKWebView? {
        guard let session = sessions[runID] else { return nil }
        return session.webView
    }

    /// The URL currently shown by a run's session, readable synchronously (used by the tools' `requirements`).
    public nonisolated func currentURL(runID: String) -> URL? {
        index.get(runID).flatMap { URL(string: $0) }
    }

    /// The host of the page currently shown by a run's session.
    public nonisolated func currentHost(runID: String) -> String? {
        currentURL(runID: runID).flatMap { BrowserURLPolicy.host(of: $0) }
    }
}

final class URLIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String: String] = [:]
    func set(_ runID: String, _ url: String?) { lock.withLock { urls[runID] = url } }
    func get(_ runID: String) -> String? { lock.withLock { urls[runID] } }
}
