// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Tests/ORIXProviderAdaptersTests/FixtureOpenRouterTests.swift
// Description: Mocked tests of the OpenRouter adapter: catalog parsing, reported cost, provider routing, headers, error bodies and mid-stream error chunks, with sanitized recorded-shape fixtures.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Testing
import Foundation
import ORIXCore
@testable import ORIXProviderAdapters

@Suite("Fixture OpenRouter adapter (mocked network)")
struct FixtureOpenRouterTests {
    func provider(_ server: StubServer, routing: ProviderRouting? = nil) -> OpenRouterProvider {
        OpenRouterProvider(apiKey: fixtureKey, session: server.session, baseURL: server.baseURL.appendingPathComponent("api/v1"), routing: routing)
    }

    static func chunk(_ delta: String, finish: String? = nil, usage: String = "") -> String {
        #"{"id":"gen-fixture","provider":"FixtureAI","model":"vendor/model-a","object":"chat.completion.chunk","created":1,"choices":[{"index":0,"delta":\#(delta),"finish_reason":\#(finish.map { "\"\($0)\"" } ?? "null"),"native_finish_reason":null}]\#(usage)}"#
    }
    static let usage = #","usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"cost":0.0000325,"is_byok":false,"prompt_tokens_details":{"cached_tokens":40,"cache_write_tokens":10},"cost_details":{"upstream_inference_cost":null},"completion_tokens_details":{"reasoning_tokens":0}}"#

    static let catalog = #"""
    {"data":[
     {"id":"vendor/model-a","canonical_slug":"vendor/model-a","name":"Vendor: Model A","created":1,"context_length":128000,
      "architecture":{"modality":"text+image->text","input_modalities":["text","image"],"output_modalities":["text"],"tokenizer":"GPT"},
      "pricing":{"prompt":"0.00000015","completion":"0.0000006","input_cache_read":"0.000000075"},
      "top_provider":{"context_length":128000,"max_completion_tokens":16384,"is_moderated":true},
      "supported_parameters":["max_tokens","response_format","structured_outputs","temperature","tool_choice","tools"]},
     {"id":"vendor/text-only","name":"Vendor: Text Only","context_length":32768,
      "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
      "pricing":{"prompt":"0.000003","completion":"0.000015"},
      "top_provider":{"context_length":32768,"max_completion_tokens":null,"is_moderated":false},
      "supported_parameters":["max_tokens","temperature"]},
     {"id":"vendor/free:free","name":"Free","context_length":8192,"pricing":{"prompt":"0","completion":"0"},"supported_parameters":["tools"]},
     {"id":"openrouter/auto","name":"Auto Router","context_length":2000000,"pricing":{"prompt":"-1","completion":"-1"},"supported_parameters":["tools","response_format"]}
    ]}
    """#

    @Test func parsesTheCatalogIntoPricesLimitsAndCapabilities() async throws {
        let server = StubServer().json(200, Self.catalog)
        let models = try await provider(server).listModels()
        #expect(server.requests[0].path == "/api/v1/models")
        #expect(models.count == 4 && models.allSatisfy { $0.source == "api" && $0.provider == .openrouter })
        let a = models[0]
        #expect(a.displayName == "Vendor: Model A" && a.contextWindow == 128_000 && a.maxOutputTokens == 16_384)
        #expect(a.inputPricePerMTok == 0.15 && a.outputPricePerMTok == 0.6, "per-token strings become USD per million tokens")
        #expect(a.supportsTools && a.supportsVision && a.supportsStructuredOutput)
        let b = models[1]
        #expect(b.inputPricePerMTok == 3 && b.outputPricePerMTok == 15 && b.maxOutputTokens == nil)
        #expect(!b.supportsTools && !b.supportsVision && !b.supportsStructuredOutput)
        #expect(models[2].inputPricePerMTok == 0 && models[2].outputPricePerMTok == 0)
        #expect(models[3].inputPricePerMTok == nil && models[3].outputPricePerMTok == nil, "dynamic pricing (-1) is unknown, not negative")
    }

    @Test func streamsTextThroughKeepAliveCommentsAndReportsCost() async {
        let transcript = ": OPENROUTER PROCESSING\n\n" + chatSSE([
            Self.chunk(#"{"role":"assistant","content":""}"#),
            Self.chunk(#"{"content":"Salut","reasoning":"Greeting in French."}"#),
        ], done: false) + ": OPENROUTER PROCESSING\n\n" + chatSSE([
            Self.chunk(#"{"content":" !"}"#, finish: "stop"),
            Self.chunk(#"{"role":"assistant","content":""}"#, usage: Self.usage),
        ])
        let server = StubServer().sse(transcript, chunkSize: 31)
        let routing = ProviderRouting(order: ["fixture-a", "fixture-b"], allowFallbacks: false, dataCollection: .deny, requireParameters: true)
        let (events, error) = await collect(provider(server, routing: routing).stream(LLMRequest(model: "vendor/model-a", system: "S", messages: [.user("Hi")], maxOutputTokens: 16, temperature: 0)))
        #expect(error == nil)
        #expect(events.text == "Salut !" && events.reasoning == "Greeting in French." && events.stop == .endTurn)
        #expect(events.lastUsage == TokenUsage(inputTokens: 50, outputTokens: 20, cacheReadTokens: 40, cacheWriteTokens: 10, reportedCostUSD: 0.0000325))
        #expect(events.lastUsage?.costUSD(model: nil) == 0.0000325)

        let req = server.requests[0]
        #expect(req.path == "/api/v1/chat/completions")
        #expect(req.header("Authorization") == "Bearer \(fixtureKey)")
        #expect(req.header("X-Title") == "ORIX OS Automation" && req.header("HTTP-Referer") == "http://localhost")
        #expect(req.body?["provider"] == ["order": ["fixture-a", "fixture-b"], "allow_fallbacks": false, "data_collection": "deny", "require_parameters": true])
        #expect(req.body?["usage"] == ["include": true])
        #expect(req.body?["max_tokens"] == 16 && req.body?["max_completion_tokens"] == nil)
        #expect(req.body?["temperature"]?.doubleValue == 0)
        #expect(req.body?["messages"]?[0] == ["role": "system", "content": "S"])
    }

    @Test func routingIsOmittedWhenEmptyAndCacheControlOnlyGoesToAnthropicModels() {
        let p = provider(StubServer(), routing: ProviderRouting())
        let plain = p.requestBody(for: LLMRequest(model: "vendor/model-a", system: "S", messages: [.user("x")], cacheSystemAndTools: true))
        #expect(plain["provider"] == nil)
        #expect(plain["messages"]?[0] == ["role": "system", "content": "S"])
        let claude = p.requestBody(for: LLMRequest(model: "anthropic/claude-haiku-5.5", system: "S", messages: [.user("x")], cacheSystemAndTools: true))
        #expect(claude["messages"]?[0] == ["role": "system", "content": [["type": "text", "text": "S", "cache_control": ["type": "ephemeral"]]]])
    }

    @Test func toolCallWithoutAnIdGetsAStablePositionalId() async {
        let transcript = chatSSE([
            Self.chunk(#"{"role":"assistant","content":null,"tool_calls":[{"index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Rome\"}"}}]}"#),
            Self.chunk("{}", finish: "stop", usage: Self.usage),
        ])
        let (events, error) = await collect(provider(StubServer().sse(transcript)).stream(LLMRequest(model: "vendor/model-a", messages: [.user("x")], tools: [weatherTool])))
        #expect(error == nil)
        #expect(events.toolUses == [LLMToolUse(id: "call_0", name: "get_weather", input: ["city": "Rome"])])
        #expect(events.stop == .toolUse, "an upstream that says `stop` while calling a tool still ends in toolUse")
    }

    @Test func structuredOutputIsRefusedUpFrontForModelsThatLackIt() async throws {
        let server = StubServer().json(200, Self.catalog).sse(chatSSE([Self.chunk(#"{"content":"{}"}"#, finish: "stop")]))
        let p = provider(server)
        _ = try await p.listModels()
        let schema = JSONSchema.object(["a": .string()], required: ["a"])
        let refused = await collect(p.stream(LLMRequest(model: "vendor/text-only", messages: [.user("x")], responseSchema: schema)))
        #expect(refused.error == .unsupported("vendor/text-only does not offer structured outputs on OpenRouter."))
        #expect(server.requests.count == 1, "no completion request was sent")
        let ok = await collect(p.stream(LLMRequest(model: "vendor/model-a", messages: [.user("x")], responseSchema: schema)))
        #expect(ok.error == nil)
        #expect(server.requests[1].body?["response_format"]?["json_schema"]?["strict"] == true)
    }

    @Test(arguments: [
        (401, #"{"error":{"code":401,"message":"No auth credentials found"}}"#, LLMError.authentication("No auth credentials found")),
        (402, #"{"error":{"code":402,"message":"Insufficient credits"}}"#, LLMError.invalidRequest("The OpenRouter account or key has insufficient credits. Insufficient credits")),
        (403, #"{"error":{"code":403,"message":"Input flagged","metadata":{"reasons":["violence"],"flagged_input":"…","provider_name":"FixtureAI","model_slug":"vendor/model-a"}}}"#, LLMError.invalidRequest("Blocked by moderation. Input flagged [provider: FixtureAI] [flagged: violence]")),
        (403, #"{"error":{"code":403,"message":"Key lacks permission for this model"}}"#, LLMError.authentication("Key lacks permission for this model")),
        (404, #"{"error":{"code":404,"message":"No endpoints found for vendor/nope."}}"#, LLMError.modelNotFound("vendor/nope — No endpoints found for vendor/nope.")),
        (400, #"{"error":{"code":400,"message":"vendor/nope is not a valid model ID"}}"#, LLMError.modelNotFound("vendor/nope — vendor/nope is not a valid model ID")),
        (400, #"{"error":{"code":400,"message":"This endpoint's maximum context length is 32768 tokens. However, you requested about 40000 tokens.","metadata":{"provider_name":"FixtureAI"}}}"#, LLMError.contextTooLong("This endpoint's maximum context length is 32768 tokens. However, you requested about 40000 tokens. [provider: FixtureAI]")),
        (408, #"{"error":{"code":408,"message":"Request timed out"}}"#, LLMError.network("the provider timed out (HTTP 408)")),
        (502, #"{"error":{"code":502,"message":"Provider returned error","metadata":{"provider_name":"FixtureAI","raw":"upstream exploded"}}}"#, LLMError.server(status: 502, message: "Provider returned error [provider: FixtureAI] upstream exploded")),
        (503, #"{"error":{"code":503,"message":"No allowed providers are available for the selected model."}}"#, LLMError.server(status: 503, message: "No allowed providers are available for the selected model.")),
        (529, #"{"error":{"code":529,"message":"Provider overloaded"}}"#, LLMError.overloaded),
        (400, #"{"error":{"code":400,"message":"tools is not supported by this provider"}}"#, LLMError.invalidRequest("tools is not supported by this provider")),
    ] as [(Int, String, LLMError)])
    func mapsErrorBodies(status: Int, body: String, expected: LLMError) async {
        let (events, error) = await collect(provider(StubServer().json(status, body)).stream(LLMRequest(model: "vendor/nope", messages: [.user("x")])))
        #expect(events.isEmpty && error == expected)
    }

    @Test func rateLimitUsesRetryAfterAndUpstreamRateLimitsAreRecognised() async {
        let direct = await collect(provider(StubServer().json(429, #"{"error":{"code":429,"message":"Rate limit exceeded"}}"#, headers: ["Retry-After": "12"])).stream(LLMRequest(model: "vendor/model-a", messages: [.user("x")])))
        #expect(direct.error == .rateLimited(retryAfterSeconds: 12))
        // The HTTP status and the body code can differ; the body code decides.
        let body = await collect(provider(StubServer().json(200, #"{"error":{"code":429,"message":"Provider returned error","metadata":{"provider_name":"FixtureAI","raw":"{\"error\":\"slow down\"}"}}}"#)).stream(LLMRequest(model: "vendor/model-a", messages: [.user("x")])))
        #expect(body.error == .rateLimited(retryAfterSeconds: nil))
    }

    @Test func midStreamErrorChunksBecomeTypedErrorsAfterThePartialOutput() async {
        let request = LLMRequest(model: "vendor/model-a", messages: [.user("x")])
        let head = chatSSE([Self.chunk(#"{"role":"assistant","content":"par"}"#), Self.chunk(#"{"content":"tial"}"#)], done: false)
        let errorChunk = #"{"id":"gen-fixture","object":"chat.completion.chunk","created":1,"model":"vendor/model-a","provider":"FixtureAI","error":{"code":502,"message":"Provider disconnected","metadata":{"error_type":"provider_unavailable","provider_name":"FixtureAI"}},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#
        let a = await collect(provider(StubServer().sse(head + chatSSE([errorChunk], done: false))).stream(request))
        #expect(a.events.text == "partial" && a.events.stop == nil)
        #expect(a.error == .server(status: 502, message: "Provider disconnected [provider: FixtureAI]"))
        #expect(a.error?.isRetryable == true)

        let limited = #"{"error":{"code":"429","message":"Upstream rate limited","metadata":{"error_type":"rate_limit_exceeded"}},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}"#
        let b = await collect(provider(StubServer().sse(head + chatSSE([limited]))).stream(request))
        #expect(b.error == .rateLimited(retryAfterSeconds: nil))

        // finish_reason "error" without an error object is still an error, never a normal stop.
        let bare = await collect(provider(StubServer().sse(head + chatSSE([Self.chunk(#"{"content":""}"#, finish: "error")]))).stream(request))
        if case .server(let status, _) = bare.error { #expect(status == 502) } else { Issue.record("expected a server error, got \(String(describing: bare.error))") }
        #expect(bare.events.stop == nil)

        let dropped = await collect(provider(StubServer().sse(head, failure: .timedOut)).stream(request))
        #expect(dropped.error == .network("the request timed out (URLError -1001)"))
    }

    @Test func errorTextIsScrubbedOfTheKey() async {
        let body = #"{"error":{"code":401,"message":"Invalid key \#(fixtureKey)","metadata":{"raw":"Authorization: Bearer \#(fixtureKey)"}}}"#
        let (_, error) = await collect(provider(StubServer().json(401, body)).stream(LLMRequest(model: "vendor/model-a", messages: [.user("x")])))
        let rendered = "\(String(describing: error)) \(error?.errorDescription ?? "")"
        #expect(!rendered.contains(fixtureKey) && rendered.contains(Redactor.placeholder))
    }
}
