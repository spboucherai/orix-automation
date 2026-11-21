// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Tests/ORIXProviderAdaptersTests/FixtureAnthropicTests.swift
// Description: Mocked tests of the Anthropic adapter against sanitized, recorded-shape SSE transcripts: streaming, tools, usage, caching, structured output, thinking continuity, errors.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Testing
import Foundation
import ORIXCore
@testable import ORIXProviderAdapters

@Suite("Fixture Anthropic adapter (mocked network)")
struct FixtureAnthropicTests {
    func provider(_ server: StubServer, options: AnthropicOptions = .init()) -> AnthropicProvider {
        AnthropicProvider(apiKey: fixtureKey, session: server.session, baseURL: server.baseURL, options: options)
    }

    static let textTranscript = anthropicSSE([
        ("message_start", #"{"type":"message_start","message":{"id":"msg_fixture_01","type":"message","role":"assistant","content":[],"model":"claude-haiku-5-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":12,"cache_creation_input_tokens":300,"cache_read_input_tokens":2000,"output_tokens":1}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        ("ping", #"{"type":"ping"}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bonjour"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", monde — ✓"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ])

    static let toolTranscript = anthropicSSE([
        ("message_start", #"{"type":"message_start","message":{"id":"msg_fixture_02","type":"message","role":"assistant","content":[],"model":"claude-haiku-5-5","stop_reason":null,"usage":{"input_tokens":400,"output_tokens":2}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking."}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_fixture_01","name":"get_weather","input":{}}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"ci"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ty\": \"Qué"}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"bec\"}"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":41}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ])

    @Test func streamsTextWithUsageAndSendsTheRightRequest() async {
        let server = StubServer().sse(Self.textTranscript, chunkSize: 17)
        let (events, error) = await collect(provider(server).stream(LLMRequest(model: "claude-haiku-5-5", system: "Be brief.",
                                                                               messages: [.user("Salut")], maxOutputTokens: 16, temperature: 0.2)))
        #expect(error == nil)
        #expect(events.text == "Bonjour, monde — ✓")
        #expect(events.stop == .endTurn)
        #expect(events.lastUsage == TokenUsage(inputTokens: 12, outputTokens: 9, cacheReadTokens: 2000, cacheWriteTokens: 300))
        #expect(events.last == .stop(.endTurn))

        let req = server.requests[0]
        #expect(req.method == "POST" && req.path == "/v1/messages")
        #expect(req.header("x-api-key") == fixtureKey)
        #expect(req.header("anthropic-version") == "2026-10-21")
        #expect(req.body?["model"] == "claude-haiku-5-5")
        #expect(req.body?["max_tokens"] == 16)
        #expect(req.body?["stream"] == true)
        #expect(req.body?["system"] == "Be brief.")
        #expect(req.body?["temperature"] == nil, "sampling parameters are rejected on API version 2026-10-21")
        #expect(req.body?["messages"] == [["role": "user", "content": [["type": "text", "text": "Salut"]]]])
        #expect(req.body?["tools"] == nil && req.body?["tool_choice"] == nil)
    }

    @Test func assemblesAToolCallFromSplitJSONDeltas() async {
        let server = StubServer().sse(Self.toolTranscript, chunkSize: 5)
        let (events, error) = await collect(provider(server).stream(LLMRequest(model: "claude-haiku-5-5", messages: [.user("Météo ?")], tools: [weatherTool])))
        #expect(error == nil)
        #expect(events.text == "Checking.")
        #expect(events.started == ["0:toolu_fixture_01:get_weather"])
        #expect(events.inputDeltas == ["{\"ci", "ty\": \"Qué", "bec\"}"])
        #expect(events.toolUses == [LLMToolUse(id: "toolu_fixture_01", name: "get_weather", input: ["city": "Québec"])])
        #expect(events.stop == .toolUse)
        #expect(events.lastUsage?.outputTokens == 41)
    }

    @Test func parallelToolCallsKeepTheirOrderAndOrdinals() async {
        let transcript = anthropicSSE([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_fixture_a","name":"get_weather","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Paris\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_fixture_b","name":"get_weather","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"Lyon\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_fixture_c","name":"no_args","input":{}}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":60}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let server = StubServer().sse(transcript)
        let response = try? await provider(server).complete(LLMRequest(model: "claude-haiku-5-5", messages: [.user("x")], tools: [weatherTool]))
        #expect(response?.toolUses.map(\.id) == ["toolu_fixture_a", "toolu_fixture_b", "toolu_fixture_c"])
        #expect(response?.toolUses.map(\.input) == [["city": "Paris"], ["city": "Lyon"], [:]])
        #expect(response?.stopReason == .toolUse)
    }

    @Test func encodesToolsToolResultsSystemCachingAndImages() {
        let p = provider(StubServer())
        let request = LLMRequest(
            model: "claude-haiku-5-5", system: "You are ORIX.",
            messages: [
                .user("Weather?"),
                LLMMessage(role: .assistant, content: [.text("Looking."), .toolUse(LLMToolUse(id: "toolu_fixture_01", name: "get_weather", input: ["city": "Paris"]))]),
                LLMMessage(role: .user, content: [.text("and this picture"), .image(base64: "AAAA", mediaType: "image/png"),
                                                  .toolResult(toolUseID: "toolu_fixture_01", content: "boom", isError: true)]),
                .user("merged into the same user turn"),
            ],
            tools: [weatherTool, LLMToolSpec(name: "second", description: "Second tool.", inputSchema: .object([:]))],
            toolChoice: .tool(name: "get_weather"), maxOutputTokens: 64, cacheSystemAndTools: true)
        let body = p.requestBody(for: request).body

        #expect(body["system"] == [["type": "text", "text": "You are ORIX.", "cache_control": ["type": "ephemeral"]]])
        let tools = body["tools"]?.arrayValue ?? []
        #expect(tools.count == 2)
        #expect(tools[0]["name"] == "get_weather" && tools[0]["input_schema"] == weatherTool.inputSchema.raw)
        #expect(tools[0]["eager_input_streaming"] == true)
        #expect(tools[0]["cache_control"] == nil && tools[1]["cache_control"] == ["type": "ephemeral"], "one breakpoint, on the last tool")
        #expect(body["tool_choice"] == ["type": "tool", "name": "get_weather"])

        let messages = body["messages"]?.arrayValue ?? []
        #expect(messages.count == 3, "consecutive user messages are merged")
        #expect(messages[1] == ["role": "assistant", "content": [["type": "text", "text": "Looking."],
                                                                 ["type": "tool_use", "id": "toolu_fixture_01", "name": "get_weather", "input": ["city": "Paris"]]]])
        let user = messages[2]["content"]?.arrayValue ?? []
        #expect(user.first == ["type": "tool_result", "tool_use_id": "toolu_fixture_01", "content": "boom", "is_error": true], "tool results come first")
        #expect(user[1] == ["type": "text", "text": "and this picture"])
        #expect(user[2] == ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]])
        #expect(user[3] == ["type": "text", "text": "merged into the same user turn"])
    }

    @Test func mapsToolChoiceIncludingModelsThatRejectForcedCalls() {
        let p = provider(StubServer())
        func body(_ model: String, _ choice: LLMToolChoice, system: String? = nil) -> JSONValue {
            p.requestBody(for: LLMRequest(model: model, system: system, messages: [.user("x")], tools: [weatherTool], toolChoice: choice)).body
        }
        #expect(body("claude-haiku-5-5", .auto)["tool_choice"] == ["type": "auto"])
        #expect(body("claude-haiku-5-5", .none)["tool_choice"] == ["type": "none"])
        #expect(body("claude-haiku-5-5", .required)["tool_choice"] == ["type": "any"])
        #expect(body("claude-haiku-4-5-20251001", .tool(name: "get_weather"))["tool_choice"] == ["type": "tool", "name": "get_weather"])

        // Claude Opus 5.5 answers 400 to forced tool use: auto + an explicit instruction, placed after the caller's system prompt.
        let forced = body("claude-opus-5-5", .tool(name: "get_weather"), system: "Base.")
        #expect(forced["tool_choice"] == ["type": "auto"])
        let system = forced["system"]?.arrayValue ?? []
        #expect(system.count == 2 && system[0]["text"] == "Base.")
        #expect(system[1]["text"]?.stringValue?.contains("`get_weather`") == true)
        #expect(body("claude-sonnet-5-5", .required)["system"]?.stringValue?.contains("calling one of the provided tools") == true)
    }

    @Test func structuredOutputUsesOutputConfigWithASanitizedSchema() {
        let schema = JSONSchema.object(["name": .string(), "age": .integer(minimum: 0, maximum: 150),
                                        "tags": .array(of: .object(["k": .string()], required: ["k"]))], required: ["name", "age"])
        let body = provider(StubServer(), options: .init(thinking: .disabled, effort: "low"))
            .requestBody(for: LLMRequest(model: "claude-haiku-5-5", messages: [.user("x")], responseSchema: schema)).body
        let format = body["output_config"]?["format"]
        #expect(format?["type"] == "json_schema")
        #expect(format?["schema"]?["additionalProperties"] == false)
        #expect(format?["schema"]?["required"] == ["age", "name"])
        #expect(format?["schema"]?["properties"]?["age"] == ["type": "integer"], "numeric bounds are not accepted by the API and are removed")
        #expect(format?["schema"]?["properties"]?["tags"]?["items"]?["additionalProperties"] == false)
        #expect(body["output_config"]?["effort"] == "low")
        #expect(body["thinking"] == ["type": "disabled"])
        // A model that rejects disabled thinking gets no thinking field at all.
        let opus = provider(StubServer(), options: .init(thinking: .disabled)).requestBody(for: LLMRequest(model: "claude-opus-5-5", messages: [.user("x")])).body
        #expect(opus["thinking"] == nil)
        let adaptive = provider(StubServer(), options: .init(thinking: .adaptive(summarized: true))).requestBody(for: LLMRequest(model: "claude-opus-5-5", messages: [.user("x")])).body
        #expect(adaptive["thinking"] == ["type": "adaptive", "display": "summarized"])
    }

    static let thinkingToolTranscript = anthropicSSE([
        ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":50,"output_tokens":1}}}"#),
        ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user wants "}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"the weather."}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"FIXTURESIGNATURE=="}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
        ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_fixture_t1","name":"get_weather","input":{}}}"#),
        ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Oslo\"}"}}"#),
        ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":70}}"#),
        ("message_stop", #"{"type":"message_stop"}"#),
    ])

    @Test func thinkingBlocksAreSummarizedThenReplayedWithTheToolResult() async throws {
        let server = StubServer().sse(Self.thinkingToolTranscript).sse(Self.textTranscript)
        let p = provider(server)
        let first = LLMRequest(model: "claude-haiku-5-5", messages: [.user("Weather in Oslo?")], tools: [weatherTool])
        var seen: [LLMStreamEvent] = []
        for try await e in p.stream(first) { seen.append(e) }
        #expect(seen.reasoning == "The user wants the weather.")
        let call = try #require(seen.toolUses.first)

        // The runtime replays the turn using Core content only (no thinking block exists in LLMContent).
        let second = LLMRequest(model: "claude-haiku-5-5", messages: first.messages + [
            LLMMessage(role: .assistant, content: [.toolUse(call)]),
            LLMMessage(role: .user, content: [.toolResult(toolUseID: call.id, content: "4°C", isError: false)]),
        ], tools: [weatherTool])
        _ = try await p.complete(second)
        let assistant = server.requests[1].body?["messages"]?[1]?["content"]?.arrayValue ?? []
        #expect(assistant.count == 2)
        #expect(assistant[0] == ["type": "thinking", "thinking": "The user wants the weather.", "signature": "FIXTURESIGNATURE=="],
                "the signed thinking block is passed back unchanged, before its tool call")
        #expect(assistant[1]["type"] == "tool_use")
    }

    @Test func rejectedThinkingBlockIsDroppedAndTheRequestSentOnceMore() async throws {
        let rejection = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation."}}"#
        let server = StubServer().sse(Self.thinkingToolTranscript).json(400, rejection).sse(Self.textTranscript)
        let p = provider(server)
        let first = LLMRequest(model: "claude-haiku-5-5", messages: [.user("Weather in Oslo?")], tools: [weatherTool])
        let call = try #require(try await p.complete(first).toolUses.first)
        let second = LLMRequest(model: "claude-haiku-5-5", messages: first.messages + [
            LLMMessage(role: .assistant, content: [.toolUse(call)]),
            LLMMessage(role: .user, content: [.toolResult(toolUseID: call.id, content: "4°C", isError: false)]),
        ], tools: [weatherTool])
        let response = try await p.complete(second)
        #expect(response.text == "Bonjour, monde — ✓")
        #expect(server.requests.count == 3)
        #expect(server.requests[1].body?["messages"]?[1]?["content"]?.arrayValue?.count == 2)
        #expect(server.requests[2].body?["messages"]?[1]?["content"]?.arrayValue?.map { $0["type"] } == ["tool_use"], "retry carries no thinking block")
        // A 400 that is not about thinking is never retried.
        let other = StubServer().json(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: must be positive"}}"#)
        let (_, error) = await collect(provider(other).stream(second))
        #expect(error == .invalidRequest("max_tokens: must be positive"))
        #expect(other.requests.count == 1)
    }

    @Test func refusalStopsWithoutReleasingToolCalls() async {
        let transcript = anthropicSSE([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_fixture_r","name":"get_weather","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"X\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":null}},"usage":{"output_tokens":12}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let (events, error) = await collect(provider(StubServer().sse(transcript)).stream(LLMRequest(model: "claude-opus-5", messages: [.user("x")], tools: [weatherTool])))
        #expect(error == nil)
        #expect(events.stop == .refusal)
        #expect(events.toolUses.isEmpty, "a refused turn's tool calls must never be executable")
    }

    @Test func truncatedToolInputIsDroppedUnderMaxTokensAndAnErrorOtherwise() async {
        func transcript(stop: String) -> String {
            anthropicSSE([
                ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}"#),
                ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_fixture_x","name":"get_weather","input":{}}}"#),
                ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Mon"}}"#),
                ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
                ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stop)"},"usage":{"output_tokens":64}}"#),
                ("message_stop", #"{"type":"message_stop"}"#),
            ])
        }
        let request = LLMRequest(model: "claude-haiku-5-5", messages: [.user("x")], tools: [weatherTool])
        let cut = await collect(provider(StubServer().sse(transcript(stop: "max_tokens"))).stream(request))
        #expect(cut.error == nil && cut.events.toolUses.isEmpty && cut.events.stop == .maxTokens)
        let broken = await collect(provider(StubServer().sse(transcript(stop: "tool_use"))).stream(request))
        #expect(broken.events.toolUses.isEmpty && broken.events.stop == nil)
        if case .decoding(let m) = broken.error { #expect(m.contains("get_weather")) } else { Issue.record("expected a decoding error, got \(String(describing: broken.error))") }
    }

    @Test(arguments: [
        (401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, LLMError.authentication("invalid x-api-key")),
        (403, #"{"type":"error","error":{"type":"permission_error","message":"Your API key does not have permission"}}"#, LLMError.authentication("Your API key does not have permission")),
        (404, #"{"type":"error","error":{"type":"not_found_error","message":"model: claude-nope"}}"#, LLMError.modelNotFound("claude-nope — model: claude-nope")),
        (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, LLMError.overloaded),
        (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 1200000 tokens > 1000000 maximum"}}"#, LLMError.contextTooLong("prompt is too long: 1200000 tokens > 1000000 maximum")),
        (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"messages: roles must alternate"}}"#, LLMError.invalidRequest("messages: roles must alternate")),
        (500, #"{"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#, LLMError.server(status: 500, message: "Internal server error")),
        (503, "upstream connect error", LLMError.server(status: 503, message: "upstream connect error")),
        (402, #"{"type":"error","error":{"type":"billing_error","message":"Credit balance too low"}}"#, LLMError.invalidRequest("Billing problem on the provider account. Credit balance too low")),
    ] as [(Int, String, LLMError)])
    func mapsHTTPErrors(status: Int, body: String, expected: LLMError) async {
        let server = StubServer().json(status, body)
        let (events, error) = await collect(provider(server).stream(LLMRequest(model: "claude-nope", messages: [.user("x")])))
        #expect(events.isEmpty)
        #expect(error == expected)
    }

    @Test func rateLimitCarriesRetryAfterAndASpendCapIsNotRetryable() async {
        let limited = StubServer().json(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"Too many requests"}}"#, headers: ["retry-after": "7"])
        let a = await collect(provider(limited).stream(LLMRequest(model: "claude-haiku-5-5", messages: [.user("x")])))
        #expect(a.error == .rateLimited(retryAfterSeconds: 7))
        #expect(a.error?.isRetryable == true)
        let capped = StubServer().json(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"Limit reached","details":{"error_code":"enforced_spend_limit_reached"}}}"#)
        let b = await collect(provider(capped).stream(LLMRequest(model: "claude-haiku-5-5", messages: [.user("x")])))
        #expect(b.error?.isRetryable == false)
    }

    @Test func midStreamErrorEventDisconnectAndEarlyEndAreTypedErrors() async {
        let head = anthropicSSE([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}"#),
        ])
        let request = LLMRequest(model: "claude-haiku-5-5", messages: [.user("x")])
        let overloaded = await collect(provider(StubServer().sse(head + anthropicSSE([("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)]))).stream(request))
        #expect(overloaded.events.text == "partial" && overloaded.error == .overloaded)

        let dropped = await collect(provider(StubServer().sse(head, failure: .networkConnectionLost)).stream(request))
        #expect(dropped.events.text == "partial")
        if case .network = dropped.error {} else { Issue.record("expected a network error, got \(String(describing: dropped.error))") }
        #expect(dropped.events.stop == nil, "no stop event is invented for an interrupted stream")

        let early = await collect(provider(StubServer().sse(head)).stream(request))
        #expect(early.error == .network("The response stream ended before the message was complete."))

        let canceled = await collect(provider(StubServer().enqueue(.init(failure: .cancelled))).stream(request))
        #expect(canceled.error == .canceled)
    }

    @Test func unknownEventsAndBlockTypesAreIgnored() async {
        let transcript = anthropicSSE([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":3,"output_tokens":1}}}"#),
            ("future_event", #"{"type":"future_event","payload":{"x":1}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_fixture","name":"web_search","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"q\":1}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ok"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"future_delta","x":1}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"pause_turn"},"usage":{"output_tokens":5}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let (events, error) = await collect(provider(StubServer().sse(transcript)).stream(LLMRequest(model: "claude-haiku-5-5", messages: [.user("x")])))
        #expect(error == nil && events.text == "ok" && events.toolUses.isEmpty && events.stop == .other)
    }

    @Test func listsModelsAcrossPagesAndMergesRegistryPrices() async throws {
        let server = StubServer()
            .json(200, #"{"data":[{"type":"model","id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","created_at":"2026-01-01T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000,"capabilities":{"image_input":{"supported":true},"structured_outputs":{"supported":true}}}],"has_more":true,"first_id":"claude-haiku-5-5","last_id":"claude-haiku-5-5"}"#)
            .json(200, #"{"data":[{"type":"model","id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5"},{"type":"model","id":"claude-future-9","display_name":"Claude Future 9","max_input_tokens":5,"capabilities":{"image_input":{"supported":false},"structured_outputs":{"supported":false}}}],"has_more":false,"last_id":"claude-future-9"}"#)
        let models = try await provider(server).listModels()
        #expect(models.map(\.id) == ["claude-haiku-5-5", "claude-haiku-4-5-20251001", "claude-future-9"])
        #expect(server.requests[0].path == "/v1/models" && server.requests[1].query?.contains("after_id=claude-haiku-5-5") == true)
        #expect(models[0].inputPricePerMTok == 0.10 && models[0].outputPricePerMTok == 0.50 && models[0].contextWindow == 1_000_000)
        #expect(models[0].supportsVision && models[0].supportsStructuredOutput && models[0].source == "api")
        #expect(models[1].inputPricePerMTok == 1 && models[1].contextWindow == 200_000 && models[1].maxOutputTokens == 64_000, "dated snapshot ids resolve to the registry entry")
        #expect(models[2].inputPricePerMTok == nil && models[2].outputPricePerMTok == nil, "an unknown model has no invented price")
        #expect(models[2].contextWindow == 5 && !models[2].supportsVision)
        let (failed, _) = (try? await provider(StubServer().json(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)).listModels(), 0)
        #expect(failed == nil)
    }

    @Test func theAPIKeyNeverAppearsInErrorsOrDescriptions() async {
        let echo = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key: \#(fixtureKey) (also Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345)"}}"#
        let p = provider(StubServer().json(401, echo))
        let (_, error) = await collect(p.stream(LLMRequest(model: "claude-haiku-5-5", messages: [.user("x")])))
        let rendered = "\(String(describing: error)) \(error?.errorDescription ?? "") \(error?.localizedDescription ?? "")"
        #expect(!rendered.contains(fixtureKey) && !rendered.contains("abcdefghijklmnopqrstuvwxyz012345"))
        #expect(rendered.contains(Redactor.placeholder))
        var dumped = ""
        dump(p, to: &dumped)
        #expect(!"\(p) \(String(reflecting: p)) \(dumped)".contains(fixtureKey))
        #expect(Redactor.shared.redact("key=\(fixtureKey)").contains(fixtureKey) == false, "the key is registered with the shared redactor at init")
    }
}
