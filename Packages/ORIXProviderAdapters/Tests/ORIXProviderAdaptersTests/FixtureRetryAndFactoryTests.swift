// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Tests/ORIXProviderAdaptersTests/FixtureRetryAndFactoryTests.swift
// Description: Mocked tests of RetryPolicy math, RetryingProvider (retry only before the first event), ProviderFactory, ProviderHealth, ModelRegistry and the DEBUG-only credential source.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Testing
import Foundation
import Synchronization
import ORIXCore
import ORIXTestingSupport
@testable import ORIXProviderAdapters

/// Yields scripted events, then optionally fails: models a stream that breaks after output was delivered.
final class BreakingProvider: LLMProvider {
    let id = ProviderID(rawValue: "breaking")
    let attempts = Mutex(0)
    let script: @Sendable (Int) -> (events: [LLMStreamEvent], error: LLMError?)
    init(script: @escaping @Sendable (Int) -> (events: [LLMStreamEvent], error: LLMError?)) { self.script = script }
    func listModels() async throws -> [ModelInfo] {
        let n = attempts.withLock { $0 += 1; return $0 }
        if let e = script(n).error { throw e }
        return [ModelInfo(id: "m", provider: id)]
    }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let n = attempts.withLock { $0 += 1; return $0 }
        let (events, error) = script(n)
        return AsyncThrowingStream { c in
            for e in events { c.yield(e) }
            c.finish(throwing: error)
        }
    }
}

final class SleepRecorder: Sendable {
    let waits = Mutex<[Double]>([])
    var sleep: RetryingProvider.Sleep { { seconds in self.waits.withLock { $0.append(seconds) } } }
    var recorded: [Double] { waits.withLock { $0 } }
}

@Suite("Fixture retry policy and retrying provider (mocked)")
struct FixtureRetryTests {
    @Test func backoffIsExponentialJitteredAndBounded() {
        let p = RetryPolicy(maxAttempts: 5, baseDelaySeconds: 1, multiplier: 2, maxDelaySeconds: 5, jitter: 0.25, totalDelayCapSeconds: 100)
        #expect(p.delay(afterFailedAttempts: 1, error: .overloaded, randomUnit: 0.5) == 1)
        #expect(p.delay(afterFailedAttempts: 2, error: .overloaded, randomUnit: 0.5) == 2)
        #expect(p.delay(afterFailedAttempts: 3, error: .overloaded, randomUnit: 0.5) == 4)
        #expect(p.delay(afterFailedAttempts: 4, error: .overloaded, randomUnit: 0.5) == 5, "capped by maxDelaySeconds")
        #expect(p.delay(afterFailedAttempts: 1, error: .overloaded, randomUnit: 0) == 0.75)
        #expect(p.delay(afterFailedAttempts: 1, error: .overloaded, randomUnit: 1) == 1.25)
        #expect(p.delay(afterFailedAttempts: 5, error: .overloaded, randomUnit: 0.5) == nil, "no wait after the last allowed attempt")
        for _ in 0..<200 {
            let d = p.delay(afterFailedAttempts: 2, error: .network("x"))!
            #expect(d >= 1.5 && d <= 2.5)
        }
    }

    @Test func onlyRetryableErrorsAreRetried() {
        let p = RetryPolicy()
        for e in [LLMError.rateLimited(retryAfterSeconds: nil), .overloaded, .network("x"), .server(status: 500, message: ""), .server(status: 503, message: "")] {
            #expect(p.delay(afterFailedAttempts: 1, error: e, randomUnit: 0.5) != nil, "\(e)")
        }
        for e in [LLMError.authentication("x"), .invalidRequest("x"), .modelNotFound("x"), .contextTooLong("x"), .unsupported("x"), .decoding("x"), .canceled,
                  .missingCredential(.openai), .server(status: 404, message: "")] {
            #expect(p.delay(afterFailedAttempts: 1, error: e, randomUnit: 0.5) == nil, "\(e)")
        }
        #expect(RetryPolicy.none.delay(afterFailedAttempts: 1, error: .overloaded) == nil)
    }

    @Test func retryAfterIsHonouredWithinTheTotalCap() {
        let p = RetryPolicy(maxAttempts: 4, baseDelaySeconds: 0.5, maxDelaySeconds: 20, jitter: 0, totalDelayCapSeconds: 30)
        #expect(p.delay(afterFailedAttempts: 1, error: .rateLimited(retryAfterSeconds: 12)) == 12, "never earlier than the server asked")
        #expect(p.delay(afterFailedAttempts: 3, error: .rateLimited(retryAfterSeconds: 0.1)) == 2, "a short retry-after does not shorten the backoff")
        #expect(p.delay(afterFailedAttempts: 1, error: .rateLimited(retryAfterSeconds: 120)) == nil, "a wait beyond the total cap is not started")
        #expect(p.delay(afterFailedAttempts: 2, error: .overloaded, elapsedDelaySeconds: 29.5) == nil)
        #expect(p.delay(afterFailedAttempts: 2, error: .overloaded, elapsedDelaySeconds: 29) == 1)
    }

    @Test func retriesBeforeTheFirstEventThenSucceeds() async throws {
        let scripted = ScriptedProvider(turns: [.failure(.overloaded), .failure(.rateLimited(retryAfterSeconds: 3)), ScriptedProvider.text("done")])
        let recorder = SleepRecorder()
        let observed = Mutex<[String]>([])
        let retrying = RetryingProvider(scripted, policy: RetryPolicy(maxAttempts: 4, baseDelaySeconds: 1, jitter: 0),
                                        onRetry: { n, e, d in observed.withLock { $0.append("\(n) \(e) \(d)") } }, sleep: recorder.sleep)
        let (events, error) = await collect(retrying.stream(LLMRequest(model: "scripted-1", messages: [.user("x")])))
        #expect(error == nil)
        #expect(events == [.textDelta("done"), .usage(.init(inputTokens: 10, outputTokens: 5)), .stop(.endTurn)], "only the successful attempt's events, nothing synthetic")
        #expect(scripted.requests.count == 3)
        #expect(recorder.recorded == [1, 3])
        #expect(observed.withLock { $0.count } == 2)
        #expect(retrying.id == scripted.id)
    }

    @Test func neverRetriesOnceAnEventWasDelivered() async {
        let base = BreakingProvider { _ in ([.textDelta("partial")], .network("connection lost")) }
        let recorder = SleepRecorder()
        let (events, error) = await collect(RetryingProvider(base, policy: RetryPolicy(maxAttempts: 5), sleep: recorder.sleep).stream(LLMRequest(model: "m", messages: [.user("x")])))
        #expect(events == [.textDelta("partial")])
        #expect(error == .network("connection lost"))
        #expect(base.attempts.withLock { $0 } == 1, "replaying would duplicate delivered output")
        #expect(recorder.recorded.isEmpty)
    }

    @Test func doesNotRetryPermanentErrorsAndStopsAtMaxAttempts() async {
        let recorder = SleepRecorder()
        let auth = BreakingProvider { _ in ([], .authentication("bad key")) }
        let a = await collect(RetryingProvider(auth, sleep: recorder.sleep).stream(LLMRequest(model: "m", messages: [.user("x")])))
        #expect(a.error == .authentication("bad key") && auth.attempts.withLock { $0 } == 1)

        let down = BreakingProvider { _ in ([], .server(status: 503, message: "down")) }
        let b = await collect(RetryingProvider(down, policy: RetryPolicy(maxAttempts: 3, baseDelaySeconds: 0.01), sleep: recorder.sleep).stream(LLMRequest(model: "m", messages: [.user("x")])))
        #expect(b.events.isEmpty && b.error == .server(status: 503, message: "down"))
        #expect(down.attempts.withLock { $0 } == 3)
        #expect(recorder.recorded.count == 2)
    }

    @Test func listModelsIsRetriedToo() async throws {
        let flaky = BreakingProvider { n in ([], n < 3 ? .network("blip") : nil) }
        let recorder = SleepRecorder()
        let models = try await RetryingProvider(flaky, policy: RetryPolicy(maxAttempts: 3, baseDelaySeconds: 0.01), sleep: recorder.sleep).listModels()
        #expect(models.map(\.id) == ["m"] && recorder.recorded.count == 2)
    }

    @Test func retriesARealAdapterOn529ThenStreams() async throws {
        let server = StubServer()
            .json(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
            .json(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#, headers: ["retry-after": "2"])
            .sse(FixtureAnthropicTests.textTranscript)
        let recorder = SleepRecorder()
        let provider = RetryingProvider(AnthropicProvider(apiKey: fixtureKey, session: server.session, baseURL: server.baseURL),
                                        policy: RetryPolicy(maxAttempts: 3, baseDelaySeconds: 0.5, jitter: 0), sleep: recorder.sleep)
        let response = try await provider.complete(LLMRequest(model: "claude-haiku-5-5", messages: [.user("x")]))
        #expect(response.text == "Bonjour, monde — ✓" && response.stopReason == .endTurn)
        #expect(server.requests.count == 3)
        #expect(recorder.recorded == [0.5, 2], "second wait follows the server's retry-after")
    }

    @Test func cancellingTheConsumerSurfacesCanceled() async {
        let scripted = ScriptedProvider(turns: [.failure(.overloaded), ScriptedProvider.text("late")])
        let retrying = RetryingProvider(scripted, policy: RetryPolicy(maxAttempts: 3, baseDelaySeconds: 30, jitter: 0, totalDelayCapSeconds: 100))
        let task = Task { await collect(retrying.stream(LLMRequest(model: "scripted-1", messages: [.user("x")]))) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let (events, error) = await task.value
        #expect(events.isEmpty)
        #expect(error == nil || error == .canceled, "a cancelled consumer gets no event; the producer ends as canceled")
        #expect(scripted.requests.count == 1)
    }
}

@Suite("Fixture factory, health check, registry and dev credentials (mocked)")
struct FixtureFactoryTests {
    @Test func factoryBuildsTheRightAdapterAndRefusesUnknownProviders() async {
        #expect(ProviderFactory.make(.anthropic, apiKey: fixtureKey) is AnthropicProvider)
        #expect(ProviderFactory.make(.openai, apiKey: fixtureKey) is OpenAIProvider)
        #expect(ProviderFactory.make(.openrouter, apiKey: fixtureKey) is OpenRouterProvider)
        #expect(ProviderFactory.makeRetrying(.openai, apiKey: fixtureKey) is RetryingProvider)
        for id in ProviderID.all { #expect(ProviderFactory.make(id, apiKey: fixtureKey).id == id) }
        let unknown = ProviderFactory.make(ProviderID(rawValue: "acme"), apiKey: fixtureKey)
        let (events, error) = await collect(unknown.stream(LLMRequest(model: "m", messages: [.user("x")])))
        #expect(events.isEmpty && error == .unsupported("No adapter exists for provider \"acme\"."))
        await #expect(throws: LLMError.self) { _ = try await unknown.listModels() }
    }

    @Test func healthCheckSendsAMinimalRequestAndReportsTypedFailures() async {
        let server = StubServer().sse(FixtureAnthropicTests.textTranscript).json(401, #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        let provider = AnthropicProvider(apiKey: fixtureKey, session: server.session, baseURL: server.baseURL)
        let ok = await ProviderHealth.check(provider: provider, model: "claude-haiku-5-5")
        #expect(ok.ok && ok.error == nil && ok.message == nil && ok.provider == .anthropic && ok.model == "claude-haiku-5-5")
        #expect(ok.latencyMs >= 0 && ok.firstEventMs != nil && ok.usage?.outputTokens == 9)
        #expect(server.requests[0].body?["max_tokens"] == 8, "the probe is capped at 8 output tokens")
        #expect(server.requests[0].body?["tools"] == nil)

        let bad = await ProviderHealth.check(provider: provider, model: "claude-haiku-5-5")
        #expect(!bad.ok && bad.error == .authentication("invalid x-api-key"))
        #expect(bad.message?.contains("rejected the API key") == true && bad.message?.contains(fixtureKey) == false)

        let offline = await ProviderHealth.check(provider: AnthropicProvider(apiKey: fixtureKey, session: StubServer().enqueue(.init(failure: .notConnectedToInternet)).session,
                                                                              baseURL: URL(string: "https://unregistered-host.test")!), model: "m")
        if case .network = offline.error {} else { Issue.record("expected a network error, got \(String(describing: offline.error))") }
        #expect(!offline.ok)
    }

    @Test func registryIsDatedPricedAndNeverGuesses() {
        #expect(ModelRegistry.lastVerified.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
        let anthropic = ModelRegistry.models(for: .anthropic), openai = ModelRegistry.models(for: .openai)
        #expect(!anthropic.isEmpty && !openai.isEmpty && ModelRegistry.models(for: .openrouter).isEmpty)
        #expect((anthropic + openai).allSatisfy { $0.source == "registry" })
        #expect(Set(ModelRegistry.entries.map { "\($0.provider)/\($0.id)" }).count == ModelRegistry.entries.count, "no duplicate ids")
        for e in ModelRegistry.entries {
            if let i = e.inputPricePerMTok, let o = e.outputPricePerMTok { #expect(i > 0 && o >= i, "\(e.id)") }
            if let r = e.cacheReadPricePerMTok, let i = e.inputPricePerMTok { #expect(r < i, "\(e.id)") }
        }
        let haiku = ModelRegistry.info(provider: .anthropic, id: "claude-haiku-5-5")
        #expect(haiku?.inputPricePerMTok == 0.10 && haiku?.outputPricePerMTok == 0.50 && haiku?.contextWindow == 1_000_000)
        #expect(ModelRegistry.info(provider: .anthropic, id: "claude-haiku-4-5-20251001")?.id == "claude-haiku-4-5-20251001")
        #expect(ModelRegistry.info(provider: .openai, id: "gpt-4o-mini-2024-07-18")?.outputPricePerMTok == 0.60)
        #expect(ModelRegistry.info(provider: .openai, id: "gpt-unknown") == nil)
        #expect(ModelRegistry.info(provider: .openai, id: "claude-haiku-5-5") == nil, "entries are per provider")
        #expect(ModelRegistry.entry(provider: .anthropic, id: "claude-opus-5-5")?.acceptsForcedToolChoice == false)
        // Cost from usage and registry prices: 1M in + 1M out on Haiku 5.5 = $0.60.
        #expect(TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000).costUSD(model: haiku) == 0.60)
        let merged = ModelRegistry.merge(api: [ModelInfo(id: "gpt-4o-mini", provider: .openai), ModelInfo(id: "x", provider: .openai, inputPricePerMTok: 9)])
        #expect(merged[0].inputPricePerMTok == 0.15 && merged[0].source == "api" && merged[1].inputPricePerMTok == 9)
    }

    @Test func toolResultWithoutErrorOmitsTheErrorFlag() {
        let p = AnthropicProvider(apiKey: fixtureKey, session: StubServer().session)
        let body = p.requestBody(for: LLMRequest(model: "claude-haiku-5-5", messages: [
            .user("x"), LLMMessage(role: .assistant, content: [.toolUse(LLMToolUse(id: "toolu_fixture_01", name: "t", input: [:]))]),
            LLMMessage(role: .user, content: [.toolResult(toolUseID: "toolu_fixture_01", content: "ok", isError: false)]),
        ])).body
        #expect(body["messages"]?[2]?["content"] == [["type": "tool_result", "tool_use_id": "toolu_fixture_01", "content": "ok"]])
        #expect(ChatCompletionsEncoder.encode(.assistant("hi")) == [["role": "assistant", "content": "hi"]])
    }

    #if DEBUG
    @Test func devCredentialsReadOnlyTheGivenEnvironment() {
        let creds = DevEnvironmentCredentials(environment: ["ORIX_DEV_ANTHROPIC_API_KEY": "  \(fixtureKey)\n", "ORIX_DEV_OPENAI_API_KEY": "   ", "UNRELATED": "x"])
        #expect(creds.apiKey(for: .anthropic) == fixtureKey)
        #expect(creds.apiKey(for: .openai) == nil, "a blank variable is no key")
        #expect(creds.apiKey(for: .openrouter) == nil && creds.apiKey(for: ProviderID(rawValue: "acme")) == nil)
        #expect(creds.availableProviders == [.anthropic])
        #expect(DevEnvironmentCredentials.variableName(for: .openrouter) == "ORIX_DEV_OPENROUTER_API_KEY")
        #expect(DevEnvironmentCredentials(environment: [:]).availableProviders.isEmpty)
    }
    #endif
}
