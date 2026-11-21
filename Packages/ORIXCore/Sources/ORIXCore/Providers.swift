// ORIX OS Automation
// File: Packages/ORIXCore/Sources/ORIXCore/Providers.swift
// Description: Provider-independent LLM contract: requests, messages, streaming events, usage, model metadata and typed provider errors.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let anthropic = ProviderID(rawValue: "anthropic")
    public static let openai = ProviderID(rawValue: "openai")
    public static let openrouter = ProviderID(rawValue: "openrouter")
    public static let all: [ProviderID] = [.anthropic, .openai, .openrouter]
    public var description: String { rawValue }
    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter"
        default: return rawValue
        }
    }
}

public struct ModelInfo: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var provider: ProviderID
    public var displayName: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsStructuredOutput: Bool
    /// USD per million tokens, when the provider or the maintained registry supplies it. Nil means unknown, never guessed.
    public var inputPricePerMTok: Double?
    public var outputPricePerMTok: Double?
    /// `api` (returned by the provider), `registry` (maintained list), or `user` (typed by hand).
    public var source: String

    public init(id: String, provider: ProviderID, displayName: String? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil,
                supportsTools: Bool = true, supportsVision: Bool = false, supportsStructuredOutput: Bool = false,
                inputPricePerMTok: Double? = nil, outputPricePerMTok: Double? = nil, source: String = "api") {
        self.id = id; self.provider = provider; self.displayName = displayName ?? id; self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens; self.supportsTools = supportsTools; self.supportsVision = supportsVision
        self.supportsStructuredOutput = supportsStructuredOutput; self.inputPricePerMTok = inputPricePerMTok
        self.outputPricePerMTok = outputPricePerMTok; self.source = source
    }
}

/// A provider + model pair, as stored in agent profiles and run records.
public struct ModelRef: Codable, Sendable, Hashable {
    public var provider: ProviderID
    public var model: String
    public init(provider: ProviderID, model: String) { self.provider = provider; self.model = model }
    public var displayString: String { "\(provider.displayName) · \(model)" }
}

public enum LLMRole: String, Codable, Sendable { case user, assistant }

public struct LLMToolUse: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public init(id: String, name: String, input: JSONValue) { self.id = id; self.name = name; self.input = input }
}

public enum LLMContent: Codable, Sendable, Hashable {
    case text(String)
    case toolUse(LLMToolUse)
    case toolResult(toolUseID: String, content: String, isError: Bool)
    case image(base64: String, mediaType: String)
}

public struct LLMMessage: Codable, Sendable, Hashable {
    public var role: LLMRole
    public var content: [LLMContent]
    public init(role: LLMRole, content: [LLMContent]) { self.role = role; self.content = content }
    public static func user(_ text: String) -> LLMMessage { .init(role: .user, content: [.text(text)]) }
    public static func assistant(_ text: String) -> LLMMessage { .init(role: .assistant, content: [.text(text)]) }

    public var text: String {
        content.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
    }
    public var toolUses: [LLMToolUse] {
        content.compactMap { if case .toolUse(let u) = $0 { return u }; return nil }
    }
}

public struct LLMToolSpec: Codable, Sendable, Hashable {
    /// Provider-safe name (`^[a-zA-Z0-9_-]{1,64}$`). ORIX tool identifiers map `.` to `__`.
    public var name: String
    public var description: String
    public var inputSchema: JSONSchema
    public init(name: String, description: String, inputSchema: JSONSchema) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
    public static func providerName(forToolID id: String) -> String { id.replacingOccurrences(of: ".", with: "__") }
    public static func toolID(fromProviderName name: String) -> String { name.replacingOccurrences(of: "__", with: ".") }
}

public enum LLMToolChoice: Codable, Sendable, Hashable {
    case auto, none, required
    case tool(name: String)
}

public struct LLMRequest: Sendable, Hashable {
    public var model: String
    public var system: String?
    public var messages: [LLMMessage]
    public var tools: [LLMToolSpec]
    public var toolChoice: LLMToolChoice
    public var maxOutputTokens: Int
    public var temperature: Double?
    /// When set, the adapter asks for JSON matching this schema using the provider's structured-output mechanism,
    /// or reports `LLMError.unsupported` if the model cannot.
    public var responseSchema: JSONSchema?
    /// Ask the adapter to mark the system prompt and tool list as cacheable where the provider supports prompt caching.
    public var cacheSystemAndTools: Bool

    public init(model: String, system: String? = nil, messages: [LLMMessage], tools: [LLMToolSpec] = [], toolChoice: LLMToolChoice = .auto,
                maxOutputTokens: Int = 4096, temperature: Double? = nil, responseSchema: JSONSchema? = nil, cacheSystemAndTools: Bool = false) {
        self.model = model; self.system = system; self.messages = messages; self.tools = tools; self.toolChoice = toolChoice
        self.maxOutputTokens = maxOutputTokens; self.temperature = temperature; self.responseSchema = responseSchema
        self.cacheSystemAndTools = cacheSystemAndTools
    }
}

public struct TokenUsage: Codable, Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// Cost reported by the provider (OpenRouter), when present.
    public var reportedCostUSD: Double?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, reportedCostUSD: Double? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens; self.reportedCostUSD = reportedCostUSD
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        let cost: Double? = (a.reportedCostUSD == nil && b.reportedCostUSD == nil) ? nil : (a.reportedCostUSD ?? 0) + (b.reportedCostUSD ?? 0)
        return TokenUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
                          cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens, cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
                          reportedCostUSD: cost)
    }

    /// Cost in USD: the provider's own figure when reported, else computed from known prices, else nil (unknown — never invented).
    public func costUSD(model: ModelInfo?) -> Double? {
        if let reportedCostUSD { return reportedCostUSD }
        guard let m = model, let pin = m.inputPricePerMTok, let pout = m.outputPricePerMTok else { return nil }
        let input = Double(inputTokens) * pin + Double(cacheReadTokens) * pin * 0.1 + Double(cacheWriteTokens) * pin * 1.25
        return (input + Double(outputTokens) * pout) / 1_000_000
    }
}

public enum LLMStopReason: String, Codable, Sendable {
    case endTurn, toolUse, maxTokens, stopSequence, refusal, contentFilter, other
}

public enum LLMStreamEvent: Sendable, Hashable {
    case textDelta(String)
    /// Provider-surfaced reasoning summary text. Never hidden chain-of-thought; shown only when the API returns it.
    case reasoningSummaryDelta(String)
    case toolUseStarted(index: Int, id: String, name: String)
    case toolUseInputDelta(index: Int, partialJSON: String)
    /// A complete, parsed tool call.
    case toolUse(LLMToolUse)
    case usage(TokenUsage)
    case stop(LLMStopReason)
}

public struct LLMResponse: Sendable, Hashable {
    public var model: String
    public var content: [LLMContent]
    public var stopReason: LLMStopReason
    public var usage: TokenUsage
    public var reasoningSummary: String

    public init(model: String, content: [LLMContent], stopReason: LLMStopReason, usage: TokenUsage, reasoningSummary: String = "") {
        self.model = model; self.content = content; self.stopReason = stopReason; self.usage = usage; self.reasoningSummary = reasoningSummary
    }
    public var text: String { LLMMessage(role: .assistant, content: content).text }
    public var toolUses: [LLMToolUse] { LLMMessage(role: .assistant, content: content).toolUses }
}

public enum LLMError: Error, Sendable, Hashable, LocalizedError {
    case missingCredential(ProviderID)
    case authentication(String)
    case rateLimited(retryAfterSeconds: Double?)
    case overloaded
    case invalidRequest(String)
    case modelNotFound(String)
    case contextTooLong(String)
    case unsupported(String)
    case server(status: Int, message: String)
    case network(String)
    case decoding(String)
    case canceled

    /// Transient errors worth a bounded retry with backoff.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network: return true
        case .server(let status, _): return status >= 500
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let p): return "No API key is stored for \(p.displayName). Add one in Settings › Providers."
        case .authentication(let m): return "The provider rejected the API key. \(m)"
        case .rateLimited(let s): return "Rate limited by the provider" + (s.map { " (retry after \(Int($0)) s)." } ?? ".")
        case .overloaded: return "The provider is overloaded. Try again shortly."
        case .invalidRequest(let m): return "The provider rejected the request: \(m)"
        case .modelNotFound(let m): return "Model not found: \(m)"
        case .contextTooLong(let m): return "The conversation exceeds the model's context window. \(m)"
        case .unsupported(let m): return "Not supported by this model or provider: \(m)"
        case .server(let s, let m): return "Provider error \(s): \(m)"
        case .network(let m): return "Network error: \(m)"
        case .decoding(let m): return "Could not read the provider's response: \(m)"
        case .canceled: return "Canceled"
        }
    }
}

public protocol LLMProvider: Sendable {
    var id: ProviderID { get }
    /// Models available to the stored key. Throws `LLMError`.
    func listModels() async throws -> [ModelInfo]
    /// Streams one model turn. The stream ends after `.stop`; errors are `LLMError`. Cancelling the consuming task cancels the request.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

public extension LLMProvider {
    /// Runs one turn to completion, forwarding each event to `onEvent`.
    func complete(_ request: LLMRequest, onEvent: (@Sendable (LLMStreamEvent) -> Void)? = nil) async throws -> LLMResponse {
        var text = "", reasoning = ""
        var content: [LLMContent] = []
        var usage = TokenUsage()
        var stop: LLMStopReason = .other
        for try await event in stream(request) {
            onEvent?(event)
            switch event {
            case .textDelta(let d): text += d
            case .reasoningSummaryDelta(let d): reasoning += d
            case .toolUse(let u):
                if !text.isEmpty { content.append(.text(text)); text = "" }
                content.append(.toolUse(u))
            case .usage(let u): usage = u
            case .stop(let s): stop = s
            case .toolUseStarted, .toolUseInputDelta: break
            }
        }
        if !text.isEmpty { content.append(.text(text)) }
        return LLMResponse(model: request.model, content: content, stopReason: stop, usage: usage, reasoningSummary: reasoning)
    }
}

/// Finds a provider client for a model reference. The app builds one from Keychain-stored keys.
public protocol ProviderResolving: Sendable {
    func provider(for id: ProviderID) async throws -> any LLMProvider
    func modelInfo(_ ref: ModelRef) async -> ModelInfo?
}
