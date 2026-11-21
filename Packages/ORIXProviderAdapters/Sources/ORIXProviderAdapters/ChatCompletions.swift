// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/ChatCompletions.swift
// Description      : The Chat Completions wire format shared by the OpenAI and
//                    OpenRouter adapters: request encoding and streamed-chunk
//                    decoding (tool calls assembled by index, usage, mid-stream
//                    errors).
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

/// Request encoding for `POST …/chat/completions`.
enum ChatCompletionsEncoder {
    struct Dialect {
        /// `max_completion_tokens` (OpenAI; `max_tokens` is deprecated there) or `max_tokens` (accepted by every OpenRouter model).
        var maxTokensField: String
        var includeTemperature: Bool
        /// Mark the system prompt with `cache_control` (OpenRouter passes it to providers with explicit caching).
        var explicitCacheControl: Bool
        var extra: [String: JSONValue] = [:]
    }

    static func body(for request: LLMRequest, dialect: Dialect) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": true,
            // Ask for the usage chunk that closes the stream.
            "stream_options": ["include_usage": true],
            dialect.maxTokensField: .int(max(1, request.maxOutputTokens)),
        ]
        var messages: [JSONValue] = []
        if let system = request.system, !system.isEmpty {
            if dialect.explicitCacheControl {
                messages.append(["role": "system", "content": [["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]]])
            } else {
                messages.append(["role": "system", "content": .string(system)])
            }
        }
        for m in request.messages { messages += encode(m) }
        body["messages"] = .array(messages)

        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { t in
                ["type": "function", "function": ["name": .string(t.name), "description": .string(t.description), "parameters": t.inputSchema.raw]]
            })
            switch request.toolChoice {
            case .auto: body["tool_choice"] = "auto"
            case .none: body["tool_choice"] = "none"
            case .required: body["tool_choice"] = "required"
            case .tool(let name): body["tool_choice"] = ["type": "function", "function": ["name": .string(name)]]
            }
        }
        if dialect.includeTemperature, let t = request.temperature { body["temperature"] = .number(t) }
        if let schema = request.responseSchema {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": "orix_response", "strict": true, "schema": schema.raw]]
        }
        for (k, v) in dialect.extra { body[k] = v }
        return .object(body)
    }

    /// One Core message can become several wire messages: each tool result is its own `role: "tool"` message, and they
    /// must directly follow the assistant message that made the calls, so they are emitted before any other user content.
    static func encode(_ m: LLMMessage) -> [JSONValue] {
        switch m.role {
        case .assistant:
            let text = m.text
            let calls: [JSONValue] = m.toolUses.map { u in
                let input: JSONValue = { if case .object = u.input { return u.input }; return .object([:]) }()
                return ["id": .string(u.id), "type": "function", "function": ["name": .string(u.name), "arguments": .string(input.serialized())]]
            }
            if text.isEmpty && calls.isEmpty { return [] }
            return [.obj([("role", "assistant"), ("content", text.isEmpty ? .null : .string(text)), ("tool_calls", calls.isEmpty ? Optional<JSONValue>.none : Optional(JSONValue.array(calls)))])]
        case .user:
            var out: [JSONValue] = []
            var parts: [JSONValue] = []
            var onlyText = true
            for c in m.content {
                switch c {
                case .toolResult(let id, let content, let isError):
                    // The format has no error flag for tool results; say so in the content so the model can react.
                    out.append(["role": "tool", "tool_call_id": .string(id), "content": .string(isError ? "[tool error] " + content : content)])
                case .text(let t): if !t.isEmpty { parts.append(["type": "text", "text": .string(t)]) }
                case .image(let b64, let mediaType):
                    onlyText = false
                    parts.append(["type": "image_url", "image_url": ["url": .string("data:\(mediaType);base64,\(b64)")]])
                case .toolUse: break
                }
            }
            if !parts.isEmpty {
                if onlyText { out.append(["role": "user", "content": .string(parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n"))]) }
                else { out.append(["role": "user", "content": .array(parts)]) }
            }
            return out
        }
    }
}

/// Decodes `chat.completion.chunk` events. Pure state machine: no I/O.
struct ChatCompletionsDecoder {
    private struct PendingCall { var id = ""; var name = ""; var arguments = ""; var started = false }

    let model: String
    /// Maps an error object found inside the stream (OpenRouter mid-stream errors, OpenAI error events) to `LLMError`.
    let mapStreamError: (ProviderFailure) -> LLMError
    /// OpenRouter reports the request cost in `usage.cost`.
    let readsCost: Bool

    private var calls: [Int: PendingCall] = [:]
    private var finishReason: String?
    private var sawRefusal = false
    private var emittedTools = false
    private var hadToolCalls = false
    private var droppedTool: String?
    private(set) var finished = false

    init(model: String, readsCost: Bool, mapStreamError: @escaping (ProviderFailure) -> LLMError) {
        self.model = model; self.readsCost = readsCost; self.mapStreamError = mapStreamError
    }

    var sawFinishReason: Bool { finishReason != nil }

    mutating func handle(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        guard !finished else { return [] }
        let data = event.data.trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return try finish() }
        guard let json = try? JSONValue.parse(data) else { throw LLMError.decoding("A stream chunk was not valid JSON.") }
        if let err = json["error"], !err.isNull {
            let status = err["code"]?.intValue ?? err["code"]?.stringValue.flatMap(Int.init) ?? 500
            throw mapStreamError(ProviderFailure(status: status, json: json))
        }
        var out: [LLMStreamEvent] = []
        if let choice = json["choices"]?[0] {
            let delta = choice["delta"]
            if let reasoning = delta?["reasoning"]?.stringValue, !reasoning.isEmpty { out.append(.reasoningSummaryDelta(reasoning)) }
            if let text = delta?["content"]?.stringValue, !text.isEmpty { out.append(.textDelta(text)) }
            if let refusal = delta?["refusal"]?.stringValue, !refusal.isEmpty { sawRefusal = true; out.append(.textDelta(refusal)) }
            for call in delta?["tool_calls"]?.arrayValue ?? [] {
                let index = call["index"]?.intValue ?? 0
                var p = calls[index] ?? PendingCall()
                if let id = call["id"]?.stringValue, !id.isEmpty { p.id = id }
                if let name = call["function"]?["name"]?.stringValue, !name.isEmpty { p.name = name }
                if !p.started, !p.id.isEmpty, !p.name.isEmpty {
                    p.started = true
                    out.append(.toolUseStarted(index: index, id: p.id, name: p.name))
                }
                if let args = call["function"]?["arguments"]?.stringValue, !args.isEmpty {
                    p.arguments += args
                    if p.started { out.append(.toolUseInputDelta(index: index, partialJSON: args)) }
                }
                calls[index] = p
            }
            if let reason = choice["finish_reason"]?.stringValue {
                if reason == "error" { throw mapStreamError(ProviderFailure(status: 502, json: json, text: "The provider ended the stream with an error.")) }
                finishReason = reason
                out += try releaseTools()
            }
        }
        if let usage = json["usage"], !usage.isNull { out.append(.usage(decode(usage: usage))) }
        return out
    }

    /// Call when the HTTP stream ends without `[DONE]`. A stream that already carried a finish reason is complete.
    mutating func endOfStream() throws -> [LLMStreamEvent] {
        guard !finished else { return [] }
        guard finishReason != nil else { throw LLMError.network("The response stream ended before the completion was finished.") }
        return try finish()
    }

    private mutating func finish() throws -> [LLMStreamEvent] {
        guard finishReason != nil else { throw LLMError.network("The response stream ended before the completion was finished.") }
        var out = try releaseTools()
        finished = true
        out.append(.stop(stopReason()))
        return out
    }

    /// Parses the assembled calls in index order, once. A call cut off by the output limit is dropped; any other
    /// incomplete JSON is a decoding error (the adapter never repairs tool input).
    private mutating func releaseTools() throws -> [LLMStreamEvent] {
        guard !emittedTools else { return [] }
        emittedTools = true
        var out: [LLMStreamEvent] = []
        for index in calls.keys.sorted() {
            guard let p = calls[index], !p.name.isEmpty else { continue }
            hadToolCalls = true
            guard let input = parseToolArguments(p.arguments) else {
                if finishReason == "length" || finishReason == "content_filter" { droppedTool = p.name; continue }
                throw LLMError.decoding("The model's arguments for tool \(p.name) were not complete JSON; the call was not executed.")
            }
            // Some OpenRouter upstreams omit the id; the tool result needs one, so derive a stable one from the position.
            out.append(.toolUse(LLMToolUse(id: p.id.isEmpty ? "call_\(index)" : p.id, name: p.name, input: input)))
        }
        return out
    }

    private func stopReason() -> LLMStopReason {
        if sawRefusal { return .refusal }
        switch finishReason {
        case "length": return .maxTokens
        case "content_filter": return .contentFilter
        case "tool_calls", "function_call": return .toolUse
        case "stop": return hadToolCalls && droppedTool == nil ? .toolUse : .endTurn
        default: return .other
        }
    }

    private func decode(usage u: JSONValue) -> TokenUsage {
        let prompt = u["prompt_tokens"]?.intValue ?? 0
        let cached = u["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? 0
        let written = u["prompt_tokens_details"]?["cache_write_tokens"]?.intValue ?? 0
        // `prompt_tokens` includes cached tokens here; Core counts them separately.
        return TokenUsage(inputTokens: max(0, prompt - cached - written), outputTokens: u["completion_tokens"]?.intValue ?? 0,
                          cacheReadTokens: cached, cacheWriteTokens: written,
                          reportedCostUSD: readsCost ? u["cost"]?.doubleValue : nil)
    }
}

/// Shared stream loop for both Chat Completions adapters.
func runChatCompletionsStream(bytes: URLSession.AsyncBytes, decoder: inout ChatCompletionsDecoder,
                              continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) async throws {
    var parser = SSEParser()
    var sawEvent = false
    var raw = Data()
    for try await byte in bytes {
        // Until the first SSE event, keep the raw body: a 200 answer can be a plain JSON error object instead of a stream.
        if !sawEvent, raw.count < Transport.maxErrorBodyBytes { raw.append(byte) }
        guard let event = parser.consume(byte) else { continue }
        sawEvent = true
        for out in try decoder.handle(event) { continuation.yield(out) }
        if decoder.finished { return }
    }
    if !sawEvent, let json = try? JSONValue.parse(raw), json["error"] != nil {
        for out in try decoder.handle(SSEEvent(data: String(decoding: raw, as: UTF8.self))) { continuation.yield(out) }
    }
    for out in try decoder.endOfStream() { continuation.yield(out) }
}
