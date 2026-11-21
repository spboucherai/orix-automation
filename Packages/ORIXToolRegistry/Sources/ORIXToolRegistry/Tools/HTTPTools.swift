// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/HTTPTools.swift
// Description: http.request: typed HTTPS requests to one declared host, secret headers resolved at the last moment, cross-host redirects returned instead of followed, bounded untrusted response.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public struct HTTPRequestTool: ORIXTool {
    public init() {}

    public let manifest = ToolManifest(
        identifier: "http.request", name: "HTTP request",
        summary: "Sends one HTTP request (HTTPS only, plain HTTP allowed for loopback) to a declared host and returns status, headers and a bounded body. Redirects to another host are reported, not followed. Secrets go in secretHeaders by reference and are never echoed.",
        family: "http",
        inputSchema: Schema.input([
            "method": .string("Default GET.", enum: ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]),
            "url": .string("Absolute URL."),
            "headers": JSONSchema(raw: ["type": "object", "additionalProperties": ["type": "string"]]),
            "secretHeaders": JSONSchema(raw: ["type": "object", "additionalProperties": ["type": "string"],
                                              "description": "Header name → secret reference name. The header value is the secret (prefix it with secretPrefix if needed)."]),
            "secretPrefix": .string("Text put before each secret value, for example \"Bearer \"."),
            "body": .string("Request body text."),
            "timeoutSeconds": Schema.timeout,
            "maxBytes": .integer("Response body bound (default 200000).", minimum: 1, maximum: 5_000_000),
            "followRedirects": .boolean("Follow redirects that stay on the same host (default true)."),
        ], required: ["url"]),
        outputSchema: Schema.output(["status": .integer(), "url": .string(), "headers": .any, "body": .string(), "bodyEncoding": .string(),
                                     "truncated": .boolean(), "redirect": .any], required: ["status", "url", "headers", "body", "truncated"]),
        sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 300, maxOutputBytes: 8_000_000,
        outputIsUntrusted: true,
        examples: [["url": "https://api.example.com/v1/items", "secretHeaders": ["Authorization": "example-api-token"], "secretPrefix": "Bearer "]])

    struct Plan {
        let url: URL; let host: String; let method: String; let headers: [String: String]; let secretHeaders: [String: String]
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.") && host.split(separator: ".").count == 4
    }

    /// Scalar-level check: "\r\n" is one Character, so `contains("\n")` would miss it.
    static func hasLineBreak(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" }
    }

    /// Validates a URL for this tool and returns it with its lowercase host.
    static func checked(_ raw: String) throws -> (URL, String) {
        guard let c = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty, let url = c.url else {
            throw ToolError.invalidInput("url must be an absolute http(s) URL")
        }
        guard c.user == nil, c.password == nil else { throw ToolError.invalidInput("credentials in the URL are not allowed; use secretHeaders") }
        guard scheme == "https" || (scheme == "http" && isLoopback(host)) else {
            throw ToolError.unsupported(scheme == "http" ? "Plain http is only allowed for loopback addresses; use https" : "Unsupported URL scheme \(scheme)")
        }
        return (url, host)
    }

    func plan(_ input: ToolInput) throws -> Plan {
        let (url, host) = try Self.checked(try input.string("url"))
        let headers = input.stringMap("headers"), secretHeaders = input.stringMap("secretHeaders")
        for name in Array(headers.keys) + Array(secretHeaders.keys) {
            let lower = name.lowercased()
            guard !name.isEmpty, name.range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil else {
                throw ToolError.invalidInput("invalid header name \(name)")
            }
            guard lower != "host", lower != "content-length" else { throw ToolError.invalidInput("header \(name) cannot be set") }
        }
        for (name, value) in headers where Self.hasLineBreak(value) { throw ToolError.invalidInput("header \(name) contains a line break") }
        for (name, ref) in secretHeaders where ref.isEmpty { throw ToolError.invalidInput("secretHeaders.\(name) is empty") }
        return Plan(url: url, host: host, method: input.optionalString("method") ?? "GET", headers: headers, secretHeaders: secretHeaders)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input)
        var caps: [Capability] = [.network(host: p.host)]
        for ref in Set(p.secretHeaders.values).sorted() { caps.append(.secret(reference: ref)) }
        let reads = ["GET", "HEAD", "OPTIONS"].contains(p.method)
        var shown = URLComponents(url: p.url, resolvingAgainstBaseURL: false)
        shown?.query = nil; shown?.fragment = nil
        return ToolRequirements(capabilities: caps, tier: reads ? .readOnly : .consequential,
                                summary: "\(p.method) \(shown?.string ?? p.host)\(p.secretHeaders.isEmpty ? "" : " with secret \(p.secretHeaders.values.sorted().joined(separator: ", "))")")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input)
        let timeout = min(context.timeoutSeconds, input.double("timeoutSeconds", default: 30))
        let maxBytes = input.int("maxBytes", default: 200_000)
        let follow = input.bool("followRedirects", default: true)

        var headers = p.headers
        if !p.secretHeaders.isEmpty {
            guard let secrets = context.secrets else { throw ToolError.unsupported("No secret store is available to resolve secretHeaders") }
            let prefix = input.optionalString("secretPrefix") ?? ""
            for (name, reference) in p.secretHeaders {
                let value: String
                do { value = try await secrets.secret(reference: reference) }
                catch let e as ToolError { throw e }
                catch { throw ToolError.notFound("Secret \(reference) could not be resolved") }
                guard !Self.hasLineBreak(value) else { throw ToolError.invalidInput("secret \(reference) is not usable as a header value") }
                headers[name] = prefix + value
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var url = p.url, method = p.method
        var body: Data? = input.optionalString("body").map { Data($0.utf8) }
        var hops = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
            request.httpMethod = method
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if let body, !["GET", "HEAD"].contains(method) { request.httpBody = body }

            let stream: URLSession.AsyncBytes, response: URLResponse
            do { (stream, response) = try await session.bytes(for: request) }
            catch { throw Self.mapped(error, host: p.host) }
            guard let http = response as? HTTPURLResponse else { throw ToolError.network("The server did not answer with HTTP", retryable: false) }

            var responseHeaders: [String: JSONValue] = [:]
            for (k, v) in http.allHeaderFields { responseHeaders[String(describing: k).lowercased()] = .string(String(describing: v)) }

            // Redirects are decided here, never by URLSession.
            var redirect: JSONValue = .null
            if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: url)?.absoluteURL {
                let nextHost = next.host?.lowercased() ?? ""
                let sameHost = nextHost == p.host
                let allowed = (try? Self.checked(next.absoluteString)) != nil
                if sameHost && allowed && follow && hops < 5 {
                    stream.task.cancel()
                    hops += 1
                    if http.statusCode == 303 || ((http.statusCode == 301 || http.statusCode == 302) && method != "GET" && method != "HEAD") {
                        method = "GET"; body = nil
                    }
                    url = next
                    continue
                }
                redirect = ["location": .string(next.absoluteString), "host": .string(nextHost), "sameHost": .bool(sameHost), "followed": false,
                            "note": .string(sameHost ? "Redirect not followed." : "Redirect to a different host: request it explicitly so it is authorised on its own.")]
            }

            var data = Data()
            var truncated = false
            if method != "HEAD" {
                do {
                    for try await byte in stream {
                        if data.count >= maxBytes { truncated = true; stream.task.cancel(); break }
                        data.append(byte)
                    }
                } catch {
                    if !truncated { throw Self.mapped(error, host: p.host) }
                }
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            var text = String(data: data, encoding: .utf8)
            if text == nil, truncated {  // a bounded read may stop inside a character
                var copy = data
                for _ in 0..<3 where text == nil && !copy.isEmpty { copy.removeLast(); text = String(data: copy, encoding: .utf8) }
            }
            if text == nil, contentType.hasPrefix("text/") { text = String(data: data, encoding: .isoLatin1) }
            let encoding = text == nil ? "base64" : "utf8"
            var result = ToolResult.success([
                "status": .int(http.statusCode), "url": .string(url.absoluteString), "headers": .object(responseHeaders),
                "body": .string(text ?? data.base64EncodedString()), "bodyEncoding": .string(encoding), "bytes": .int(data.count),
                "truncated": .bool(truncated), "redirect": redirect, "redirectsFollowed": .int(hops),
            ], summary: "\(p.method) \(p.host) → \(http.statusCode) (\(data.count) bytes\(truncated ? ", truncated" : ""))")
            result.truncated = truncated
            result.untrusted = true
            return result
        }
    }

    static func mapped(_ error: Error, host: String) -> Error {
        if error is CancellationError { return ToolError.canceled }
        guard let e = error as? URLError else { return ToolError.network("Request to \(host) failed: \(error.localizedDescription)", retryable: false) }
        switch e.code {
        case .cancelled: return ToolError.canceled
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return ToolError.network("Request to \(host) failed (\(e.code.rawValue)): \(e.localizedDescription)", retryable: true)
        default:
            return ToolError.network("Request to \(host) failed (\(e.code.rawValue)): \(e.localizedDescription)", retryable: false)
        }
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
