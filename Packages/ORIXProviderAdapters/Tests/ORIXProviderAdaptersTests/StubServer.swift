// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Tests/ORIXProviderAdaptersTests/StubServer.swift
// Description: Test double for the network: a URLProtocol that replays scripted HTTP/SSE responses per fake host and records the requests it received.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Synchronization
import ORIXCore
@testable import ORIXProviderAdapters

/// A scripted fake server. Each instance owns a unique host name, so tests can run in parallel without sharing state.
final class StubServer: Sendable {
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var chunks: [Data] = []
        /// When set, the connection fails with this error after the chunks were delivered (mid-stream disconnect).
        var failure: URLError.Code?
    }
    struct Recorded: Sendable {
        var method: String
        var path: String
        var query: String?
        var headers: [String: String]
        var body: JSONValue?
        func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    }
    private struct State { var queue: [Response] = []; var recorded: [Recorded] = [] }

    static let registry = Mutex<[String: StubServer]>([:])
    let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let state = Mutex(State())

    init() { Self.registry.withLock { $0[host] = self } }
    deinit { Self.registry.withLock { $0[host] = nil } }

    var baseURL: URL { URL(string: "https://\(host)")! }
    var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }
    var requests: [Recorded] { state.withLock { $0.recorded } }

    @discardableResult func enqueue(_ r: Response) -> StubServer { state.withLock { $0.queue.append(r) }; return self }
    @discardableResult func sse(_ text: String, chunkSize: Int? = nil, failure: URLError.Code? = nil) -> StubServer {
        let bytes = Array(text.utf8)
        let chunks: [Data] = chunkSize.map { n in stride(from: 0, to: bytes.count, by: n).map { Data(bytes[$0..<min($0 + n, bytes.count)]) } } ?? [Data(bytes)]
        return enqueue(Response(chunks: chunks, failure: failure))
    }
    @discardableResult func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> StubServer {
        enqueue(Response(status: status, headers: ["Content-Type": "application/json"].merging(headers) { _, b in b }, chunks: [Data(body.utf8)]))
    }

    fileprivate func next(for request: Recorded) -> Response? {
        state.withLock { s in
            s.recorded.append(request)
            return s.queue.isEmpty ? nil : s.queue.removeFirst()
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host, let server = StubServer.registry.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        let recorded = StubServer.Recorded(method: request.httpMethod ?? "GET", path: url.path, query: url.query,
                                           headers: request.allHTTPHeaderFields ?? [:], body: body.flatMap { try? JSONValue.parse($0) })
        guard let response = server.next(for: recorded) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if let failure = response.failure {
            // Let the delivered bytes reach the consumer first, as on a real connection that drops later.
            if !response.chunks.isEmpty { Thread.sleep(forTimeInterval: 0.15) }
            client?.urlProtocol(self, didFailWithError: URLError(failure))
        }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
}

/// Collects a provider stream: the events delivered and the error that ended it, if any.
func collect(_ stream: AsyncThrowingStream<LLMStreamEvent, Error>) async -> (events: [LLMStreamEvent], error: LLMError?) {
    var events: [LLMStreamEvent] = []
    do {
        for try await e in stream { events.append(e) }
        return (events, nil)
    } catch {
        return (events, error as? LLMError ?? .network("non-LLMError: \(type(of: error))"))
    }
}

extension Array where Element == LLMStreamEvent {
    var text: String { compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined() }
    var reasoning: String { compactMap { if case .reasoningSummaryDelta(let t) = $0 { return t }; return nil }.joined() }
    var toolUses: [LLMToolUse] { compactMap { if case .toolUse(let u) = $0 { return u }; return nil } }
    var lastUsage: TokenUsage? { compactMap { if case .usage(let u) = $0 { return u }; return nil }.last }
    var stop: LLMStopReason? { compactMap { if case .stop(let s) = $0 { return s }; return nil }.last }
    var inputDeltas: [String] { compactMap { if case .toolUseInputDelta(_, let p) = $0 { return p }; return nil } }
    var started: [String] { compactMap { if case .toolUseStarted(let i, let id, let name) = $0 { return "\(i):\(id):\(name)" }; return nil } }
}

/// A key-shaped value that is obviously not a real credential; used to assert that keys never leak into errors.
let fixtureKey = "sk-fixture-0000-not-a-real-key-0000"

/// Builds an Anthropic-style SSE transcript from (event, JSON) pairs.
func anthropicSSE(_ events: [(String, String)]) -> String {
    events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
}

/// Builds a Chat Completions SSE transcript from JSON chunks, closed by `[DONE]`.
func chatSSE(_ chunks: [String], done: Bool = true) -> String {
    chunks.map { "data: \($0)\n\n" }.joined() + (done ? "data: [DONE]\n\n" : "")
}

let weatherTool = LLMToolSpec(name: "get_weather", description: "Returns the weather for a city.",
                              inputSchema: .object(["city": .string("City name")], required: ["city"]))
