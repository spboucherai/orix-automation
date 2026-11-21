// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/PythonTools.swift
// Description: python.run and python.envInfo over a managed virtual environment (never the system Python), pinned-only package installs, Seatbelt-confined execution, new files returned as artifacts.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

private var fm: FileManager { FileManager.default }
private func show(_ path: String) -> String { PathResolver.display(path) }

/// The managed virtual environment ORIX runs Python in.
public struct PythonEnvironment: Sendable, Hashable {
    public let root: URL

    public init(root: URL? = nil) { self.root = root ?? Self.defaultRoot }

    /// `<Application Support>/ORIX Automation/python-env`.
    public static var defaultRoot: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("ORIX Automation/python-env")
    }

    public var rootPath: String { PathResolver.resolveSymlinks(root.path) }
    public var interpreter: String { rootPath + "/bin/python" }
    public var exists: Bool { fm.isExecutableFile(atPath: interpreter) }

    /// The interpreter used to create the environment: the first `python3` on the safe PATH. `/usr/bin/python3` is only
    /// accepted when developer tools are installed (otherwise it is a stub that opens an install dialog).
    public static func basePython() -> String? {
        for dir in ProcessRunner.safePath.split(separator: ":") {
            let candidate = "\(dir)/python3"
            guard fm.isExecutableFile(atPath: candidate) else { continue }
            if candidate == "/usr/bin/python3" {
                let hasTools = fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3") || fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer")
                if !hasTools { continue }
            }
            return candidate
        }
        return nil
    }

    /// Accepts only `name==version`. URLs, VCS references, local paths, options, extras, ranges and markers are refused.
    public static func validate(requirement raw: String) throws -> String {
        let r = raw.trimmingCharacters(in: .whitespaces)
        let lower = r.lowercased()
        if r.hasPrefix("-") { throw ToolError.invalidInput("requirement \(raw): pip options are not allowed") }
        if lower.contains("://") || lower.contains("git+") || lower.contains("hg+") || lower.contains("svn+") || lower.contains("bzr+") || r.contains("@") {
            throw ToolError.invalidInput("requirement \(raw): installing from a URL or a repository is not allowed")
        }
        if r.contains("/") || r.contains("\\") || r.hasPrefix(".") || r.hasPrefix("~") || lower.hasSuffix(".whl") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".zip") {
            throw ToolError.invalidInput("requirement \(raw): installing from a local path or archive is not allowed")
        }
        guard r.range(of: #"^[A-Za-z0-9]([A-Za-z0-9._-]{0,98}[A-Za-z0-9])?==[0-9]+(\.[0-9A-Za-z]+){0,5}((a|b|rc|\.post|\.dev)[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw ToolError.invalidInput("requirement \(raw): only exact pins of the form name==1.2.3 are accepted")
        }
        return r
    }
}

/// Creates each environment once, even when several calls need it at the same moment.
actor PythonEnvironmentCoordinator {
    static let shared = PythonEnvironmentCoordinator()
    private var creating: [String: Task<Void, Error>] = [:]

    func ensure(_ env: PythonEnvironment, context: ToolExecutionContext, runner: ProcessRunner) async throws {
        if env.exists { return }
        let key = env.rootPath
        if let running = creating[key] { try await running.value; return }
        let timeout = context.timeoutSeconds
        let task = Task<Void, Error> {
            guard let base = PythonEnvironment.basePython() else {
                throw ToolError.unsupported("No python3 was found in \(ProcessRunner.safePath); install Python (for example the Xcode command line tools) to use python.run")
            }
            let parent = (key as NSString).deletingLastPathComponent
            do { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) }
            catch { throw ToolError.io("Cannot create \(parent): \(error.localizedDescription)") }
            let out = try await runner.run(ProcessSpec(executable: base, arguments: ["-m", "venv", key], environment: ["LC_ALL": "C"], workingDirectory: parent,
                                                       timeoutSeconds: min(300, timeout), confinement: SeatbeltProfile(writeRoots: [key], allowsNetwork: false)))
            do { try out.requireSuccess(timeoutSeconds: min(300, timeout)) }
            catch {
                try? FileManager.default.removeItem(atPath: key)  // never leave a half-built environment behind
                throw error
            }
            guard env.exists else { throw ToolError.io("python3 -m venv did not produce an interpreter at \(env.interpreter)") }
        }
        creating[key] = task
        defer { creating[key] = nil }
        try await task.value
    }
}

public struct PythonRunTool: ORIXTool {
    let environment: PythonEnvironment
    let runner: ProcessRunner
    public init(envRoot: URL? = nil, runner: ProcessRunner = .shared) { environment = PythonEnvironment(root: envRoot); self.runner = runner }

    public let manifest = ToolManifest(
        identifier: "python.run", name: "Run Python",
        summary: "Runs Python code (or a script file) in ORIX's own virtual environment, inside a sandbox limited to the run's granted folders. Files it creates are returned as artifacts. Packages can be installed first, exact pins only (name==1.2.3).",
        family: "python",
        inputSchema: Schema.input([
            "code": JSONSchema(raw: ["type": "string", "description": "Python source to run.", "maxLength": 400_000]),
            "path": .string("Script file to run instead of code."),
            "args": .array(of: .string(), "sys.argv[1:]."),
            "cwd": .string("Working directory (default: a fresh folder in the run's artifacts)."),
            "requirements": JSONSchema(raw: ["type": "array", "items": ["type": "string"], "maxItems": 50, "description": "Packages to install first, each pinned as name==version."]),
            "stdin": .string(), "timeoutSeconds": Schema.timeout, "maxBytes": .integer(minimum: 1, maximum: 4_000_000),
        ]),
        outputSchema: ProcessToolSupport.outputSchema,
        sideEffect: .external, defaultTier: .consequential, defaultTimeoutSeconds: 1_800, maxOutputBytes: 6_000_000,
        redactedInputKeys: ["stdin"], outputIsUntrusted: true,
        examples: [["code": "import json, sys\nprint(json.dumps({'ok': True}))"]])

    struct Plan { let script: String?; let code: String?; let cwd: String; let defaultCwd: Bool; let requirements: [String] }

    func plan(_ input: ToolInput, _ context: ToolExecutionContext) throws -> Plan {
        let code = input.optionalString("code"), script = try input.optionalPath("path", context)
        guard (code != nil) != (script != nil) else { throw ToolError.invalidInput("give code or path, exactly one") }
        if let code, code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ToolError.invalidInput("code is empty") }
        let requirements = try input.strings("requirements").map(PythonEnvironment.validate(requirement:))
        let scratch = PathResolver.resolveSymlinks(context.artifactsDirectory.path) + "/python/" + context.callID
        let cwd = try input.optionalPath("cwd", context)
        return Plan(script: script, code: code, cwd: cwd ?? scratch, defaultCwd: cwd == nil, requirements: requirements)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let p = try plan(input, context)
        var caps: [Capability] = [.scriptRuntime(name: "python"), .fileRead(path: p.cwd)]
        if let s = p.script { caps.append(.fileRead(path: s)) }
        if !p.requirements.isEmpty { caps += [.network(host: "pypi.org"), .network(host: "files.pythonhosted.org")] }
        let what = p.script.map { "the Python script \(show($0))" } ?? "\((p.code ?? "").split(whereSeparator: \.isNewline).count) lines of Python"
        let install = p.requirements.isEmpty ? "" : ", after installing \(p.requirements.joined(separator: ", ")) from PyPI"
        return ToolRequirements(capabilities: caps, tier: .consequential, summary: "Run \(what) in \(show(p.cwd))\(install)")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let p = try plan(input, context)
        let artifactsDir = try ToolSupport.artifactsDirectory(context)
        let scratch = try ToolSupport.artifactsDirectory(context, subdirectory: "python/" + context.callID)
        if !p.defaultCwd { try ToolSupport.requireDirectory(p.cwd) }
        try await PythonEnvironmentCoordinator.shared.ensure(environment, context: context, runner: runner)
        let timeout = min(context.timeoutSeconds, input.double("timeoutSeconds", default: 120))

        if !p.requirements.isEmpty {
            // The only step with network access, and it can only write inside the environment.
            let args = ["-m", "pip", "install", "--disable-pip-version-check", "--no-input", "--isolated", "--no-cache-dir",
                        "--index-url", "https://pypi.org/simple", "--only-binary=:all:"] + p.requirements
            let pip = try await ToolSupport.run(ProcessSpec(executable: environment.interpreter, arguments: args, environment: ["LC_ALL": "C", "PIP_CONFIG_FILE": "/dev/null"],
                                                            workingDirectory: scratch, timeoutSeconds: context.timeoutSeconds, maxOutputBytes: 400_000,
                                                            confinement: SeatbeltProfile(writeRoots: [environment.rootPath], allowsNetwork: true)),
                                                context: context, runner: runner, stream: true)
            guard pip.exitCode == 0 else {
                let text = (pip.stderrText.isEmpty ? pip.stdoutText : pip.stderrText)
                if text.contains("Could not find a version") || text.contains("No matching distribution") {
                    throw ToolError.notFound("pip could not install \(p.requirements.joined(separator: ", ")): no matching binary distribution on PyPI (source builds are not allowed)")
                }
                if text.contains("ConnectionError") || text.contains("Temporary failure") || text.contains("Failed to establish") || text.contains("Operation not permitted") {
                    throw ToolError.network("pip could not reach PyPI: \(text.suffix(600))", retryable: true)
                }
                throw ToolError.processFailed(exitCode: pip.exitCode, stderr: String(text.suffix(2_000)))
            }
        }

        var scriptPath: String
        if let s = p.script { try ToolSupport.requireFile(s); scriptPath = s }
        else {
            scriptPath = scratch + "/main.py"
            try ToolSupport.io("Writing the script") { try Data((p.code ?? "").utf8).write(to: URL(fileURLWithPath: scriptPath), options: .atomic) }
        }
        let maxBytes = input.int("maxBytes", default: 100_000)
        let watched = [p.cwd, artifactsDir]
        let before = ProcessToolSupport.snapshot(watched)
        let env = ["PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8", "MPLBACKEND": "Agg",
                   "VIRTUAL_ENV": environment.rootPath, "ORIX_ARTIFACTS_DIR": artifactsDir]
        let spec = ProcessSpec(executable: environment.interpreter, arguments: ["-B", "-s", scriptPath] + input.strings("args"), environment: env,
                               workingDirectory: p.cwd, timeoutSeconds: timeout, maxOutputBytes: maxBytes,
                               stdin: input.optionalString("stdin").map { Data($0.utf8) }, confinement: ToolSupport.profile(context))
        let out = try await ToolSupport.run(spec, context: context, runner: runner, stream: true)
        let artifacts = ProcessToolSupport.newArtifacts(before: before, after: ProcessToolSupport.snapshot(watched), excluding: [scriptPath], note: "Created by python.run")
        return ProcessToolSupport.result(out, label: "python", maxBytes: maxBytes,
                                         extra: ["files": .array(artifacts.map { .string($0.path) }), "cwd": .string(p.cwd),
                                                 "installed": .array(p.requirements.map(JSONValue.string))], artifacts: artifacts)
    }
}

public struct PythonEnvInfoTool: ORIXTool {
    let environment: PythonEnvironment
    let runner: ProcessRunner
    public init(envRoot: URL? = nil, runner: ProcessRunner = .shared) { environment = PythonEnvironment(root: envRoot); self.runner = runner }

    public let manifest = ToolManifest(
        identifier: "python.envInfo", name: "Python environment",
        summary: "Describes ORIX's managed Python environment: whether it exists yet, interpreter path and version, and the installed packages.",
        family: "python", inputSchema: Schema.input([:]),
        outputSchema: Schema.output(["exists": .boolean(), "root": .string(), "interpreter": .any, "version": .any, "packages": .array(of: .any)],
                                    required: ["exists", "root", "packages"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 60, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "Describe the managed Python environment")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let none = SeatbeltProfile(writeRoots: [], allowsNetwork: false)
        func version(_ python: String) async throws -> String? {
            let out = try await ToolSupport.run(ProcessSpec(executable: python, arguments: ["--version"], environment: ["LC_ALL": "C"], workingDirectory: "/",
                                                            timeoutSeconds: min(30, context.timeoutSeconds), confinement: none), context: context, runner: runner)
            let text = (out.stdoutText + out.stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
            return out.exitCode == 0 && text.hasPrefix("Python ") ? String(text.dropFirst(7)) : nil
        }
        let base = PythonEnvironment.basePython()
        guard environment.exists else {
            var v: String?
            if let base { v = try await version(base) }
            return .success(["exists": false, "root": .string(environment.rootPath), "interpreter": .null, "version": .null, "packages": [],
                             "basePython": base.map(JSONValue.string) ?? .null, "baseVersion": v.map(JSONValue.string) ?? .null],
                            summary: base == nil ? "No managed environment and no python3 found" : "Managed environment not created yet (will use \(base!))")
        }
        let v = try await version(environment.interpreter)
        let list = try await ToolSupport.run(ProcessSpec(executable: environment.interpreter, arguments: ["-m", "pip", "list", "--format=json", "--disable-pip-version-check"],
                                                         environment: ["LC_ALL": "C", "PIP_CONFIG_FILE": "/dev/null"], workingDirectory: environment.rootPath,
                                                         timeoutSeconds: min(60, context.timeoutSeconds), maxOutputBytes: 2_000_000, confinement: none),
                                             context: context, runner: runner)
        var packages: [JSONValue] = []
        if list.exitCode == 0, let parsed = try? JSONValue.parse(list.stdout), let items = parsed.arrayValue {
            packages = items.compactMap { item in
                guard let name = item["name"]?.stringValue, let ver = item["version"]?.stringValue else { return nil }
                return ["name": .string(name), "version": .string(ver)]
            }
        }
        return .success(["exists": true, "root": .string(environment.rootPath), "interpreter": .string(environment.interpreter),
                         "version": v.map(JSONValue.string) ?? .null, "packages": .array(packages), "basePython": base.map(JSONValue.string) ?? .null,
                         "packagesListed": .bool(list.exitCode == 0)],
                        summary: "Python \(v ?? "?") with \(ToolSupport.plural(packages.count, "package"))")
    }
}
