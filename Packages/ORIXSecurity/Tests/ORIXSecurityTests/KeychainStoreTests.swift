// ORIX OS Automation
// File: Packages/ORIXSecurity/Tests/ORIXSecurityTests/KeychainStoreTests.swift
// Description: Keychain tests. Naming/masking are unit tests; item tests are integration tests on the real Keychain under a unique test-only service, cleaned up afterwards.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
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
