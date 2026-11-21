// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXBrowserAutomation/Sources/ORIXBrowserAutomation/BrowserSession.swift
// Description      : One ORIX-owned WKWebView in an offscreen window:
//                    navigation policy enforcement, dialog handling, script
//                    evaluation, snapshots and explicit downloads.
// Module           : ORIXBrowserAutomation
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
import CryptoKit
import Foundation
import ORIXCore
import WebKit

public struct BrowserConfiguration: Sendable, Hashable {
    /// Viewport in points. Screenshots are rendered at this size, one pixel per point.
    public var viewportWidth: Int
    public var viewportHeight: Int
    /// False (default): a fresh non-persistent data store per session, so no cookie, cache or login survives the
    /// session and nothing is shared with Safari or with other sessions.
    public var persistentDataStore: Bool
    /// Appended to WebKit's user agent.
    public var applicationName: String
    /// How long navigation must stay quiet after a load or a click before the page is considered settled.
    public var settleQuietSeconds: Double

    public init(viewportWidth: Int = 1280, viewportHeight: Int = 800, persistentDataStore: Bool = false,
                applicationName: String = "ORIXAutomation/1.0", settleQuietSeconds: Double = 0.2) {
        self.viewportWidth = viewportWidth; self.viewportHeight = viewportHeight; self.persistentDataStore = persistentDataStore
        self.applicationName = applicationName; self.settleQuietSeconds = settleQuietSeconds
    }
}

/// A JavaScript dialog the page tried to show. Dialogs never block: alerts are dismissed, confirms answer "cancel",
/// prompts answer nothing, file choosers choose nothing.
public struct BrowserDialog: Codable, Sendable, Hashable {
    /// `alert`, `confirm`, `prompt` or `fileChooser`.
    public var kind: String
    public var message: String
    /// What ORIX answered: `dismissed`, `canceled`.
    public var response: String
}

/// What happened to navigation during one tool operation.
public struct NavigationOutcome: Sendable, Hashable {
    /// A main-frame load finished during the operation.
    public var navigated: Bool
    public var url: String
    public var title: String
    /// HTTP status of the last main-frame response, when one was received.
    public var httpStatus: Int?
    public var blocked: NavigationBlock?
    /// Load error (connection refused, DNS…), when the load failed.
    public var error: String?
    public var timedOut: Bool
}

/// The file a finished download produced.
public struct DownloadedFile: Sendable, Hashable {
    public var path: String
    public var bytes: Int
    public var sha256: String
    public var mimeType: String?
    public var suggestedFilename: String
    public var httpStatus: Int?
    public var finalURL: String
}

/// One browser tab owned by ORIX for one run.
///
/// The web view lives in a borderless window that is never ordered on screen, so layout, scripts and snapshots work
/// without showing anything. `webView` can be moved into a visible window by the app.
///
/// Navigation policy: every main-frame navigation (typed URL, server redirect, script, link, form post, new-window
/// request) goes through `decidePolicyFor` and is cancelled unless its host is in `allowedHosts` and its scheme is
/// https (or http on loopback). Known limits: subresources and subframes are not host-filtered (a page may still load
/// images, scripts or iframes from other hosts); between two tool calls the allowlist of the last call stays in force;
/// while the window is offscreen pages see `document.visibilityState == "hidden"`.
@MainActor
public final class BrowserSession: NSObject {
    public let runID: String
    public let configuration: BrowserConfiguration
    public let webView: WKWebView
    private let window: NSWindow
    private let world = WKContentWorld.world(name: "ai.orix.automation")

    /// Host patterns main-frame navigations are currently allowed to reach.
    public private(set) var allowedHosts: [String] = []
    private var dialogs: [BrowserDialog] = []
    private var blocks: [NavigationBlock] = []
    private var finishedCount = 0
    private var failedCount = 0
    private var provisional = false
    private var lastActivity = Date()
    private var lastHTTPStatus: Int?
    private var lastLoadError: String?
    private var closed = false
    private var waiters: [UUID: (continuation: CheckedContinuation<Void, Never>, timer: Task<Void, Never>)] = [:]
    private var lockHeld = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeDownloads: [UUID: DownloadFetcher] = [:]
    var onURLChange: (@Sendable (String?) -> Void)?

    public init(runID: String, configuration: BrowserConfiguration = BrowserConfiguration()) {
        self.runID = runID
        self.configuration = configuration
        // AppKit needs an application object before a window can exist; in the app this is already the case.
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = configuration.persistentDataStore ? .default() : .nonPersistent()
        config.applicationNameForUserAgent = configuration.applicationName
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.suppressesIncrementalRendering = false
        let frame = NSRect(x: 0, y: 0, width: configuration.viewportWidth, height: configuration.viewportHeight)
        webView = WKWebView(frame: frame, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.allowsMagnification = false
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.hasShadow = false
        super.init()
        window.contentView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    // MARK: State

    public var currentURL: URL? { webView.url }
    public var title: String { webView.title ?? "" }
    public var isClosed: Bool { closed }

    /// The host of the current page, when it has one.
    public var currentHost: String? { webView.url.flatMap { BrowserURLPolicy.host(of: $0) } }

    /// Replaces the allowlist used by the navigation delegate. Called by each tool before it acts.
    public func setAllowedHosts(_ hosts: [String]) {
        var seen = Set<String>()
        allowedHosts = hosts.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Dialogs shown since the last call, oldest first.
    public func takeDialogs() -> [BrowserDialog] {
        let d = dialogs
        dialogs = []
        return d
    }

    /// Serialises tool operations on this session (different tools may target the same page concurrently).
    public func withExclusiveAccess<T: Sendable>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        if lockHeld {
            await withCheckedContinuation { lockWaiters.append($0) }
        } else {
            lockHeld = true
        }
        defer {
            if lockWaiters.isEmpty { lockHeld = false } else { lockWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    /// Stops everything and releases the web view's content. The session cannot be used afterwards.
    public func close() {
        guard !closed else { return }
        closed = true
        webView.stopLoading()
        for fetcher in activeDownloads.values { fetcher.cancel() }
        activeDownloads = [:]
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        window.contentView = nil
        window.close()
        notify()
        onURLChange?(nil)
    }

    // MARK: Event plumbing

    private func notify() {
        let all = waiters
        waiters = [:]
        for (_, w) in all {
            w.timer.cancel()
            w.continuation.resume()
        }
    }

    /// Suspends until the next navigation event or `timeout`, whichever comes first.
    private func nextEvent(timeout: Double) async {
        let id = UUID()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let timer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000))
                if let w = self?.waiters.removeValue(forKey: id) { w.continuation.resume() }
            }
            waiters[id] = (c, timer)
        }
    }

    private func publishURL() { onURLChange?(webView.url?.absoluteString) }

    private func record(_ block: NavigationBlock) {
        blocks.append(block)
        lastActivity = Date()
        notify()
    }

    // MARK: Navigation

    struct Marker {
        var finished: Int
        var failed: Int
        var blocks: Int
        var url: String?
        var start: Date
    }

    func marker() -> Marker {
        lastLoadError = nil
        return Marker(finished: finishedCount, failed: failedCount, blocks: blocks.count, url: webView.url?.absoluteString, start: Date())
    }

    /// Loads `url` and waits until the page has settled. The caller has validated the URL and set the allowlist.
    public func load(_ url: URL, timeoutSeconds: Double) async throws -> NavigationOutcome {
        let m = marker()
        lastHTTPStatus = nil
        webView.load(URLRequest(url: url))
        return try await settle(since: m, requireActivity: true, timeoutSeconds: timeoutSeconds)
    }

    /// Waits until navigation is quiet: no provisional load, and nothing new for `settleQuietSeconds`. Used after a load
    /// and after a click, where a navigation may or may not follow. With `requireActivity`, a load must have finished,
    /// failed or been blocked first.
    func settle(since m: Marker, requireActivity: Bool, timeoutSeconds: Double) async throws -> NavigationOutcome {
        let deadline = m.start.addingTimeInterval(timeoutSeconds)
        lastActivity = max(lastActivity, m.start)
        while true {
            if closed { throw ToolError.canceled }
            if Task.isCancelled {
                webView.stopLoading()
                throw ToolError.canceled
            }
            if blocks.count > m.blocks { return outcome(since: m, blocked: blocks.last) }
            let now = Date()
            let active = finishedCount > m.finished || failedCount > m.failed
            if !provisional && !webView.isLoading && (active || !requireActivity) {
                let quietFor = now.timeIntervalSince(lastActivity)
                if quietFor >= configuration.settleQuietSeconds { return outcome(since: m, blocked: nil) }
                await nextEvent(timeout: min(configuration.settleQuietSeconds - quietFor, deadline.timeIntervalSince(now)))
            } else {
                if now >= deadline {
                    webView.stopLoading()
                    var o = outcome(since: m, blocked: nil)
                    o.timedOut = true
                    return o
                }
                await nextEvent(timeout: min(0.25, deadline.timeIntervalSince(now)))
            }
            if Date() >= deadline, provisional || webView.isLoading {
                webView.stopLoading()
                var o = outcome(since: m, blocked: nil)
                o.timedOut = true
                return o
            }
        }
    }

    private func outcome(since m: Marker, blocked: NavigationBlock?) -> NavigationOutcome {
        publishURL()
        let navigated = finishedCount > m.finished || webView.url?.absoluteString != m.url
        let failed = failedCount > m.failed && finishedCount == m.finished
        return NavigationOutcome(navigated: navigated, url: webView.url?.absoluteString ?? "", title: title,
                                 httpStatus: navigated || failed ? lastHTTPStatus : nil, blocked: blocked,
                                 error: failed ? lastLoadError : nil, timedOut: false)
    }

    // MARK: Scripts

    /// Runs one of the `PageScripts` bodies in ORIX's content world and parses its JSON result.
    func evaluate(_ body: String, arguments: [String: Any]) async throws -> JSONValue {
        guard !closed else { throw ToolError.canceled }
        do {
            let result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
            guard let text = result as? String else { return .null }
            return try JSONValue.parse(text)
        } catch let error as ToolError {
            throw error
        } catch {
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            throw PageScriptError(underlying: detail ?? error.localizedDescription)
        }
    }

    /// A script could not complete, usually because the page navigated away while it ran.
    struct PageScriptError: Error { let underlying: String }

    // MARK: Snapshot

    /// Renders the visible viewport to PNG at one pixel per point.
    public func snapshotPNG() async throws -> (data: Data, width: Int, height: Int) {
        guard !closed else { throw ToolError.canceled }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: NSImage
        do { image = try await webView.takeSnapshot(configuration: config) } catch {
            throw ToolError.io("The page could not be rendered: \(error.localizedDescription)")
        }
        let width = configuration.viewportWidth, height = configuration.viewportHeight
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw ToolError.internalError("Could not create a bitmap for the screenshot.")
        }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ToolError.internalError("Could not encode the screenshot as PNG.")
        }
        return (data, width, height)
    }

    // MARK: Download

    /// Downloads `url` into `destination` (which must not exist) with the session's cookies and user agent.
    ///
    /// The transfer runs on a private, ephemeral `URLSession` rather than `WKDownload`: WebKit follows a download's
    /// redirects without consulting the client, whereas here every redirect is checked against the allowlist **before**
    /// the next request is sent, and the size cap is enforced while the bytes arrive. Cookies are copied from the web
    /// view's store for the duration of the transfer; cookies set by the download's responses are not copied back.
    public func download(_ url: URL, to destination: URL, maxBytes: Int, timeoutSeconds: Double) async throws -> DownloadedFile {
        guard !closed else { throw ToolError.canceled }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let userAgent = (try? await webView.callAsyncJavaScript("return navigator.userAgent;", arguments: [:], in: nil, contentWorld: world)) as? String
        let fetcher = DownloadFetcher(destination: destination, maxBytes: maxBytes, allowedHosts: allowedHosts, cookies: cookies,
                                      userAgent: userAgent, timeoutSeconds: timeoutSeconds)
        let id = UUID()
        activeDownloads[id] = fetcher
        defer { activeDownloads[id] = nil }
        return try await fetcher.run(url)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Navigation delegate

extension BrowserSession: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        // A nil target frame is a new-window request: it is treated as a main-frame navigation of this view.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let scheme = url.scheme?.lowercased() ?? ""
        if navigationAction.shouldPerformDownload {
            if isMainFrame {
                record(.init(reason: "download_refused", url: url.absoluteString, host: BrowserURLPolicy.host(of: url) ?? "",
                             message: "The page tried to start a download; downloads only happen through browser.download."))
            }
            return .cancel
        }
        if !isMainFrame {
            // Subframes are not host-filtered (documented limitation), but never load local files.
            return ["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
        }
        if scheme == "about" { return .allow }
        switch BrowserURLPolicy.check(url, allowedHosts: allowedHosts) {
        case .success:
            lastActivity = Date()
            return .allow
        case .failure(let block):
            record(block)
            return .cancel
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame else { return .allow }
        let http = navigationResponse.response as? HTTPURLResponse
        lastHTTPStatus = http?.statusCode
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            let url = navigationResponse.response.url
            record(.init(reason: "download_refused", url: url?.absoluteString ?? "", host: url.flatMap { BrowserURLPolicy.host(of: $0) } ?? "",
                         message: "The server answered with a file to download, not a page; downloads only happen through browser.download."))
            return .cancel
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        provisional = true
        lastActivity = Date()
        notify()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        lastActivity = Date()
        publishURL()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        provisional = false
        finishedCount += 1
        lastActivity = Date()
        publishURL()
        notify()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: any Error) {
        provisional = false
        let ns = error as NSError
        // 102 = "frame load interrupted" (our own policy cancel); -999 = cancelled by a newer navigation or stopLoading.
        let ours = (ns.domain == "WebKitErrorDomain" && ns.code == 102) || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
        if !ours {
            failedCount += 1
            lastLoadError = ns.localizedDescription
        }
        lastActivity = Date()
        notify()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        provisional = false
        failedCount += 1
        lastLoadError = "The web content process ended unexpectedly."
        notify()
    }
}

// MARK: - UI delegate

extension BrowserSession: WKUIDelegate {
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        // No second window: the request is loaded in this view and goes through the navigation policy like any other.
        if navigationAction.targetFrame == nil, navigationAction.request.url != nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        dialogs.append(BrowserDialog(kind: "alert", message: String(message.prefix(2000)), response: "dismissed"))
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        dialogs.append(BrowserDialog(kind: "confirm", message: String(message.prefix(2000)), response: "canceled"))
        return false
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                        initiatedByFrame frame: WKFrameInfo) async -> String? {
        dialogs.append(BrowserDialog(kind: "prompt", message: String(prompt.prefix(2000)), response: "canceled"))
        return nil
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        dialogs.append(BrowserDialog(kind: "fileChooser", message: "The page asked to choose a file.", response: "canceled"))
        return nil
    }

    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo,
                        type: WKMediaCaptureType) async -> WKPermissionDecision {
        .deny
    }
}

// MARK: - Downloads

enum DownloadFailure: Error, Sendable, Hashable {
    case blocked(NavigationBlock)
    case httpStatus(Int)
    case tooLarge(Int)
    case timeout(seconds: Double)
    case canceled
    case network(String)
}

/// One explicit download: streams to a file, hashes as it goes, checks every redirect and enforces the size cap.
final class DownloadFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let maxBytes: Int
    private let allowedHosts: [String]
    private let timeoutSeconds: Double
    private let userAgent: String?
    private let cookies: [HTTPCookie]
    private let delegateQueue: OperationQueue

    // Touched on `delegateQueue` only, except `task` and `continuation`, which are guarded by `lock`.
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Result<DownloadedFile, DownloadFailure>, Never>?
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var received = 0
    private var failure: DownloadFailure?
    private var response: HTTPURLResponse?
    private var mimeType: String?
    private var suggestedFilename = ""

    init(destination: URL, maxBytes: Int, allowedHosts: [String], cookies: [HTTPCookie], userAgent: String?, timeoutSeconds: Double) {
        self.destination = destination; self.maxBytes = maxBytes; self.allowedHosts = allowedHosts
        self.cookies = cookies; self.userAgent = userAgent; self.timeoutSeconds = timeoutSeconds
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
    }

    func run(_ url: URL) async throws -> DownloadedFile {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.timeoutIntervalForRequest = min(timeoutSeconds, 60)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // No stored credentials, no shared cookie jar: only the web view's cookies for this transfer.
        configuration.urlCredentialStorage = nil
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
        if let userAgent { configuration.httpAdditionalHeaders = ["User-Agent": userAgent] }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        defer { session.invalidateAndCancel() }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Result<DownloadedFile, DownloadFailure>, Never>) in
                let t = session.dataTask(with: URLRequest(url: url))
                lock.withLock {
                    continuation = c
                    task = t
                }
                if Task.isCancelled { cancel() }
                t.resume()
            }
        } onCancel: {
            cancel()
        }
        return try result.get()
    }

    /// Stops the transfer; the pending `run` throws `DownloadFailure.canceled`.
    func cancel() {
        delegateQueue.addOperation { [self] in
            if failure == nil { failure = .canceled }
            lock.withLock { task }?.cancel()
        }
    }

    private func stop(_ reason: DownloadFailure) {
        if failure == nil { failure = reason }
        lock.withLock { task }?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url else { completionHandler(nil); stop(.network("redirect without a URL")); return }
        switch BrowserURLPolicy.check(url, allowedHosts: allowedHosts) {
        case .success:
            completionHandler(request)
        case .failure(let block):
            // Refuse before anything is sent to the new host.
            completionHandler(nil)
            stop(.blocked(block))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else { completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        self.response = http
        mimeType = response.mimeType
        suggestedFilename = String((response.suggestedFilename ?? "").prefix(255))
        if let status = http?.statusCode, status >= 400 { failure = .httpStatus(status); completionHandler(.cancel); return }
        if response.expectedContentLength > Int64(maxBytes) {
            failure = .tooLarge(Int(response.expectedContentLength)); completionHandler(.cancel); return
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil), let h = try? FileHandle(forWritingTo: destination) else {
            failure = .network("cannot create \(destination.lastPathComponent)"); completionHandler(.cancel); return
        }
        handle = h
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        received += data.count
        if received > maxBytes { stop(.tooLarge(received)); return }
        do { try handle.write(contentsOf: data) } catch { stop(.network("could not write the file: \(error.localizedDescription)")); return }
        hasher.update(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        try? handle?.close()
        handle = nil
        let result: Result<DownloadedFile, DownloadFailure>
        if let failure {
            result = .failure(failure)
        } else if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut { result = .failure(.timeout(seconds: timeoutSeconds)) }
            else if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { result = .failure(.canceled) }
            else { result = .failure(.network(ns.localizedDescription)) }
        } else if let response, (300..<400).contains(response.statusCode) {
            result = .failure(.network("the server answered HTTP \(response.statusCode) without a usable redirect"))
        } else {
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            result = .success(DownloadedFile(path: destination.path, bytes: received, sha256: digest, mimeType: mimeType,
                                             suggestedFilename: suggestedFilename, httpStatus: response?.statusCode,
                                             finalURL: response?.url?.absoluteString ?? ""))
        }
        if case .failure = result { try? FileManager.default.removeItem(at: destination) }
        let c: CheckedContinuation<Result<DownloadedFile, DownloadFailure>, Never>? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        c?.resume(returning: result)
    }
}
