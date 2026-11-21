// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXSecurity/Tests/ORIXSecurityTests/KeychainStoreTests.swift
// Description      : Keychain tests. Naming/masking are unit tests; item tests
//                    are integration tests on the real Keychain under a unique
//                    test-only service, cleaned up afterwards.
// Module           : ORIXSecurityTests
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
import Testing
@testable import ORIXSecurity

@Suite("KeychainStore naming and masking (unit)")
struct KeychainNamingTests {
    @Test func accountNames() {
        #expect(KeychainStore.providerAccount(.anthropic) == "provider.anthropic")
        #expect(KeychainStore.providerAccount(ProviderID(rawValue: "custom")) == "provider.custom")
        #expect(KeychainStore.secretAccount("github-token") == "secret.github-token")
        #expect(KeychainStore().service == "ai.spboucher.orix.automation")
    }

    @Test func maskingNeverRevealsMoreThanFourTrailingCharacters() {
        #expect(KeychainStore.masked("sk-ant-api03-ABCDEFGHIJKLMNOPa1b2") == "sk-…a1b2")
        #expect(KeychainStore.masked("xai-0123456789abcdefWXYZ") == "xai-…WXYZ")
        #expect(KeychainStore.masked("0123456789abcdefghijklmnop") == "…mnop")
        #expect(KeychainStore.masked("12345678-abcdefghijklmnop") == "…mnop")
        #expect(KeychainStore.masked("short") == "••••")
        #expect(KeychainStore.masked("") == "••••")
        #expect(KeychainStore.masked("twelve-chars") == "…rs")
        #expect(KeychainStore().masked("sk-proj-0000000000000000zzzz") == "sk-…zzzz")
        for value in ["sk-ant-api03-ABCDEFGHIJKLMNOPa1b2", "ghp_abcdefghijklmnopqrstuvwxyz0123456789"] {
            let masked = KeychainStore.masked(value)
            let middle = String(value.dropFirst(4).dropLast(4))
            #expect(!masked.contains(middle))
            #expect(masked.count <= 12)
        }
    }

    @Test func errorsAreReadable() {
        let missing = KeychainError.missingSecret(reference: "github").errorDescription ?? ""
        #expect(missing.contains("github") && missing.contains("Keychain"))
        let status = KeychainError.status(errSecItemNotFound, operation: "read")
        #expect(status.osStatus == errSecItemNotFound)
        #expect(status.errorDescription?.contains("-25300") == true)
        #expect(throws: KeychainError.invalidAccount) { try KeychainStore(service: "ai.spboucher.orix.automation.tests.unused").set("x", account: "") }
    }
}

@Suite("KeychainStore (integration, real Keychain, unique test-only service)", .serialized)
struct KeychainIntegrationTests {
    /// A store under a service nobody else uses. Returns nil, after printing why, when this session has no usable Keychain.
    private func makeStore() -> KeychainStore? {
        let store = KeychainStore(service: "ai.spboucher.orix.automation.tests.\(UUID().uuidString)")
        do {
            try store.set("probe-value", account: "probe")
            try store.delete(account: "probe")
            return store
        } catch {
            print("SKIPPED(Keychain is not usable in this session: \(error.localizedDescription))")
            return nil
        }
    }

    private func cleanUp(_ store: KeychainStore) {
        for account in (try? store.accounts()) ?? [] { try? store.delete(account: account) }
    }

    @Test func setGetUpdateDeleteAndList() throws {
        guard let store = makeStore() else {
            withKnownIssue("Keychain unavailable in this session") { Issue.record("SKIPPED(Keychain unavailable)") }
            return
        }
        defer { cleanUp(store) }
        #expect(try store.accounts().isEmpty)
        #expect(try store.get(account: "provider.anthropic") == nil)
        #expect(!store.exists(account: "provider.anthropic"))

        try store.set("first-value-0001", account: KeychainStore.providerAccount(.anthropic))
        try store.set("other-value-0002", account: KeychainStore.secretAccount("github"))
        #expect(try store.get(account: "provider.anthropic") == "first-value-0001")
        #expect(store.exists(account: "provider.anthropic"))
        #expect(try store.accounts() == ["provider.anthropic", "secret.github"])

        try store.set("second-value-0003 ünïcödé", account: "provider.anthropic")
        #expect(try store.get(account: "provider.anthropic") == "second-value-0003 ünïcödé")
        #expect(try store.accounts().count == 2)

        try store.delete(account: "provider.anthropic")
        try store.delete(account: "provider.anthropic")
        #expect(try store.get(account: "provider.anthropic") == nil)
        #expect(try store.accounts() == ["secret.github"])

        // Another service does not see these items.
        let other = KeychainStore(service: store.service + ".other")
        #expect(try other.get(account: "secret.github") == nil)
        #expect(try other.accounts().isEmpty)

        cleanUp(store)
        #expect(try store.accounts().isEmpty)
    }

    @Test func resolverReadsRegistersAndReportsMissing() async throws {
        guard let store = makeStore() else {
            withKnownIssue("Keychain unavailable in this session") { Issue.record("SKIPPED(Keychain unavailable)") }
            return
        }
        defer { cleanUp(store) }
        let value = "orix-resolver-\(UUID().uuidString)"
        defer { Redactor.shared.unregister(secret: value) }
        try store.set(value, account: KeychainStore.secretAccount("deploy"))
        let resolver = KeychainSecretResolver(store: store)
        #expect(Redactor.shared.redact("value is \(value)").contains(value))
        #expect(try await resolver.secret(reference: "deploy") == value)
        #expect(Redactor.shared.redact("value is \(value)") == "value is \(Redactor.placeholder)")
        await #expect(throws: KeychainError.missingSecret(reference: "absent")) {
            _ = try await resolver.secret(reference: "absent")
        }
    }
}
