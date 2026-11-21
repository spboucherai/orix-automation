// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXSecurity/Sources/ORIXSecurity/KeychainStore.swift
// Description      : Generic-password Keychain items for provider keys and
//                    named secrets, with a resolver that hands values to tools
//                    at the last moment.
// Module           : ORIXSecurity
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
import Security

public enum KeychainError: Error, Sendable, Hashable, LocalizedError {
    /// A Security framework call failed.
    case status(OSStatus, operation: String)
    /// The stored item is not UTF-8 text.
    case invalidData(account: String)
    case invalidAccount
    /// No secret is stored under this reference.
    case missingSecret(reference: String)

    public var osStatus: OSStatus? {
        if case .status(let s, _) = self { return s }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .status(let status, let operation):
            let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
            return "Keychain \(operation) failed (\(status)): \(text)"
        case .invalidData(let account): return "The Keychain item \(account) does not contain text."
        case .invalidAccount: return "A Keychain account name cannot be empty."
        case .missingSecret(let reference):
            return "No secret named \(reference) is stored in the Keychain. Add it in Settings › Secrets, then run again."
        }
    }
}

/// Stores secrets as generic-password items of one service. It only ever touches items of its own service.
public struct KeychainStore: Sendable {
    public static let defaultService = "ai.spboucher.orix.automation"

    public let service: String
    /// When true, items live in the data-protection keychain (requires a signed app with a keychain access group).
    public let useDataProtectionKeychain: Bool

    public init(service: String = KeychainStore.defaultService, useDataProtectionKeychain: Bool = false) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    // MARK: Items

    /// Creates or replaces the value stored for `account`.
    public func set(_ value: String, account: String) throws {
        guard !account.isEmpty else { throw KeychainError.invalidAccount }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update, operation: "update") }
        var attributes = query(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "ORIX OS Automation (\(account))"
        let add = SecItemAdd(attributes as CFDictionary, nil)
        if add == errSecDuplicateItem {
            let retry = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard retry == errSecSuccess else { throw KeychainError.status(retry, operation: "update") }
            return
        }
        guard add == errSecSuccess else { throw KeychainError.status(add, operation: "add") }
    }

    public func get(account: String) throws -> String? {
        guard !account.isEmpty else { throw KeychainError.invalidAccount }
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status, operation: "read") }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData(account: account)
        }
        return text
    }

    /// Deleting an account that does not exist is not an error.
    public func delete(account: String) throws {
        guard !account.isEmpty else { throw KeychainError.invalidAccount }
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status, operation: "delete") }
    }

    /// Account names stored for this service, sorted. Values are not read.
    public func accounts() throws -> [String] {
        var q = query(account: nil)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.status(status, operation: "list") }
        let items = (result as? [[String: Any]]) ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    /// True when an item exists. The value is not read, so this never prompts.
    public func exists(account: String) -> Bool {
        guard !account.isEmpty else { return false }
        var q = query(account: account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess
    }

    private func query(account: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    // MARK: Naming and display

    public static func providerAccount(_ id: ProviderID) -> String { "provider.\(id.rawValue)" }
    public static func secretAccount(_ ref: String) -> String { "secret.\(ref)" }

    /// A display form that proves which key is stored without revealing it: at most a short vendor prefix and the
    /// last four characters (`sk-…a1b2`). Short values reveal nothing.
    public static func masked(_ value: String) -> String {
        let count = value.count
        if count < 8 { return "••••" }
        if count < 16 { return "…" + String(value.suffix(2)) }
        var prefix = ""
        if let dash = value.firstIndex(of: "-") {
            let head = value[...dash]
            if head.count <= 6, head.dropLast().allSatisfy({ $0.isLetter }) { prefix = String(head) }
        }
        return prefix + "…" + String(value.suffix(4))
    }

    public func masked(_ value: String) -> String { Self.masked(value) }
}

/// Resolves `secret.<reference>` items for tools. Every value it returns is registered with `Redactor.shared` first,
/// so it is scrubbed from logs, events and anything sent back to a model.
public struct KeychainSecretResolver: SecretResolving {
    public let store: KeychainStore

    public init(store: KeychainStore = KeychainStore()) { self.store = store }

    public func secret(reference: String) async throws -> String {
        guard let value = try store.get(account: KeychainStore.secretAccount(reference)) else {
            throw KeychainError.missingSecret(reference: reference)
        }
        Redactor.shared.register(secret: value)
        return value
    }
}
