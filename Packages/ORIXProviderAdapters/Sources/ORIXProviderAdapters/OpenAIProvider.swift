// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/OpenAIProvider.swift
// Description      : OpenAI adapter over the Chat Completions endpoint:
//                    streaming, tool calls, structured outputs, usage,
//                    temperature handling for models that reject it, typed
//                    errors.
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
import Synchronization
import ORIXCore

public struct OpenAIOptions: Sendable, Hashable {
    /// `reasoning_effort`, passed through when set (reasoning models spend output tokens on reasoning before any text).
    public var reasoningEffort: String?
    public var organization: String?
    public var project: String?
    public init(reasoningEffort: String? = nil, organization: String? = nil, project: String? = nil) {
        self.reasoningEffort = reasoningEffort; self.organization = organization; self.project = project
    }
}

/// OpenAI adapter.
///
/// **Endpoint choice.** This adapter uses **Chat Completions** (`POST /v1/chat/completions`), not the Responses API. The
/// reason is the shared wire format: OpenRouter exposes the same request and chunk shapes, so one encoder and one stream
/// decoder (`ChatCompletions.swift`) serve both providers and are tested once. Consequences: models offered only through
/// the Responses API (the `*-pro` family, deep-research, Codex models) are filtered out of `listModels()`, and reasoning
/// summaries are not available (Chat Completions does not return them). Moving OpenAI to the Responses API is future work.
///
/// Mapping notes:
/// - Output cap is sent as `max_completion_tokens` (`max_tokens` is deprecated and rejected by reasoning models).
/// - `temperature` is omitted for models the registry or the id pattern marks as rejecting it. If a model still answers
///   400 on `temperature`, the request is sent once more without it and the model is remembered for the process lifetime.
/// - `responseSchema` → `response_format: {type: "json_schema", json_schema: {name, strict: true, schema}}`. Strict mode
///   requires every property to be listed in `required` and `additionalProperties: false`; the schema is sent as given and
///   a schema the API refuses surfaces as `LLMError.invalidRequest`.
/// - `cacheSystemAndTools` needs nothing: OpenAI caches prompt prefixes automatically; cached tokens are reported in usage.
/// - Tool results have no error flag in this format; an error result is prefixed with `[tool error] `.
public final class OpenAIProvider: LLMProvider, CustomStringConvertible, CustomReflectable {
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    public let id = ProviderID.openai
    public let options: OpenAIOptions
    private let apiKey: String
    private let baseURL: URL
    private let transport: Transport
    private let noTemperature = Mutex<Set<String>>([])

    public init(apiKey: String, session: URLSession = .shared, baseURL: URL = OpenAIProvider.defaultBaseURL, options: OpenAIOptions = .init()) {
        self.apiKey = apiKey; self.baseURL = baseURL; self.options = options
        self.transport = Transport(session: session, secret: apiKey)
    }

    public var description: String { "OpenAIProvider(\(baseURL.host ?? "?"), key: \(Redactor.placeholder))" }
    public var customMirror: Mirror { Mirror(self, children: ["id": id.rawValue]) }

    private var headers: [String: String] {
        var h = ["Authorization": "Bearer \(apiKey)"]
        if let o = options.organization { h["OpenAI-Organization"] = o }
        if let p = options.project { h["OpenAI-Project"] = p }
        return h
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        let req = transport.request("GET", baseURL.appendingPathComponent("models"), headers: headers, timeout: 30)
        let data = try await transport.data(req) { self.mapFailure($0, model: nil) }
        guard let json = try? JSONValue.parse(data), let items = json["data"]?.arrayValue else {
            throw LLMError.decoding("The model list was not in the expected format.")
        }
        // The endpoint returns ids only (no capabilities, limits or prices): keep chat-capable ids and enrich from the registry.
        return items.compactMap { $0["id"]?.stringValue }.filter(Self.isChatModel).sorted().map { mid in
            var info = ModelRegistry.info(provider: .openai, id: mid) ?? ModelInfo(id: mid, provider: .openai)
            info.source = "api"
            return info
        }
    }

    /// Chat Completions text models: GPT and o-series ids, minus audio, realtime, image, embedding, moderation, legacy
    /// completion models and models served only by the Responses API.
    static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        guard lower.hasPrefix("gpt-") || lower.hasPrefix("chatgpt-") || lower.range(of: #"^o\d"#, options: .regularExpression) != nil else { return false }
        let excluded = ["embedding", "whisper", "tts", "audio", "realtime", "image", "dall-e", "moderation", "transcribe", "search",
                        "instruct", "davinci", "babbage", "codex", "deep-research", "computer-use", "-pro"]
        return !excluded.contains { lower.contains($0) }
    }

    // MARK: Streaming

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        Transport.stream { continuation in
            var sendTemperature = request.temperature != nil && self.acceptsTemperature(request.model)
            while true {
                let body = self.requestBody(for: request, includeTemperature: sendTemperature)
                var headers = self.headers
                headers["Accept"] = "text/event-stream"
                let req = self.transport.request("POST", self.baseURL.appendingPathComponent("chat/completions"), headers: headers, body: body, timeout: 300)
                let bytes: URLSession.AsyncBytes
                do {
                    bytes = try await self.transport.open(req) { self.mapFailure($0, model: request.model) }
                } catch LLMError.invalidRequest(let message) where sendTemperature && Self.isTemperatureRejection(message) {
                    // The one specific 400 this adapter retries: the model does not take `temperature`. Nothing was delivered yet.
                    self.noTemperature.withLock { _ = $0.insert(request.model) }
                    sendTemperature = false
                    continue
                }
                var decoder = ChatCompletionsDecoder(model: request.model, readsCost: false) { self.mapFailure($0, model: request.model) }
                try await runChatCompletionsStream(bytes: bytes, decoder: &decoder, continuation: continuation)
                return
            }
        }
    }

    func requestBody(for request: LLMRequest, includeTemperature: Bool? = nil) -> JSONValue {
        var extra: [String: JSONValue] = [:]
        if let effort = options.reasoningEffort { extra["reasoning_effort"] = .string(effort) }
        let dialect = ChatCompletionsEncoder.Dialect(maxTokensField: "max_completion_tokens",
                                                     includeTemperature: includeTemperature ?? acceptsTemperature(request.model),
                                                     explicitCacheControl: false, extra: extra)
        return ChatCompletionsEncoder.body(for: request, dialect: dialect)
    }

    func acceptsTemperature(_ model: String) -> Bool {
        if noTemperature.withLock({ $0.contains(model) }) { return false }
        if let e = ModelRegistry.entry(provider: .openai, id: model) { return e.acceptsTemperature }
        // Unknown id: o-series and GPT-5 reasoning models only take the default; everything else is tried (and retried without on a 400).
        let lower = model.lowercased()
        return !(lower.range(of: #"^o\d"#, options: .regularExpression) != nil || lower.hasPrefix("gpt-5"))
    }

    static func isTemperatureRejection(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("temperature") && (m.contains("unsupported") || m.contains("not supported") || m.contains("does not support") || m.contains("only the default"))
    }

    // MARK: Errors

    func mapFailure(_ f: ProviderFailure, model: String?) -> LLMError {
        Self.mapFailure(f, model: model, scrub: { transport.scrub($0) })
    }

    static func mapFailure(_ f: ProviderFailure, model: String?, scrub: (String) -> String) -> LLMError {
        let err = f.json?["error"]
        let code = err?["code"]?.stringValue ?? "", type = err?["type"]?.stringValue ?? ""
        let raw = err?["message"]?.stringValue ?? (f.json == nil ? f.text : "")
        var message = scrub(raw.isEmpty ? "HTTP \(f.status)" : raw)
        if let param = err?["param"]?.stringValue, !param.isEmpty, !message.lowercased().contains(param.lowercased()) { message += " (parameter: \(param))" }
        let lower = message.lowercased()
        if code == "invalid_api_key" || f.status == 401 { return .authentication(message) }
        if code == "model_not_found" || (f.status == 404 && (lower.contains("model") || model != nil)) {
            return .modelNotFound(model.map { "\($0) — \(message)" } ?? message)
        }
        if f.status == 403 { return .authentication(message) }
        if code == "insufficient_quota" || type == "insufficient_quota" || f.status == 402 {
            return .invalidRequest("The provider account has no remaining quota or credit. \(message)")
        }
        if f.status == 429 || code == "rate_limit_exceeded" { return .rateLimited(retryAfterSeconds: f.retryAfterSeconds) }
        if f.status == 529 || lower.contains("overloaded") && f.status >= 500 { return .overloaded }
        if code == "context_length_exceeded" || lower.contains("maximum context length") || lower.contains("context window")
            || lower.contains("context length") {
            return .contextTooLong(message)
        }
        if f.status == 408 { return .network("the provider timed out (HTTP 408)") }
        if f.status >= 500 { return .server(status: f.status, message: message) }
        return .invalidRequest(message)
    }
}
