// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Tests/ORIXProviderAdaptersTests/FixtureOpenAITests.swift
// Description: Mocked tests of the OpenAI adapter (Chat Completions) against sanitized, recorded-shape SSE transcripts: streaming, tool calls by index, usage, structured outputs, temperature handling, errors.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Testing
import Foundation
import ORIXCore
@testable import ORIXProviderAdapters

@Suite("Fixture OpenAI adapter (mocked network)")
struct FixtureOpenAITests {
    func provider(_ server: StubServer, options: OpenAIOptions = .init()) -> OpenAIProvider {
        OpenAIProvider(apiKey: fixtureKey, session: server.session, baseURL: server.baseURL.appendingPathComponent("v1"), options: options)
    }

    static func chunk(_ delta: String, finish: String? = nil) -> String {
        #"{"id":"chatcmpl-fixture","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish.map { "\"\($0)\"" } ?? "null")}],"usage":null}"#
    }
    static let usageChunk = #"{"id":"chatcmpl-fixture","object":"chat.completion.chunk","created":1,"model":"gpt-4o-mini","choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":7,"total_tokens":1207,"prompt_tokens_details":{"cached_tokens":1024,"audio_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}"#

    static let textTranscript = chatSSE([
        chunk(#"{"role":"assistant","content":"","refusal":null}"#),
        chunk(#"{"content":"Hello"}"#),
        chunk(#"{"content":" wörld"}"#),
        chunk("{}", finish: "stop"),
        usageChunk,
    ])

    @Test func streamsTextAndReadsUsageFromTheFinalChunk() async {
        let server = StubServer().sse(Self.textTranscript, chunkSize: 13)
        let request = LLMRequest(model: "gpt-4o-mini", system: "Be brief.", messages: [.user("Hi")], maxOutputTokens: 16, temperature: 0.3)
        let (events, error) = await collect(provider(server, options: .init(organization: "org-fixture")).stream(request))
        #expect(error == nil)
        #expect(events.text == "Hello wörld")
        #expect(events.lastUsage == TokenUsage(inputTokens: 176, outputTokens: 7, cacheReadTokens: 1024), "cached prompt tokens are counted apart from uncached input")
        #expect(events.suffix(2) == [.usage(events.lastUsage!), .stop(.endTurn)])

        let req = server.requests[0]
        #expect(req.method == "POST" && req.path == "/v1/chat/completions")
        #expect(req.header("Authorization") == "Bearer \(fixtureKey)")
        #expect(req.header("OpenAI-Organization") == "org-fixture")
        #expect(req.body?["max_completion_tokens"] == 16 && req.body?["max_tokens"] == nil)
        #expect(req.body?["stream"] == true && req.body?["stream_options"] == ["include_usage": true])
        #expect(req.body?["temperature"] == .number(0.3))
        #expect(req.body?["messages"] == [["role": "system", "content": "Be brief."], ["role": "user", "content": "Hi"]])
    }

    @Test func assemblesParallelToolCallsByIndexFromInterleavedDeltas() async {
        let transcript = chatSSE([
            Self.chunk(#"{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_fixture_a","type":"function","function":{"name":"get_weather","arguments":""}}]}"#),
            Self.chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"{\"ci"}}]}"#),
            Self.chunk(#"{"tool_calls":[{"index":1,"id":"call_fixture_b","type":"function","function":{"name":"get_weather","arguments":"{\"city\":"}}]}"#),
            Self.chunk(#"{"tool_calls":[{"index":0,"function":{"arguments":"ty\":\"Paris\"}"}},{"index":1,"function":{"arguments":"\"Lyon\"}"}}]}"#),
            Self.chunk("{}", finish: "tool_calls"),
            Self.usageChunk,
        ])
        let (events, error) = await collect(provider(StubServer().sse(transcript, chunkSize: 9)).stream(LLMRequest(model: "gpt-4o-mini", messages: [.user("x")], tools: [weatherTool])))
        #expect(error == nil)
        #expect(events.started == ["0:call_fixture_a:get_weather", "1:call_fixture_b:get_weather"])
        #expect(events.inputDeltas == ["{\"ci", "{\"city\":", "ty\":\"Paris\"}", "\"Lyon\"}"])
        #expect(events.toolUses == [LLMToolUse(id: "call_fixture_a", name: "get_weather", input: ["city": "Paris"]),
                                    LLMToolUse(id: "call_fixture_b", name: "get_weather", input: ["city": "Lyon"])])
        #expect(events.stop == .toolUse)
    }

    @Test func encodesToolsToolResultsImagesAndStrictStructuredOutput() {
        let schema = JSONSchema.object(["answer": .string()], required: ["answer"])
        let request = LLMRequest(
            model: "gpt-4o-mini", system: "S",
            messages: [
                .user("Weather?"),
                LLMMessage(role: .assistant, content: [.text("Looking."), .toolUse(LLMToolUse(id: "call_fixture_a", name: "get_weather", input: ["city": "Paris"])),
                                                       .toolUse(LLMToolUse(id: "call_fixture_b", name: "get_weather", input: ["city": "Lyon"]))]),
                LLMMessage(role: .user, content: [.text("thanks"), .toolResult(toolUseID: "call_fixture_a", content: "12°C", isError: false),
                                                  .toolResult(toolUseID: "call_fixture_b", content: "timeout", isError: true)]),
                LLMMessage(role: .user, content: [.text("look"), .image(base64: "AAAA", mediaType: "image/jpeg")]),
            ],
            tools: [weatherTool], toolChoice: .tool(name: "get_weather"), maxOutputTokens: 64, responseSchema: schema, cacheSystemAndTools: true)
        let body = provider(StubServer(), options: .init(reasoningEffort: "low")).requestBody(for: request)

        #expect(body["tools"] == [["type": "function", "function": ["name": "get_weather", "description": "Returns the weather for a city.", "parameters": weatherTool.inputSchema.raw]]])
        #expect(body["tool_choice"] == ["type": "function", "function": ["name": "get_weather"]])
        #expect(body["response_format"] == ["type": "json_schema", "json_schema": ["name": "orix_response", "strict": true, "schema": schema.raw]])
        #expect(body["reasoning_effort"] == "low")
        let m = body["messages"]?.arrayValue ?? []
        #expect(m.count == 7)
        #expect(m[0] == ["role": "system", "content": "S"])
        #expect(m[2]["content"] == "Looking." && m[2]["tool_calls"]?.arrayValue?.count == 2)
        #expect(m[2]["tool_calls"]?[0] == ["id": "call_fixture_a", "type": "function", "function": ["name": "get_weather", "arguments": "{\"city\":\"Paris\"}"]])
        #expect(m[3] == ["role": "tool", "tool_call_id": "call_fixture_a", "content": "12°C"], "tool results directly follow the assistant turn")
        #expect(m[4] == ["role": "tool", "tool_call_id": "call_fixture_b", "content": "[tool error] timeout"])
        #expect(m[5] == ["role": "user", "content": "thanks"])
        #expect(m[6] == ["role": "user", "content": [["type": "text", "text": "look"], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,AAAA"]]]])

        func choice(_ c: LLMToolChoice) -> JSONValue? { provider(StubServer()).requestBody(for: LLMRequest(model: "gpt-4o-mini", messages: [.user("x")], tools: [weatherTool], toolChoice: c))["tool_choice"] }
        #expect(choice(.auto) == "auto" && choice(.none) == "none" && choice(.required) == "required")
        // An assistant turn that only calls tools has null content.
        #expect(ChatCompletionsEncoder.encode(LLMMessage(role: .assistant, content: [.toolUse(LLMToolUse(id: "c", name: "n", input: [:]))]))[0]["content"] == .null)
    }

    @Test func omitsTemperatureForModelsKnownToRejectIt() {
        let p = provider(StubServer())
        func temp(_ model: String) -> JSONValue? { p.requestBody(for: LLMRequest(model: model, messages: [.user("x")], temperature: 0.5))["temperature"] }
        #expect(temp("gpt-4o-mini") == .number(0.5))
        #expect(temp("gpt-4o-mini-2024-07-18") == .number(0.5))
        #expect(temp("gpt-5-nano") == nil)
        #expect(temp("gpt-5-mini-2025-08-07") == nil)
        #expect(temp("o3") == nil && temp("o4-mini") == nil && temp("gpt-5.9-unknown") == nil)
        #expect(temp("gpt-6-luna") == .number(0.5), "not known to reject it: sent, with the one-shot retry as safety net")
    }

    @Test func retriesOnceWithoutTemperatureOnTheSpecific400() async throws {
        let rejection = #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.5 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#
        let server = StubServer().json(400, rejection).sse(Self.textTranscript).sse(Self.textTranscript)
        let p = provider(server)
        let request = LLMRequest(model: "gpt-6-luna", messages: [.user("x")], temperature: 0.5)
        #expect(try await p.complete(request).text == "Hello wörld")
        #expect(server.requests.count == 2)
        #expect(server.requests[0].body?["temperature"] == .number(0.5) && server.requests[1].body?["temperature"] == nil)
        // The model is remembered: the next call does not send temperature at all.
        _ = try await p.complete(request)
        #expect(server.requests.count == 3 && server.requests[2].body?["temperature"] == nil)

        // Any other 400 is not retried, and a second temperature rejection cannot loop.
        let other = StubServer().json(400, #"{"error":{"message":"Invalid schema for response_format","type":"invalid_request_error","param":"response_format","code":null}}"#)
        let (_, error) = await collect(provider(other).stream(LLMRequest(model: "gpt-4o-mini", messages: [.user("x")], temperature: 0.5)))
        #expect(error == .invalidRequest("Invalid schema for response_format"))
        #expect(other.requests.count == 1)
    }

    @Test(arguments: [
        (401, #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#, LLMError.authentication("Incorrect API key provided.")),
        (403, #"{"error":{"message":"Country not supported","type":"request_forbidden","param":null,"code":"unsupported_country_region_territory"}}"#, LLMError.authentication("Country not supported")),
        (404, #"{"error":{"message":"The model `gpt-nope` does not exist or you do not have access to it.","type":"invalid_request_error","param":null,"code":"model_not_found"}}"#, LLMError.modelNotFound("gpt-nope — The model `gpt-nope` does not exist or you do not have access to it.")),
        (400, #"{"error":{"message":"This model's maximum context length is 128000 tokens. However, your messages resulted in 130000 tokens.","type":"invalid_request_error","param":"messages","code":"context_length_exceeded"}}"#, LLMError.contextTooLong("This model's maximum context length is 128000 tokens. However, your messages resulted in 130000 tokens.")),
        (500, #"{"error":{"message":"The server had an error","type":"server_error","param":null,"code":null}}"#, LLMError.server(status: 500, message: "The server had an error")),
        (503, #"{"error":{"message":"The engine is currently overloaded, please try again later","type":"server_error"}}"#, LLMError.overloaded),
        (529, "", LLMError.overloaded),
        (429, #"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#, LLMError.invalidRequest("The provider account has no remaining quota or credit. You exceeded your current quota")),
    ] as [(Int, String, LLMError)])
    func mapsHTTPErrors(status: Int, body: String, expected: LLMError) async {
        let (events, error) = await collect(provider(StubServer().json(status, body)).stream(LLMRequest(model: "gpt-nope", messages: [.user("x")])))
        #expect(events.isEmpty && error == expected)
    }

    @Test func rateLimitHonoursRetryAfterHeaders() async {
        let body = #"{"error":{"message":"Rate limit reached","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#
        let seconds = await collect(provider(StubServer().json(429, body, headers: ["Retry-After": "3"])).stream(LLMRequest(model: "gpt-4o-mini", messages: [.user("x")])))
        #expect(seconds.error == .rateLimited(retryAfterSeconds: 3))
        let millis = await collect(provider(StubServer().json(429, body, headers: ["retry-after-ms": "250", "retry-after": "1"])).stream(LLMRequest(model: "gpt-4o-mini", messages: [.user("x")])))
        #expect(millis.error == .rateLimited(retryAfterSeconds: 0.25))
        let none = await collect(provider(StubServer().json(429, body)).stream(LLMRequest(model: "gpt-4o-mini", messages: [.user("x")])))
        #expect(none.error == .rateLimited(retryAfterSeconds: nil))
    }

    @Test func midStreamDisconnectAndStreamsWithoutDoneAreHandled() async {
        let request = LLMRequest(model: "gpt-4o-mini", messages: [.user("x")])
        let head = chatSSE([Self.chunk(#"{"role":"assistant","content":"par"}"#), Self.chunk(#"{"content":"tial"}"#)], done: false)
        let dropped = await collect(provider(StubServer().sse(head, failure: .networkConnectionLost)).stream(request))
        #expect(dropped.events.text == "partial" && dropped.events.stop == nil)
        if case .network = dropped.error {} else { Issue.record("expected a network error, got \(String(describing: dropped.error))") }

        let early = await collect(provider(StubServer().sse(head)).stream(request))
        #expect(early.error == .network("The response stream ended before the completion was finished."))

        // A stream that carried its finish reason but no [DONE] sentinel is complete.
        let noDone = await collect(provider(StubServer().sse(head + chatSSE([Self.chunk("{}", finish: "stop")], done: false))).stream(request))
        #expect(noDone.error == nil && noDone.events.stop == .endTurn)

        let garbage = await collect(provider(StubServer().sse("data: {not json}\n\n")).stream(request))
        #expect(garbage.error == .decoding("A stream chunk was not valid JSON."))
    }

    @Test func lengthCutToolCallIsDroppedAndRefusalAndFilterAreReported() async {
        let request = LLMRequest(model: "gpt-4o-mini", messages: [.user("x")], tools: [weatherTool])
        func run(_ chunks: [String]) async -> (events: [LLMStreamEvent], error: LLMError?) {
            await collect(provider(StubServer().sse(chatSSE(chunks))).stream(request))
        }
        let call = Self.chunk(#"{"tool_calls":[{"index":0,"id":"call_fixture_a","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Mon"}}]}"#)
        let cut = await run([call, Self.chunk("{}", finish: "length")])
        #expect(cut.error == nil && cut.events.toolUses.isEmpty && cut.events.stop == .maxTokens)
        let broken = await run([call, Self.chunk("{}", finish: "tool_calls")])
        if case .decoding(let m) = broken.error { #expect(m.contains("get_weather")) } else { Issue.record("expected a decoding error") }
        #expect(broken.events.toolUses.isEmpty && broken.events.stop == nil)

        let refusal = await run([Self.chunk(#"{"role":"assistant","content":null,"refusal":"I can't help with that."}"#), Self.chunk("{}", finish: "stop")])
        #expect(refusal.events.stop == .refusal && refusal.events.text == "I can't help with that.")
        let filtered = await run([Self.chunk(#"{"content":"x"}"#), Self.chunk("{}", finish: "content_filter")])
        #expect(filtered.events.stop == .contentFilter)
    }

    @Test func listsOnlyChatModelsAndEnrichesFromTheRegistry() async throws {
        let ids = ["gpt-4o-mini", "gpt-4o-mini-2024-07-18", "gpt-5-nano", "o3", "gpt-9-future", "text-embedding-3-small", "whisper-1", "tts-1",
                   "gpt-4o-audio-preview", "gpt-4o-realtime-preview", "gpt-image-1", "dall-e-3", "omni-moderation-latest", "gpt-3.5-turbo-instruct",
                   "gpt-5-pro", "gpt-5.2-codex", "gpt-4o-mini-transcribe", "gpt-4o-search-preview", "davinci-002", "o3-deep-research"]
        let body = "{\"object\":\"list\",\"data\":[" + ids.map { "{\"id\":\"\($0)\",\"object\":\"model\",\"created\":1,\"owned_by\":\"system\"}" }.joined(separator: ",") + "]}"
        let server = StubServer().json(200, body)
        let models = try await provider(server).listModels()
        #expect(server.requests[0].path == "/v1/models" && server.requests[0].method == "GET")
        #expect(models.map(\.id) == ["gpt-4o-mini", "gpt-4o-mini-2024-07-18", "gpt-5-nano", "gpt-9-future", "o3"])
        #expect(models.allSatisfy { $0.source == "api" && $0.provider == .openai })
        #expect(models[0].inputPricePerMTok == 0.15 && models[0].outputPricePerMTok == 0.60)
        #expect(models[1].inputPricePerMTok == 0.15 && models[1].id == "gpt-4o-mini-2024-07-18")
        #expect(models[2].inputPricePerMTok == 0.05 && models[2].outputPricePerMTok == 0.40)
        #expect(models[3].inputPricePerMTok == nil && models[3].contextWindow == nil, "unknown models carry no invented metadata")
    }
}
