// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/OpenRouterProvider.swift
// Description: OpenRouter adapter (OpenAI-compatible endpoint): live model catalog with prices and capabilities, provider routing, reported cost, precise error mapping including mid-stream errors.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Synchronization
import ORIXCore

/// OpenRouter provider-routing preferences, passed through as the request's `provider` object.
public struct ProviderRouting: Sendable, Hashable, Codable {
    public enum DataCollection: String, Sendable, Hashable, Codable { case allow, deny }
    /// Provider slugs to try in sequence.
    public var order: [String]?
    /// Whether OpenRouter may fall back to other providers when the preferred ones fail (API default: true).
    public var allowFallbacks: Bool?
    /// `deny` restricts routing to providers that do not store or train on prompts.
    public var dataCollection: DataCollection?
    /// Only use providers that support every parameter of the request (e.g. tools, structured outputs).
    public var requireParameters: Bool?

    public init(order: [String]? = nil, allowFallbacks: Bool? = nil, dataCollection: DataCollection? = nil, requireParameters: Bool? = nil) {
        self.order = order; self.allowFallbacks = allowFallbacks; self.dataCollection = dataCollection; self.requireParameters = requireParameters
    }

    var json: JSONValue? {
        let o = JSONValue.obj([("order", order.map { .array($0.map(JSONValue.string)) }), ("allow_fallbacks", allowFallbacks.map(JSONValue.bool)),
                               ("data_collection", dataCollection.map { .string($0.rawValue) }),
                               ("require_parameters", requireParameters.map(JSONValue.bool))])
        guard let fields = o.objectValue, !fields.isEmpty else { return nil }
        return o
    }
}

/// OpenRouter adapter (`https://openrouter.ai/api/v1`, Chat Completions wire format shared with `OpenAIProvider`).
///
/// - `listModels()` reads the live catalog: per-token prices → USD per MTok, `context_length`,
///   `top_provider.max_completion_tokens`, tools / structured outputs from `supported_parameters`, vision from
///   `architecture.input_modalities`. Models with dynamic pricing (router ids, price `-1`) keep nil prices.
/// - Cost: OpenRouter reports the request cost in `usage.cost` (credits, 1 credit = 1 USD) → `TokenUsage.reportedCostUSD`.
///   `usage: {include: true}` is still sent; current OpenRouter always includes usage and ignores the flag.
/// - `responseSchema`: when the catalog has been loaded and the model lists neither `structured_outputs` nor
///   `response_format`, the stream fails with `LLMError.unsupported` before any request is made.
/// - Output cap is sent as `max_tokens`, the field every OpenRouter model accepts.
/// - `cacheSystemAndTools`: for `anthropic/*` models the system prompt is marked with `cache_control` (explicit caching);
///   other providers cache automatically or not at all.
public final class OpenRouterProvider: LLMProvider, CustomStringConvertible, CustomReflectable {
    public static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    public static let appTitle = "ORIX OS Automation"
    /// Generic value sent as `HTTP-Referer` (OpenRouter uses it only for app attribution). It carries no user, machine or
    /// site detail; the app can replace it with its public page once one is chosen.
    public static let appReferer = "http://localhost"

    public let id = ProviderID.openrouter
    public let routing: ProviderRouting?
    private let apiKey: String
    private let baseURL: URL
    private let transport: Transport
    private let catalog = Mutex<[String: Set<String>]>([:]) // model id → supported_parameters

    public init(apiKey: String, session: URLSession = .shared, baseURL: URL = OpenRouterProvider.defaultBaseURL, routing: ProviderRouting? = nil) {
        self.apiKey = apiKey; self.baseURL = baseURL; self.routing = routing
        self.transport = Transport(session: session, secret: apiKey)
    }

    public var description: String { "OpenRouterProvider(\(baseURL.host ?? "?"), key: \(Redactor.placeholder))" }
    public var customMirror: Mirror { Mirror(self, children: ["id": id.rawValue]) }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(apiKey)", "HTTP-Referer": Self.appReferer, "X-Title": Self.appTitle]
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        let req = transport.request("GET", baseURL.appendingPathComponent("models"), headers: headers, timeout: 30)
        let data = try await transport.data(req) { self.mapFailure($0, model: nil) }
        guard let json = try? JSONValue.parse(data), let items = json["data"]?.arrayValue else {
            throw LLMError.decoding("The model catalog was not in the expected format.")
        }
        var supported: [String: Set<String>] = [:]
        let models: [ModelInfo] = items.compactMap { item in
            guard let mid = item["id"]?.stringValue else { return nil }
            let params = Set(item["supported_parameters"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            supported[mid] = params
            let inputs = item["architecture"]?["input_modalities"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return ModelInfo(id: mid, provider: .openrouter, displayName: item["name"]?.stringValue,
                             contextWindow: item["context_length"]?.intValue ?? item["top_provider"]?["context_length"]?.intValue,
                             maxOutputTokens: item["top_provider"]?["max_completion_tokens"]?.intValue,
                             supportsTools: params.contains("tools"), supportsVision: inputs.contains("image"),
                             supportsStructuredOutput: params.contains("structured_outputs"),
                             inputPricePerMTok: Self.perMTok(item["pricing"]?["prompt"]),
                             outputPricePerMTok: Self.perMTok(item["pricing"]?["completion"]), source: "api")
        }
        catalog.withLock { $0 = supported }
        return models
    }

    /// Catalog prices are USD per token, as decimal strings. Negative values mean "decided at routing time": unknown.
    static func perMTok(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        let perToken: Double?
        if let s = value.stringValue { perToken = Double(s) } else { perToken = value.doubleValue }
        guard let p = perToken, p >= 0, p.isFinite else { return nil }
        // Round away binary noise from the multiplication (0.00000015 × 1e6 → 0.15).
        return (p * 1_000_000 * 1e6).rounded() / 1e6
    }

    // MARK: Streaming

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        Transport.stream { continuation in
            if request.responseSchema != nil, let params = self.catalog.withLock({ $0[request.model] }),
               !params.contains("structured_outputs"), !params.contains("response_format") {
                throw LLMError.unsupported("\(request.model) does not offer structured outputs on OpenRouter.")
            }
            var headers = self.headers
            headers["Accept"] = "text/event-stream"
            let req = self.transport.request("POST", self.baseURL.appendingPathComponent("chat/completions"), headers: headers,
                                             body: self.requestBody(for: request), timeout: 300)
            let bytes = try await self.transport.open(req) { self.mapFailure($0, model: request.model) }
            var decoder = ChatCompletionsDecoder(model: request.model, readsCost: true) { self.mapFailure($0, model: request.model) }
            try await runChatCompletionsStream(bytes: bytes, decoder: &decoder, continuation: continuation)
        }
    }

    func requestBody(for request: LLMRequest) -> JSONValue {
        var extra: [String: JSONValue] = ["usage": ["include": true]]
        if let r = routing?.json { extra["provider"] = r }
        let dialect = ChatCompletionsEncoder.Dialect(maxTokensField: "max_tokens", includeTemperature: true,
                                                     explicitCacheControl: request.cacheSystemAndTools && request.model.hasPrefix("anthropic/"),
                                                     extra: extra)
        return ChatCompletionsEncoder.body(for: request, dialect: dialect)
    }

    // MARK: Errors

    func mapFailure(_ f: ProviderFailure, model: String?) -> LLMError {
        Self.mapFailure(f, model: model, scrub: { transport.scrub($0) })
    }

    /// OpenRouter errors are `{error: {code, message, metadata}}`; `code` mirrors the HTTP status and is the only status
    /// available for an error delivered inside a 200 stream. `metadata` names the upstream provider and may carry its raw
    /// error, the moderation reasons, or an `error_type`.
    static func mapFailure(_ f: ProviderFailure, model: String?, scrub: (String) -> String) -> LLMError {
        let err = f.json?["error"]
        let meta = err?["metadata"]
        let status = err?["code"]?.intValue ?? err?["code"]?.stringValue.flatMap(Int.init) ?? f.status
        var parts: [String] = []
        if let m = err?["message"]?.stringValue, !m.isEmpty { parts.append(m) } else if f.json == nil, !f.text.isEmpty { parts.append(f.text) }
        if let p = meta?["provider_name"]?.stringValue { parts.append("[provider: \(p)]") }
        if let reasons = meta?["reasons"]?.arrayValue?.compactMap(\.stringValue), !reasons.isEmpty { parts.append("[flagged: \(reasons.joined(separator: ", "))]") }
        if let raw = meta?["raw"] { parts.append(raw.stringValue ?? raw.serialized()) }
        let message = scrub(parts.isEmpty ? "HTTP \(status)" : parts.joined(separator: " "))
        let lower = message.lowercased()
        let errorType = meta?["error_type"]?.stringValue ?? ""

        switch status {
        case 401: return .authentication(message)
        case 402: return .invalidRequest("The OpenRouter account or key has insufficient credits. \(message)")
        case 403:
            if meta?["reasons"] != nil || lower.contains("moderation") || lower.contains("flagged") { return .invalidRequest("Blocked by moderation. \(message)") }
            return .authentication(message)
        case 404: return .modelNotFound(model.map { "\($0) — \(message)" } ?? message)
        case 408: return .network("the provider timed out (HTTP 408)")
        case 429: return .rateLimited(retryAfterSeconds: f.retryAfterSeconds)
        case 529: return .overloaded
        default: break
        }
        if errorType == "rate_limit_exceeded" { return .rateLimited(retryAfterSeconds: f.retryAfterSeconds) }
        if lower.contains("overloaded") && status >= 500 { return .overloaded }
        if lower.contains("context length") || lower.contains("context window") || lower.contains("maximum context")
            || (lower.contains("too many") && lower.contains("tokens")) || lower.contains("prompt is too long") {
            return .contextTooLong(message)
        }
        if status == 400, lower.contains("not a valid model") || lower.contains("model not found") {
            return .modelNotFound(model.map { "\($0) — \(message)" } ?? message)
        }
        if status >= 500 { return .server(status: status, message: message) }
        return .invalidRequest(message)
    }
}
