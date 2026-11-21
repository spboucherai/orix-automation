// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/ShellTools.swift
// Description: shell.run (one executable with an argv array, no shell, privilege escalation and inline interpreter code refused) and shell.script (bash text, always Seatbelt-confined).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

private func show(_ path: String) -> String { PathResolver.display(path) }

/// Rules deciding what `shell.run` refuses outright. Pure functions, unit-tested on their own.
public enum ShellCommandRules {
    static let privilege: Set<String> = ["sudo", "su", "doas", "login", "pkexec"]
    /// Launchers that only exist to run another command: the real command must be the one that is declared.
    static let wrappers: Set<String> = ["env", "xargs", "nohup", "nice", "time", "timeout", "caffeinate", "sandbox-exec", "script", "expect",
                                        "command", "exec", "launchctl", "open", "osacompile"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish"]
    /// Interpreter name prefix → options that take inline code.
    static let inlineCodeOptions: [(prefix: String, options: Set<String>)] = [
        ("python", ["-c"]), ("perl", ["-e", "-E"]), ("ruby", ["-e"]), ("node", ["-e", "--eval", "-p", "--print"]),
        ("osascript", ["-e"]), ("php", ["-r"]), ("swift", ["-e"]), ("lua", ["-e"]), ("deno", ["eval"]), ("bun", ["-e", "--eval"]),
        ("tclsh", ["-c"]), ("jsc", ["-e"]),
    ]
    static let environmentDenied: Set<String> = ["PATH", "HOME", "TMPDIR", "IFS", "ENV", "BASH_ENV", "SHELL", "PYTHONSTARTUP", "NODE_OPTIONS", "PERL5OPT", "RUBYOPT"]

    /// Returns the reason the command is refused, or nil when it may be evaluated by the policy.
    public static func refusal(executablePath: String, arguments: [String], hasStdin: Bool = false) -> String? {
        let name = (executablePath as NSString).lastPathComponent.lowercased()
        if privilege.contains(name) { return "\(name) is not supported: ORIX never escalates privileges" }
        if wrappers.contains(name) { return "\(name) only launches another command; call that command directly so it can be authorised by name" }
        // Options before the first operand.
        var options: [String] = []
        var firstOperand: String?
        for a in arguments {
            if a == "--" { break }
            if a.hasPrefix("-") && a.count > 1 { options.append(a) } else { firstOperand = a; break }
        }
        if shells.contains(name) {
            // Conservative: any single-dash option cluster containing `c`, wherever it appears (`bash -o pipefail -c …`).
            if arguments.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("c") }) {
                return "\(name) -c runs inline shell code; use shell.script so the code is confined and reviewed"
            }
            if firstOperand == nil || firstOperand == "-" || firstOperand == "/dev/stdin" { return "\(name) without a script file would read commands from standard input; use shell.script" }
        }
        for (prefix, flags) in inlineCodeOptions where name == prefix || (name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy { $0.isNumber || $0 == "." }) {
            if arguments.contains(where: { flags.contains($0) }) || options.contains(where: { o in flags.contains { f in f.count == 2 && !o.hasPrefix("--") && o.dropFirst().contains(f.last!) } }) {
                let route = prefix == "python" ? "python.run" : (prefix == "swift" ? "script.swift" : (prefix == "osascript" ? "the applescript tools" : "shell.script or a script tool"))
                return "\(name) with inline code is refused; use \(route) so the code is confined and reviewed"
            }
            if firstOperand == nil && hasStdin && prefix != "osascript" { return "\(name) would read its program from standard input; use the matching script tool" }
        }
        if name == "rm", arguments.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && ($0.contains("r") || $0.contains("R")) || $0 == "--recursive" }) {
            let home = NSHomeDirectory()
            for a in arguments where !a.hasPrefix("-") {
                let expanded = a == "~" ? home : (a.hasPrefix("~/") ? home + a.dropFirst(1) : a)
                let trimmed = expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
                let normal = trimmed.hasPrefix("/") ? ToolSupport.lexical(trimmed) : trimmed
                if normal == "/" || normal == home || normal == "/*" || trimmed.hasSuffix("/*") && ((trimmed as NSString).deletingLastPathComponent == "/" || (trimmed as NSString).deletingLastPathComponent == home)
                    || normal.split(separator: "/").count == 1 && normal.hasPrefix("/") {
                    return "rm -r on \(a) is not supported"
                }
            }
        }
        return nil
    }

    /// Validates caller-supplied environment additions.
    public static func checkEnvironment(_ env: [String: String]) throws {
        for key in env.keys {
            let upper = key.uppercased()
            if environmentDenied.contains(upper) || upper.hasPrefix("DYLD_") || upper.hasPrefix("LD_") || upper.hasPrefix("GIT_CONFIG") || upper.hasPrefix("BASH_FUNC") {
                throw ToolError.invalidInput("environment variable \(key) cannot be set by a tool call")
            }
            if key.isEmpty || key.contains("=") { throw ToolError.invalidInput("invalid environment variable name") }
        }
    }
}

private let processOutput = Schema.output([
    "exitCode": .integer(), "stdout": .string(), "stderr": .string(), "truncated": .boolean(), "durationMs": .integer(),
], required: ["exitCode", "stdout", "stderr", "truncated"])

private func processResult(_ out: ProcessOutput, label: String, maxBytes: Int, extra: [String: JSONValue] = [:], artifacts: [Artifact] = []) -> ToolResult {
    let so = out.stdoutText.truncated(maxBytes: maxBytes), se = out.stderrText.truncated(maxBytes: max(4_096, maxBytes / 4))
    let cut = out.truncated || so.truncated || se.truncated
    var object: [String: JSONValue] = ["exitCode": .int(Int(out.exitCode)), "stdout": .string(so.text), "stderr": .string(se.text),
                                       "truncated": .bool(cut), "durationMs": .int(out.durationMs)]
    if let s = out.signal { object["signal"] = .int(Int(s)) }
    for (k, v) in extra { object[k] = v }
    var result = ToolResult.success(.object(object), summary: "\(label) exited with code \(out.exitCode) in \(out.durationMs) ms", artifacts: artifacts)
    result.truncated = cut
    result.untrusted = true
    return result
}

// MARK: - shell.run

public struct ShellRunTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }

    public let manifest = ToolManifest(
        identifier: "shell.run", name: "Run a program",
        summary: "Runs one executable with an explicit argument array (no shell, no interpolation), confined to the folders granted to the run. Refuses sudo/su/doas and interpreters given inline code; a non-zero exit code is returned, not raised.",
        family: "shell",
        inputSchema: Schema.input([
            "executable": .string("Program name (resolved through a fixed system PATH) or absolute path."),
            "args": .array(of: .string(), "Arguments, passed verbatim as separate argv elements."),
            "cwd": .string("Working directory (default: the run's working directory)."),
            "env": JSONSchema(raw: ["type": "object", "additionalProperties": ["type": "string"], "description": "Extra environment variables."]),
            "stdin": .string("Text written to the program's standard input."),
            "timeoutSeconds": Schema.timeout, "maxBytes": .integer("Output bound per stream (default 100000).", minimum: 1, maximum: 4_000_000),
        ], required: ["executable"]),
        outputSchema: processOutput,
        sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 1_800, maxOutputBytes: 6_000_000,
        redactedInputKeys: ["env", "stdin"], outputIsUntrusted: true,
        examples: [["executable": "git", "args": ["--version"]]])

    struct Plan { let executablePath: String; let capabilityName: String; let cwd: String; let args: [String]; let env: [String: String] }

    func plan(_ input: ToolInput, _ context: ToolExecutionContext) throws -> Plan {
        let raw = try input.string("executable").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { throw ToolError.invalidInput("executable is empty") }
        let path: String, capability: String
        if raw.contains("/") {
            let canonical = try PathResolver.canonical(raw, relativeTo: context.workingDirectory)
            guard let resolved = ProcessRunner.resolveExecutable(canonical) else { throw ToolError.notFound("Not an executable file: \(show(canonical))") }
            path = resolved; capability = resolved
        } else {
            guard let resolved = ProcessRunner.resolveExecutable(raw) else {
                throw ToolError.notFound("\(raw) was not found in \(ProcessRunner.safePath)")
            }
            path = resolved; capability = raw
        }
        let args = input.strings("args")
        guard args.count == (input.arguments["args"]?.arrayValue?.count ?? 0) else { throw ToolError.invalidInput("args must be an array of strings") }
        // Judge the real binary too, so a symlink or copy named differently cannot hide sudo or a shell.
        let real = PathResolver.resolveSymlinks(path)
        for candidate in Set([path, real]) {
            if let reason = ShellCommandRules.refusal(executablePath: candidate, arguments: args, hasStdin: input.optionalString("stdin") != nil) {
                throw ToolError.unsupported(reason)
            }
        }
        let env = input.stringMap("env")
        try ShellCommandRules.checkEnvironment(env)
        let cwd = try input.optionalPath("cwd", context) ?? PathResolver.resolveSymlinks(context.workingDirectory.path)
        return Plan(executablePath: path, capabilityName: capability, cwd: cwd, args: args, env: env)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input, context)
        let shown = ([p.capabilityName] + p.args).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        return ToolRequirements(capabilities: [.processExec(executable: p.capabilityName), .fileRead(path: p.cwd)], tier: .consequential,
                                summary: "Run \(String(shown.prefix(300))) in \(show(p.cwd))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input, context)
        try ToolSupport.requireDirectory(p.cwd)
        let timeout = min(context.timeoutSeconds, input.double("timeoutSeconds", default: 120))
        let maxBytes = input.int("maxBytes", default: 100_000)
        let spec = ProcessSpec(executable: p.executablePath, arguments: p.args, environment: p.env, workingDirectory: p.cwd, timeoutSeconds: timeout,
                               maxOutputBytes: maxBytes, stdin: input.optionalString("stdin").map { Data($0.utf8) },
                               confinement: ToolSupport.profile(context))
        let out = try await ToolSupport.run(spec, context: context, runner: runner, stream: true)
        return processResult(out, label: (p.executablePath as NSString).lastPathComponent, maxBytes: maxBytes, extra: ["executable": .string(p.executablePath)])
    }
}

// MARK: - shell.script

public struct ShellScriptTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }

    public let manifest = ToolManifest(
        identifier: "shell.script", name: "Run a bash script",
        summary: "Runs bash script text inside a Seatbelt sandbox: it can only write to the folders granted to the run and its artifacts, and has no network unless a host is granted. Privilege escalation is refused.",
        family: "shell",
        inputSchema: Schema.input([
            "script": JSONSchema(raw: ["type": "string", "description": "Bash source.", "minLength": 1, "maxLength": 200_000]),
            "args": .array(of: .string(), "Positional parameters ($1, $2 …)."),
            "cwd": .string("Working directory (default: the run's working directory)."),
            "env": JSONSchema(raw: ["type": "object", "additionalProperties": ["type": "string"]]),
            "timeoutSeconds": Schema.timeout, "maxBytes": .integer(minimum: 1, maximum: 4_000_000),
        ], required: ["script"]),
        outputSchema: processOutput,
        sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 1_800, maxOutputBytes: 6_000_000,
        redactedInputKeys: ["env"], outputIsUntrusted: true)

    static let escalation = try! NSRegularExpression(pattern: #"(^|[;&|(){}\s`])(sudo|doas|su|pkexec)(\s|$)"#, options: [.anchorsMatchLines])

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let script = try input.string("script")
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.invalidInput("script is empty") }
        if Self.escalation.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)) != nil {
            throw ToolError.unsupported("The script calls sudo/su/doas: ORIX never escalates privileges")
        }
        try ShellCommandRules.checkEnvironment(input.stringMap("env"))
        let cwd = try input.optionalPath("cwd", context) ?? PathResolver.resolveSymlinks(context.workingDirectory.path)
        let first = script.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let lines = script.split(whereSeparator: \.isNewline).count
        return ToolRequirements(capabilities: [.scriptRuntime(name: "bash"), .fileRead(path: cwd)], tier: .consequential,
                                summary: "Run a \(lines)-line bash script in \(show(cwd)) (starts with: \(first.prefix(80)))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let script = try input.string("script")
        let cwd = try input.optionalPath("cwd", context) ?? PathResolver.resolveSymlinks(context.workingDirectory.path)
        try ToolSupport.requireDirectory(cwd)
        let timeout = min(context.timeoutSeconds, input.double("timeoutSeconds", default: 120))
        let maxBytes = input.int("maxBytes", default: 100_000)
        var env = input.stringMap("env")
        env["ORIX_ARTIFACTS_DIR"] = try ToolSupport.artifactsDirectory(context)
        // The script is one argv element of bash: no file to clean up, nothing interpolated.
        let spec = ProcessSpec(executable: "/bin/bash", arguments: ["--noprofile", "--norc", "-c", script, "orix-script"] + input.strings("args"),
                               environment: env, workingDirectory: cwd, timeoutSeconds: timeout, maxOutputBytes: maxBytes,
                               confinement: ToolSupport.profile(context))
        let out = try await ToolSupport.run(spec, context: context, runner: runner, stream: true)
        return processResult(out, label: "bash script", maxBytes: maxBytes)
    }
}

/// Shared by the script-running tools of this package.
enum ProcessToolSupport {
    static let outputSchema = processOutput
    static func result(_ out: ProcessOutput, label: String, maxBytes: Int, extra: [String: JSONValue] = [:], artifacts: [Artifact] = []) -> ToolResult {
        processResult(out, label: label, maxBytes: maxBytes, extra: extra, artifacts: artifacts)
    }

    /// Files (path → size, mtime) under `roots`, bounded, for before/after artifact detection.
    static func snapshot(_ roots: [String], limit: Int = 5_000) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        for root in Set(roots) {
            guard let walker = fm.enumerator(atPath: root) else { continue }
            while let rel = walker.nextObject() as? String {
                if out.count >= limit { return out }
                if rel.hasPrefix("backups/") || rel.contains("/.") || rel.hasPrefix(".") || rel.contains("__pycache__") { continue }
                let full = root + "/" + rel
                var st = stat()
                guard lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                out[full] = "\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
            }
        }
        return out
    }

    static func newArtifacts(before: [String: String], after: [String: String], excluding: Set<String> = [], note: String) -> [Artifact] {
        after.filter { before[$0.key] != $0.value && !excluding.contains($0.key) }.keys.sorted().prefix(100).map {
            ToolSupport.artifact($0, kind: "file", note: note)
        }
    }
}
