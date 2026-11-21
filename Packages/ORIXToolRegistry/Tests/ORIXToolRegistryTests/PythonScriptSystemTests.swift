// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Tests/ORIXToolRegistryTests/PythonScriptSystemTests.swift
// Description: Integration tests of python.* (a managed environment in a temp root, no network installs), script.swift, script.javascript and system.*, plus unit tests of requirement pinning.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Testing
import ORIXCore
import ORIXTestingSupport
@testable import ORIXToolRegistry

@Suite("python.* tools (integration, real venv in a temp root)")
struct PythonToolsTests {
    @Test func managedEnvironmentLifecycleRunAndConfinement() async throws {
        guard PythonEnvironment.basePython() != nil else {
            print("SKIPPED(no python3 on the safe PATH: python.run cannot create its environment on this Mac)")
            return
        }
        let envHome = try TempDirectory(prefix: "orix-pyenv"); defer { envHome.remove() }
        let envRoot = envHome.url.appendingPathComponent("python-env")
        let h = try await Harness(pythonEnvRoot: envRoot); defer { h.tmp.remove() }
        let outside = try TempDirectory(prefix: "orix-outside"); defer { outside.remove() }

        let before = await h.call("python.envInfo")
        #expect(before.status == .succeeded && before.output["exists"] == false && before.output["basePython"]?.stringValue != nil)
        #expect(before.output["baseVersion"]?.stringValue?.first?.isNumber == true && !FileManager.default.fileExists(atPath: envRoot.path), "envInfo never creates the environment")

        let code = """
        import sys, os, json
        open('result.json', 'w').write(json.dumps({'sum': sum(range(10))}))
        open(os.path.join(os.environ['ORIX_ARTIFACTS_DIR'], 'chart.txt'), 'w').write('chart')
        print('venv' if sys.prefix != sys.base_prefix else 'system')
        print(sys.executable)
        print(sys.argv[1:])
        """
        let run = await h.call("python.run", ["code": .string(code), "args": ["--n", "3"]])
        #expect(run.status == .succeeded && run.output["exitCode"] == 0, "\(run.failure?.message ?? "") \(run.output["stderr"]?.stringValue ?? "")")
        let lines = (run.output["stdout"]?.stringValue ?? "").split(separator: "\n").map(String.init)
        #expect(lines.count == 3 && lines[0] == "venv" && lines[1].hasPrefix(envRoot.path) && lines[2] == "['--n', '3']")
        let files = Set(run.artifacts.map { ($0.path as NSString).lastPathComponent })
        #expect(files == ["result.json", "chart.txt"], "new files are returned as artifacts, the script itself is not: \(files)")
        #expect(run.artifacts.allSatisfy { $0.path.hasPrefix(h.path("artifacts")) && $0.sha256 != nil } && run.untrusted)
        #expect(FileManager.default.isExecutableFile(atPath: envRoot.path + "/bin/python"))

        let after = await h.call("python.envInfo")
        #expect(after.output["exists"] == true && after.output["version"]?.stringValue?.first?.isNumber == true)
        #expect(after.output["packages"]?.arrayValue?.contains { $0["name"] == "pip" } == true, "\(after.output.serialized())")

        // Script file + cwd + stdin.
        try h.tmp.write("work/tool.py", "import sys\ndata = sys.stdin.read()\nopen('out.txt', 'w').write(data.upper())\nprint(len(data))\n")
        let script = await h.call("python.run", ["path": "work/tool.py", "cwd": "work", "stdin": "abc"])
        #expect(script.output["stdout"] == "3\n" && h.read("work/out.txt") == "ABC" && script.artifacts.map(\.path) == [h.path("work/out.txt")])

        // Confinement: no write outside the granted folder, no network, no credential stores.
        let probe = """
        import socket, os
        for label, action in [('write', lambda: open(r'\(outside.url.path)/leak.txt', 'w').write('x')),
                              ('net', lambda: socket.socket().bind(('127.0.0.1', 0))),
                              ('ssh', lambda: os.listdir(os.path.expanduser('~/.ssh')))]:
            try:
                action(); print(label, 'ALLOWED')
            except Exception as e:
                print(label, 'DENIED', type(e).__name__)
        """
        let confined = await h.call("python.run", ["code": .string(probe)])
        let report = confined.output["stdout"]?.stringValue ?? ""
        #expect(report.contains("write DENIED") && report.contains("net DENIED") && !report.contains("ALLOWED"), "\(report)")
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.ssh") { #expect(report.contains("ssh DENIED PermissionError"), "\(report)") }
        #expect(!FileManager.default.fileExists(atPath: outside.file("leak.txt").path))

        let failing = await h.call("python.run", ["code": "raise SystemExit('boom')"])
        #expect(failing.status == .succeeded && failing.output["exitCode"] == 1 && failing.output["stderr"]?.stringValue?.contains("boom") == true)
        let slow = await h.call("python.run", ["code": "import time\ntime.sleep(60)", "timeoutSeconds": 1])
        #expect(slow.status == .timedOut)
        // The system interpreter's site-packages were never touched: the environment is self-contained under its root.
        #expect(FileManager.default.fileExists(atPath: envRoot.path + "/pyvenv.cfg"))
    }

    @Test func argumentsAndRequirementsAreValidatedBeforeAnythingRuns() async throws {
        let policy = ApprovalPolicy(denyTools: ["python.run"])
        let h = try await Harness(policy: policy); defer { h.tmp.remove() }
        #expect(await h.call("python.run", [:]).status == .invalidInput)
        #expect(await h.call("python.run", ["code": "print(1)", "path": "x.py"]).status == .invalidInput)
        #expect(await h.call("python.run", ["code": "  "]).status == .invalidInput)
        for bad in ["requests", "requests>=2.0", "git+https://github.com/psf/requests", "https://example.com/pkg.whl", "./local-pkg", "-r requirements.txt",
                    "--index-url=https://evil.example/simple", "pkg @ file:///tmp/pkg", "pkg[extra]==1.0", "pkg==1.0; python_version<'3'", "pkg==1.*", "../pkg==1.0", "pkg==1.0 --pre"] {
            #expect(await h.call("python.run", ["code": "print(1)", "requirements": [.string(bad)]]).status == .invalidInput, "\(bad)")
        }
        #expect(await policy.requests.isEmpty, "invalid requirements never reach the policy")

        // A valid pinned install is a tier-2 call that needs both PyPI hosts; here the policy refuses it, so nothing is installed.
        let denied = await h.call("python.run", ["code": "print(1)", "requirements": ["requests==2.32.3", "numpy==2.1.0"]], id: "call-py")
        #expect(denied.status == .denied)
        let request = try #require(await policy.requests.last)
        #expect(request.tier == .consequential)
        // The default working folder lives in the run's artifacts, which the executor grants implicitly.
        #expect(request.capabilities == [.scriptRuntime(name: "python"), .network(host: "pypi.org"), .network(host: "files.pythonhosted.org")])
        #expect(request.summary.contains("requests==2.32.3"))
        _ = await h.call("python.run", ["path": "scripts/a.py", "cwd": "scripts"])
        #expect(await policy.requests.last?.capabilities == [.scriptRuntime(name: "python"), .fileRead(path: h.path("scripts")), .fileRead(path: h.path("scripts/a.py"))])
        #expect(!h.exists("py-env-unused"), "a refused call does not create the environment")
    }

    @Test func requirementPinsOnly() throws {
        for ok in ["requests==2.32.3", "numpy==1.26.4", "typing_extensions==4.12.2", "ruamel.yaml==0.18.6", "torch==2.1.0rc1", "pkg==1.0.post1", "A==1"] {
            #expect(try PythonEnvironment.validate(requirement: ok) == ok, "\(ok)")
        }
        #expect(try PythonEnvironment.validate(requirement: "  pandas==2.2.2 ") == "pandas==2.2.2")
        for bad in ["", "pandas", "pandas==", "==1.0", "pandas===1.0", "pandas~=2.0", "pandas==2.0,<3", "svn+ssh://host/repo", "pkg==1.0@evil", "C:\\pkg==1.0", "pkg.whl", "~/pkg==1"] {
            #expect(throws: ToolError.self, "\(bad)") { try PythonEnvironment.validate(requirement: bad) }
        }
        #expect(PythonEnvironment().root.path.hasSuffix("/ORIX Automation/python-env"))
        #expect(PythonEnvironment(root: URL(fileURLWithPath: "/tmp/x")).interpreter.hasSuffix("/x/bin/python"))
    }
}

@Suite("script.* tools (integration, real interpreters)")
struct ScriptToolsTests {
    @Test func swiftScriptRunsConfined() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/swift") else { print("SKIPPED(/usr/bin/swift is missing)"); return }
        let h = try await Harness(); defer { h.tmp.remove() }
        let outside = try TempDirectory(prefix: "orix-outside"); defer { outside.remove() }
        let source = """
        import Foundation
        let args = CommandLine.arguments.dropFirst()
        print("sum=\\(args.compactMap { Int($0) }.reduce(0, +))")
        let artifacts = ProcessInfo.processInfo.environment["ORIX_ARTIFACTS_DIR"]!
        try "made by swift".write(toFile: artifacts + "/swift-out.txt", atomically: false, encoding: .utf8)
        do { try "leak".write(toFile: "\(outside.url.path)/leak.txt", atomically: false, encoding: .utf8); print("outside WRITTEN") }
        catch { print("outside DENIED") }
        """
        let r = await h.call("script.swift", ["script": .string(source), "args": ["4", "5", "x"]])
        guard r.output["exitCode"] == 0 else {
            let stderr = r.output["stderr"]?.stringValue ?? r.failure?.message ?? ""
            if stderr.contains("xcrun") || stderr.contains("developer tools") || stderr.contains("xcode-select") {
                print("SKIPPED(the Swift toolchain is not usable here: \(stderr.prefix(200)))"); return
            }
            Issue.record("script.swift failed: \(r.status) \(stderr.prefix(2000))"); return
        }
        let stdout = r.output["stdout"]?.stringValue ?? ""
        #expect(r.status == .succeeded && stdout.contains("sum=9") && stdout.contains("outside DENIED") && !stdout.contains("WRITTEN"))
        #expect(h.read("artifacts/swift-out.txt") == "made by swift" && r.artifacts.map { ($0.path as NSString).lastPathComponent } == ["swift-out.txt"])
        #expect(!FileManager.default.fileExists(atPath: outside.file("leak.txt").path))
        let broken = await h.call("script.swift", ["script": "let x: Int = \"not an int\""])
        #expect(broken.status == .succeeded && broken.output["exitCode"] != 0 && broken.output["stderr"]?.stringValue?.contains("error") == true)
    }

    @Test func javascriptRunsOutOfProcessInJSC() async throws {
        guard FileManager.default.isExecutableFile(atPath: ScriptJavaScriptTool.jscPath) else {
            let h = try await Harness(); defer { h.tmp.remove() }
            #expect(await h.call("script.javascript", ["script": "print(1)"]).status == .unsupported)
            print("SKIPPED(the jsc helper is not present on this Mac; the tool answers unsupported)")
            return
        }
        let policy = ApprovalPolicy()
        let h = try await Harness(policy: policy, approvals: ScriptedApprovalBroker(fallback: .approveOnce)); defer { h.tmp.remove() }
        let source = """
        const data = [3, 1, 2].sort().map(x => x * 2);
        print(JSON.stringify({ data, args: arguments, hasProcess: typeof process, hasFetch: typeof fetch }));
        """
        let r = await h.call("script.javascript", ["script": .string(source), "args": ["one", "two"]], id: "call-js")
        #expect(r.status == .succeeded && r.output["exitCode"] == 0, "\(r.output.serialized()) \(r.failure?.message ?? "")")
        let parsed = try JSONValue.parse((r.output["stdout"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(parsed["data"] == [2, 4, 6] && parsed["args"] == ["one", "two"] && parsed["hasProcess"] == "undefined" && parsed["hasFetch"] == "undefined")
        let request = await policy.requests.last
        #expect(request?.tier == .consequential && request?.capabilities == [.scriptRuntime(name: "javascript")])
        let thrown = await h.call("script.javascript", ["script": "throw new Error('kaboom')"])
        #expect(thrown.output["exitCode"] != 0 && (thrown.output["stderr"]?.stringValue ?? "").contains("kaboom") || (thrown.output["stdout"]?.stringValue ?? "").contains("kaboom"))
        let loop = await h.call("script.javascript", ["script": "while (true) {}", "timeoutSeconds": 1])
        #expect(loop.status == .timedOut)
        #expect(await h.call("script.javascript", ["script": ""]).status == .invalidInput)
    }
}

@Suite("system.* tools (integration, this Mac)")
struct SystemToolsTests {
    @Test func info() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        let r = await h.call("system.info")
        #expect(r.status == .succeeded && !r.untrusted)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #expect(r.output["osVersion"] == .string("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"))
        #expect(r.output["model"]?.stringValue?.isEmpty == false && r.output["model"] != "unknown" && r.output["cpu"] != "unknown")
        #expect(r.output["cores"] == .int(ProcessInfo.processInfo.processorCount) && (r.output["memoryBytes"]?.intValue ?? 0) >= 4_000_000_000)
        #expect((r.output["uptimeSeconds"]?.intValue ?? 0) > 0 && ["arm64", "x86_64"].contains(r.output["architecture"]?.stringValue ?? ""))
    }

    @Test func processes() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        let cpu = await h.call("system.processes", ["limit": 5])
        let list = cpu.output["processes"]?.arrayValue ?? []
        #expect(cpu.status == .succeeded && list.count == 5 && (cpu.output["total"]?.intValue ?? 0) > 20, "\(cpu.failure?.message ?? "")")
        #expect(list.allSatisfy { ($0["pid"]?.intValue ?? 0) > 0 && $0["name"]?.stringValue?.isEmpty == false && $0["user"]?.stringValue?.isEmpty == false })
        let values = list.compactMap { $0["cpuPercent"]?.doubleValue }
        #expect(values == values.sorted(by: >))
        let memory = await h.call("system.processes", ["sortBy": "memory", "limit": 3])
        let rss = (memory.output["processes"]?.arrayValue ?? []).compactMap { $0["residentBytes"]?.intValue }
        #expect(rss.count == 3 && rss == rss.sorted(by: >) && rss[0] > 1_000_000)
        let parsed = SystemProcessesTool.parse("  PID  PPID  %CPU %MEM    RSS USER             COMM\n    1     0   0.3  0.1  19088 root             launchd\n  612     1  12.5  1.4 234112 simon            Google Chrome Helper\nbroken line\n")
        #expect(parsed.count == 2 && parsed[1]["name"] == "Google Chrome Helper" && parsed[1]["cpuPercent"] == 12.5 && parsed[1]["residentBytes"] == .int(234112 * 1024) && parsed[0]["ppid"] == 0)
    }

    @Test func diskUsage() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        let r = await h.call("system.diskUsage")
        let volumes = r.output["volumes"]?.arrayValue ?? []
        #expect(r.status == .succeeded && !volumes.isEmpty)
        let root = try #require(volumes.first { $0["path"] == "/" })
        let total = root["totalBytes"]?.intValue ?? 0, available = root["availableBytes"]?.intValue ?? -1
        #expect(total > 10_000_000_000 && available >= 0 && available <= total && root["internal"] != nil)
        #expect((root["usedPercent"]?.doubleValue ?? -1) >= 0 && (root["usedPercent"]?.doubleValue ?? 101) <= 100)
    }

    @Test func powerState() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        let r = await h.call("system.powerState")
        #expect(r.status == .succeeded, "\(r.failure?.message ?? "")")
        let batteries = r.output["batteries"]?.arrayValue ?? []
        #expect(r.output["hasBattery"] == .bool(!batteries.isEmpty) && r.output["source"]?.stringValue?.isEmpty == false)
        if batteries.isEmpty { #expect(r.output["onACPower"] == true, "a Mac without a battery runs on AC power") }
        for b in batteries { #expect((0...100).contains(b["percent"]?.intValue ?? -1) && b["charging"]?.boolValue != nil) }
    }

    @Test func networkState() async throws {
        let h = try await Harness(); defer { h.tmp.remove() }
        let r = await h.call("system.networkState")
        #expect(r.status == .succeeded, "\(r.failure?.message ?? "")")
        #expect(["satisfied", "unsatisfied", "requiresConnection"].contains(r.output["status"]?.stringValue ?? ""))
        #expect(r.output["online"] == .bool(r.output["status"] == "satisfied") && r.output["interfaces"]?.arrayValue != nil)
        if r.output["online"] == true { #expect(r.output["usedInterfaceTypes"]?.arrayValue?.isEmpty == false) }
    }

    @Test func systemToolsNeedNoCapability() async throws {
        let policy = ApprovalPolicy()
        let h = try await Harness(policy: policy); defer { h.tmp.remove() }
        for id in ["system.info", "system.processes", "system.diskUsage", "system.powerState", "system.networkState", "python.envInfo"] {
            #expect(await h.call(id).status == .succeeded, "\(id)")
        }
        #expect(await policy.requests.count == 6)
        #expect(await policy.requests.allSatisfy { $0.capabilities.isEmpty && $0.tier == .readOnly })
        #expect(await h.call("system.info", ["extra": 1]).status == .invalidInput)
    }
}
