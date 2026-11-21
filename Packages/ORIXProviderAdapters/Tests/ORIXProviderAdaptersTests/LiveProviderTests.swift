// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Tests/ORIXProviderAdaptersTests/LiveProviderTests.swift
// Description: Live smoke tests against the real provider APIs (model list, one capped streamed completion, one forced tool-call round trip). Run only when the provider's ORIX_DEV_*_API_KEY is set; otherwise skipped out loud.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Testing
import Foundation
import ORIXCore
@testable import ORIXProviderAdapters

// Budget: each provider makes 2 model-list calls (free) and at most 4 completions of ≤ 64 output tokens (one Anthropic
// extra of two requests at ≤ 400) on the cheapest model class. Worst case for the whole suite is far below US$0.01.
// Nothing here prints, logs or stores a key: results are printed as `LIVE_RESULT` lines with model ids, timings and token counts only.

#if DEBUG
struct LiveHarness {
    let provider: ProviderID
    /// Preferred cheap models, in order; the first one the key can use is taken.
    let candidates: [String]
    let make: @Sendable (String) -> any LLMProvider

    var key: String? { DevEnvironmentCredentials().apiKey(for: provider) }

    /// The provider client, or nil after printing the skip line.
    func client() -> (any LLMProvider)? {
        guard let key else {
            print("SKIPPED(no \(DevEnvironmentCredentials.variableName(for: provider) ?? "key"))")
            return nil
        }
        return make(key)
    }

    func pickModel(_ models: [ModelInfo]) -> String? {
        let ids = Set(models.map(\.id))
        return candidates.first(where: ids.contains)
    }

    func report(_ test: String, model: String, started: Date, usage: TokenUsage?, note: String = "") {
        let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
        let cost = usage?.reportedCostUSD.map { String(format: " reportedCostUSD=%.6f", $0) } ?? ""
        print("LIVE_RESULT provider=\(provider.rawValue) test=\(test) model=\(model) latencyMs=\(ms) inputTokens=\(usage?.inputTokens ?? 0) outputTokens=\(usage?.outputTokens ?? 0) cacheRead=\(usage?.cacheReadTokens ?? 0)\(cost) result=pass\(note.isEmpty ? "" : " note=\(note)")")
    }

    static let lookupTool = LLMToolSpec(name: "orix_lookup", description: "Looks up the value stored under a key. Call this whenever the user asks for a stored value.",
                                        inputSchema: .object(["key": .string("The key to look up")], required: ["key"]))

    func listModels() async throws {
        guard let client = client() else { return }
        let started = Date()
        let models = try await client.listModels()
        #expect(!models.isEmpty)
        #expect(models.allSatisfy { $0.provider == provider && !$0.id.isEmpty })
        let model = try #require(pickModel(models), "none of the candidate models \(candidates) is available to this key")
        let info = try #require(models.first { $0.id == model })
        #expect(info.inputPricePerMTok != nil && info.outputPricePerMTok != nil, "the smoke model must have a known price")
        print("LIVE_RESULT provider=\(provider.rawValue) test=listModels models=\(models.count) priced=\(models.filter { $0.inputPricePerMTok != nil }.count) smokeModel=\(model) latencyMs=\(Int((Date().timeIntervalSince(started) * 1000).rounded())) result=pass")
    }

    func streamedText() async throws {
        guard let client = client() else { return }
        let model = try #require(pickModel(try await client.listModels()))
        let started = Date()
        var deltas = 0
        var response = LLMResponse(model: model, content: [], stopReason: .other, usage: TokenUsage())
        var text = ""
        for try await event in client.stream(LLMRequest(model: model, messages: [.user("Reply with the single word: pong")], maxOutputTokens: 16)) {
            switch event {
            case .textDelta(let t): deltas += 1; text += t
            case .usage(let u): response.usage = u
            case .stop(let s): response.stopReason = s
            default: break
            }
        }
        response.content = [.text(text)]
        #expect(deltas >= 1, "text must arrive as stream deltas")
        #expect(!response.text.isEmpty)
        #expect(response.stopReason == .endTurn || response.stopReason == .maxTokens)
        #expect(response.usage.inputTokens > 0 && response.usage.outputTokens > 0 && response.usage.outputTokens <= 16)
        report("streamedText", model: model, started: started, usage: response.usage)
    }

    func toolRoundTrip() async throws {
        guard let client = client() else { return }
        let model = try #require(pickModel(try await client.listModels()))
        let started = Date()
        let question = LLMMessage.user("What value is stored under the key alpha? Use the orix_lookup tool.")
        let first = try await client.complete(LLMRequest(model: model, system: "You answer using the provided tool.", messages: [question],
                                                         tools: [Self.lookupTool], toolChoice: .tool(name: "orix_lookup"), maxOutputTokens: 64))
        #expect(first.stopReason == .toolUse)
        let call = try #require(first.toolUses.first, "the forced tool call was not returned")
        #expect(call.name == "orix_lookup" && !call.id.isEmpty)
        #expect(Self.lookupTool.inputSchema.validate(call.input).isEmpty, "tool input must satisfy the declared schema")

        let second = try await client.complete(LLMRequest(model: model, system: "You answer using the provided tool.", messages: [
            question,
            LLMMessage(role: .assistant, content: first.content),
            LLMMessage(role: .user, content: [.toolResult(toolUseID: call.id, content: "alpha = 42", isError: false)]),
        ], tools: [Self.lookupTool], toolChoice: .auto, maxOutputTokens: 64))
        #expect(second.toolUses.isEmpty)
        #expect(second.text.contains("42"), "the final answer should use the tool result")
        #expect(second.stopReason == .endTurn || second.stopReason == .maxTokens)
        report("toolRoundTrip", model: model, started: started, usage: first.usage + second.usage)
    }
}

@Suite("Live Anthropic (real API)", .serialized)
struct LiveAnthropicTests {
    // Thinking is switched off for the capped requests so the 16/64-token caps buy visible output, not reasoning.
    static let harness = LiveHarness(provider: .anthropic, candidates: ["claude-haiku-5-5", "claude-haiku-4-5", "claude-haiku-4-5-20251001"]) {
        AnthropicProvider(apiKey: $0, options: .init(thinking: .disabled))
    }
    @Test func listModels() async throws { try await Self.harness.listModels() }
    @Test func streamedText() async throws { try await Self.harness.streamedText() }
    @Test func toolRoundTrip() async throws { try await Self.harness.toolRoundTrip() }

    /// The API requires thinking blocks to accompany a replayed tool call. This checks the adapter's in-memory replay against
    /// the real API with thinking left on (the default of current models).
    @Test func toolRoundTripWithThinkingReplay() async throws {
        guard let key = Self.harness.key else { print("SKIPPED(no ORIX_DEV_ANTHROPIC_API_KEY)"); return }
        let client = AnthropicProvider(apiKey: key, options: .init(thinking: .adaptive(summarized: true), effort: "high"))
        let model = "claude-haiku-5-5"
        guard try await client.listModels().contains(where: { $0.id == model }) else { print("SKIPPED(\(model) is not available to this key)"); return }
        let started = Date()
        let question = LLMMessage.user("Work out 17 × 23 − 91 carefully. The result is the name of a key: look that key up with the orix_lookup tool and tell me its value.")
        let first = try await client.complete(LLMRequest(model: model, messages: [question], tools: [LiveHarness.lookupTool], maxOutputTokens: 400))
        guard let call = first.toolUses.first else { print("SKIPPED(the model answered without calling the tool; nothing to replay)"); return }
        let followUp = LLMRequest(model: model, messages: [
            question, LLMMessage(role: .assistant, content: first.content),
            LLMMessage(role: .user, content: [.toolResult(toolUseID: call.id, content: "the stored value is 42", isError: false)]),
        ], tools: [LiveHarness.lookupTool], maxOutputTokens: 400)
        let replayed = client.requestBody(for: followUp).injected
        let second = try await client.complete(followUp)
        #expect(second.text.contains("42"))
        Self.harness.report("toolRoundTripWithThinkingReplay", model: model, started: started, usage: first.usage + second.usage,
                            note: replayed ? "thinking-blocks-replayed-and-accepted" : "model-did-not-think-before-the-call")
    }
}

@Suite("Live OpenAI (real API)", .serialized)
struct LiveOpenAITests {
    // Non-reasoning small models first: a reasoning model can spend a 16-token cap entirely on reasoning.
    static let harness = LiveHarness(provider: .openai, candidates: ["gpt-4o-mini", "gpt-4.1-mini"]) { OpenAIProvider(apiKey: $0) }
    @Test func listModels() async throws { try await Self.harness.listModels() }
    @Test func streamedText() async throws { try await Self.harness.streamedText() }
    @Test func toolRoundTrip() async throws { try await Self.harness.toolRoundTrip() }
}

@Suite("Live OpenRouter (real API)", .serialized)
struct LiveOpenRouterTests {
    static let harness = LiveHarness(provider: .openrouter, candidates: ["openai/gpt-4o-mini", "google/gemini-3.1-flash-lite", "mistralai/mistral-nemo"]) {
        OpenRouterProvider(apiKey: $0, routing: ProviderRouting(allowFallbacks: true, requireParameters: true))
    }
    @Test func listModels() async throws { try await Self.harness.listModels() }
    @Test func streamedText() async throws {
        try await Self.harness.streamedText()
    }
    @Test func toolRoundTrip() async throws { try await Self.harness.toolRoundTrip() }

    /// OpenRouter reports what the request cost; the adapter must surface it.
    @Test func reportsCost() async throws {
        guard let client = Self.harness.client() else { return }
        let model = try #require(Self.harness.pickModel(try await client.listModels()))
        let started = Date()
        let response = try await client.complete(LLMRequest(model: model, messages: [.user("Reply with the single word: pong")], maxOutputTokens: 16))
        let cost = try #require(response.usage.reportedCostUSD, "usage.cost was not reported")
        #expect(cost > 0 && cost < 0.001)
        Self.harness.report("reportsCost", model: model, started: started, usage: response.usage)
    }
}
#endif
