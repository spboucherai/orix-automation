// ORIX OS Automation
// File: Packages/ORIXSkills/Sources/ORIXSkills/SkillRuntime.swift
// Description: Running a skill as a confined tool, testing it on synthetic fixtures, the versioned skill store with rollback, and the tools an agent uses to propose and install one.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore
import ORIXToolRegistry

/// A skill exposed as a tool. Input goes to the process as JSON on stdin; the last JSON object on stdout is the output.
public struct SkillTool: ORIXTool {
    public let package: SkillPackage
    public let manifest: ToolManifest
    let runner: ProcessRunner
    /// Tests force this off regardless of the manifest.
    let networkAllowed: Bool

    public init(package: SkillPackage, runner: ProcessRunner = .shared, networkAllowed: Bool? = nil) {
        self.package = package; self.runner = runner
        manifest = package.manifest.toolManifest()
        self.networkAllowed = networkAllowed ?? !package.manifest.permissions.network.isEmpty
    }

    func resolve(_ specs: [String], input: ToolInput, context: ToolExecutionContext) throws -> [String] {
        var out: [String] = []
        for spec in specs {
            if spec.hasPrefix("$input.") {
                let field = String(spec.dropFirst(7))
                guard let v = input.arguments[field] else { continue }
                let raws = v.stringValue.map { [$0] } ?? (v.arrayValue?.compactMap(\.stringValue) ?? [])
                for raw in raws { out.append(try PathResolver.canonical(raw, relativeTo: context.workingDirectory)) }
            } else {
                out.append(try PathResolver.canonical(spec, relativeTo: context.workingDirectory))
            }
        }
        return out
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let m = package.manifest
        let reads = try resolve(m.permissions.fileRead, input: input, context: context)
        let writes = try resolve(m.permissions.fileWrite, input: input, context: context)
        var caps: [Capability] = [.skill(id: m.id), .scriptRuntime(name: m.runtime)]
        caps += reads.map { .fileRead(path: $0) } + writes.map { .fileWrite(path: $0) }
        caps += m.permissions.network.map { .network(host: $0.lowercased()) }
        var parts = ["Run skill \(m.name) \(m.version)"]
        if !reads.isEmpty { parts.append("reading " + reads.map(PathResolver.display).joined(separator: ", ")) }
        if !writes.isEmpty { parts.append("writing " + writes.map(PathResolver.display).joined(separator: ", ")) }
        if !m.permissions.network.isEmpty { parts.append("contacting " + m.permissions.network.joined(separator: ", ")) }
        return ToolRequirements(capabilities: caps, tier: m.tier, summary: parts.joined(separator: ", "))
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let m = package.manifest
        let interpreter: String
        switch m.runtime {
        case "python":
            guard let p = PythonEnvironment.basePython() else { throw ToolError.unsupported("No python3 interpreter was found on this Mac.") }
            interpreter = p
        case "bash": interpreter = "/bin/bash"
        default: throw ToolError.unsupported("Runtime \(m.runtime) is not supported.")
        }
        // Re-verify the package right before running: an installed skill that changed on disk does not run.
        let current = try SkillPackage.load(package.directory)
        guard current.digest == package.digest else { throw ToolError.permissionDenied("Skill \(m.id) changed on disk since it was installed; it was not run.") }

        let writes = try resolve(m.permissions.fileWrite, input: input, context: context)
        try? FileManager.default.createDirectory(at: context.artifactsDirectory, withIntermediateDirectories: true)
        let artifacts = PathResolver.resolveSymlinks(context.artifactsDirectory.path)
        let profile = SeatbeltProfile(writeRoots: writes + [artifacts], allowsNetwork: networkAllowed)
        let stdin = Data(input.arguments.serialized().utf8)
        let args = m.runtime == "python" ? ["-I", "-B", package.directory.appendingPathComponent(m.entry).path]
                                         : ["--noprofile", "--norc", package.directory.appendingPathComponent(m.entry).path]
        var spec = ProcessSpec(executable: interpreter, arguments: args, workingDirectory: PathResolver.resolveSymlinks(context.workingDirectory.path))
        spec.environment = ["ORIX_SKILL_ID": m.id, "ORIX_ARTIFACTS_DIR": artifacts]
        spec.timeoutSeconds = min(context.timeoutSeconds, m.timeoutSeconds)
        spec.maxOutputBytes = 200_000
        spec.stdin = stdin
        spec.confinement = profile
        let progress = context.progress
        spec.onOutput = { stream, text in progress(ToolProgress(stream: stream == .stderr ? .stderr : .stdout, text: text)) }
        let out = try await runner.run(spec)
        try out.throwIfInterrupted(timeoutSeconds: spec.timeoutSeconds)
        guard out.exitCode == 0 else { throw ToolError.processFailed(exitCode: out.exitCode, stderr: String(out.stderrText.suffix(2000))) }
        let text = out.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = try? JSONValue.parse(text)
        if value == nil, let last = text.split(separator: "\n").last(where: { $0.hasPrefix("{") }) { value = try? JSONValue.parse(String(last)) }
        guard let output = value, output.objectValue != nil else {
            throw ToolError.internalError("Skill \(m.id) did not print a JSON object on stdout.")
        }
        var result = ToolResult.success(output, summary: "Skill \(m.name) finished in \(out.durationMs) ms")
        result.untrusted = true
        return result
    }
}

public struct SkillTestResult: Codable, Sendable, Hashable {
    public var name: String
    public var passed: Bool
    public var detail: String
    public var durationMs: Int
}

/// Runs a skill's own test cases, each in a fresh scratch directory, with networking denied and writes limited to that directory.
public enum SkillTestRunner {
    static func substitute(_ v: JSONValue, fixture: String) -> JSONValue {
        switch v {
        case .string(let s): return .string(s.replacingOccurrences(of: "$fixture", with: fixture))
        case .array(let a): return .array(a.map { substitute($0, fixture: fixture) })
        case .object(let o): return .object(o.mapValues { substitute($0, fixture: fixture) })
        default: return v
        }
    }

    public static func run(_ package: SkillPackage, runner: ProcessRunner = .shared) async -> [SkillTestResult] {
        var results: [SkillTestResult] = []
        let tool = SkillTool(package: package, runner: runner, networkAllowed: false)
        for test in package.manifest.tests {
            let started = Date()
            let scratch = URL(fileURLWithPath: PathResolver.resolveSymlinks(NSTemporaryDirectory())).appendingPathComponent("orix-skill-test-\(UUID().uuidString.prefix(8))")
            defer { try? FileManager.default.removeItem(at: scratch) }
            func done(_ ok: Bool, _ detail: String) { results.append(.init(name: test.name, passed: ok, detail: detail, durationMs: Int(Date().timeIntervalSince(started) * 1000))) }
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                for (rel, text) in test.files {
                    guard !rel.contains(".."), !rel.hasPrefix("/") else { throw SkillError.invalid(["fixture path \(rel) is not relative"]) }
                    let f = scratch.appendingPathComponent(rel)
                    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: f, atomically: true, encoding: .utf8)
                }
                let input = ToolInput(arguments: substitute(test.input, fixture: scratch.path))
                let violations = package.manifest.inputSchema.validate(input.arguments)
                guard violations.isEmpty else { done(false, "test input does not match the input schema: \(violations.map(\.description).joined(separator: "; "))"); continue }
                let ctx = ToolExecutionContext(runID: "skill-test", workingDirectory: scratch, artifactsDirectory: scratch.appendingPathComponent(".artifacts"),
                                               timeoutSeconds: min(package.manifest.timeoutSeconds, 60))
                let req = try tool.requirements(for: input, context: ctx)
                let outside = req.capabilities.filter { c in
                    switch c { case .fileRead(let p), .fileWrite(let p): return !(p == scratch.path || p.hasPrefix(scratch.path + "/")); default: return false }
                }
                guard outside.isEmpty else { done(false, "the test would touch paths outside its fixture: \(outside.map(\.scope).joined(separator: ", "))"); continue }
                var status = "succeeded", output: JSONValue = .null, failure = ""
                do {
                    let r = try await tool.execute(input: input, context: ctx)
                    output = r.output
                    let bad = package.manifest.outputSchema.validate(output)
                    if !bad.isEmpty { status = "failed"; failure = "output does not match the output schema: \(bad.map(\.description).joined(separator: "; "))" }
                } catch { status = "failed"; failure = (error as? ToolError)?.failure.message ?? error.localizedDescription }
                guard status == test.expectStatus else { done(false, "expected \(test.expectStatus), got \(status)" + (failure.isEmpty ? "" : " — \(failure)")); continue }
                var mismatch: String?
                for (path, expected) in test.expectOutput where output.value(atPath: path) != expected {
                    mismatch = "output.\(path) is \(output.value(atPath: path)?.serialized() ?? "missing"), expected \(expected.serialized())"; break
                }
                for rel in test.expectFiles where mismatch == nil && !FileManager.default.fileExists(atPath: scratch.appendingPathComponent(rel).path) {
                    mismatch = "expected file \(rel) was not created"
                }
                done(mismatch == nil, mismatch ?? (status == "failed" ? "failed as expected: \(failure)" : "ok"))
            } catch { done(false, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        }
        return results
    }
}

public struct SkillProvenance: Codable, Sendable, Hashable {
    /// `agent:<runID>`, `import:<path>`, `builtin`, `user`.
    public var source: String
    public var installedAt: Date
    public var digest: String
    public var warnings: Int
    public var testsPassed: Int
    public var testsTotal: Int
}

public struct InstalledSkill: Sendable, Hashable, Identifiable {
    public var id: String { package.manifest.id }
    public var package: SkillPackage
    public var enabled: Bool
    public var versions: [String]
    public var provenance: SkillProvenance?
}

public struct SkillDraft: Sendable, Hashable, Identifiable {
    public var id: String
    public var package: SkillPackage
    public var source: String
    public var findings: [SkillFinding]
    public var tests: [SkillTestResult]
    public var createdAt: Date
    public var sources: [String: String]
    public var testsPassed: Bool { !tests.isEmpty && tests.allSatisfy(\.passed) }
    public var installable: Bool { !SkillAnalyzer.hasBlocker(findings) && testsPassed }
}

struct SkillState: Codable {
    var current: String
    var enabled: Bool
    var history: [String]
    var provenance: [String: SkillProvenance]
}

/// Versioned local skill storage: `<root>/installed/<id>/<version>/`, `<root>/installed/<id>/state.json`, `<root>/drafts/<draftID>/`.
public actor SkillStore {
    public nonisolated let root: URL
    let runner: ProcessRunner
    private var drafts: [String: SkillDraft] = [:]
    private var listeners: [@Sendable () -> Void] = []
    /// Synchronous snapshot of drafts for tools.
    public nonisolated let index = SkillDraftIndex()

    public init(root: URL, runner: ProcessRunner = .shared) throws {
        self.root = root; self.runner = runner
        try FileManager.default.createDirectory(at: root.appendingPathComponent("installed"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drafts"), withIntermediateDirectories: true)
    }

    /// Called after every install, removal, enable/disable or rollback so the owner can refresh the tool registry.
    public func onChange(_ f: @escaping @Sendable () -> Void) { listeners.append(f) }
    private func changed() { index.replace(Array(drafts.values)); for l in listeners { l() } }

    func dir(_ id: String) -> URL { root.appendingPathComponent("installed").appendingPathComponent(id) }
    func state(_ id: String) -> SkillState? {
        guard let d = FileManager.default.contents(atPath: dir(id).appendingPathComponent("state.json").path) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SkillState.self, from: d)
    }
    func save(_ s: SkillState, _ id: String) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: dir(id).appendingPathComponent("state.json"), options: .atomic)
    }

    // MARK: Drafts

    /// Builds a draft package, analyses it and runs its tests confined. Nothing is installed.
    public func propose(manifest: SkillManifest, sources: [String: String], source: String) async throws -> SkillDraft {
        let draftID = "draft-" + UUID().uuidString.prefix(8).lowercased()
        let dir = root.appendingPathComponent("drafts").appendingPathComponent(draftID)
        let pkg: SkillPackage
        do { pkg = try SkillPackage.write(manifest: manifest, sources: sources, to: dir) }
        catch { try? FileManager.default.removeItem(at: dir); throw error }
        let findings = SkillAnalyzer.analyze(pkg)
        let tests = await SkillTestRunner.run(pkg, runner: runner)
        let draft = SkillDraft(id: draftID, package: pkg, source: source, findings: findings, tests: tests, createdAt: Date(), sources: sources)
        drafts[draftID] = draft
        changed()
        return draft
    }

    /// Imports a package folder as a draft (for review), never directly as an installed skill.
    public func importDraft(from directory: URL) async throws -> SkillDraft {
        let pkg = try SkillPackage.load(directory)
        var sources: [String: String] = [:]
        for rel in try SkillPackage.files(in: directory) {
            sources[rel] = String(data: FileManager.default.contents(atPath: directory.appendingPathComponent(rel).path) ?? Data(), encoding: .utf8) ?? ""
        }
        return try await propose(manifest: pkg.manifest, sources: sources, source: "import:\(directory.lastPathComponent)")
    }

    public func allDrafts() -> [SkillDraft] { drafts.values.sorted { $0.createdAt > $1.createdAt } }
    public func draft(id: String) -> SkillDraft? { drafts[id] }
    public func discardDraft(id: String) {
        if let d = drafts.removeValue(forKey: id) { try? FileManager.default.removeItem(at: d.package.directory); changed() }
    }

    // MARK: Installation

    /// Installs an approved draft as a new version. Refuses blockers, failing or absent tests, and a changed package under an existing version number.
    @discardableResult
    public func install(draftID: String) throws -> InstalledSkill {
        guard let draft = drafts[draftID] else { throw SkillError.notFound(draftID) }
        let pkg = try SkillPackage.load(draft.package.directory)   // re-verify checksums at install time
        guard pkg.digest == draft.package.digest else { throw SkillError.checksumMismatch("draft \(draftID)") }
        if SkillAnalyzer.hasBlocker(draft.findings) {
            throw SkillError.invalid(draft.findings.filter { $0.severity == .blocker }.map { "\($0.file):\($0.line) \($0.message)" })
        }
        guard draft.testsPassed else {
            throw SkillError.invalid(draft.tests.isEmpty ? ["the skill has no tests; at least one is required"] : draft.tests.filter { !$0.passed }.map { "test \($0.name): \($0.detail)" })
        }
        let m = pkg.manifest
        let target = dir(m.id).appendingPathComponent(m.version)
        var st = state(m.id) ?? SkillState(current: m.version, enabled: true, history: [], provenance: [:])
        if FileManager.default.fileExists(atPath: target.path) {
            guard let existing = try? SkillPackage.load(target), existing.digest == pkg.digest else {
                throw SkillError.invalid(["version \(m.version) of \(m.id) is already installed with different content; raise the version number"])
            }
        } else {
            try FileManager.default.createDirectory(at: dir(m.id), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: pkg.directory, to: target)
        }
        if !st.history.contains(m.version) { st.history.append(m.version) }
        st.current = m.version; st.enabled = true
        st.provenance[m.version] = SkillProvenance(source: draft.source, installedAt: Date(), digest: pkg.digest,
                                                   warnings: draft.findings.filter { $0.severity == .warning }.count,
                                                   testsPassed: draft.tests.filter(\.passed).count, testsTotal: draft.tests.count)
        try save(st, m.id)
        drafts[draftID] = nil
        try? FileManager.default.removeItem(at: draft.package.directory)
        changed()
        guard let installed = skill(id: m.id) else { throw SkillError.io("installation of \(m.id) could not be read back") }
        return installed
    }

    public func skill(id: String) -> InstalledSkill? {
        guard let st = state(id), let pkg = try? SkillPackage.load(dir(id).appendingPathComponent(st.current)) else { return nil }
        return InstalledSkill(package: pkg, enabled: st.enabled, versions: st.history, provenance: st.provenance[st.current])
    }

    public func installed() -> [InstalledSkill] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("installed").path)) ?? []
        return ids.sorted().compactMap { skill(id: $0) }
    }

    /// Tools for every enabled skill whose package still verifies.
    public func tools() -> [SkillTool] { installed().filter(\.enabled).map { SkillTool(package: $0.package, runner: runner) } }

    public func setEnabled(_ enabled: Bool, id: String) throws {
        guard var st = state(id) else { throw SkillError.notFound(id) }
        st.enabled = enabled; try save(st, id); changed()
    }

    /// Makes the previously installed version current again. The newer version stays on disk.
    @discardableResult
    public func rollback(id: String) throws -> String {
        guard var st = state(id) else { throw SkillError.notFound(id) }
        guard let i = st.history.firstIndex(of: st.current), i > 0 else { throw SkillError.invalid(["\(id) has no earlier version to return to"]) }
        st.current = st.history[i - 1]
        _ = try SkillPackage.load(dir(id).appendingPathComponent(st.current))
        try save(st, id); changed()
        return st.current
    }

    public func activate(id: String, version: String) throws {
        guard var st = state(id), st.history.contains(version) else { throw SkillError.notFound("\(id) \(version)") }
        _ = try SkillPackage.load(dir(id).appendingPathComponent(version))
        st.current = version; try save(st, id); changed()
    }

    public func uninstall(id: String) throws {
        guard state(id) != nil else { throw SkillError.notFound(id) }
        try FileManager.default.removeItem(at: dir(id)); changed()
    }
}

// MARK: Tools for agents

/// `skills.propose`: an agent submits a manifest, source and tests. The package is analysed and tested confined; nothing is installed.
public struct SkillsProposeTool: ORIXTool {
    let store: SkillStore
    public init(store: SkillStore) { self.store = store }
    public let manifest = ToolManifest(
        identifier: "skills.propose", name: "Propose a skill",
        summary: "Propose a new reusable tool when no existing tool fits. Give a manifest (name, summary, runtime python or bash, input/output schemas, the exact file and network permissions it needs), the source, and tests with fixture files. The source reads its input as JSON on stdin and prints one JSON object on stdout. The package is analysed and its tests are run in a sandbox with no network. Nothing is installed: use skills.install afterwards, which asks the user.",
        family: "skill",
        inputSchema: .object([
            "name": .string("camelCase name; the tool becomes skill.<name>", pattern: "^[a-z][A-Za-z0-9]{1,48}$"),
            "title": .string("Human-readable name"),
            "summary": .string("What the tool does, for a model choosing tools"),
            "version": .string("major.minor.patch"),
            "runtime": .string(enum: SkillManifest.supportedRuntimes),
            "source": .string("Complete source of the entry file"),
            "inputSchema": JSONSchema(raw: ["type": "object", "description": "JSON Schema of the input object"]),
            "outputSchema": JSONSchema(raw: ["type": "object", "description": "JSON Schema of the output object"]),
            "fileRead": .array(of: .string("Absolute path, ~/path, or $input.<field>")),
            "fileWrite": .array(of: .string("Absolute path, ~/path, or $input.<field>")),
            "network": .array(of: .string("Host name")),
            "tests": .array(of: JSONSchema(raw: ["type": "object", "description": "{name, input, files, expectStatus, expectOutput, expectFiles}; $fixture in input is the scratch folder holding files"])),
        ], required: ["name", "title", "summary", "runtime", "source", "inputSchema", "tests"]),
        sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 300, concurrency: .serial)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let runtime = try input.string("runtime")
        return ToolRequirements(capabilities: [.scriptRuntime(name: runtime)], tier: .consequential,
                                summary: "Analyse and test a proposed skill “\(input.optionalString("title") ?? "?")” (\(runtime)) in a sandbox; nothing is installed")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let runtime = try input.string("runtime")
        let tests: [SkillTestCase]
        do { tests = try (input.arguments["tests"] ?? .array([])).decode([SkillTestCase].self) }
        catch { throw ToolError.invalidInput("tests could not be read: \(error.localizedDescription)") }
        let m = SkillManifest(id: "skill." + (try input.string("name")), name: try input.string("title"), version: input.optionalString("version") ?? "1.0.0",
                              summary: try input.string("summary"), runtime: runtime, entry: runtime == "python" ? "main.py" : "main.sh",
                              inputSchema: JSONSchema(raw: input.arguments["inputSchema"] ?? .object([:])),
                              outputSchema: JSONSchema(raw: input.arguments["outputSchema"] ?? .object([:])),
                              permissions: SkillPermissions(fileRead: input.strings("fileRead"), fileWrite: input.strings("fileWrite"), network: input.strings("network")),
                              author: "agent:\(context.runID)", tests: tests)
        let draft: SkillDraft
        do { draft = try await store.propose(manifest: m, sources: [m.entry: try input.string("source")], source: "agent:\(context.runID)") }
        catch let e as SkillError { throw ToolError.invalidInput(e.errorDescription ?? "invalid skill") }
        let out: JSONValue = [
            "draftID": .string(draft.id), "skillID": .string(m.id), "version": .string(m.version), "installable": .bool(draft.installable),
            "findings": .array(draft.findings.map { ["severity": .string($0.severity.rawValue), "file": .string($0.file), "line": .int($0.line), "message": .string($0.message)] }),
            "tests": .array(draft.tests.map { ["name": .string($0.name), "passed": .bool($0.passed), "detail": .string($0.detail)] }),
        ]
        return .success(out, summary: draft.installable ? "Draft \(draft.id) passed analysis and \(draft.tests.count) test(s); ready for skills.install"
                                                         : "Draft \(draft.id) is not installable: fix the findings or failing tests and propose again")
    }
}

/// `skills.install`: installs a reviewed draft. Tier 2 and a `skill` capability, so the user is asked.
public struct SkillsInstallTool: ORIXTool {
    let store: SkillStore
    /// The draft is looked up synchronously for `requirements`; the store keeps a snapshot here.
    let lookup: @Sendable (String) -> SkillDraft?
    public init(store: SkillStore, lookup: @escaping @Sendable (String) -> SkillDraft?) { self.store = store; self.lookup = lookup }
    public let manifest = ToolManifest(
        identifier: "skills.install", name: "Install a skill",
        summary: "Install a draft produced by skills.propose as a versioned local tool. The user reviews its source, permissions, analysis and test results and must approve. After installation the tool skill.<name> is available.",
        family: "skill", inputSchema: .object(["draftID": .string()], required: ["draftID"]),
        sideEffect: .external, defaultTier: .consequential, concurrency: .serial)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let id = try input.string("draftID")
        guard let d = lookup(id) else { throw ToolError.notFound("No draft \(id). Propose the skill first.") }
        let m = d.package.manifest
        let p = m.permissions
        let warn = d.findings.filter { $0.severity == .warning }.count, block = d.findings.filter { $0.severity == .blocker }.count
        let summary = "Install skill “\(m.name)” \(m.version) (\(m.runtime)). Reads: \(p.fileRead.isEmpty ? "nothing" : p.fileRead.joined(separator: ", ")). Writes: \(p.fileWrite.isEmpty ? "nothing" : p.fileWrite.joined(separator: ", ")). Network: \(p.network.isEmpty ? "none" : p.network.joined(separator: ", ")). Analysis: \(block) blocker(s), \(warn) warning(s). Tests: \(d.tests.filter(\.passed).count)/\(d.tests.count) passed."
        return ToolRequirements(capabilities: [.skill(id: m.id)], tier: .consequential, summary: summary)
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        do {
            let s = try await store.install(draftID: try input.string("draftID"))
            return .success(["skillID": .string(s.id), "version": .string(s.package.manifest.version), "digest": .string(s.package.digest)],
                            summary: "Installed \(s.id) \(s.package.manifest.version)")
        } catch let e as SkillError { throw ToolError.permissionDenied(e.errorDescription ?? "The skill cannot be installed.") }
    }
}

public struct SkillsListTool: ORIXTool {
    let store: SkillStore
    public init(store: SkillStore) { self.store = store }
    public let manifest = ToolManifest(identifier: "skills.list", name: "List skills", summary: "List installed skills and pending drafts with their versions and permissions.",
                                       family: "skill", inputSchema: .object([:]), sideEffect: .read, defaultTier: .readOnly, idempotent: true)
    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "List installed skills")
    }
    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let installed = await store.installed(), drafts = await store.allDrafts()
        return .success([
            "installed": .array(installed.map { ["id": .string($0.id), "version": .string($0.package.manifest.version), "enabled": .bool($0.enabled), "summary": .string($0.package.manifest.summary)] }),
            "drafts": .array(drafts.map { ["draftID": .string($0.id), "id": .string($0.package.manifest.id), "installable": .bool($0.installable)] }),
        ], summary: "\(installed.count) installed, \(drafts.count) draft(s)")
    }
}

/// A thread-safe snapshot of drafts so `skills.install` can describe a draft from its synchronous `requirements`.
public final class SkillDraftIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: SkillDraft] = [:]
    public init() {}
    public func replace(_ drafts: [SkillDraft]) { lock.lock(); items = Dictionary(drafts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }); lock.unlock() }
    public func draft(_ id: String) -> SkillDraft? { lock.lock(); defer { lock.unlock() }; return items[id] }
}

public enum ORIXSkillsTools {
    /// The management tools. Installed skills themselves come from `SkillStore.tools()`.
    public static func all(store: SkillStore) -> [any ORIXTool] {
        let index = store.index
        return [SkillsProposeTool(store: store), SkillsInstallTool(store: store, lookup: { index.draft($0) }), SkillsListTool(store: store)]
    }
}
