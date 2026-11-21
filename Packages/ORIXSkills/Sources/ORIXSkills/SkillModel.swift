// ORIX OS Automation
// File: Packages/ORIXSkills/Sources/ORIXSkills/SkillModel.swift
// Description: Skill manifest (`skill.json`), package loading with checksum verification, and the static analyser that compares source against declared permissions.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import CryptoKit
import Foundation
import ORIXCore

/// What a skill may touch. Paths are either absolute/tilde literals or `$input.<field>` (a path the caller passes in that field).
public struct SkillPermissions: Codable, Sendable, Hashable {
    public var fileRead: [String]
    public var fileWrite: [String]
    /// Hosts the skill may contact. Empty means no network: the process runs with networking denied.
    public var network: [String]
    public init(fileRead: [String] = [], fileWrite: [String] = [], network: [String] = []) {
        self.fileRead = fileRead; self.fileWrite = fileWrite; self.network = network
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileRead = try c.decodeIfPresent([String].self, forKey: .fileRead) ?? []
        fileWrite = try c.decodeIfPresent([String].self, forKey: .fileWrite) ?? []
        network = try c.decodeIfPresent([String].self, forKey: .network) ?? []
    }
}

public struct SkillTestCase: Codable, Sendable, Hashable {
    public var name: String
    /// Input object. The string `$fixture` inside any value is replaced by the path of a scratch directory holding `files`.
    public var input: JSONValue
    /// Files created in the scratch directory before the run: relative path → text content.
    public var files: [String: String]
    /// `succeeded` or `failed`.
    public var expectStatus: String
    /// Dotted output path → expected value.
    public var expectOutput: [String: JSONValue]
    /// Relative paths that must exist in the scratch directory afterwards.
    public var expectFiles: [String]

    public init(name: String, input: JSONValue, files: [String: String] = [:], expectStatus: String = "succeeded",
                expectOutput: [String: JSONValue] = [:], expectFiles: [String] = []) {
        self.name = name; self.input = input; self.files = files; self.expectStatus = expectStatus
        self.expectOutput = expectOutput; self.expectFiles = expectFiles
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])
        files = try c.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
        expectStatus = try c.decodeIfPresent(String.self, forKey: .expectStatus) ?? "succeeded"
        expectOutput = try c.decodeIfPresent([String: JSONValue].self, forKey: .expectOutput) ?? [:]
        expectFiles = try c.decodeIfPresent([String].self, forKey: .expectFiles) ?? []
    }
}

public struct SkillManifest: Codable, Sendable, Hashable {
    public static let fileName = "skill.json"
    public static let supportedRuntimes = ["python", "bash"]

    /// Tool identifier: `skill.<camelCaseName>`.
    public var id: String
    public var name: String
    /// Semantic version `major.minor.patch`.
    public var version: String
    public var summary: String
    public var runtime: String
    /// Entry file, relative to the package.
    public var entry: String
    public var inputSchema: JSONSchema
    public var outputSchema: JSONSchema
    public var permissions: SkillPermissions
    public var timeoutSeconds: Double
    public var author: String
    public var tests: [SkillTestCase]
    /// Relative file path → SHA-256. Every file of the package except `skill.json` must be listed.
    public var checksums: [String: String]

    public init(id: String, name: String, version: String = "1.0.0", summary: String, runtime: String = "python", entry: String = "main.py",
                inputSchema: JSONSchema, outputSchema: JSONSchema = .any, permissions: SkillPermissions = .init(), timeoutSeconds: Double = 30,
                author: String = "", tests: [SkillTestCase] = [], checksums: [String: String] = [:]) {
        self.id = id; self.name = name; self.version = version; self.summary = summary; self.runtime = runtime; self.entry = entry
        self.inputSchema = inputSchema; self.outputSchema = outputSchema; self.permissions = permissions; self.timeoutSeconds = timeoutSeconds
        self.author = author; self.tests = tests; self.checksums = checksums
    }

    public var sideEffect: SideEffect {
        if !permissions.network.isEmpty { return .external }
        return permissions.fileWrite.isEmpty ? .read : .write
    }

    /// Tier derived from what the manifest declares; a skill cannot choose a lower one.
    public var tier: ApprovalTier {
        if !permissions.network.isEmpty { return .consequential }
        return permissions.fileWrite.isEmpty ? .readOnly : .reversibleWrite
    }

    public func toolManifest() -> ToolManifest {
        ToolManifest(identifier: id, name: name, version: version, summary: summary, family: "skill", inputSchema: inputSchema,
                     outputSchema: outputSchema, sideEffect: sideEffect, defaultTier: tier, defaultTimeoutSeconds: timeoutSeconds,
                     concurrency: .unlimited, supportsDryRun: false, idempotent: sideEffect == .read, outputIsUntrusted: true)
    }

    public static func semver(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.map { $0! }
    }

    public func problems() -> [String] {
        var out = toolManifest().problems()
        if id.range(of: #"^skill\.[a-z][A-Za-z0-9]{1,48}$"#, options: .regularExpression) == nil { out.append("id must look like skill.camelCaseName") }
        if Self.semver(version) == nil { out.append("version must be major.minor.patch") }
        if !Self.supportedRuntimes.contains(runtime) { out.append("runtime must be one of \(Self.supportedRuntimes.joined(separator: ", "))") }
        if entry.contains("..") || entry.hasPrefix("/") || entry.isEmpty { out.append("entry must be a relative path inside the package") }
        for p in permissions.fileRead + permissions.fileWrite {
            if p.hasPrefix("$input.") {
                let field = String(p.dropFirst(7))
                if inputSchema.raw["properties"]?[field] == nil { out.append("permission \(p) refers to an input field that the schema does not define") }
            } else if !(p.hasPrefix("/") || p.hasPrefix("~/")) { out.append("permission path \(p) must be absolute, start with ~/, or be $input.<field>") }
            else if let c = try? PathResolver.canonical(p, relativeTo: URL(fileURLWithPath: "/")), PathResolver.isProtected(c) {
                out.append("permission path \(p) is a protected location")
            }
        }
        for h in permissions.network where h.contains("/") || h.contains(" ") || h == "*" { out.append("network permission \(h) must be a host name (\"*\" is not accepted)") }
        if timeoutSeconds > 600 { out.append("timeoutSeconds must not exceed 600") }
        return out
    }
}

public enum SkillError: Error, LocalizedError, Sendable, Hashable {
    case invalid([String])
    case notFound(String)
    case checksumMismatch(String)
    case io(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let p): return "Invalid skill: " + p.joined(separator: "; ")
        case .notFound(let s): return "Skill not found: \(s)"
        case .checksumMismatch(let f): return "Checksum mismatch for \(f): the package was modified after it was described."
        case .io(let m): return m
        }
    }
}

/// A skill on disk.
public struct SkillPackage: Sendable, Hashable {
    public let directory: URL
    public let manifest: SkillManifest
    /// SHA-256 over the sorted (path, hash) list plus the manifest's contract fields: identifies exactly this content.
    public let digest: String

    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Relative paths of every regular file in a package directory except the manifest. Symlinks are rejected.
    public static func files(in directory: URL) throws -> [String] {
        let root = PathResolver.resolveSymlinks(directory.path)
        guard let e = FileManager.default.enumerator(atPath: root) else { throw SkillError.io("cannot read \(root)") }
        var out: [String] = []
        for case let rel as String in e {
            let full = root + "/" + rel
            let attrs = try FileManager.default.attributesOfItem(atPath: full)
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw SkillError.invalid(["the package contains a symbolic link (\(rel)); links are not allowed"]) }
            if type == .typeRegular && rel != SkillManifest.fileName && !rel.hasPrefix(".") { out.append(rel) }
        }
        return out.sorted()
    }

    public static func checksums(in directory: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for rel in try files(in: directory) {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(rel).path) else { throw SkillError.io("cannot read \(rel)") }
            out[rel] = sha256(data)
        }
        return out
    }

    /// Loads and verifies a package: manifest validity, entry present, every file listed and matching its checksum.
    public static func load(_ directory: URL) throws -> SkillPackage {
        let url = directory.appendingPathComponent(SkillManifest.fileName)
        guard let data = FileManager.default.contents(atPath: url.path) else { throw SkillError.notFound("\(SkillManifest.fileName) in \(directory.lastPathComponent)") }
        let manifest: SkillManifest
        do { manifest = try JSONDecoder().decode(SkillManifest.self, from: data) }
        catch { throw SkillError.invalid(["skill.json cannot be read: \(error.localizedDescription)"]) }
        let problems = manifest.problems()
        guard problems.isEmpty else { throw SkillError.invalid(problems) }
        let actual = try checksums(in: directory)
        guard actual[manifest.entry] != nil else { throw SkillError.invalid(["entry file \(manifest.entry) is missing"]) }
        for (file, hash) in actual {
            guard let declared = manifest.checksums[file] else { throw SkillError.invalid(["file \(file) is not listed in checksums"]) }
            guard declared == hash else { throw SkillError.checksumMismatch(file) }
        }
        for file in manifest.checksums.keys where actual[file] == nil { throw SkillError.invalid(["listed file \(file) is missing"]) }
        let contract = (try? JSONValue.encoding(manifest.permissions))?.serialized() ?? ""
        let material = actual.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n" + manifest.id + "@" + manifest.version + "\n" + contract
        return SkillPackage(directory: directory, manifest: manifest, digest: sha256(Data(material.utf8)))
    }

    /// Writes a package directory from source text. Used for drafts proposed by an agent and by tests.
    @discardableResult
    public static func write(manifest: SkillManifest, sources: [String: String], to directory: URL) throws -> SkillPackage {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (rel, text) in sources {
            guard !rel.contains(".."), !rel.hasPrefix("/"), rel != SkillManifest.fileName else { throw SkillError.invalid(["invalid source path \(rel)"]) }
            let f = directory.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: f, atomically: true, encoding: .utf8)
        }
        var m = manifest
        m.checksums = try checksums(in: directory)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(m).write(to: directory.appendingPathComponent(SkillManifest.fileName))
        return try load(directory)
    }
}

public struct SkillFinding: Codable, Sendable, Hashable {
    public enum Severity: String, Codable, Sendable { case info, warning, blocker }
    public var severity: Severity
    public var file: String
    public var line: Int
    public var message: String
}

/// Heuristic source review. It reports what the code appears to do that the manifest does not declare.
/// It is advice for the reviewer; the enforced boundary is the Seatbelt profile and the policy engine.
public enum SkillAnalyzer {
    struct Rule { let pattern: String; let severity: SkillFinding.Severity; let message: String; let unlessNetworkDeclared: Bool }

    static let rules: [Rule] = [
        .init(pattern: #"\b(urllib|requests|httpx|aiohttp|http\.client|socket|ftplib|smtplib|websocket)\b"#, severity: .blocker, message: "uses the network but the manifest declares no network host", unlessNetworkDeclared: true),
        .init(pattern: #"\b(curl|wget|nc|ncat|ssh|scp|rsync|telnet)\s"#, severity: .blocker, message: "calls a network program but the manifest declares no network host", unlessNetworkDeclared: true),
        .init(pattern: #"https?://"#, severity: .warning, message: "contains a URL", unlessNetworkDeclared: true),
        .init(pattern: #"\bsudo\b|\bsu\s+-|\bdoas\b"#, severity: .blocker, message: "asks for elevated privileges, which skills never get", unlessNetworkDeclared: false),
        .init(pattern: #"\.ssh\b|\.aws\b|\.gnupg\b|Keychains?\b|security\s+find-|\.netrc|TCC\.db"#, severity: .blocker, message: "refers to a credential store", unlessNetworkDeclared: false),
        .init(pattern: #"\b(eval|exec)\s*\(|\bcompile\s*\(|__import__\s*\(|base64\.b64decode|marshal\.loads|pickle\.loads"#, severity: .warning, message: "builds or decodes code at run time, which hides behaviour from review", unlessNetworkDeclared: false),
        .init(pattern: #"\b(subprocess|os\.system|os\.popen|os\.exec\w*|pty\.spawn)\b"#, severity: .warning, message: "starts other programs", unlessNetworkDeclared: false),
        .init(pattern: #"\bosascript\b|\bAppleScript\b|\bopen\s+-a\b|\blaunchctl\b|\bdefaults\s+write\b|\bcrontab\b"#, severity: .blocker, message: "controls applications or system services, which a skill cannot declare", unlessNetworkDeclared: false),
        .init(pattern: #"\bos\.environ\b|\bprintenv\b|\benv\b\s*$"#, severity: .info, message: "reads environment variables (the skill runs with a minimal environment)", unlessNetworkDeclared: false),
        .init(pattern: #"\brm\s+-[a-zA-Z]*[rf]|shutil\.rmtree|os\.remove|os\.unlink"#, severity: .warning, message: "deletes files", unlessNetworkDeclared: false),
    ]

    public static func analyze(_ package: SkillPackage) -> [SkillFinding] {
        var findings: [SkillFinding] = []
        let declaresNetwork = !package.manifest.permissions.network.isEmpty
        let declaresWrite = !package.manifest.permissions.fileWrite.isEmpty
        let files = (try? SkillPackage.files(in: package.directory)) ?? []
        for rel in files {
            guard let data = FileManager.default.contents(atPath: package.directory.appendingPathComponent(rel).path) else { continue }
            guard let text = String(data: data, encoding: .utf8) else {
                findings.append(.init(severity: .blocker, file: rel, line: 0, message: "is not text; binary content cannot be reviewed"))
                continue
            }
            if data.count > 400_000 { findings.append(.init(severity: .warning, file: rel, line: 0, message: "is very large for a skill (\(data.count) bytes)")) }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") && !trimmed.hasPrefix("#!") { continue }
                if line.count > 2000 { findings.append(.init(severity: .warning, file: rel, line: i + 1, message: "has a very long line, which can hide content")) }
                for rule in rules {
                    if rule.unlessNetworkDeclared && declaresNetwork { continue }
                    if line.range(of: rule.pattern, options: .regularExpression) != nil {
                        findings.append(.init(severity: rule.severity, file: rel, line: i + 1, message: rule.message))
                    }
                }
                if !declaresWrite, line.range(of: #"open\s*\([^)]*['"][wax]b?\+?['"]|>\s*[\w$"'/~]|\.write_text\(|\.write_bytes\(|\bmkdir\b|\btouch\b"#, options: .regularExpression) != nil {
                    findings.append(.init(severity: .warning, file: rel, line: i + 1, message: "appears to write files but the manifest declares no write location (writes will be denied at run time)"))
                }
            }
        }
        return findings
    }

    public static func hasBlocker(_ findings: [SkillFinding]) -> Bool { findings.contains { $0.severity == .blocker } }
}
