// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Tests/ORIXToolRegistryTests/ProcessRunnerTests.swift
// Description: Integration tests of ProcessRunner with real subprocesses (argv, env, output bounds, timeout, cancellation, process-tree cleanup) and security tests of the Seatbelt profile.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Testing
import ORIXCore
import ORIXTestingSupport
@testable import ORIXToolRegistry

@Suite("ProcessRunner (integration, real subprocesses)")
struct ProcessRunnerTests {
    let runner = ProcessRunner()

    func sh(_ script: String, cwd: String, timeout: Double = 20, maxBytes: Int = 1_048_576, grace: Double = 2,
            profile: SeatbeltProfile? = nil, env: [String: String] = [:]) async throws -> ProcessOutput {
        try await runner.run(ProcessSpec(executable: "/bin/sh", arguments: ["-c", script], environment: env, workingDirectory: cwd,
                                         timeoutSeconds: timeout, maxOutputBytes: maxBytes, confinement: profile, killGraceSeconds: grace))
    }

    @Test func capturesOutputExitCodeAndWorkingDirectory() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let out = try await sh("pwd; echo problem >&2; exit 3", cwd: tmp.url.path)
        #expect(out.exitCode == 3 && out.termination == .exited && out.signal == nil)
        #expect(out.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == tmp.url.path)
        #expect(out.stderrText == "problem\n")
        #expect(runner.liveProcessGroups.isEmpty)
    }

    @Test func argumentsAreLiteralArgvElements() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let nasty = "a b; rm -rf ~ $(echo x) `id` 'q' \"d\" *"
        let out = try await runner.run(ProcessSpec(executable: "/usr/bin/printf", arguments: ["%s|", nasty, "second"], workingDirectory: tmp.url.path))
        #expect(out.stdoutText == nasty + "|second|")
    }

    @Test func environmentIsMinimalAndExplicit() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        setenv("ORIX_TEST_LEAK", "must-not-be-inherited", 1)
        let out = try await runner.run(ProcessSpec(executable: "/usr/bin/env", environment: ["EXTRA": "yes"], workingDirectory: tmp.url.path))
        let vars = Dictionary(uniqueKeysWithValues: out.stdoutText.split(separator: "\n").compactMap { line -> (String, String)? in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        })
        #expect(vars["PATH"] == ProcessRunner.safePath)
        #expect(vars["HOME"] == NSHomeDirectory() && vars["EXTRA"] == "yes" && vars["LANG"] != nil)
        #expect(vars["TMPDIR"]?.contains("orix-proc-") == true)
        #expect(vars["ORIX_TEST_LEAK"] == nil && vars["USER"] == nil && vars["SSH_AUTH_SOCK"] == nil)
        #expect(Set(vars.keys).subtracting(["PATH", "HOME", "LANG", "TMPDIR", "EXTRA", "__CF_USER_TEXT_ENCODING"]).isEmpty)
        // The scratch directory is removed when the process ends.
        #expect(!FileManager.default.fileExists(atPath: vars["TMPDIR"] ?? "/"))
    }

    @Test func executableResolutionUsesOnlyTheSafePath() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        #expect(ProcessRunner.resolveExecutable("ls") == "/bin/ls")
        #expect(ProcessRunner.resolveExecutable("git") == "/usr/bin/git")
        #expect(ProcessRunner.resolveExecutable("definitely-not-a-program-xyz") == nil)
        #expect(ProcessRunner.resolveExecutable("./ls") == nil && ProcessRunner.resolveExecutable("bin/ls") == nil)
        #expect(ProcessRunner.resolveExecutable("/bin") == nil && ProcessRunner.resolveExecutable("") == nil)
        // A program reachable only through a caller-supplied PATH is not found.
        let fake = try tmp.write("orixfake", "#!/bin/sh\necho hijacked\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        await #expect(throws: ToolError.self) {
            _ = try await runner.run(ProcessSpec(executable: "orixfake", environment: ["PATH": tmp.url.path], workingDirectory: tmp.url.path))
        }
        await #expect(throws: ToolError.self) {
            _ = try await runner.run(ProcessSpec(executable: "/bin/ls", workingDirectory: tmp.url.path + "/missing"))
        }
    }

    @Test func standardInputIsDelivered() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let out = try await runner.run(ProcessSpec(executable: "/bin/cat", workingDirectory: tmp.url.path, stdin: Data("from stdin".utf8)))
        #expect(out.stdoutText == "from stdin")
        // Without stdin the child reads /dev/null and ends at once.
        let none = try await runner.run(ProcessSpec(executable: "/bin/cat", workingDirectory: tmp.url.path, timeoutSeconds: 5))
        #expect(none.termination == .exited && none.stdout.isEmpty)
    }

    @Test func outputIsBoundedAndStreamed() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let chunks = Counter()
        var spec = ProcessSpec(executable: "/bin/sh", arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' 'a'; echo err >&2"],
                               workingDirectory: tmp.url.path, maxOutputBytes: 1_000)
        spec.onOutput = { stream, text in if stream == .stdout, !text.isEmpty { chunks.increment() } }
        let out = try await runner.run(spec)
        #expect(out.stdout.count == 1_000 && out.stdoutTruncated && !out.stderrTruncated && out.truncated)
        #expect(out.exitCode == 0 && chunks.value >= 1)
    }

    @Test func timeoutTerminatesAndReports() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let clock = ContinuousClock(); let start = clock.now
        let out = try await runner.run(ProcessSpec(executable: "/bin/sleep", arguments: ["30"], workingDirectory: tmp.url.path, timeoutSeconds: 0.4))
        #expect(out.termination == .timedOut && out.signal == SIGTERM && out.exitCode == 128 + SIGTERM)
        #expect(clock.now - start < .seconds(5))
        #expect(throws: ToolError.timeout(seconds: 0.4)) { try out.throwIfInterrupted(timeoutSeconds: 0.4) }
    }

    @Test func sigtermResistantGroupIsKilled() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let runner = self.runner
        // The script ignores SIGTERM (and so do its children); it is stopped once it has announced itself.
        let task = Task { try await runner.run(ProcessSpec(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; echo $$ > leader.pid; while true; do sleep 1; done"],
                                                           workingDirectory: tmp.url.path, timeoutSeconds: 120, killGraceSeconds: 0.4)) }
        #expect(await TestProcess.eventually(timeout: 15) { TestProcess.pid(inFile: tmp.file("leader.pid").path) != nil })
        let pid = try #require(TestProcess.pid(inFile: tmp.file("leader.pid").path))
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let out = try await task.value
        #expect(out.termination == .canceled && out.signal == SIGKILL, "SIGTERM was ignored, so the group had to be killed")
        #expect(!TestProcess.isAlive(pid))
    }

    static let forkingScript = "(sleep 300 & echo $! > grandchild.pid; wait) & echo $! > child.pid; wait"

    @Test func timeoutKillsChildrenAndGrandchildren() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let out = try await sh(Self.forkingScript, cwd: tmp.url.path, timeout: 3, grace: 0.5)
        #expect(out.termination == .timedOut)
        let child = try #require(TestProcess.pid(inFile: tmp.file("child.pid").path))
        let grandchild = try #require(TestProcess.pid(inFile: tmp.file("grandchild.pid").path))
        #expect(await TestProcess.eventually(timeout: 3) { !TestProcess.isAlive(child) && !TestProcess.isAlive(grandchild) && !TestProcess.isAlive(out.pid) })
    }

    @Test func cancellationKillsTheWholeTree() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let runner = self.runner
        let task = Task { try await runner.run(ProcessSpec(executable: "/bin/sh", arguments: ["-c", Self.forkingScript], workingDirectory: tmp.url.path,
                                                           timeoutSeconds: 120, killGraceSeconds: 0.5)) }
        #expect(await TestProcess.eventually { FileManager.default.fileExists(atPath: tmp.file("grandchild.pid").path) && TestProcess.pid(inFile: tmp.file("grandchild.pid").path) != nil })
        let grandchild = try #require(TestProcess.pid(inFile: tmp.file("grandchild.pid").path))
        let child = try #require(TestProcess.pid(inFile: tmp.file("child.pid").path))
        #expect(TestProcess.isAlive(grandchild))
        #expect(runner.liveProcessGroups.count == 1)
        task.cancel()
        let out = try await task.value
        #expect(out.termination == .canceled)
        #expect(throws: ToolError.canceled) { try out.throwIfInterrupted(timeoutSeconds: 1) }
        #expect(await TestProcess.eventually(timeout: 3) { !TestProcess.isAlive(child) && !TestProcess.isAlive(grandchild) })
        #expect(runner.liveProcessGroups.isEmpty)
    }

    @Test func backgroundChildDoesNotOutliveANormalExit() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let clock = ContinuousClock(); let start = clock.now
        let out = try await sh("sleep 300 & echo $! > bg.pid; echo done", cwd: tmp.url.path)
        #expect(out.exitCode == 0 && out.stdoutText == "done\n" && out.termination == .exited)
        #expect(clock.now - start < .seconds(5))
        let bg = try #require(TestProcess.pid(inFile: tmp.file("bg.pid").path))
        #expect(await TestProcess.eventually(timeout: 3) { !TestProcess.isAlive(bg) })
    }

    @Test func descendantThatLeftTheGroupIsKilledOnTimeout() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let code = """
        import os, time
        pid = os.fork()
        if pid == 0:
            os.setsid()
            open('escaped.pid', 'w').write(str(os.getpid()))
            time.sleep(300)
        else:
            time.sleep(300)
        """
        let out = try await runner.run(ProcessSpec(executable: "/usr/bin/python3", arguments: ["-c", code], workingDirectory: tmp.url.path,
                                                   timeoutSeconds: 5, killGraceSeconds: 0.5))
        #expect(out.termination == .timedOut)
        guard let escaped = TestProcess.pid(inFile: tmp.file("escaped.pid").path) else {
            print("SKIPPED(python3 did not start within the timeout, the escape scenario was not exercised)")
            return
        }
        #expect(await TestProcess.eventually(timeout: 3) { !TestProcess.isAlive(escaped) })
    }

    @Test func killAllStopsEveryGroupOfThisRunner() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let runner = ProcessRunner()
        async let a = runner.run(ProcessSpec(executable: "/bin/sleep", arguments: ["60"], workingDirectory: tmp.url.path, killGraceSeconds: 0.5))
        async let b = runner.run(ProcessSpec(executable: "/bin/sleep", arguments: ["61"], workingDirectory: tmp.url.path, killGraceSeconds: 0.5))
        #expect(await TestProcess.eventually { runner.liveProcessGroups.count == 2 })
        runner.killAll()
        let (ra, rb) = try await (a, b)
        #expect(ra.termination == .killed && rb.termination == .killed)
        #expect(runner.liveProcessGroups.isEmpty)
    }

    @Test func preCancelledTaskStartsNothing() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let runner = self.runner
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do { _ = try await runner.run(ProcessSpec(executable: "/usr/bin/touch", arguments: ["ran.txt"], workingDirectory: tmp.url.path)); return false }
            catch { return (error as? ToolError) == .canceled }
        }
        task.cancel()
        #expect(await task.value)
        #expect(!FileManager.default.fileExists(atPath: tmp.file("ran.txt").path))
    }
}

@Suite("Seatbelt confinement (security, real sandbox-exec)")
struct SeatbeltConfinementTests {
    let runner = ProcessRunner()

    func run(_ executable: String, _ args: [String], cwd: String, profile: SeatbeltProfile?) async throws -> ProcessOutput {
        try await runner.run(ProcessSpec(executable: executable, arguments: args, workingDirectory: cwd, timeoutSeconds: 60, confinement: profile))
    }

    @Test func sandboxExecIsPresent() {
        #expect(SeatbeltProfile.isAvailable)
    }

    @Test func writesAreLimitedToWriteRootsAndTheScratchDirectory() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let allowed = tmp.url.appendingPathComponent("allowed").path
        try FileManager.default.createDirectory(atPath: allowed, withIntermediateDirectories: true)
        let profile = SeatbeltProfile(writeRoots: [allowed], allowsNetwork: false)
        let script = """
        echo in > "\(allowed)/inside.txt" && echo INSIDE_OK
        echo out > "\(tmp.url.path)/outside.txt" 2>/dev/null && echo OUTSIDE_WRITTEN
        mkdir "\(tmp.url.path)/newdir" 2>/dev/null && echo MKDIR_DONE
        echo home > "$HOME/orix-seatbelt-test-\(UUID().uuidString).txt" 2>/dev/null && echo HOME_WRITTEN
        echo t > "$TMPDIR/scratch.txt" && cat "$TMPDIR/scratch.txt"
        rm -f "\(tmp.url.path)/victim.txt" 2>/dev/null
        true
        """
        try tmp.write("victim.txt", "keep me")
        let out = try await run("/bin/sh", ["-c", script], cwd: tmp.url.path, profile: profile)
        #expect(out.stdoutText.contains("INSIDE_OK") && out.stdoutText.contains("t\n"))
        #expect(!out.stdoutText.contains("OUTSIDE_WRITTEN") && !out.stdoutText.contains("MKDIR_DONE") && !out.stdoutText.contains("HOME_WRITTEN"))
        #expect(FileManager.default.fileExists(atPath: allowed + "/inside.txt"))
        #expect(!FileManager.default.fileExists(atPath: tmp.file("outside.txt").path) && !FileManager.default.fileExists(atPath: tmp.file("newdir").path))
        #expect(FileManager.default.fileExists(atPath: tmp.file("victim.txt").path), "a confined process must not delete outside its roots")
        // Control: the same script unconfined does write outside, so the denial above is the sandbox's doing.
        let control = try await run("/bin/sh", ["-c", "echo out > \"\(tmp.url.path)/outside.txt\" && echo OUTSIDE_WRITTEN"], cwd: tmp.url.path, profile: nil)
        #expect(control.stdoutText.contains("OUTSIDE_WRITTEN"))
    }

    static let socketProbe = """
    import socket, sys
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.bind(('127.0.0.1', 0)); s.listen(1)
        c = socket.create_connection(s.getsockname(), timeout=3); print('NET_OK')
    except Exception as e:
        print('NET_DENIED', type(e).__name__)
    """

    @Test func networkIsDeniedUnlessAllowed() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let denied = try await run("/usr/bin/python3", ["-c", Self.socketProbe], cwd: tmp.url.path, profile: SeatbeltProfile(writeRoots: [], allowsNetwork: false))
        #expect(denied.stdoutText.contains("NET_DENIED") && !denied.stdoutText.contains("NET_OK"), "\(denied.stdoutText) \(denied.stderrText)")
        let allowed = try await run("/usr/bin/python3", ["-c", Self.socketProbe], cwd: tmp.url.path, profile: SeatbeltProfile(writeRoots: [], allowsNetwork: true))
        #expect(allowed.stdoutText.contains("NET_OK"), "\(allowed.stdoutText) \(allowed.stderrText)")
        // Name resolution is networking too: a confined process cannot resolve a host (no DNS exfiltration).
        let dns = try await run("/usr/bin/python3", ["-c", "import socket\ntry:\n    socket.getaddrinfo('example.com', 443); print('RESOLVED')\nexcept Exception as e:\n    print('DNS_DENIED')"],
                                cwd: tmp.url.path, profile: SeatbeltProfile(writeRoots: [], allowsNetwork: false))
        #expect(dns.stdoutText.contains("DNS_DENIED"))
    }

    @Test func credentialStoresAreUnreadableEvenWithRootWriteAccess() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        let ssh = NSHomeDirectory() + "/.ssh"
        guard FileManager.default.fileExists(atPath: ssh) else {
            print("SKIPPED(~/.ssh does not exist on this Mac, the read denial cannot be observed)")
            return
        }
        let control = try await run("/bin/ls", [ssh], cwd: tmp.url.path, profile: nil)
        try #require(control.exitCode == 0, "control: ~/.ssh must be listable without the sandbox")
        for profile in [SeatbeltProfile(writeRoots: [], allowsNetwork: false), SeatbeltProfile(writeRoots: ["/"], allowsNetwork: true)] {
            let listing = try await run("/bin/ls", [ssh], cwd: tmp.url.path, profile: profile)
            #expect(listing.exitCode != 0 && listing.stdout.isEmpty)
            let cat = try await run("/bin/sh", ["-c", "cat \"$HOME\"/.ssh/* 2>/dev/null | wc -c"], cwd: tmp.url.path, profile: profile)
            #expect(cat.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
            let keychains = try await run("/bin/ls", [NSHomeDirectory() + "/Library/Keychains"], cwd: tmp.url.path, profile: profile)
            #expect(keychains.exitCode != 0)
        }
    }

    @Test func ordinaryToolsStillRunConfined() async throws {
        let tmp = try TempDirectory(); defer { tmp.remove() }
        try tmp.write("a.txt", "A")
        let profile = SeatbeltProfile(writeRoots: [tmp.url.path], allowsNetwork: false)
        let ls = try await run("/bin/ls", [tmp.url.path], cwd: tmp.url.path, profile: profile)
        #expect(ls.exitCode == 0 && ls.stdoutText.contains("a.txt"))
        let python = try await run("/usr/bin/python3", ["-c", "import json, hashlib; print(json.dumps({'ok': hashlib.sha256(b'x').hexdigest()[:4]}))"], cwd: tmp.url.path, profile: profile)
        #expect(python.exitCode == 0 && python.stdoutText.contains("\"ok\""), "\(python.stderrText)")
        let git = try await run("git", ["--version"], cwd: tmp.url.path, profile: profile)
        #expect(git.exitCode == 0 && git.stdoutText.hasPrefix("git version"), "\(git.stderrText)")
        let initRepo = try await run("git", ["init", "-q", "repo"], cwd: tmp.url.path, profile: profile)
        #expect(initRepo.exitCode == 0 && FileManager.default.fileExists(atPath: tmp.file("repo/.git/HEAD").path), "\(initRepo.stderrText)")
    }

    @Test func profileSourceQuotesPathsAndOrdersRules() {
        let profile = SeatbeltProfile(writeRoots: ["/tmp/has \"quote\"", "relative/ignored"], allowsNetwork: false)
        let source = profile.source(tempDirectory: "/private/tmp/scratch")
        #expect(source.contains(#"(subpath "/private/tmp/has \"quote\"")"#))
        #expect(!source.contains("relative/ignored"))
        #expect(source.contains("(deny network*)") && source.contains("/private/tmp/scratch"))
        let denyWrites = try! #require(source.range(of: "(deny file-write*)"))
        let allowWrites = try! #require(source.range(of: "(allow file-write* (subpath"))
        let denyCredentials = try! #require(source.range(of: "(deny file-read* file-write*"))
        #expect(denyWrites.lowerBound < allowWrites.lowerBound && allowWrites.lowerBound < denyCredentials.lowerBound)
        #expect(!SeatbeltProfile(writeRoots: [], allowsNetwork: true).source().contains("deny network"))
        for root in SeatbeltProfile.deniedRoots { #expect(PathResolver.isProtected(root)) }
    }
}
