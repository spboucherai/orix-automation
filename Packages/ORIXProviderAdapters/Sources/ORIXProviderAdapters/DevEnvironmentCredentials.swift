// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Sources/ORIXProviderAdapters/DevEnvironmentCredentials.swift
// Description: Developer-only credential source for live provider tests: reads ORIX_DEV_*_API_KEY from the process environment. Compiled in DEBUG builds only.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
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
