// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/DevEnvironmentCredentials.swift
// Description      : Developer-only credential source for live provider tests:
//                    reads ORIX_DEV_*_API_KEY from the process environment.
//                    Compiled in DEBUG builds only.
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

#if DEBUG
import Foundation
import ORIXCore

/// Developer-only test adapter. It exists so live smoke tests can run with keys that a broker script
/// (`Scripts/test/with-dev-keys.sh`) injects into one process. It reads the process environment and nothing else: no file,
/// no Keychain, no defaults. The whole type is excluded from release builds by `#if DEBUG`; the shipping app gets keys from
/// the Keychain only.
public struct DevEnvironmentCredentials: Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }

    /// Name of the environment variable for a provider, or nil for a provider without one.
    public static func variableName(for provider: ProviderID) -> String? {
        switch provider {
        case .anthropic: return "ORIX_DEV_ANTHROPIC_API_KEY"
        case .openai: return "ORIX_DEV_OPENAI_API_KEY"
        case .openrouter: return "ORIX_DEV_OPENROUTER_API_KEY"
        default: return nil
        }
    }

    /// The key for a provider when its variable is set and not blank. The value is registered with `Redactor.shared`.
    public func apiKey(for provider: ProviderID) -> String? {
        guard let name = Self.variableName(for: provider),
              let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        Redactor.shared.register(secret: value)
        return value
    }

    /// Providers that have a key in this environment.
    public var availableProviders: [ProviderID] { ProviderID.all.filter { apiKey(for: $0) != nil } }
}
#endif
