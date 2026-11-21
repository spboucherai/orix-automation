// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/Transport.swift
// Description      : Shared URLSession plumbing for the adapters: request
//                    execution, SSE byte streams, secret scrubbing, retry-after
//                    parsing, URLError/cancellation mapping.
// Module           : ORIXProviderAdapters
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

import Foundation
import ORIXCore

/// A provider failure in a provider-neutral shape: an HTTP error response, or an error object found inside a stream.
struct ProviderFailure: Sendable {
    var status: Int
    var retryAfterSeconds: Double?
    var json: JSONValue?
    var text: String

    init(status: Int, retryAfterSeconds: Double? = nil, json: JSONValue? = nil, text: String = "") {
        self.status = status; self.retryAfterSeconds = retryAfterSeconds; self.json = json; self.text = text
    }

    init(response: HTTPURLResponse, body: Data) {
        status = response.statusCode
        retryAfterSeconds = Transport.retryAfter(response)
        json = try? JSONValue.parse(body)
        text = String(decoding: body.prefix(4096), as: UTF8.self)
    }
}

struct Transport: Sendable {
    static let userAgent = "ORIX-OS-Automation/1.0"
    static let maxErrorBodyBytes = 64 * 1024

    let session: URLSession
    /// The API key, kept only to scrub it out of anything that becomes an error message.
    private let secret: String

    init(session: URLSession, secret: String) {
        self.session = session; self.secret = secret
        Redactor.shared.register(secret: secret)
    }

    /// Removes the key (exact value and credential-shaped strings) and bounds the length of server-supplied text.
    func scrub(_ text: String, limit: Int = 600) -> String {
        var out = text
        if !secret.isEmpty { out = out.replacingOccurrences(of: secret, with: Redactor.placeholder) }
        out = Redactor.shared.redact(out)
        if out.count > limit { out = String(out.prefix(limit)) + "…" }
        return out
    }

    func request(_ method: String, _ url: URL, headers: [String: String], body: JSONValue? = nil, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.httpShouldHandleCookies = false
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(body.serialized().utf8)
        }
        return r
    }

    /// Runs a non-streaming request. Non-2xx responses are returned to the caller's mapper as a `ProviderFailure`.
    func data(_ request: URLRequest, mapFailure: (ProviderFailure) -> LLMError) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.network("The server did not answer with HTTP.") }
            guard (200..<300).contains(http.statusCode) else { throw mapFailure(ProviderFailure(response: http, body: data)) }
            return data
        } catch { throw Self.llmError(from: error) }
    }

    /// Opens a streaming request. Returns the byte stream on 2xx; otherwise reads the (bounded) error body and throws the mapped error.
    func open(_ request: URLRequest, mapFailure: (ProviderFailure) -> LLMError) async throws -> URLSession.AsyncBytes {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.network("The server did not answer with HTTP.") }
            guard (200..<300).contains(http.statusCode) else {
                var body = Data()
                for try await b in bytes {
                    body.append(b)
                    if body.count >= Self.maxErrorBodyBytes { break }
                }
                throw mapFailure(ProviderFailure(response: http, body: body))
            }
            return bytes
        } catch { throw Self.llmError(from: error) }
    }

    /// Wraps an async producer into the stream shape `LLMProvider` requires: errors become `LLMError`, and cancelling the
    /// consumer (or dropping the stream) cancels the request.
    static func stream(_ produce: @escaping @Sendable (AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) async throws -> Void)
        -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await produce(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: llmError(from: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func llmError(from error: Error) -> LLMError {
        if let e = error as? LLMError { return e }
        if error is CancellationError { return .canceled }
        if let u = error as? URLError {
            if u.code == .cancelled { return .canceled }
            return .network(describe(u.code))
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return .canceled }
            return .network(describe(URLError.Code(rawValue: ns.code)))
        }
        if error is DecodingError { return .decoding("The response was not the expected JSON.") }
        return .network("Unexpected transport failure (\(ns.domain) \(ns.code)).")
    }

    /// English, locale-independent description of a URLError code (the system's own text is localized and may quote URLs).
    static func describe(_ code: URLError.Code) -> String {
        let name: String
        switch code {
        case .timedOut: name = "the request timed out"
        case .notConnectedToInternet: name = "no internet connection"
        case .networkConnectionLost: name = "the connection was lost"
        case .cannotFindHost, .dnsLookupFailed: name = "the host could not be resolved"
        case .cannotConnectToHost: name = "could not connect to the host"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            name = "the secure connection failed"
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData, .cannotDecodeRawData: name = "the server sent an unreadable response"
        case .dataNotAllowed, .internationalRoamingOff: name = "network access is not allowed right now"
        default: name = "transport error"
        }
        return "\(name) (URLError \(code.rawValue))"
    }

    /// Seconds to wait, from `retry-after-ms`, a numeric `retry-after`, or an HTTP-date `retry-after`.
    static func retryAfter(_ response: HTTPURLResponse) -> Double? {
        if let ms = response.value(forHTTPHeaderField: "retry-after-ms"), let v = Double(ms.trimmingCharacters(in: .whitespaces)), v >= 0 {
            return v / 1000
        }
        guard let raw = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let v = Double(raw), v >= 0 { return v }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = f.date(from: raw) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }
}

extension JSONValue {
    /// Object builder that drops nil values.
    static func obj(_ pairs: [(String, JSONValue?)]) -> JSONValue {
        var o: [String: JSONValue] = [:]
        for (k, v) in pairs { if let v { o[k] = v } }
        return .object(o)
    }
}

/// Strict JSON parse of an accumulated tool-call argument string. An empty string means "no arguments" (`{}`).
/// Returns nil when the text is not a complete JSON object: the adapters never repair or guess tool input.
func parseToolArguments(_ text: String) -> JSONValue? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .object([:]) }
    guard let v = try? JSONValue.parse(trimmed), case .object = v else { return nil }
    return v
}
