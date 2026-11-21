// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/ModelRegistry.swift
// Description      : Maintained model registry (context, output cap, USD prices
//                    per MTok, request-shaping capabilities) merged into what
//                    each provider's API lists.
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

/// One maintained registry entry. Every number here was read from the provider's own documentation on
/// `ModelRegistry.lastVerified`; anything that could not be read there is nil (unknown), never estimated.
public struct RegisteredModel: Sendable, Hashable {
    public var id: String
    public var provider: ProviderID
    public var displayName: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var inputPricePerMTok: Double?
    public var outputPricePerMTok: Double?
    /// Price of a cache hit per MTok, when published. (`TokenUsage.costUSD` in Core applies a flat 0.1× instead.)
    public var cacheReadPricePerMTok: Double?
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsStructuredOutput: Bool
    /// False when the model rejects a `temperature` field (the adapter then omits it).
    public var acceptsTemperature: Bool
    /// False when the model rejects `tool_choice` values that force a call (Anthropic `any` / `tool`).
    public var acceptsForcedToolChoice: Bool
    /// False when the model rejects `thinking: {type: "disabled"}` (Anthropic only).
    public var thinkingCanBeDisabled: Bool
    public var note: String?

    public init(id: String, provider: ProviderID, displayName: String, contextWindow: Int? = nil, maxOutputTokens: Int? = nil,
                inputPricePerMTok: Double? = nil, outputPricePerMTok: Double? = nil, cacheReadPricePerMTok: Double? = nil,
                supportsTools: Bool = true, supportsVision: Bool = true, supportsStructuredOutput: Bool = true,
                acceptsTemperature: Bool = true, acceptsForcedToolChoice: Bool = true, thinkingCanBeDisabled: Bool = true, note: String? = nil) {
        self.id = id; self.provider = provider; self.displayName = displayName; self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens; self.inputPricePerMTok = inputPricePerMTok; self.outputPricePerMTok = outputPricePerMTok
        self.cacheReadPricePerMTok = cacheReadPricePerMTok; self.supportsTools = supportsTools; self.supportsVision = supportsVision
        self.supportsStructuredOutput = supportsStructuredOutput; self.acceptsTemperature = acceptsTemperature
        self.acceptsForcedToolChoice = acceptsForcedToolChoice; self.thinkingCanBeDisabled = thinkingCanBeDisabled; self.note = note
    }

    /// The registry's own view of the model (`source: "registry"`).
    public var modelInfo: ModelInfo {
        ModelInfo(id: id, provider: provider, displayName: displayName, contextWindow: contextWindow, maxOutputTokens: maxOutputTokens,
                  supportsTools: supportsTools, supportsVision: supportsVision, supportsStructuredOutput: supportsStructuredOutput,
                  inputPricePerMTok: inputPricePerMTok, outputPricePerMTok: outputPricePerMTok, source: "registry")
    }
}

public enum ModelRegistry {
    /// Date (ISO 8601) on which the entries below were last compared with the official pages listed in `sources`.
    public static let lastVerified = "2026-11-21"

    /// Pages the numbers were read from.
    public static let sources: [ProviderID: [String]] = [
        .anthropic: ["https://platform.claude.com/docs/en/about-claude/pricing", "https://platform.claude.com/docs/en/about-claude/models/overview"],
        .openai: ["https://developers.openai.com/api/docs/pricing", "https://developers.openai.com/api/docs/models/compare"],
        // OpenRouter has no registry entries: its catalog endpoint is the source of prices and limits.
        .openrouter: ["https://openrouter.ai/api/v1/models"],
    ]

    public static let entries: [RegisteredModel] = anthropic + openai

    // Anthropic: prices from the pricing page (standard, global routing, 5-minute cache). Context and output caps from the
    // models overview. `acceptsTemperature` is false everywhere because the adapter speaks API version 2026-10-21, on which
    // any sampling parameter is a 400 for every model.
    static let anthropic: [RegisteredModel] = {
        func m(_ id: String, _ name: String, _ ctx: Int?, _ out: Int?, _ pin: Double, _ pout: Double, read: Double,
               forced: Bool = true, thinkingOff: Bool = true, note: String? = nil) -> RegisteredModel {
            RegisteredModel(id: id, provider: .anthropic, displayName: name, contextWindow: ctx, maxOutputTokens: out,
                            inputPricePerMTok: pin, outputPricePerMTok: pout, cacheReadPricePerMTok: read,
                            acceptsTemperature: false, acceptsForcedToolChoice: forced, thinkingCanBeDisabled: thinkingOff, note: note)
        }
        let M = 1_000_000, K128 = 128_000
        return [
            m("claude-fable-5-2", "Claude Fable 5.2", M, K128, 8, 40, read: 0.20, forced: false, thinkingOff: false),
            m("claude-mythos-5-2", "Claude Mythos 5.2", M, K128, 8, 40, read: 0.20, forced: false, thinkingOff: false, note: "Verified organizations only."),
            m("claude-fable-5-1", "Claude Fable 5.1", M, K128, 10, 50, read: 0.25, forced: false, thinkingOff: false),
            m("claude-mythos-5-1", "Claude Mythos 5.1", M, K128, 10, 50, read: 0.25, forced: false, thinkingOff: false, note: "Verified organizations only."),
            m("claude-fable-5", "Claude Fable 5", M, K128, 10, 50, read: 1, thinkingOff: false),
            m("claude-mythos-5", "Claude Mythos 5", M, K128, 10, 50, read: 1, thinkingOff: false, note: "Verified organizations only."),
            m("claude-opus-5-5", "Claude Opus 5.5", M, K128, 4, 20, read: 0.20, forced: false, thinkingOff: false),
            m("claude-opus-5", "Claude Opus 5", M, K128, 5, 25, read: 0.50),
            m("claude-opus-4-8", "Claude Opus 4.8", M, K128, 5, 25, read: 0.50),
            m("claude-opus-4-7", "Claude Opus 4.7", M, K128, 5, 25, read: 0.50),
            m("claude-opus-4-6", "Claude Opus 4.6", M, K128, 5, 25, read: 0.50),
            m("claude-opus-4-5", "Claude Opus 4.5", nil, nil, 5, 25, read: 0.50, note: "Legacy."),
            m("claude-sonnet-5-5", "Claude Sonnet 5.5", M, K128, 2, 10, read: 0.10, forced: false, thinkingOff: false),
            m("claude-sonnet-5", "Claude Sonnet 5", M, K128, 2, 10, read: 0.20),
            m("claude-sonnet-4-6", "Claude Sonnet 4.6", M, K128, 3, 15, read: 0.30),
            m("claude-sonnet-4-5", "Claude Sonnet 4.5", nil, nil, 3, 15, read: 0.30, note: "Deprecated; retires 2026-11-30."),
            m("claude-haiku-5-5", "Claude Haiku 5.5", M, K128, 0.10, 0.50, read: 0.01,
              note: "Prices for prompts up to 100,000 tokens; above that the request is billed at $0.50 / $2.50 per MTok."),
            m("claude-haiku-4-5", "Claude Haiku 4.5", 200_000, 64_000, 1, 5, read: 0.10),
        ]
    }()

    // OpenAI: standard-tier, short-context text prices from the pricing page. Context/output caps only where the model
    // comparison page showed them; nil elsewhere. Models served only by the Responses API (`*-pro`) are not listed because
    // this package speaks Chat Completions.
    static let openai: [RegisteredModel] = {
        func m(_ id: String, _ name: String, _ pin: Double, _ pout: Double, read: Double?, ctx: Int? = nil, out: Int? = nil,
               temperature: Bool = true) -> RegisteredModel {
            RegisteredModel(id: id, provider: .openai, displayName: name, contextWindow: ctx, maxOutputTokens: out,
                            inputPricePerMTok: pin, outputPricePerMTok: pout, cacheReadPricePerMTok: read, acceptsTemperature: temperature)
        }
        return [
            m("gpt-6.2-astra", "GPT-6.2 Astra", 8, 40, read: 0.40, ctx: 1_050_000, out: 128_000),
            m("gpt-6.2-sol", "GPT-6.2 Sol", 2, 10, read: 0.10, ctx: 1_050_000, out: 128_000),
            m("gpt-6.1-sol", "GPT-6.1 Sol", 2, 10, read: 0.10),
            m("gpt-6.1-terra", "GPT-6.1 Terra", 1, 5, read: 0.05),
            m("gpt-6-astra", "GPT-6 Astra", 10, 50, read: 1),
            m("gpt-6-sol", "GPT-6 Sol", 2, 10, read: 0.20),
            m("gpt-6-luna", "GPT-6 Luna", 0.10, 0.50, read: 0.01, ctx: 1_050_000, out: 128_000),
            m("gpt-5.6-sol", "GPT-5.6 Sol", 4, 20, read: 0.40),
            m("gpt-5.6-terra", "GPT-5.6 Terra", 2, 12, read: 0.20),
            m("gpt-5.6-luna", "GPT-5.6 Luna", 0.20, 1.20, read: 0.02),
            m("gpt-5.5", "GPT-5.5", 5, 30, read: 0.50, temperature: false),
            m("gpt-5.4", "GPT-5.4", 2.50, 15, read: 0.25, temperature: false),
            m("gpt-5.4-mini", "GPT-5.4 mini", 0.75, 4.50, read: 0.075, temperature: false),
            m("gpt-5.4-nano", "GPT-5.4 nano", 0.20, 1.25, read: 0.02, temperature: false),
            m("gpt-5.2", "GPT-5.2", 1.75, 14, read: 0.175, temperature: false),
            m("gpt-5.1", "GPT-5.1", 1.25, 10, read: 0.125, temperature: false),
            m("gpt-5", "GPT-5", 1.25, 10, read: 0.125, temperature: false),
            m("gpt-5-mini", "GPT-5 mini", 0.25, 2, read: 0.025, temperature: false),
            m("gpt-5-nano", "GPT-5 nano", 0.05, 0.40, read: 0.005, temperature: false),
            m("gpt-4.1", "GPT-4.1", 2, 8, read: 0.50),
            m("gpt-4.1-mini", "GPT-4.1 mini", 0.40, 1.60, read: 0.10),
            m("gpt-4o", "GPT-4o", 2.50, 10, read: 1.25),
            m("gpt-4o-mini", "GPT-4o mini", 0.15, 0.60, read: 0.075),
            m("o3", "o3", 2, 8, read: 0.50, temperature: false),
        ]
    }()

    /// Registry entries of one provider as `ModelInfo` with `source: "registry"`.
    public static func models(for provider: ProviderID) -> [ModelInfo] {
        entries.filter { $0.provider == provider }.map(\.modelInfo)
    }

    /// Looks up an entry by exact id, then by the id without a dated snapshot suffix
    /// (`claude-haiku-4-5-20251001` → `claude-haiku-4-5`, `gpt-4o-mini-2024-07-18` → `gpt-4o-mini`).
    public static func entry(provider: ProviderID, id: String) -> RegisteredModel? {
        if let e = entries.first(where: { $0.provider == provider && $0.id == id }) { return e }
        let base = baseID(id)
        guard base != id else { return nil }
        return entries.first(where: { $0.provider == provider && $0.id == base })
    }

    public static func info(provider: ProviderID, id: String) -> ModelInfo? {
        guard var info = entry(provider: provider, id: id)?.modelInfo else { return nil }
        info.id = id
        return info
    }

    /// Fills the gaps of what an API returned with registry data. API values win where both exist; prices, which no
    /// first-party API returns, come from the registry. Models the API did not list are not added: the key cannot use them.
    public static func merge(api: [ModelInfo]) -> [ModelInfo] {
        api.map { item in
            guard let e = entry(provider: item.provider, id: item.id) else { return item }
            var out = item
            if out.displayName == out.id { out.displayName = e.displayName }
            out.contextWindow = out.contextWindow ?? e.contextWindow
            out.maxOutputTokens = out.maxOutputTokens ?? e.maxOutputTokens
            out.inputPricePerMTok = out.inputPricePerMTok ?? e.inputPricePerMTok
            out.outputPricePerMTok = out.outputPricePerMTok ?? e.outputPricePerMTok
            return out
        }
    }

    static func baseID(_ id: String) -> String {
        for pattern in [#"-\d{8}$"#, #"-\d{4}-\d{2}-\d{2}$"#] {
            if let r = id.range(of: pattern, options: .regularExpression) { return String(id[..<r.lowerBound]) }
        }
        return id
    }
}
