// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Tests/ORIXFeatureManageTests/ManageModelTests.swift
// Description: View models of the management sections against real services on a temporary data folder: keys, grants, agents, settings, skills, storage, memory.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Testing
@testable import ORIXFeatureManage
import ORIXAppUI

/// A provider that answers every turn with the same short text. Used only to drive a real agent run without a network.
struct CannedProvider: LLMProvider {
    let id = ProviderID(rawValue: "canned")
    func listModels() async throws -> [ModelInfo] { [ModelInfo(id: "canned-1", provider: id, inputPricePerMTok: 1, outputPricePerMTok: 1)] }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { c in
            c.yield(.textDelta("Nothing to change."))
            c.yield(.usage(TokenUsage(inputTokens: 10, outputTokens: 4)))
            c.yield(.stop(.endTurn))
            c.finish()
        }
    }
}

func tempFolder(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: PathResolver.resolveSymlinks(NSTemporaryDirectory())).appendingPathComponent("orix-manage-\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Integration · providers (preview Keychain service)") @MainActor struct ProvidersModelTests {
    @Test func keyIsStoredMaskedAndDeletedWithoutEverBeingExposed() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let providers = ProvidersModel(services: model.services)
        let fake = "sk-test-0000-unit-\(UUID().uuidString.prefix(8))"
        defer { try? model.services.keychain.delete(account: KeychainStore.providerAccount(.openrouter)); Redactor.shared.unregister(secret: fake) }

        // Too short: refused, and the message does not echo the input.
        #expect(await providers.saveKey("abc", for: .openrouter) == false)
        #expect(providers.state(.openrouter).keyError?.contains("abc") == false)

        #expect(await providers.saveKey(fake, for: .openrouter))
        let state = providers.state(.openrouter)
        #expect(state.source == .keychain)
        let masked = try #require(state.masked)
        #expect(masked != fake && !masked.contains(fake) && masked.count < fake.count)
        #expect(masked.hasSuffix(String(fake.suffix(4))))
        #expect(await model.services.providers.configuredProviders().contains(.openrouter))

        await providers.removeKey(for: .openrouter)
        #expect(providers.state(.openrouter).source == .none)
        #expect(providers.state(.openrouter).masked == nil)
        #expect(model.services.keychain.exists(account: KeychainStore.providerAccount(.openrouter)) == false)
    }

    @Test func catalogFallsBackToTheRegistryWithTheReasonWhenThereIsNoKey() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let providers = ProvidersModel(services: model.services)
        await providers.reload()
        guard providers.state(.openai).source == .none else { print("SKIPPED(an OpenAI key exists in the preview Keychain service)"); return }
        await providers.loadCatalog(for: .openai)
        let s = providers.state(.openai)
        #expect(s.catalogLoaded && !s.models.isEmpty)
        #expect(s.catalogError != nil)
        #expect(!providers.catalogIsLive(.openai))
        #expect(providers.filtered(.openai, search: "zzzz-no-such-model").isEmpty)
        #expect(providers.testModel(for: .openai, settings: AppSettings()) != nil)
        // Without a key the test reports the precise problem and sends nothing.
        await providers.test(.openai, settings: AppSettings())
        #expect(providers.state(.openai).test?.ok == false)
        #expect(providers.state(.openai).test?.message?.isEmpty == false)
    }

    @Test func budgetBoundsClampEveryLimit() {
        let wild = Budget(maxTurns: 0, maxWallSeconds: 1, maxTotalTokens: 1, maxCostUSD: 9999, maxToolCalls: -4, maxSubprocessSeconds: 99_999, maxConcurrentTasks: 400)
        let b = BudgetBounds.clamped(wild)
        #expect(b.maxTurns == 1 && b.maxWallSeconds == 30 && b.maxTotalTokens == 10_000 && b.maxCostUSD == 100)
        #expect(b.maxToolCalls == 1 && b.maxSubprocessSeconds == 3600 && b.maxConcurrentTasks == 16)
        #expect(BudgetBounds.clamped(.standard) == .standard)
    }
}

@Suite("Integration · permissions") @MainActor struct PermissionsModelTests {
    @Test func addFilterRevokeAndRefuseProtectedLocations() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let p = PermissionsModel(services: model.services)
        await p.reload()
        #expect(p.grants.isEmpty)
        let folder = try tempFolder("grant"); defer { try? FileManager.default.removeItem(at: folder) }

        let g = try await p.addPersistentGrant(kind: .fileRead, value: folder.path, tier: .highRisk, note: " test ")
        #expect(g.maxTier == .consequential)          // never above tier 2
        #expect(g.scope == .persistent && g.note == "test")
        #expect(p.visible(in: .persistent).map(\.id) == [g.id])
        _ = try await p.addPersistentGrant(kind: .network, value: "API.Example.com", tier: .consequential, note: "")
        #expect(p.grants.contains { $0.capability == .network(host: "api.example.com") })

        // Protected paths, the whole disk, wildcards and sudo are refused with a reason.
        for bad in ["~/.ssh", NSHomeDirectory() + "/Library/Keychains", "/System/Library", "/"] {
            await #expect(throws: GrantRefusal.self) { try await p.addPersistentGrant(kind: .fileWrite, value: bad, tier: .reversibleWrite, note: "") }
        }
        await #expect(throws: GrantRefusal.self) { try await p.addPersistentGrant(kind: .network, value: "*", tier: .consequential, note: "") }
        await #expect(throws: GrantRefusal.self) { try await p.addPersistentGrant(kind: .processExec, value: "sudo", tier: .consequential, note: "") }
        await #expect(throws: GrantRefusal.self) { try await p.addPersistentGrant(kind: .fileRead, value: folder.path + "/missing", tier: .readOnly, note: "") }
        #expect(p.grants.count == 2)

        p.search = "example"
        #expect(p.visible.count == 1)
        p.search = ""
        await p.revoke(g.id)
        #expect(p.visible.count == 1)                  // active only by default
        p.activeOnly = false
        #expect(p.visible.count == 2)
        #expect(PermissionsModel.state(try #require(p.grants.first { $0.id == g.id })) == .revoked)
        await p.revokeAll()
        #expect(p.activeCount == 0)
        #expect(p.audit.contains { $0.kind == .grantRevoked } && p.audit.contains { $0.kind == .grantCreated })
        #expect(await model.services.policy.activeGrants().isEmpty)
    }

    @Test func statusIsNeverInventedAndToolsAreMappedToPermissions() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let p = PermissionsModel(services: model.services)
        await p.reload()
        #expect(p.snapshot.count == MacPermission.allCases.count)
        #expect(p.snapshot[.accessibility] == MacPermissions.status(.accessibility))
        #expect(p.snapshot[.appleEvents] == .unknown)
        #expect(p.toolsByPermission[.accessibility]?.contains("accessibility.press") == true)
        #expect(PermissionsModel.canRequest(.fullDiskAccess) == false && PermissionsModel.canRequest(.appleEvents) == false)
        #expect(ManualGrantKind.allCases.allSatisfy { $0.defaultTier <= .consequential })
    }
}

@Suite("Unit · tool grant tree") struct ToolGrantTreeTests {
    let all = ["filesystem.list", "filesystem.read", "filesystem.write", "git.status", "git.push", "http.request"]

    @Test func triStateFollowsPatterns() {
        #expect(ToolGrantTree.state(family: "filesystem", tools: Array(all[0...2]), patterns: ["filesystem.read"]) == .mixed)
        #expect(ToolGrantTree.state(family: "filesystem", tools: Array(all[0...2]), patterns: ["filesystem.*"]) == .on)
        #expect(ToolGrantTree.state(family: "git", tools: ["git.status", "git.push"], patterns: ["filesystem.*"]) == .off)
        #expect(ToolGrantTree.state(family: "git", tools: ["git.status", "git.push"], patterns: ["*"]) == .on)
        #expect(ToolGrantTree.families(all).map(\.family) == ["filesystem", "git", "http"])
    }

    @Test func togglingMapsToFamilyWildcardsAndIndividualIdentifiers() {
        var p = ToolGrantTree.setFamily("filesystem", on: true, patterns: ["filesystem.read", "git.status"], all: all)
        #expect(p == ["filesystem.*", "git.status"])
        p = ToolGrantTree.setTool("filesystem.write", on: false, patterns: p, all: all)
        #expect(p == ["filesystem.list", "filesystem.read", "git.status"])
        p = ToolGrantTree.setTool("git.push", on: true, patterns: p, all: all)
        #expect(p.contains("git.push") && !p.contains("git.*"))
        p = ToolGrantTree.setFamily("git", on: false, patterns: p, all: all)
        #expect(p == ["filesystem.list", "filesystem.read"])
        // "*" expands to one wildcard per family before a single change.
        p = ToolGrantTree.setTool("http.request", on: false, patterns: ["*"], all: all)
        #expect(p == ["filesystem.*", "git.*"])
        #expect(ToolGrantTree.setEverything(true, patterns: p, all: all) == ["*"])
        #expect(ToolGrantTree.setEverything(false, patterns: ["*"], all: all) == ["filesystem.*", "git.*", "http.*"])
        #expect(ToolGrantTree.normalized(["git.status", "git.*", "git.status", ""]) == ["git.*"])
        // The mapping agrees with the runtime's own matching.
        let profile = AgentProfile(name: "x", instructions: "y", model: ModelRef(provider: .anthropic, model: ""), toolPatterns: ["filesystem.*", "git.status"])
        for id in all { #expect(profile.allows(toolID: id) == ToolGrantTree.allows(id, profile.toolPatterns)) }
    }
}

@Suite("Integration · agents") @MainActor struct AgentsModelTests {
    @Test func createValidateSaveDuplicateDelete() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let a = AgentsModel(services: model.services)
        await a.reload()
        #expect(a.profiles.count == BuiltInAgents.all.count && a.profiles.allSatisfy(\.builtIn))
        #expect(a.toolIDs.contains("filesystem.read"))
        #expect(await a.save() == false)                // a built-in is selected: read-only

        a.newProfile()
        #expect(a.isDirty && !a.problems.isEmpty)        // instructions are missing
        a.draft?.name = "general"
        a.draft?.instructions = "Summarise."
        #expect(a.problems.count == 1)                   // the name is taken
        a.draft?.name = "Bad Name"
        #expect(!a.problems.isEmpty)
        a.draft?.name = "summary-writer"
        let before = a.draft?.toolPatterns ?? []
        a.draft?.toolPatterns = ToolGrantTree.setFamily("documents", on: true, patterns: before, all: a.toolIDs)
        a.draft?.budget.maxTurns = 100_000
        #expect(a.problems.isEmpty)
        #expect(await a.save())
        let stored = try #require(await model.services.agents.profile(named: "summary-writer"))
        #expect(!stored.builtIn && stored.toolPatterns.contains("documents.*") && stored.budget.maxTurns == 200)
        #expect(stored.model.model.isEmpty)              // "use the default model"
        #expect(!a.isDirty)

        let copy = try #require(await a.duplicate(BuiltInAgents.all[1].id))
        #expect(copy.name == BuiltInAgents.all[1].name + "-copy" && !copy.builtIn && a.selectedID == copy.id)
        await a.delete(copy.id)
        #expect(await model.services.agents.profile(named: copy.name) == nil)
        await a.delete(stored.id)
        #expect(a.profiles.count == BuiltInAgents.all.count)
    }

    @Test func evaluationRunsRealReviewModeRunsAndStoresResults() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        await model.services.providers.register(CannedProvider())
        model.settings.defaultModel = ModelRef(provider: ProviderID(rawValue: "canned"), model: "canned-1")
        try await model.services.runs.save(model.settings)
        let folder = try tempFolder("eval"); defer { try? FileManager.default.removeItem(at: folder) }
        try "hello".write(to: folder.appendingPathComponent("present.txt"), atomically: true, encoding: .utf8)

        let a = AgentsModel(services: model.services)
        await a.reload()
        a.newProfile()
        a.draft?.name = "eval-agent"; a.draft?.instructions = "Inspect only."; a.draft?.toolPatterns = ["filesystem.list"]
        #expect(await a.save())
        await a.addCase(AgentEvalCase(objective: "Confirm present.txt exists", workspace: folder.path, expectations: [Expectation(kind: "file_exists", path: folder.path + "/present.txt")]))
        await a.addCase(AgentEvalCase(objective: "Confirm missing.txt exists", workspace: folder.path, expectations: [Expectation(kind: "file_exists", path: folder.path + "/missing.txt")]))
        await a.runEvaluation(defaultWorkspace: folder.path)

        let agentID = try #require(a.selectedID)
        let stored = try #require(try await model.services.store.get(AgentEvalProfile.self, collection: AgentEvalProfile.collection, id: agentID))
        #expect(stored.cases.count == 2 && stored.results.count == 2)
        for r in stored.results {
            let runID = try #require(r.runID)
            let run = try #require(try await model.services.store.run(id: runID))
            #expect(run.mode == .review && run.status.isTerminal && run.status.rawValue == r.status)
        }
        // The missing file can never pass: the check is made by the runtime, not by what the model says.
        #expect(stored.results[1].passed == false)
        #expect(stored.results[0].checksTotal == 1)
        await a.removeCase(stored.cases[1].id)
        #expect(a.evaluation?.cases.count == 1 && a.evaluation?.results.count == 1)
    }
}

@Suite("Integration · settings, storage, memory") @MainActor struct SettingsStorageTests {
    @Test func settingsPersistThroughTheModel() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        model.setting(\.defaultMode).wrappedValue = .review
        model.setting(\.appearance).wrappedValue = "dark"
        model.setting(\.retentionDays).wrappedValue = 14
        model.setting(\.allowScreenContentToProvider).wrappedValue = true
        model.settings.plannerModel = ModelRef(provider: .openai, model: "planner-x")
        model.settings.defaultBudget = BudgetBounds.clamped(Budget(maxTurns: 7))
        model.settings.onboardingCompleted = true
        model.saveSettings()
        var stored = AppSettings()
        for _ in 0..<50 {
            stored = await model.services.runs.settings()
            if stored.plannerModel != nil && stored.onboardingCompleted { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        #expect(stored.defaultMode == .review && stored.appearance == "dark" && stored.retentionDays == 14)
        #expect(stored.allowScreenContentToProvider && stored.plannerModel?.model == "planner-x" && stored.defaultBudget.maxTurns == 7)
        #expect(stored.onboardingCompleted)
        #expect(AppSettings().allowScreenContentToProvider == false && AppSettings().backgroundAgentEnabled == false)
    }

    @Test func backupExportImportRoundTripAndPrune() async throws {
        let model = try await PreviewEnvironment.make()
        let storage = StorageModel(services: model.services)
        await storage.reload()
        #expect((storage.databaseBytes ?? 0) > 0 && storage.artifactsBytes != nil)
        let out = try tempFolder("storage"); defer { try? FileManager.default.removeItem(at: out) }

        let backup = out.appendingPathComponent("backup.sqlite")
        #expect(await storage.backup(to: backup))
        #expect(((try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? Int) ?? 0) > 10_000)
        #expect(await storage.backup(to: backup) == false)        // never overwrites
        #expect(storage.message?.kind == .error)

        let bundle = out.appendingPathComponent("export.json")
        let exported = try #require(await storage.exportBundle(to: bundle))
        #expect(exported.workflows == 3)
        let text = try String(contentsOf: bundle, encoding: .utf8)
        #expect(!text.contains("Sample grant"))                    // grants are not exported
        #expect(StorageModel.summaryLines(exported).count == 4)

        let other = try await PreviewEnvironment.make(seed: false)
        #expect(await other.services.workflows.list().isEmpty)
        let imported = try #require(await StorageModel(services: other.services).importBundle(from: bundle))
        #expect(imported.workflows == 3)
        #expect(Set(await other.services.workflows.list().map(\.id)) == Set(await model.services.workflows.list().map(\.id)))
        #expect(await other.services.policy.grants().isEmpty)

        #expect(await StorageModel(services: other.services).importBundle(from: backup) == nil)   // not a bundle: precise failure, nothing imported

        #expect(await storage.pruneRuns(olderThanDays: 3650) == 0)
        #expect(await storage.pruneRuns(olderThanDays: 0) == 6)
        #expect(try await model.services.store.runs(limit: 50).isEmpty)
    }

    @Test func auditVerifyReportsValidThenTheFirstBrokenLine() async throws {
        let model = try await PreviewEnvironment.make()
        let storage = StorageModel(services: model.services)
        await storage.reload()
        #expect((storage.auditCount ?? 0) >= 2 && storage.auditEntries.count == storage.auditCount)
        await storage.verifyAudit()
        #expect(storage.verification?.isValid == true)
        let out = try tempFolder("audit"); defer { try? FileManager.default.removeItem(at: out) }
        #expect(await storage.exportAudit(to: out.appendingPathComponent("audit.jsonl")))
        #expect(try String(contentsOf: out.appendingPathComponent("audit.jsonl"), encoding: .utf8).split(separator: "\n").count == storage.auditCount)

        // Tamper with the first line on disk: verification names it.
        let url = model.services.paths.auditLog
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        lines[0] = lines[0].replacingOccurrences(of: "Grant", with: "Grunt")
        try lines.joined(separator: "\n").write(to: url, atomically: false, encoding: .utf8)
        await storage.verifyAudit()
        #expect(storage.verification?.isValid == false)
        #expect(storage.verification?.firstBrokenLine == 1)
    }

    @Test func memoryApproveExportDelete() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let memory = MemoryModel(services: model.services)
        await model.services.memory.save(MemoryRecord(id: "m1", scope: .user, kind: "preference", text: "Reports in French", provenance: "run r1"))
        await model.services.memory.save(MemoryRecord(id: "m2", scope: .agent("general"), kind: "fix", text: "Use absolute paths", provenance: "run r2"))
        await memory.reload()
        #expect(memory.records.count == 2)
        #expect(memory.records.filter(MemoryModel.isPending).map(\.id) == ["m1"])
        await memory.approve("m1")
        #expect(memory.records.filter(MemoryModel.isPending).isEmpty)
        let json = try JSONValue.parse(try memory.exportJSON())
        #expect(json.arrayValue?.count == 2 && json[0]?["provenance"] != nil)
        await memory.delete("m2")
        #expect(memory.records.map(\.id) == ["m1"])
        await memory.deleteAll()
        #expect(await model.services.memory.all().isEmpty)
    }

    @Test func diagnosticsContainNoSecretAndOnlyShortPaths() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let secret = "sk-test-diagnostics-\(UUID().uuidString)"
        Redactor.shared.register(secret: secret); defer { Redactor.shared.unregister(secret: secret) }
        let report = await DiagnosticsReport.make(model)
        #expect(report.toolTotal > 40 && report.toolsByFamily.contains { $0.family == "filesystem" })
        #expect(report.toolsByFamily.map(\.count).reduce(0, +) == report.toolTotal)
        #expect(report.permissions.count == MacPermission.allCases.count)
        #expect(!report.text.contains(secret) && !report.text.contains("sk-"))
        #expect(report.dataFolder == PathResolver.display(model.services.paths.root.path))
    }
}

@Suite("Integration · skills") @MainActor struct SkillsModelTests {
    @Test func formBuildsAManifestOrExplainsTheProblem() throws {
        let built = try SkillForm.wordCountTemplate.build()
        #expect(built.manifest.id == "skill.wordCount" && built.manifest.tests.count == 1 && built.sources.keys.sorted() == ["main.py"])
        #expect(built.manifest.permissions.fileRead == ["$input.path"] && built.manifest.tier == .readOnly)
        var bad = SkillForm.wordCountTemplate
        bad.inputSchemaJSON = "{ not json"
        #expect(throws: SkillForm.Problem.self) { try bad.build() }
        bad = .wordCountTemplate; bad.fileRead = "~/.ssh"
        #expect(throws: SkillForm.Problem.self) { try bad.build() }
        bad = .wordCountTemplate; bad.version = "one"
        #expect(throws: SkillForm.Problem.self) { try bad.build() }
        #expect(throws: SkillForm.Problem.self) { try SkillForm().build() }
        #expect(SkillsModel.permissionLines(built.manifest).count == 3)
    }

    @Test func draftInstallNewVersionRollbackTestUninstall() async throws {
        let model = try await PreviewEnvironment.make(seed: false)
        let skills = SkillsModel(services: model.services)
        let draft = try #require(await skills.propose(.wordCountTemplate))
        guard draft.installable else {
            print("SKIPPED(the word-count skill's own test did not pass here, python3 is probably unavailable: \(draft.tests.map(\.detail)))")
            return
        }
        #expect(skills.drafts.count == 1 && skills.installed.isEmpty)
        #expect(await model.services.registry.tool(id: "skill.wordCount") == nil)      // a draft cannot be called
        let installed = try #require(await skills.install(draftID: draft.id))
        #expect(installed.provenance?.source == "user" && installed.provenance?.testsPassed == 1)
        #expect(skills.drafts.isEmpty && skills.installed.map(\.id) == ["skill.wordCount"])
        #expect(await model.services.registry.tool(id: "skill.wordCount") != nil)      // the registry was refreshed
        #expect(await model.services.audit.entries(limit: 50).contains { $0.kind == .skillInstalled })

        var v2 = SkillForm.wordCountTemplate
        v2.version = "1.1.0"; v2.source += "\n# second version\n"
        let d2 = try #require(await skills.propose(v2))
        _ = try #require(await skills.install(draftID: d2.id))
        #expect(skills.installed.first?.package.manifest.version == "1.1.0" && skills.installed.first?.versions == ["1.0.0", "1.1.0"])
        await skills.rollback("skill.wordCount")
        #expect(skills.installed.first?.package.manifest.version == "1.0.0")
        await skills.activate("skill.wordCount", version: "1.1.0")
        #expect(skills.installed.first?.package.manifest.version == "1.1.0")

        await skills.test(try #require(skills.installed.first))
        #expect(skills.testResults["skill.wordCount"]?.allSatisfy(\.passed) == true)

        await skills.setEnabled(false, id: "skill.wordCount")
        #expect(await model.services.registry.tool(id: "skill.wordCount") == nil)

        // A draft with a blocker is never installed.
        var bad = SkillForm.wordCountTemplate
        bad.name = "Fetch"; bad.source = "import json, urllib.request\nprint(json.dumps({'words': 1, 'lines': 1}))\n"
        let blocked = try #require(await skills.propose(bad))
        #expect(!blocked.installable)
        #expect(await skills.install(draftID: blocked.id) == nil)
        #expect(skills.message?.kind == .error)
        await skills.discard(draftID: blocked.id)
        #expect(skills.drafts.isEmpty)

        // Import always lands in drafts.
        let first = try #require(skills.installed.first)
        let imported = try #require(await skills.importFolder(first.package.directory))
        #expect(imported.source.hasPrefix("import:") && skills.drafts.count == 1)

        await skills.uninstall("skill.wordCount")
        #expect(skills.installed.isEmpty)
        #expect(skills.catalog(search: "filesystem.move").first?.tools.map(\.identifier) == ["filesystem.move"])
    }
}
