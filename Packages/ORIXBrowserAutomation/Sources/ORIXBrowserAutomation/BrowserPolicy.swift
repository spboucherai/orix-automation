// ORIX OS Automation
// File: Packages/ORIXBrowserAutomation/Sources/ORIXBrowserAutomation/BrowserPolicy.swift
// Description: Pure URL and host rules for the ORIX browser: allowed schemes, loopback detection, host allowlist matching, and the record of a blocked navigation.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

/// A navigation the browser refused, as reported in tool results.
public struct NavigationBlock: Error, Codable, Sendable, Hashable {
    /// `host_not_allowed`, `scheme_not_allowed`, `invalid_url` or `download_refused`.
    public var reason: String
    public var url: String
    /// Lowercase host, empty when the URL has none.
    public var host: String
    public var message: String
    public init(reason: String, url: String, host: String, message: String) {
        self.reason = reason; self.url = url; self.host = host; self.message = message
    }
}

/// URL rules shared by `requirements` (before anything runs) and by the navigation delegate (on every navigation).
public enum BrowserURLPolicy {
    /// `localhost`, `*.localhost`, `127.0.0.0/8` and `::1`.
    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// The lowercase host of a URL without port or IPv6 brackets.
    public static func host(of url: URL) -> String? {
        guard let h = url.host(percentEncoded: false), !h.isEmpty else { return nil }
        return h.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// Checks scheme and shape only: `https` anywhere, `http` for loopback hosts, nothing else (`file:`, `data:`,
    /// `javascript:`, `blob:`, custom schemes), and no credentials embedded in the URL. Returns the host.
    public static func validate(_ url: URL) -> Result<String, NavigationBlock> {
        let text = url.absoluteString
        guard let scheme = url.scheme?.lowercased() else {
            return .failure(.init(reason: "invalid_url", url: text, host: "", message: "The URL has no scheme."))
        }
        guard scheme == "https" || scheme == "http" else {
            return .failure(.init(reason: "scheme_not_allowed", url: String(text.prefix(200)), host: "",
                                  message: "\(scheme): URLs are refused; the browser only opens https pages (and http on this Mac's loopback)."))
        }
        guard let host = host(of: url) else {
            return .failure(.init(reason: "invalid_url", url: text, host: "", message: "The URL has no host."))
        }
        if url.user != nil || url.password != nil {
            return .failure(.init(reason: "invalid_url", url: "\(scheme)://\(host)/…", host: host, message: "URLs that embed credentials are refused."))
        }
        if scheme == "http" && !isLoopback(host) {
            return .failure(.init(reason: "scheme_not_allowed", url: text, host: host,
                                  message: "Plain http is only allowed for loopback hosts; \(host) must be reached over https."))
        }
        return .success(host)
    }

    /// True when `host` is covered by one of `patterns`, with the same semantics as a `.browser(host:)` grant:
    /// exact host, or `*.example.com` for subdomains.
    public static func host(_ host: String, isCoveredBy patterns: [String]) -> Bool {
        let requested = Capability.browser(host: host.lowercased())
        return patterns.contains { Capability.browser(host: $0.lowercased()).covers(requested) }
    }

    /// Full check for a main-frame navigation.
    public static func check(_ url: URL, allowedHosts: [String]) -> Result<String, NavigationBlock> {
        switch validate(url) {
        case .failure(let block): return .failure(block)
        case .success(let host):
            if Self.host(host, isCoveredBy: allowedHosts) { return .success(host) }
            return .failure(.init(reason: "host_not_allowed", url: url.absoluteString, host: host,
                                  message: "Navigation to \(host) was blocked: this run has no browser grant for that host."))
        }
    }
}

public extension NavigationBlock {
    /// The typed tool failure for a blocked navigation.
    var toolResult: ToolResult {
        let code = reason == "download_refused" ? "download_refused" : "navigation_blocked"
        let recovery = reason == "host_not_allowed"
            ? "Ask the user to grant browser access to \(host); do not look for another route."
            : (reason == "download_refused" ? "Use browser.download to save a file." : nil)
        var result = ToolResult.failure(.denied, ToolFailure(code: code, message: message, recovery: recovery))
        result.output = ["blocked": (try? JSONValue.encoding(self)) ?? .null]
        result.untrusted = true
        return result
    }
}
