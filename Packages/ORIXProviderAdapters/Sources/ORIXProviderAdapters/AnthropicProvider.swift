// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/AnthropicProvider.swift
// Description      : Anthropic Messages API adapter: SSE streaming, tool use
//                    with partial-JSON assembly, prompt caching, structured
//                    outputs, thinking-block continuity, usage and typed
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

/// Request-shaping options that the provider-neutral `LLMRequest` does not carry.
public struct AnthropicOptions: Sendable, Hashable {
    public enum Thinking: Sendable, Hashable {
        /// Send no `thinking` field: each model uses its own default (on for current models, off for Haiku 4.5).
        case providerDefault
        /// `{"type": "disabled"}` on models that accept it; omitted (provider default) on models known to reject it.
        case disabled
        /// `{"type": "adaptive"}`, optionally with `display: "summarized"` so reasoning summaries stream as `reasoningSummaryDelta`.
        case adaptive(summarized: Bool)
    }
    public var thinking: Thinking
    /// `output_config.effort` (`low` … `max`), passed through when set.
    public var effort: String?
    /// Sets `eager_input_streaming` on every tool so large inputs stream as they are generated. The server then no longer
    /// validates tool input; this adapter parses it strictly and never emits a tool call whose JSON is incomplete.
    public var eagerToolInputStreaming: Bool
    public var apiVersion: String

    public init(thinking: Thinking = .providerDefault, effort: String? = nil, eagerToolInputStreaming: Bool = true,
                apiVersion: String = AnthropicProvider.defaultAPIVersion) {
        self.thinking = thinking; self.effort = effort; self.eagerToolInputStreaming = eagerToolInputStreaming; self.apiVersion = apiVersion
    }
}

/// Anthropic adapter (`POST /v1/messages` with `stream: true`, `GET /v1/models`).
///
/// Mapping notes:
/// - `LLMRequest.temperature` is not sent: on API version 2026-10-21 any sampling parameter is rejected for every model.
/// - `toolChoice` `.required` / `.tool` map to `any` / `tool`. Models that reject forced tool use (registry flag
///   `acceptsForcedToolChoice == false`) get `auto` plus one explicit system instruction naming the expectation; a call is
///   then likely but not guaranteed, and the caller must check that one was made.
/// - `responseSchema` uses the API's structured outputs (`output_config.format`, `json_schema`). Keywords the API rejects
///   (numeric bounds, string lengths, array bounds) are removed from the schema that is sent and `additionalProperties:
///   false` is set on objects; the caller still validates the returned JSON against the full schema.
/// - `cacheSystemAndTools` puts an ephemeral `cache_control` breakpoint on the last tool and on the system prompt.
/// - Thinking blocks: Core's `LLMContent` cannot carry them, yet the API requires the blocks that accompanied a tool call
///   to come back with the tool result. The adapter keeps the signed blocks of recent turns in memory, keyed by tool-use
///   id, and re-inserts them when the same tool call is replayed. If the API then rejects a block, the request is sent once
///   more without any thinking block (the documented recovery), before any event has been delivered.
public final class AnthropicProvider: LLMProvider, CustomStringConvertible, CustomReflectable {
    public static let defaultAPIVersion = "2026-10-21"
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!

    public let id = ProviderID.anthropic
    public let options: AnthropicOptions
    private let apiKey: String
    private let baseURL: URL
    private let transport: Transport
    private let thinkingStore = ThinkingStore()

    public init(apiKey: String, session: URLSession = .shared, baseURL: URL = AnthropicProvider.defaultBaseURL, options: AnthropicOptions = .init()) {
        self.apiKey = apiKey; self.baseURL = baseURL; self.options = options
        self.transport = Transport(session: session, secret: apiKey)
    }

    public var description: String { "AnthropicProvider(\(baseURL.host ?? "?"), key: \(Redactor.placeholder))" }
    public var customMirror: Mirror { Mirror(self, children: ["id": id.rawValue]) }

    private var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": options.apiVersion]
    }

    // MARK: Models

    public func listModels() async throws -> [ModelInfo] {
        var out: [ModelInfo] = []
        var after: String?
        for _ in 0..<20 {
            var comps = URLComponents(url: baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            let req = transport.request("GET", comps.url!, headers: headers, timeout: 30)
            let data = try await transport.data(req) { self.mapFailure($0, model: nil) }
            guard let json = try? JSONValue.parse(data), let items = json["data"]?.arrayValue else {
                throw LLMError.decoding("The model list was not in the expected format.")
            }
            for item in items {
                guard let mid = item["id"]?.stringValue else { continue }
                let caps = item["capabilities"]
                out.append(ModelInfo(id: mid, provider: .anthropic, displayName: item["display_name"]?.stringValue,
                                     contextWindow: item["max_input_tokens"]?.intValue, maxOutputTokens: item["max_tokens"]?.intValue,
                                     supportsTools: true,
                                     supportsVision: caps?["image_input"]?["supported"]?.boolValue
                                        ?? ModelRegistry.entry(provider: .anthropic, id: mid)?.supportsVision ?? false,
                                     supportsStructuredOutput: caps?["structured_outputs"]?["supported"]?.boolValue
                                        ?? ModelRegistry.entry(provider: .anthropic, id: mid)?.supportsStructuredOutput ?? false,
                                     source: "api"))
            }
            guard json["has_more"]?.boolValue == true, let last = json["last_id"]?.stringValue else { break }
            after = last
        }
        return ModelRegistry.merge(api: out)
    }

    // MARK: Streaming

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        Transport.stream { continuation in
            var includeThinking = true
            while true {
                let (body, injected) = self.requestBody(for: request, includeThinking: includeThinking)
                var headers = self.headers
                headers["Accept"] = "text/event-stream"
                let req = self.transport.request("POST", self.baseURL.appendingPathComponent("v1/messages"), headers: headers, body: body, timeout: 300)
                let bytes: URLSession.AsyncBytes
                do {
                    bytes = try await self.transport.open(req) { self.mapFailure($0, model: request.model) }
                } catch LLMError.invalidRequest(let message) where injected && Self.isThinkingBlockRejection(message) {
                    // Documented recovery: drop every thinking block from the history and retry once. Nothing was delivered yet.
                    self.thinkingStore.forget(toolUseIDs: request.messages.flatMap(\.toolUses).map(\.id))
                    includeThinking = false
                    continue
                }
                var parser = SSEParser()
                var decoder = AnthropicStreamDecoder(model: request.model, scrub: { self.transport.scrub($0) })
                for try await byte in bytes {
                    guard let event = parser.consume(byte) else { continue }
                    for out in try decoder.handle(event) { continuation.yield(out) }
                    if decoder.finished { break }
                }
                guard decoder.finished else { throw LLMError.network("The response stream ended before the message was complete.") }
                self.thinkingStore.remember(decoder.thinkingByToolUse)
                return
            }
        }
    }

    static func isThinkingBlockRejection(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("thinking") || m.contains("signature")
    }

    // MARK: Request encoding

    /// Builds the JSON body. `injected` tells whether stored thinking blocks were re-inserted into the history.
    func requestBody(for request: LLMRequest, includeThinking: Bool = true) -> (body: JSONValue, injected: Bool) {
        let entry = ModelRegistry.entry(provider: .anthropic, id: request.model)
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .int(max(1, request.maxOutputTokens)),
            "stream": true,
        ]
        let cache: JSONValue = ["type": "ephemeral"]

        // Tools (rendered first by the API, so the breakpoint on the last tool caches the whole tool list).
        var forcedInstruction: String?
        if !request.tools.isEmpty {
            var tools: [JSONValue] = request.tools.map { t in
                var o: [String: JSONValue] = ["name": .string(t.name), "description": .string(t.description), "input_schema": t.inputSchema.raw]
                if options.eagerToolInputStreaming { o["eager_input_streaming"] = true }
                return .object(o)
            }
            if request.cacheSystemAndTools, var last = tools.popLast() {
                last["cache_control"] = cache
                tools.append(last)
            }
            body["tools"] = .array(tools)
            let forcedOK = entry?.acceptsForcedToolChoice ?? true
            switch request.toolChoice {
            case .auto: body["tool_choice"] = ["type": "auto"]
            case .none: body["tool_choice"] = ["type": "none"]
            case .required:
                if forcedOK { body["tool_choice"] = ["type": "any"] } else {
                    body["tool_choice"] = ["type": "auto"]
                    forcedInstruction = "You must answer this turn by calling one of the provided tools. Do not answer with text only."
                }
            case .tool(let name):
                if forcedOK { body["tool_choice"] = ["type": "tool", "name": .string(name)] } else {
                    body["tool_choice"] = ["type": "auto"]
                    forcedInstruction = "You must answer this turn by calling the `\(name)` tool. Do not answer with text only."
                }
            }
        }

        // System prompt. The forced-tool instruction, when needed, goes after the cached block so it never invalidates the prefix.
        var system: [JSONValue] = []
        if let s = request.system, !s.isEmpty {
            system.append(request.cacheSystemAndTools ? ["type": "text", "text": .string(s), "cache_control": cache] : ["type": "text", "text": .string(s)])
        }
        if let forcedInstruction { system.append(["type": "text", "text": .string(forcedInstruction)]) }
        if !system.isEmpty {
            if system.count == 1, !request.cacheSystemAndTools, let only = system[0]["text"] { body["system"] = only }
            else { body["system"] = .array(system) }
        }

        let (messages, injected) = encodeMessages(request.messages, includeThinking: includeThinking)
        body["messages"] = .array(messages)

        var outputConfig: [String: JSONValue] = [:]
        if let schema = request.responseSchema {
            outputConfig["format"] = ["type": "json_schema", "schema": Self.structuredOutputSchema(schema.raw)]
        }
        if let effort = options.effort { outputConfig["effort"] = .string(effort) }
        if !outputConfig.isEmpty { body["output_config"] = .object(outputConfig) }

        switch options.thinking {
        case .providerDefault: break
        case .disabled: if entry?.thinkingCanBeDisabled ?? true { body["thinking"] = ["type": "disabled"] }
        case .adaptive(let summarized): body["thinking"] = summarized ? ["type": "adaptive", "display": "summarized"] : ["type": "adaptive"]
        }
        return (.object(body), injected)
    }

    private func encodeMessages(_ messages: [LLMMessage], includeThinking: Bool) -> ([JSONValue], Bool) {
        // Merge consecutive messages of the same role: the API wants alternating turns and all tool results of a turn together.
        var merged: [LLMMessage] = []
        for m in messages {
            if let last = merged.last, last.role == m.role { merged[merged.count - 1].content += m.content } else { merged.append(m) }
        }
        var out: [JSONValue] = []
        var injected = false
        for m in merged {
            var blocks: [JSONValue] = []
            switch m.role {
            case .user:
                // tool_result blocks must come first in the user turn that answers a tool call.
                var results: [JSONValue] = [], rest: [JSONValue] = []
                for c in m.content {
                    switch c {
                    case .toolResult(let id, let content, let isError):
                        results.append(.obj([("type", "tool_result"), ("tool_use_id", .string(id)), ("content", .string(content)),
                                             ("is_error", isError ? Optional(JSONValue.bool(true)) : Optional<JSONValue>.none)]))
                    case .text(let t): if !t.isEmpty { rest.append(["type": "text", "text": .string(t)]) }
                    case .image(let b64, let mediaType):
                        rest.append(["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(b64)]])
                    case .toolUse: break // not valid in a user turn
                    }
                }
                blocks = results + rest
            case .assistant:
                var textPositions: [Int] = []
                for c in m.content {
                    switch c {
                    case .text(let t):
                        if !t.isEmpty { textPositions.append(blocks.count); blocks.append(["type": "text", "text": .string(t)]) }
                    case .toolUse(let u):
                        if includeThinking, let stored = thinkingStore.blocks(forToolUse: u.id), !stored.isEmpty {
                            injected = true
                            // Insert back to front so earlier positions stay valid and equal positions keep their order.
                            for s in stored.reversed() {
                                let at = s.textBlocksBefore < textPositions.count ? textPositions[s.textBlocksBefore] : blocks.count
                                blocks.insert(s.block, at: at)
                                textPositions = textPositions.map { $0 >= at ? $0 + 1 : $0 }
                            }
                        }
                        let input: JSONValue = { if case .object = u.input { return u.input }; return .object([:]) }()
                        blocks.append(["type": "tool_use", "id": .string(u.id), "name": .string(u.name), "input": input])
                        textPositions = []
                    case .toolResult, .image: break // not valid in an assistant turn
                    }
                }
            }
            if blocks.isEmpty { continue }
            out.append(["role": .string(m.role.rawValue), "content": .array(blocks)])
        }
        return (out, injected)
    }

    /// Removes the JSON Schema keywords the structured-output grammar rejects and closes every object.
    static func structuredOutputSchema(_ schema: JSONValue) -> JSONValue {
        let unsupported: Set<String> = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength",
                                        "maxItems", "uniqueItems", "minProperties", "maxProperties"]
        switch schema {
        case .array(let a): return .array(a.map(structuredOutputSchema))
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, v) in o {
                if unsupported.contains(k) { continue }
                if k == "minItems", let n = v.intValue, n > 1 { continue }
                if k == "properties", case .object(let props) = v { out[k] = .object(props.mapValues(structuredOutputSchema)); continue }
                if k == "enum" || k == "const" || k == "required" || k == "default" { out[k] = v; continue }
                out[k] = structuredOutputSchema(v)
            }
            if out["type"] == "object" || out["properties"] != nil { out["additionalProperties"] = false }
            return .object(out)
        default: return schema
        }
    }

    // MARK: Errors

    func mapFailure(_ f: ProviderFailure, model: String?) -> LLMError {
        Self.mapFailure(f, model: model, scrub: { transport.scrub($0) })
    }

    static func mapFailure(_ f: ProviderFailure, model: String?, scrub: (String) -> String) -> LLMError {
        let err = f.json?["error"]
        let type = err?["type"]?.stringValue ?? ""
        let raw = err?["message"]?.stringValue ?? (f.json == nil ? f.text : "")
        let message = scrub(raw.isEmpty ? "HTTP \(f.status)" : raw)
        let lower = message.lowercased()
        if type == "overloaded_error" || f.status == 529 { return .overloaded }
        if type == "authentication_error" || type == "permission_error" || f.status == 401 || f.status == 403 { return .authentication(message) }
        if type == "not_found_error" || f.status == 404 {
            return lower.contains("model") || model != nil ? .modelNotFound(model.map { "\($0) — \(message)" } ?? message) : .invalidRequest(message)
        }
        if type == "rate_limit_error" || f.status == 429 {
            // A reached spend cap is a 429 that no retry can fix.
            if err?["details"]?["error_code"]?.stringValue == "enforced_spend_limit_reached" || lower.contains("spend limit") {
                return .invalidRequest("The organization's spend limit is reached. \(message)")
            }
            return .rateLimited(retryAfterSeconds: f.retryAfterSeconds)
        }
        if type == "billing_error" || f.status == 402 { return .invalidRequest("Billing problem on the provider account. \(message)") }
        if type == "request_too_large" || f.status == 413 { return .invalidRequest("The request is larger than the API accepts. \(message)") }
        if type == "invalid_request_error" || f.status == 400 || f.status == 422 {
            if lower.contains("prompt is too long") || lower.contains("context window") || lower.contains("context length")
                || (lower.contains("too many") && lower.contains("tokens")) || lower.contains("exceed context limit") {
                return .contextTooLong(message)
            }
            return .invalidRequest(message)
        }
        if type == "timeout_error" || f.status == 408 { return .network("the provider timed out (HTTP \(f.status))") }
        if type == "api_error" || f.status >= 500 { return .server(status: f.status >= 500 ? f.status : 500, message: message) }
        return .invalidRequest(message)
    }
}

// MARK: - Thinking-block memory

/// Signed thinking blocks of recent assistant turns, kept so they can accompany the tool call they preceded when that call
/// is replayed with its result. Bounded; process memory only.
final class ThinkingStore: Sendable {
    struct Stored: Sendable, Hashable {
        var block: JSONValue
        /// Number of text blocks that preceded this thinking block since the previous tool call of the same turn.
        var textBlocksBefore: Int
    }
    private struct State { var byID: [String: [Stored]] = [:]; var order: [String] = [] }
    private let state = Mutex(State())
    private let capacity = 512

    func remember(_ items: [String: [Stored]]) {
        guard !items.isEmpty else { return }
        state.withLock { s in
            for (id, blocks) in items where !blocks.isEmpty {
                if s.byID[id] == nil { s.order.append(id) }
                s.byID[id] = blocks
            }
            while s.order.count > capacity { s.byID[s.order.removeFirst()] = nil }
        }
    }

    func blocks(forToolUse id: String) -> [Stored]? { state.withLock { $0.byID[id] } }

    func forget(toolUseIDs: [String]) {
        state.withLock { s in
            for id in toolUseIDs { s.byID[id] = nil }
            s.order.removeAll { s.byID[$0] == nil }
        }
    }
}

// MARK: - Stream decoding

/// Turns Messages API server-sent events into `LLMStreamEvent`s. Pure state machine: no I/O, fed by tests directly.
struct AnthropicStreamDecoder {
    private enum Block {
        case text
        case tool(ordinal: Int, id: String, name: String, json: String, initial: JSONValue?)
        case thinking(text: String, signature: String)
        case redactedThinking(JSONValue)
        case other
    }
    let model: String
    let scrub: (String) -> String
    private var blocks: [Int: Block] = [:]
    private var usage = TokenUsage()
    private var toolCount = 0
    private var completedTools: [LLMToolUse] = []
    private var brokenTool: String?
    private var stopReason: LLMStopReason?
    private var pendingThinking: [ThinkingStore.Stored] = []
    private var textBlocksInSegment = 0
    private(set) var thinkingByToolUse: [String: [ThinkingStore.Stored]] = [:]
    private(set) var finished = false

    init(model: String, scrub: @escaping (String) -> String = { $0 }) { self.model = model; self.scrub = scrub }

    mutating func handle(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        guard !finished else { return [] }
        guard let json = try? JSONValue.parse(event.data) else {
            throw LLMError.decoding("A stream event was not valid JSON (\(event.event ?? "unnamed")).")
        }
        let type = json["type"]?.stringValue ?? event.event ?? ""
        switch type {
        case "message_start":
            if let u = json["message"]?["usage"] { apply(usage: u) }
            return [.usage(usage)]
        case "content_block_start":
            guard let index = json["index"]?.intValue, let block = json["content_block"] else { return [] }
            switch block["type"]?.stringValue {
            case "text":
                blocks[index] = .text
                textBlocksInSegment += 1
                if let t = block["text"]?.stringValue, !t.isEmpty { return [.textDelta(t)] }
            case "tool_use":
                let id = block["id"]?.stringValue ?? "", name = block["name"]?.stringValue ?? ""
                let initial = block["input"].flatMap { v -> JSONValue? in if case .object(let o) = v, !o.isEmpty { return v }; return nil }
                blocks[index] = .tool(ordinal: toolCount, id: id, name: name, json: "", initial: initial)
                defer { toolCount += 1 }
                return [.toolUseStarted(index: toolCount, id: id, name: name)]
            case "thinking":
                blocks[index] = .thinking(text: block["thinking"]?.stringValue ?? "", signature: block["signature"]?.stringValue ?? "")
            case "redacted_thinking":
                blocks[index] = .redactedThinking(block)
            default:
                blocks[index] = .other // server tools and block types added later are ignored, not errors
            }
            return []
        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"] else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                if let t = delta["text"]?.stringValue, !t.isEmpty { return [.textDelta(t)] }
            case "input_json_delta":
                if case .tool(let ordinal, let id, let name, let acc, let initial) = blocks[index], let part = delta["partial_json"]?.stringValue {
                    blocks[index] = .tool(ordinal: ordinal, id: id, name: name, json: acc + part, initial: initial)
                    if !part.isEmpty { return [.toolUseInputDelta(index: ordinal, partialJSON: part)] }
                }
            case "thinking_delta":
                if case .thinking(let text, let sig) = blocks[index], let t = delta["thinking"]?.stringValue {
                    blocks[index] = .thinking(text: text + t, signature: sig)
                    if !t.isEmpty { return [.reasoningSummaryDelta(t)] }
                }
            case "signature_delta":
                if case .thinking(let text, let sig) = blocks[index], let s = delta["signature"]?.stringValue {
                    blocks[index] = .thinking(text: text, signature: sig + s)
                }
            default: break
            }
            return []
        case "content_block_stop":
            guard let index = json["index"]?.intValue, let block = blocks.removeValue(forKey: index) else { return [] }
            switch block {
            case .tool(_, let id, let name, let acc, let initial):
                let parsed = acc.isEmpty ? (initial ?? .object([:])) : parseToolArguments(acc)
                if let parsed { completedTools.append(LLMToolUse(id: id, name: name, input: parsed)) } else { brokenTool = brokenTool ?? name }
                if !pendingThinking.isEmpty { thinkingByToolUse[id] = pendingThinking; pendingThinking = [] }
                textBlocksInSegment = 0
            case .thinking(let text, let signature):
                // Only signed blocks can be replayed; an unsigned one is dropped.
                if !signature.isEmpty {
                    pendingThinking.append(.init(block: ["type": "thinking", "thinking": .string(text), "signature": .string(signature)],
                                                 textBlocksBefore: textBlocksInSegment))
                }
            case .redactedThinking(let raw):
                pendingThinking.append(.init(block: raw, textBlocksBefore: textBlocksInSegment))
            case .text, .other: break
            }
            return []
        case "message_delta":
            if let u = json["usage"] { apply(usage: u) }
            var out: [LLMStreamEvent] = []
            if let reason = json["delta"]?["stop_reason"]?.stringValue {
                let mapped = Self.stopReason(reason)
                stopReason = mapped
                // Complete tool calls are released only once the stop reason is known: a refused turn's tools must never run.
                if mapped != .refusal { out += completedTools.map(LLMStreamEvent.toolUse) }
                completedTools = []
            }
            out.append(.usage(usage))
            return out
        case "message_stop":
            let reason = stopReason ?? .other
            if let brokenTool, reason != .maxTokens, reason != .refusal {
                throw LLMError.decoding("The model's input for tool \(brokenTool) was not complete JSON; the call was not executed.")
            }
            finished = true
            var out = completedTools.map(LLMStreamEvent.toolUse)
            completedTools = []
            // A cut-off tool call under max_tokens/refusal is dropped, so the turn must not report `toolUse` for it alone.
            out.append(.stop(reason))
            return out
        case "error":
            let err = json["error"]
            let status: Int
            switch err?["type"]?.stringValue {
            case "overloaded_error": status = 529
            case "rate_limit_error": status = 429
            case "authentication_error": status = 401
            case "permission_error": status = 403
            case "not_found_error": status = 404
            case "invalid_request_error": status = 400
            case "timeout_error": status = 408
            default: status = 500
            }
            throw AnthropicProvider.mapFailure(ProviderFailure(status: status, json: json), model: model, scrub: scrub)
        default:
            return [] // ping and event types added later
        }
    }

    private mutating func apply(usage u: JSONValue) {
        if let v = u["input_tokens"]?.intValue { usage.inputTokens = v }
        if let v = u["output_tokens"]?.intValue { usage.outputTokens = v }
        if let v = u["cache_read_input_tokens"]?.intValue { usage.cacheReadTokens = v }
        if let v = u["cache_creation_input_tokens"]?.intValue { usage.cacheWriteTokens = v }
    }

    static func stopReason(_ raw: String) -> LLMStopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        case "stop_sequence": return .stopSequence
        case "refusal": return .refusal
        default: return .other // pause_turn, model_context_window_exceeded, values added later
        }
    }
}
