// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/GitTools.swift
// Description: git.* tools over /usr/bin/git: status (porcelain v2), diff, log, branches, commit, createPatch and push. No history-rewriting tool exists.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

private func show(_ path: String) -> String { PathResolver.display(path) }

/// Where a git remote points.
public enum GitRemoteTarget: Sendable, Hashable {
    case host(String)
    case local(String)

    /// Parses `https://host/…`, `ssh://user@host:22/…`, `user@host:path` and plain paths (relative to `repository`).
    public static func parse(_ url: String, repository: String) -> GitRemoteTarget? {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return nil }
        if u.contains("://") {
            guard let c = URLComponents(string: u), let scheme = c.scheme?.lowercased() else { return nil }
            if scheme == "file" { return .local(PathResolver.resolveSymlinks(c.path)) }
            guard let host = c.host?.lowercased(), !host.isEmpty else { return nil }
            return .host(host)
        }
        if let colon = u.firstIndex(of: ":"), !u[..<colon].contains("/"), !u.hasPrefix("/"), !u.hasPrefix(".") {
            let authority = String(u[..<colon])
            let host = authority.split(separator: "@").last.map(String.init) ?? authority
            return host.isEmpty ? nil : .host(host.lowercased())
        }
        return (try? PathResolver.canonical(u, relativeTo: URL(fileURLWithPath: repository))).map(GitRemoteTarget.local)
    }

    /// Removes `user:password@` from a URL before it is shown.
    public static func sanitized(_ url: String) -> String {
        guard url.contains("://"), var c = URLComponents(string: url) else { return url }
        c.password = nil
        if c.user != nil, c.scheme?.lowercased().hasPrefix("http") == true { c.user = nil }
        return c.string ?? url
    }
}

enum Git {
    static let executable = "/usr/bin/git"
    static let refPattern = #"^[A-Za-z0-9_][A-Za-z0-9_./@^~{}:+-]*$"#

    static func checkRef(_ ref: String, what: String) throws {
        guard ref.range(of: refPattern, options: .regularExpression) != nil, ref.count <= 250 else {
            throw ToolError.invalidInput("\(what) is not a valid git revision or name")
        }
    }

    static func repository(_ input: ToolInput, _ context: ToolExecutionContext) throws -> String {
        try input.optionalPath("path", context) ?? PathResolver.resolveSymlinks(context.workingDirectory.path)
    }

    /// Runs git on `repo`, confined: read-only commands cannot write anywhere, write commands only below `writeRoots`.
    static func run(_ repo: String, _ args: [String], context: ToolExecutionContext, runner: ProcessRunner, writeRoots: [String] = [],
                    confined: Bool = true, extraConfig: [String] = [], maxBytes: Int = 4_000_000, timeout: Double? = nil) async throws -> ProcessOutput {
        try ToolSupport.requireDirectory(repo)
        var argv = ["-c", "core.fsmonitor=false", "-c", "core.quotepath=false", "-c", "color.ui=false"]
        for c in extraConfig { argv += ["-c", c] }
        argv += ["-C", repo] + args
        var env = ["GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C", "GIT_PAGER": "cat", "PAGER": "cat", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false"]
        if writeRoots.isEmpty { env["GIT_OPTIONAL_LOCKS"] = "0" }
        let limit = min(context.timeoutSeconds, timeout ?? context.timeoutSeconds)
        let profile = confined ? SeatbeltProfile(writeRoots: writeRoots, allowsNetwork: false) : nil
        return try await ToolSupport.run(ProcessSpec(executable: executable, arguments: argv, environment: env, workingDirectory: repo,
                                                     timeoutSeconds: limit, maxOutputBytes: maxBytes, confinement: profile), context: context, runner: runner)
    }

    /// Runs a command that must succeed; "not a git repository" becomes a clear input error.
    static func checked(_ repo: String, _ args: [String], context: ToolExecutionContext, runner: ProcessRunner, writeRoots: [String] = [],
                        maxBytes: Int = 4_000_000) async throws -> ProcessOutput {
        let out = try await run(repo, args, context: context, runner: runner, writeRoots: writeRoots, maxBytes: maxBytes)
        if out.exitCode != 0 {
            if out.stderrText.contains("not a git repository") { throw ToolError.invalidInput("\(show(repo)) is not a git repository") }
            throw ToolError.processFailed(exitCode: out.exitCode, stderr: out.stderrText)
        }
        return out
    }

    /// Reads the configured URL of a remote straight from the repository's config file (no process, usable from `requirements`).
    static func configuredRemoteURL(repository: String, remote: String) -> String? {
        let fm = FileManager.default
        var gitDir = repository + "/.git"
        if let text = try? String(contentsOfFile: gitDir, encoding: .utf8), text.hasPrefix("gitdir:") {
            let target = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = target.hasPrefix("/") ? target : repository + "/" + target
        }
        if let common = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) {
            let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = c.hasPrefix("/") ? c : gitDir + "/" + c
        }
        if !fm.fileExists(atPath: gitDir + "/config"), fm.fileExists(atPath: repository + "/config"), fm.fileExists(atPath: repository + "/HEAD") {
            gitDir = repository  // bare repository
        }
        guard let config = try? String(contentsOfFile: gitDir + "/config", encoding: .utf8) else { return nil }
        var inSection = false
        var url: String?, pushURL: String?
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.replacingOccurrences(of: " ", with: "").lowercased().hasPrefix("[remote\"") && line.contains("\"\(remote)\"")
                continue
            }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if key == "url", url == nil { url = value }
            if key == "pushurl", pushURL == nil { pushURL = value }
        }
        return pushURL ?? url
    }

    // MARK: Porcelain v2

    static func parseStatus(_ raw: String) -> [String: JSONValue] {
        var branch: JSONValue = .null, oid: JSONValue = .null, upstream: JSONValue = .null
        var ahead = 0, behind = 0
        var staged: [JSONValue] = [], unstaged: [JSONValue] = [], untracked: [JSONValue] = [], conflicted: [JSONValue] = [], ignored: [JSONValue] = []
        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        func name(_ code: Character) -> String {
            switch code {
            case "M": return "modified"
            case "T": return "typeChanged"
            case "A": return "added"
            case "D": return "deleted"
            case "R": return "renamed"
            case "C": return "copied"
            case "U": return "unmerged"
            default: return String(code)
            }
        }
        var i = 0
        while i < tokens.count {
            let t = tokens[i]; i += 1
            if t.hasPrefix("# ") {
                let parts = t.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid": oid = parts[2] == "(initial)" ? .null : .string(parts[2])
                case "branch.head": branch = parts[2] == "(detached)" ? .null : .string(parts[2])
                case "branch.upstream": upstream = .string(parts[2])
                case "branch.ab":
                    for p in parts[2].split(separator: " ") {
                        if p.hasPrefix("+") { ahead = Int(p.dropFirst()) ?? 0 }
                        if p.hasPrefix("-") { behind = Int(p.dropFirst()) ?? 0 }
                    }
                default: break
                }
            } else if t.hasPrefix("1 ") || t.hasPrefix("2 ") {
                let renamed = t.hasPrefix("2 ")
                let f = t.split(separator: " ", maxSplits: renamed ? 9 : 8, omittingEmptySubsequences: false).map(String.init)
                guard f.count == (renamed ? 10 : 9) else { continue }
                let xy = Array(f[1]), path = f.last!
                var original: String?
                if renamed, i < tokens.count { original = tokens[i]; i += 1 }
                if xy.count == 2 {
                    if xy[0] != "." {
                        var e: [String: JSONValue] = ["path": .string(path), "status": .string(name(xy[0]))]
                        if let original { e["originalPath"] = .string(original) }
                        staged.append(.object(e))
                    }
                    if xy[1] != "." { unstaged.append(["path": .string(path), "status": .string(name(xy[1]))]) }
                }
            } else if t.hasPrefix("u ") {
                let f = t.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
                if f.count == 11 { conflicted.append(["path": .string(f[10]), "status": .string(f[1])]) }
            } else if t.hasPrefix("? ") { untracked.append(.string(String(t.dropFirst(2)))) }
            else if t.hasPrefix("! ") { ignored.append(.string(String(t.dropFirst(2)))) }
        }
        let clean = staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicted.isEmpty
        return ["branch": branch, "oid": oid, "upstream": upstream, "ahead": .int(ahead), "behind": .int(behind), "clean": .bool(clean),
                "staged": .array(staged), "unstaged": .array(unstaged), "untracked": .array(untracked), "conflicted": .array(conflicted)]
    }
}

private let repoPath = JSONSchema.string("Repository directory (default: the run's working directory).")

// MARK: - status

public struct GitStatusTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ToolManifest(
        identifier: "git.status", name: "Git status",
        summary: "Reports the branch, upstream, ahead/behind counts and the staged, unstaged, untracked and conflicted files of a repository.",
        family: "git", inputSchema: Schema.input(["path": repoPath]),
        outputSchema: Schema.output(["clean": .boolean(), "staged": .array(of: .any), "unstaged": .array(of: .any), "untracked": .array(of: .any)],
                                    required: ["clean", "staged", "unstaged", "untracked"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 60, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let repo = try Git.repository(input, context)
        return ToolRequirements(capabilities: [.fileRead(path: repo)], tier: .readOnly, summary: "Read the git status of \(show(repo))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let repo = try Git.repository(input, context)
        let out = try await Git.checked(repo, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], context: context, runner: runner)
        var status = Git.parseStatus(out.stdoutText)
        status["repository"] = .string(repo)
        let n = (status["staged"]?.arrayValue?.count ?? 0) + (status["unstaged"]?.arrayValue?.count ?? 0) + (status["untracked"]?.arrayValue?.count ?? 0)
        return .success(.object(status), summary: status["clean"] == .bool(true) ? "Working tree clean on \(status["branch"]?.stringValue ?? "detached HEAD")"
                        : "\(ToolSupport.plural(n, "change")) on \(status["branch"]?.stringValue ?? "detached HEAD")")
    }
}

// MARK: - diff

public struct GitDiffTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ToolManifest(
        identifier: "git.diff", name: "Git diff",
        summary: "Shows the unstaged diff, the staged diff, or the diff of a revision range (a..b), optionally limited to paths. Output is bounded.",
        family: "git",
        inputSchema: Schema.input(["path": repoPath, "staged": .boolean("Diff of the index against HEAD."), "range": .string("Revision or range such as main..feature."),
                                   "paths": .array(of: .string(), "Limit to these paths."), "stat": .boolean("Only the per-file summary."),
                                   "contextLines": .integer(minimum: 0, maximum: 100), "maxBytes": .integer("Default 100000.", minimum: 1, maximum: 2_000_000)]),
        outputSchema: Schema.output(["diff": .string(), "truncated": .boolean(), "empty": .boolean()], required: ["diff", "truncated", "empty"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 120, maxOutputBytes: 3_000_000, idempotent: true, outputIsUntrusted: true)

    static func arguments(_ input: ToolInput, repo: String, context: ToolExecutionContext, base: [String]) throws -> [String] {
        var args = base
        if input.bool("staged", default: false) { args.append("--staged") }
        if let range = input.optionalString("range") {
            guard !input.bool("staged", default: false) else { throw ToolError.invalidInput("give staged or range, not both") }
            try Git.checkRef(range, what: "range")
            args.append(range)
        }
        let paths = try input.strings("paths").map { try PathResolver.canonical($0, relativeTo: URL(fileURLWithPath: repo)) }
        for p in paths where !(p == repo || p.hasPrefix(repo + "/")) { throw ToolError.invalidInput("\(show(p)) is outside the repository") }
        if !paths.isEmpty { args += ["--"] + paths }
        return args
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let repo = try Git.repository(input, context)
        _ = try Self.arguments(input, repo: repo, context: context, base: [])
        let what = input.optionalString("range") ?? (input.bool("staged", default: false) ? "staged changes" : "unstaged changes")
        return ToolRequirements(capabilities: [.fileRead(path: repo)], tier: .readOnly, summary: "Show the git diff (\(what)) of \(show(repo))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let repo = try Git.repository(input, context)
        var base = ["diff", "--no-ext-diff", "--no-color"]
        if input.bool("stat", default: false) { base.append("--stat") }
        if let c = input.arguments["contextLines"]?.intValue { base.append("-U\(c)") }
        let maxBytes = input.int("maxBytes", default: 100_000)
        let out = try await Git.checked(repo, try Self.arguments(input, repo: repo, context: context, base: base), context: context, runner: runner, maxBytes: maxBytes)
        let text = out.stdoutText.truncated(maxBytes: maxBytes)
        let cut = text.truncated || out.stdoutTruncated
        var result = ToolResult.success(["diff": .string(text.text), "truncated": .bool(cut), "empty": .bool(out.stdout.isEmpty)],
                                        summary: out.stdout.isEmpty ? "No differences" : "Diff of \(out.stdout.count) bytes\(cut ? " (truncated)" : "")")
        result.truncated = cut
        return result
    }
}

// MARK: - log

public struct GitLogTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ToolManifest(
        identifier: "git.log", name: "Git log",
        summary: "Lists recent commits (hash, author, date, subject) of a branch or revision range, optionally limited to paths.",
        family: "git",
        inputSchema: Schema.input(["path": repoPath, "limit": .integer("Default 20.", minimum: 1, maximum: 500), "ref": .string("Branch, tag, commit or range."),
                                   "paths": .array(of: .string())]),
        outputSchema: Schema.output(["commits": .array(of: .any), "count": .integer()], required: ["commits", "count"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 60, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let repo = try Git.repository(input, context)
        if let ref = input.optionalString("ref") { try Git.checkRef(ref, what: "ref") }
        return ToolRequirements(capabilities: [.fileRead(path: repo)], tier: .readOnly, summary: "Read the git log of \(show(repo))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let repo = try Git.repository(input, context)
        var args = ["log", "-n", String(input.int("limit", default: 20)), "--pretty=format:%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e"]
        if let ref = input.optionalString("ref") { try Git.checkRef(ref, what: "ref"); args.append(ref) }
        let paths = try input.strings("paths").map { try PathResolver.canonical($0, relativeTo: URL(fileURLWithPath: repo)) }
        args.append("--")
        args += paths
        let out = try await Git.run(repo, args, context: context, runner: runner)
        if out.exitCode != 0 {
            if out.stderrText.contains("does not have any commits yet") { return .success(["commits": [], "count": 0], summary: "No commits yet") }
            if out.stderrText.contains("not a git repository") { throw ToolError.invalidInput("\(show(repo)) is not a git repository") }
            throw ToolError.processFailed(exitCode: out.exitCode, stderr: out.stderrText)
        }
        let commits: [JSONValue] = out.stdoutText.split(separator: "\u{1e}").compactMap { record in
            let f = record.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6 else { return nil }
            return ["hash": .string(f[0]), "shortHash": .string(f[1]), "author": .string(f[2]), "email": .string(f[3]), "date": .string(f[4]), "subject": .string(f[5])]
        }
        return .success(["commits": .array(commits), "count": .int(commits.count)], summary: "\(ToolSupport.plural(commits.count, "commit"))")
    }
}

// MARK: - branches

public struct GitBranchesTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ToolManifest(
        identifier: "git.branches", name: "Git branches",
        summary: "Lists local branches (and remote-tracking branches on request) with their tip, upstream and which one is checked out.",
        family: "git", inputSchema: Schema.input(["path": repoPath, "includeRemotes": .boolean()]),
        outputSchema: Schema.output(["branches": .array(of: .any), "current": .any], required: ["branches"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 60, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let repo = try Git.repository(input, context)
        return ToolRequirements(capabilities: [.fileRead(path: repo)], tier: .readOnly, summary: "List the git branches of \(show(repo))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let repo = try Git.repository(input, context)
        var args = ["for-each-ref", "--format=%(refname)%1f%(refname:short)%1f%(objectname:short)%1f%(upstream:short)%1f%(HEAD)%1f%(committerdate:iso-strict)%1f%(subject)", "refs/heads"]
        if input.bool("includeRemotes", default: false) { args.append("refs/remotes") }
        let out = try await Git.checked(repo, args, context: context, runner: runner)
        var current: JSONValue = .null
        let branches: [JSONValue] = out.stdoutText.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 7 else { return nil }
            let isCurrent = f[4] == "*"
            if isCurrent { current = .string(f[1]) }
            return ["name": .string(f[1]), "remote": .bool(f[0].hasPrefix("refs/remotes/")), "commit": .string(f[2]),
                    "upstream": f[3].isEmpty ? .null : .string(f[3]), "current": .bool(isCurrent), "date": .string(f[5]), "subject": .string(f[6])]
        }
        return .success(["branches": .array(branches), "current": current], summary: "\(ToolSupport.plural(branches.count, "branch", "branches"))")
    }
}

// MARK: - commit

public struct GitCommitTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ToolManifest(
        identifier: "git.commit", name: "Git commit",
        summary: "Stages the given paths and commits exactly those paths with a message. Hooks run; history is never amended or rewritten.",
        family: "git",
        inputSchema: Schema.input([
            "path": repoPath,
            "paths": JSONSchema(raw: ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 500, "description": "Files or folders to commit."]),
            "message": JSONSchema(raw: ["type": "string", "minLength": 1, "maxLength": 20_000]),
        ], required: ["paths", "message"]),
        outputSchema: Schema.output(["commit": .string(), "branch": .any, "summary": .string()], required: ["commit"]),
        sideEffect: .write, defaultTier: .reversibleWrite, defaultTimeoutSeconds: 300, supportsDryRun: true, outputIsUntrusted: true)

    func plan(_ input: ToolInput, _ context: ToolExecutionContext) throws -> (repo: String, relative: [String], message: String) {
        let repo = try Git.repository(input, context)
        let message = try input.string("message")
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.invalidInput("message is empty") }
        var relative: [String] = []
        for raw in input.strings("paths") {
            // Lexical resolution only: a tracked symlink is committed as a link, not followed.
            guard !raw.contains("\0") else { throw ToolError.invalidInput("path contains a NUL byte") }
            let absolute = raw.hasPrefix("/") ? raw : (raw.hasPrefix("~/") ? NSHomeDirectory() + raw.dropFirst(1) : repo + "/" + raw)
            let lexical = ToolSupport.lexical(absolute)
            let normal: String
            if PathResolver.resolveSymlinks(lexical) == repo { normal = repo }
            else { normal = PathResolver.resolveSymlinks((lexical as NSString).deletingLastPathComponent) + "/" + (lexical as NSString).lastPathComponent }
            guard normal == repo || normal.hasPrefix(repo + "/") else { throw ToolError.invalidInput("\(raw) is outside the repository") }
            guard !(normal == repo + "/.git" || normal.hasPrefix(repo + "/.git/")) else { throw ToolError.invalidInput("paths inside .git cannot be committed") }
            relative.append(normal == repo ? "." : String(normal.dropFirst(repo.count + 1)))
        }
        guard !relative.isEmpty else { throw ToolError.invalidInput("paths is empty") }
        return (repo, relative, message)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input, context)
        let subject = p.message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return ToolRequirements(capabilities: [.fileRead(path: p.repo), .fileWrite(path: p.repo)], tier: .reversibleWrite,
                                summary: "Commit \(ToolSupport.plural(p.relative.count, "path")) in \(show(p.repo)): “\(subject.prefix(100))”")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input, context)
        let pending = try await Git.checked(p.repo, ["status", "--porcelain", "-z", "--"] + p.relative, context: context, runner: runner)
        guard !pending.stdout.isEmpty else { throw ToolError.invalidInput("Nothing to commit for these paths") }
        if input.dryRun {
            let files = pending.stdoutText.split(separator: "\0").map { JSONValue.string(String($0)) }
            return .simulated(["repository": .string(p.repo), "wouldCommit": .array(files), "message": .string(p.message)],
                              summary: "Would commit \(ToolSupport.plural(files.count, "change")) in \(show(p.repo))")
        }
        let add = try await Git.run(p.repo, ["add", "--"] + p.relative, context: context, runner: runner, writeRoots: [p.repo])
        try add.requireSuccess(timeoutSeconds: context.timeoutSeconds)
        let commit = try await Git.run(p.repo, ["commit", "-m", p.message, "--"] + p.relative, context: context, runner: runner, writeRoots: [p.repo])
        try commit.requireSuccess(timeoutSeconds: context.timeoutSeconds)
        let head = try await Git.checked(p.repo, ["rev-parse", "HEAD"], context: context, runner: runner)
        let branch = try await Git.run(p.repo, ["symbolic-ref", "--short", "-q", "HEAD"], context: context, runner: runner)
        let sha = head.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = branch.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(["commit": .string(sha), "branch": name.isEmpty ? .null : .string(name),
                         "summary": .string(commit.stdoutText.truncated(maxBytes: 4_000).text)],
                        summary: "Committed \(sha.prefix(8)) on \(name.isEmpty ? "detached HEAD" : name)")
    }
}

// MARK: - createPatch

public struct GitCreatePatchTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ToolManifest(
        identifier: "git.createPatch", name: "Create a patch file",
        summary: "Writes the unstaged, staged or range diff of a repository as a .patch file in the run's artifacts (untracked files are not included). The repository is not modified.",
        family: "git",
        inputSchema: Schema.input(["path": repoPath, "staged": .boolean(), "range": .string("Revision or range such as main..feature."),
                                   "paths": .array(of: .string()), "name": .string("File name without extension.", pattern: "^[A-Za-z0-9._-]{1,80}$")]),
        outputSchema: Schema.output(["patchPath": .any, "bytes": .integer(), "empty": .boolean()], required: ["bytes", "empty"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 120, idempotent: true)

    func target(_ input: ToolInput, _ context: ToolExecutionContext) -> String {
        let name = input.optionalString("name") ?? "changes-\(context.callID.prefix(8))"
        return PathResolver.resolveSymlinks(context.artifactsDirectory.path) + "/patches/\(name).patch"
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let repo = try Git.repository(input, context)
        _ = try GitDiffTool.arguments(input, repo: repo, context: context, base: [])
        return ToolRequirements(capabilities: [.fileRead(path: repo), .fileWrite(path: target(input, context))], tier: .readOnly,
                                summary: "Write a patch of \(show(repo)) to the run's artifacts")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let repo = try Git.repository(input, context)
        let args = try GitDiffTool.arguments(input, repo: repo, context: context, base: ["diff", "--no-ext-diff", "--no-color", "--binary"])
        let out = try await Git.checked(repo, args, context: context, runner: runner, maxBytes: 64_000_000)
        if out.stdoutTruncated { throw ToolError.unsupported("The diff is larger than 64 MB; narrow it with paths or a smaller range") }
        if out.stdout.isEmpty { return .success(["patchPath": .null, "bytes": 0, "empty": true], summary: "No differences: no patch written") }
        let path = target(input, context)
        try ToolSupport.io("Writing the patch") {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try out.stdout.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        return .success(["patchPath": .string(path), "bytes": .int(out.stdout.count), "empty": false], summary: "Wrote a \(out.stdout.count)-byte patch",
                        artifacts: [ToolSupport.artifact(path, kind: "patch", note: "git diff of \(show(repo))")])
    }
}

// MARK: - push

public struct GitPushTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ToolManifest(
        identifier: "git.push", name: "Git push",
        summary: "Pushes one branch to a configured remote. This publishes commits outside the Mac; force replaces remote history and is high-risk.",
        family: "git",
        inputSchema: Schema.input(["path": repoPath, "remote": .string("Remote name (default origin).", pattern: "^[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$"),
                                   "branch": .string("Branch to push (default: the current branch)."), "force": .boolean("Replace the remote branch."),
                                   "setUpstream": .boolean(), "timeoutSeconds": Schema.timeout]),
        outputSchema: Schema.output(["remote": .string(), "branch": .string(), "forced": .boolean(), "output": .string()], required: ["remote", "branch", "forced"]),
        sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 600, supportsDryRun: true, outputIsUntrusted: true)

    func plan(_ input: ToolInput, _ context: ToolExecutionContext) throws -> (repo: String, remote: String, url: String, target: GitRemoteTarget, branch: String?) {
        let repo = try Git.repository(input, context)
        let remote = input.optionalString("remote") ?? "origin"
        let branch = input.optionalString("branch")
        if let branch {
            try Git.checkRef(branch, what: "branch")
            guard !branch.contains(":"), !branch.contains("^"), !branch.contains("~"), !branch.contains("..") else { throw ToolError.invalidInput("branch must be a plain branch name") }
        }
        guard let url = Git.configuredRemoteURL(repository: repo, remote: remote) else {
            throw ToolError.invalidInput("\(show(repo)) has no remote named \(remote)")
        }
        guard let target = GitRemoteTarget.parse(url, repository: repo) else { throw ToolError.invalidInput("Cannot determine where remote \(remote) points") }
        return (repo, remote, url, target, branch)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input, context)
        let force = input.bool("force", default: false)
        var caps: [Capability] = [.fileRead(path: p.repo), .externalSend(channel: "git-push")]
        switch p.target {
        case .host(let h): caps.append(.network(host: h))
        case .local(let path): caps.append(.fileWrite(path: path))
        }
        return ToolRequirements(capabilities: caps, tier: force ? .highRisk : .consequential,
                                summary: "\(force ? "Force-push" : "Push") \(p.branch ?? "the current branch") of \(show(p.repo)) to \(p.remote) (\(GitRemoteTarget.sanitized(p.url)))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input, context)
        let force = input.bool("force", default: false)
        var branch = p.branch ?? ""
        if branch.isEmpty {
            let current = try await Git.run(p.repo, ["symbolic-ref", "--short", "-q", "HEAD"], context: context, runner: runner)
            branch = current.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { throw ToolError.invalidInput("HEAD is detached; give the branch to push") }
        }
        // The URL git will really use (after insteadOf / pushInsteadOf rewrites) must be the one that was authorised.
        let effective = try await Git.checked(p.repo, ["remote", "get-url", "--push", p.remote], context: context, runner: runner)
        let effectiveURL = effective.stdoutText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard GitRemoteTarget.parse(effectiveURL, repository: p.repo) == p.target else {
            throw ToolError.permissionDenied("Remote \(p.remote) is rewritten by git configuration to a different destination than the one that was authorised")
        }
        if input.dryRun {
            return .simulated(["remote": .string(p.remote), "branch": .string(branch), "forced": .bool(force), "url": .string(GitRemoteTarget.sanitized(p.url))],
                              summary: "Would \(force ? "force-push" : "push") \(branch) to \(p.remote)")
        }
        var args = ["push", "--porcelain"]
        if force { args.append("--force") }
        if input.bool("setUpstream", default: false) { args.append("--set-upstream") }
        args += [p.remote, "refs/heads/\(branch):refs/heads/\(branch)"]
        // Hooks and helper commands configured by the repository must not run during a push.
        let config = ["core.hooksPath=/dev/null", "core.sshCommand=/usr/bin/ssh -oBatchMode=yes", "credential.helper=", "credential.helper=osxkeychain"]
        let out: ProcessOutput
        switch p.target {
        case .local(let path):
            out = try await Git.run(p.repo, args, context: context, runner: runner, writeRoots: [path, p.repo], extraConfig: config,
                                    timeout: input.double("timeoutSeconds", default: 120))
        case .host:
            // Network pushes need the user's SSH keys or keychain credentials, which a Seatbelt-confined process cannot read.
            out = try await Git.run(p.repo, args, context: context, runner: runner, confined: false, extraConfig: config,
                                    timeout: input.double("timeoutSeconds", default: 120))
        }
        guard out.exitCode == 0 else {
            let text = out.stderrText.isEmpty ? out.stdoutText : out.stderrText
            if text.contains("Could not resolve host") || text.contains("Connection") || text.contains("timed out") {
                throw ToolError.network("git push failed: \(text.prefix(1_000))", retryable: true)
            }
            throw ToolError.processFailed(exitCode: out.exitCode, stderr: text)
        }
        return .success(["remote": .string(p.remote), "branch": .string(branch), "forced": .bool(force),
                         "output": .string((out.stdoutText + out.stderrText).truncated(maxBytes: 8_000).text)],
                        summary: "\(force ? "Force-pushed" : "Pushed") \(branch) to \(p.remote)")
    }
}
