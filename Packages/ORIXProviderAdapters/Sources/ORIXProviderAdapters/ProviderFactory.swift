// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/ProviderFactory.swift
// Description: Builds the adapter for a provider id and runs the minimal "test connection" request used by the BYOK settings.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public enum ProviderFactory {
    /// Builds the adapter for `id`. An id this package has no adapter for yields a provider whose every call throws
    /// `LLMError.unsupported` (never a silent stand-in).
    public static func make(_ id: ProviderID, apiKey: String, session: URLSession = .shared) -> any LLMProvider {
        switch id {
        case .anthropic: return AnthropicProvider(apiKey: apiKey, session: session)
        case .openai: return OpenAIProvider(apiKey: apiKey, session: session)
        case .openrouter: return OpenRouterProvider(apiKey: apiKey, session: session)
        default:
            Redactor.shared.register(secret: apiKey)
            return UnsupportedProvider(id: id)
        }
    }

    /// Same, wrapped in `RetryingProvider`.
    public static func makeRetrying(_ id: ProviderID, apiKey: String, session: URLSession = .shared, policy: RetryPolicy = .default) -> any LLMProvider {
        RetryingProvider(make(id, apiKey: apiKey, session: session), policy: policy)
    }
}

/// Stands in for a provider id without an adapter; every call fails with a typed error.
public struct UnsupportedProvider: LLMProvider {
    public let id: ProviderID
    public init(id: ProviderID) { self.id = id }
    private var error: LLMError { .unsupported("No adapter exists for provider \"\(id.rawValue)\".") }
    public func listModels() async throws -> [ModelInfo] { throw error }
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

public struct ProviderHealthResult: Sendable, Hashable {
    public var provider: ProviderID
    public var model: String
    /// True when the provider streamed a turn to its stop event.
    public var ok: Bool
    /// Wall-clock time of the whole request.
    public var latencyMs: Int
    /// Time to the first stream event, when one arrived.
    public var firstEventMs: Int?
    public var usage: TokenUsage?
    public var error: LLMError?
    /// `error.errorDescription`, for direct display.
    public var message: String?
}

public enum ProviderHealth {
    /// Output cap of the probe. Small on purpose: this request is billed to the user's key.
    public static let maxOutputTokens = 8

    /// Sends one minimal streamed request (a one-word prompt, at most 8 output tokens) and reports whether the provider
    /// answered, how fast, and the typed error otherwise. Never throws. A reasoning model may spend the whole cap on
    /// reasoning and return no text; the probe still counts as healthy because the round trip completed.
    public static func check(provider: any LLMProvider, model: String) async -> ProviderHealthResult {
        let start = Date()
        var first: Int?
        var usage: TokenUsage?
        func ms() -> Int { Int((Date().timeIntervalSince(start) * 1000).rounded()) }
        do {
            var stopped = false
            let request = LLMRequest(model: model, messages: [.user("ping")], maxOutputTokens: maxOutputTokens)
            for try await event in provider.stream(request) {
                if first == nil { first = ms() }
                if case .usage(let u) = event { usage = u }
                if case .stop = event { stopped = true }
            }
            guard stopped else { throw LLMError.network("The response stream ended without a stop event.") }
            return ProviderHealthResult(provider: provider.id, model: model, ok: true, latencyMs: ms(), firstEventMs: first, usage: usage)
        } catch {
            let e = Transport.llmError(from: error)
            return ProviderHealthResult(provider: provider.id, model: model, ok: false, latencyMs: ms(), firstEventMs: first, usage: usage,
                                        error: e, message: e.errorDescription)
        }
    }
}
