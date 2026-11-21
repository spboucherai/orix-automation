// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/ProcessRunner.swift
// Description: The only way tools start subprocesses: posix_spawn with explicit argv/env/cwd, its own process group, timeout, group-wide SIGTERM→SIGKILL, bounded streamed output and optional Seatbelt confinement.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public enum ProcessOutputStream: String, Sendable { case stdout, stderr }

/// Everything needed to start one subprocess. Nothing is inherited implicitly from the host process.
public struct ProcessSpec: Sendable {
    /// Absolute path, or a bare name resolved through `ProcessRunner.safePath` (never a caller-supplied PATH).
    public var executable: String
    public var arguments: [String]
    /// Added to the minimal base environment (`PATH`, `HOME`, `LANG`, `TMPDIR`).
    public var environment: [String: String]
    public var workingDirectory: String
    public var timeoutSeconds: Double
    /// Per stream. Output beyond the bound is drained and discarded.
    public var maxOutputBytes: Int
    public var stdin: Data?
    /// When set, the process runs under `/usr/bin/sandbox-exec -p <profile>`.
    public var confinement: SeatbeltProfile?
    /// Delay between SIGTERM and SIGKILL of the process group.
    public var killGraceSeconds: Double
    public var onOutput: (@Sendable (ProcessOutputStream, String) -> Void)?

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:], workingDirectory: String,
                timeoutSeconds: Double = 60, maxOutputBytes: Int = 1_048_576, stdin: Data? = nil, confinement: SeatbeltProfile? = nil,
                killGraceSeconds: Double = 2, onOutput: (@Sendable (ProcessOutputStream, String) -> Void)? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.timeoutSeconds = timeoutSeconds; self.maxOutputBytes = maxOutputBytes
        self.stdin = stdin; self.confinement = confinement; self.killGraceSeconds = killGraceSeconds; self.onOutput = onOutput
    }
}

public struct ProcessOutput: Sendable {
    public enum Termination: String, Sendable {
        /// The process ended by itself (normal exit or a signal it was not sent by the runner).
        case exited
        case timedOut
        case canceled
        /// Stopped by `ProcessRunner.killAll()`.
        case killed
    }
    public var pid: Int32
    /// Exit code; `128 + signal` when the process died from a signal.
    public var exitCode: Int32
    public var signal: Int32?
    public var termination: Termination
    public var stdout: Data
    public var stderr: Data
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var durationMs: Int

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var truncated: Bool { stdoutTruncated || stderrTruncated }

    /// Throws the matching `ToolError` when the process was stopped by a timeout or a cancellation.
    public func throwIfInterrupted(timeoutSeconds: Double) throws {
        switch termination {
        case .timedOut: throw ToolError.timeout(seconds: timeoutSeconds)
        case .canceled, .killed: throw ToolError.canceled
        case .exited: return
        }
    }

    /// Throws when interrupted or when the exit code is not zero.
    public func requireSuccess(timeoutSeconds: Double) throws {
        try throwIfInterrupted(timeoutSeconds: timeoutSeconds)
        if exitCode != 0 { throw ToolError.processFailed(exitCode: exitCode, stderr: stderrText.isEmpty ? stdoutText : stderrText) }
    }
}

public final class ProcessRunner: Sendable {
    public static let shared = ProcessRunner()

    /// The only search path used to resolve bare executable names and the `PATH` given to children.
    public static let safePath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

    private let live = LiveProcesses()

    public init() {}

    /// Resolves an executable to an absolute path: absolute paths must be executable regular files, bare names are
    /// looked up in `safePath`. Relative paths containing a slash are rejected (callers canonicalise them first).
    public static func resolveExecutable(_ name: String) -> String? {
        let fm = FileManager.default
        func usable(_ p: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: p)
        }
        guard !name.isEmpty, !name.contains("\0") else { return nil }
        if name.hasPrefix("/") { return usable(name) ? name : nil }
        if name.contains("/") { return nil }
        for dir in safePath.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if usable(candidate) { return candidate }
        }
        return nil
    }

    /// Process group identifiers of the children currently running through this runner.
    public var liveProcessGroups: [Int32] { live.all().map(\.pid) }

    /// Terminates every child process group started by this runner (SIGTERM, then SIGKILL after each run's grace period).
    public func killAll() {
        for state in live.all() { state.terminate(.killed) }
    }

    /// Runs the process to completion. Throws only when it cannot be started; timeouts and cancellations are reported
    /// in `ProcessOutput.termination` after the whole process group is gone.
    public func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
        if Task.isCancelled { throw ToolError.canceled }
        guard let executable = Self.resolveExecutable(spec.executable) else {
            throw ToolError.notFound("Executable not found or not executable: \(spec.executable)")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: spec.workingDirectory, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError.notFound("Working directory does not exist: \(spec.workingDirectory)")
        }
        if spec.confinement != nil, !SeatbeltProfile.isAvailable {
            throw ToolError.unsupported("Seatbelt confinement is required but \(SeatbeltProfile.sandboxExecPath) is not available on this Mac")
        }

        // Per-process scratch directory: the only temp location a confined process can write.
        let tempBase = PathResolver.resolveSymlinks(NSTemporaryDirectory())
        let tempDir = tempBase + "/orix-proc-" + UUID().uuidString.prefix(12)
        do { try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ToolError.io("Cannot create the process temp directory: \(error.localizedDescription)") }

        var env: [String: String] = ["PATH": Self.safePath, "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "TMPDIR": tempDir]
        for (k, v) in spec.environment where !k.isEmpty && !k.contains("=") && !k.contains("\0") && !v.contains("\0") { env[k] = v }

        var argv: [String]
        if let profile = spec.confinement {
            argv = [SeatbeltProfile.sandboxExecPath, "-p", profile.source(tempDirectory: tempDir), executable] + spec.arguments
        } else {
            argv = [executable] + spec.arguments
        }
        guard !argv.contains(where: { $0.contains("\0") }) else {
            try? FileManager.default.removeItem(atPath: tempDir)
            throw ToolError.invalidInput("arguments must not contain NUL bytes")
        }

        let started = DispatchTime.now()
        let spawned: Spawned
        do { spawned = try Self.spawn(argv: argv, env: env, cwd: spec.workingDirectory, wantsStdin: spec.stdin != nil) }
        catch { try? FileManager.default.removeItem(atPath: tempDir); throw error }

        let state = RunState(pid: spawned.pid, grace: spec.killGraceSeconds)
        live.add(state)
        let live = self.live

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ProcessOutput, Never>) in
                let out = Collector(limit: spec.maxOutputBytes), err = Collector(limit: spec.maxOutputBytes)
                let readers = DispatchGroup()
                let onOutput = spec.onOutput
                for (fd, collector, stream) in [(spawned.stdout, out, ProcessOutputStream.stdout), (spawned.stderr, err, .stderr)] {
                    readers.enter()
                    let t = Thread {
                        Self.drain(fd: fd, into: collector, state: state) { onOutput?(stream, $0) }
                        readers.leave()
                    }
                    t.stackSize = 256 * 1024
                    t.start()
                }
                if let stdinFD = spawned.stdin, let data = spec.stdin {
                    let t = Thread { Self.feed(fd: stdinFD, data: data) }
                    t.stackSize = 256 * 1024
                    t.start()
                }
                // No-op once the process has exited.
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, spec.timeoutSeconds)) { state.terminate(.timedOut) }

                let waiter = Thread {
                    // Wait without reaping so the pid (= pgid) cannot be reused while the leftover group is killed.
                    var info = siginfo_t()
                    while waitid(P_PID, id_t(spawned.pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
                    state.leaderExited()
                    var status: Int32 = 0
                    while waitpid(spawned.pid, &status, 0) == -1 && errno == EINTR {}
                    state.reaped()
                    readers.wait()
                    live.remove(state)
                    try? FileManager.default.removeItem(atPath: tempDir)
                    let signaled = (status & 0x7f) != 0
                    let sig: Int32? = signaled ? (status & 0x7f) : nil
                    let code: Int32 = signaled ? 128 + (status & 0x7f) : (status >> 8) & 0xff
                    let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
                    cont.resume(returning: ProcessOutput(pid: spawned.pid, exitCode: code, signal: sig, termination: state.termination,
                                                         stdout: out.data, stderr: err.data, stdoutTruncated: out.truncated,
                                                         stderrTruncated: err.truncated, durationMs: elapsed))
                }
                waiter.stackSize = 256 * 1024
                waiter.start()
            }
        } onCancel: {
            state.terminate(.canceled)
        }
    }

    // MARK: Spawn

    private struct Spawned { let pid: pid_t; let stdout: Int32; let stderr: Int32; let stdin: Int32? }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ToolError.io("pipe() failed: \(String(cString: strerror(errno)))") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }

    private static func spawn(argv: [String], env: [String: String], cwd: String, wantsStdin: Bool) throws -> Spawned {
        let outPipe = try makePipe()
        let errPipe: (read: Int32, write: Int32)
        do { errPipe = try makePipe() } catch { close(outPipe.read); close(outPipe.write); throw error }
        var inPipe: (read: Int32, write: Int32)?
        if wantsStdin {
            do { inPipe = try makePipe() }
            catch { [outPipe.read, outPipe.write, errPipe.read, errPipe.write].forEach { close($0) }; throw error }
        }
        func closeAll() {
            [outPipe.read, outPipe.write, errPipe.read, errPipe.write].forEach { close($0) }
            if let p = inPipe { close(p.read); close(p.write) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let p = inPipe { posix_spawn_file_actions_adddup2(&actions, p.read, 0) }
        else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&actions, outPipe.write, 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe.write, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group (pgid = pid), default signal dispositions, empty signal mask, no inherited descriptors.
        var allSignals = sigset_t(); sigfillset(&allSignals)
        var noSignals = sigset_t(); sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setpgroup(&attr, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        guard rc == 0 else {
            closeAll()
            let reason = String(cString: strerror(rc))
            if rc == ENOENT || rc == EACCES { throw ToolError.notFound("Cannot start \(argv[0]): \(reason)") }
            throw ToolError.io("Cannot start \(argv[0]): \(reason)")
        }
        close(outPipe.write); close(errPipe.write)
        var stdinFD: Int32?
        if let p = inPipe {
            close(p.read)
            _ = fcntl(p.write, F_SETNOSIGPIPE, 1)
            stdinFD = p.write
        }
        return Spawned(pid: pid, stdout: outPipe.read, stderr: errPipe.read, stdin: stdinFD)
    }

    private static func feed(fd: Int32, data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if errno != EINTR { break }
            }
        }
        close(fd)
    }

    /// Reads until EOF. After the child has been reaped, lingers briefly for late bytes and then stops even if a
    /// process that escaped the group still holds the pipe open.
    private static func drain(fd: Int32, into collector: Collector, state: RunState, emit: (String) -> Void) {
        let size = 65_536
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        defer { buffer.deallocate(); close(fd) }
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 100)
            if ready > 0 {
                let n = read(fd, buffer, size)
                if n > 0 {
                    let chunk = Data(bytes: buffer, count: n)
                    collector.append(chunk)
                    emit(String(decoding: chunk, as: UTF8.self))
                } else if n == 0 { return }
                else if errno != EINTR && errno != EAGAIN { return }
            } else if ready == 0 {
                if let t = state.reapedAt, DispatchTime.now().uptimeNanoseconds - t > 300_000_000 { return }
            } else if errno != EINTR { return }
        }
    }

    /// Every descendant of `root`, found by walking the kernel process table (catches children that left the group).
    static func descendants(of root: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var children: [pid_t: [pid_t]] = [:]
        for p in procs.prefix(count) { children[p.kp_eproc.e_ppid, default: []].append(p.kp_proc.p_pid) }
        var out: [pid_t] = [], queue = [root], seen: Set<pid_t> = [root]
        while let next = queue.popLast() {
            for c in children[next] ?? [] where seen.insert(c).inserted { out.append(c); queue.append(c) }
        }
        return out
    }
}

// MARK: - Internals

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()
    private var cut = false
    init(limit: Int) { self.limit = max(0, limit) }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = limit - buffer.count
        if room >= chunk.count { buffer.append(chunk) }
        else { if room > 0 { buffer.append(chunk.prefix(room)) }; cut = true }
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return cut }
}

/// Lifecycle of one child process group.
final class RunState: @unchecked Sendable {
    let pid: pid_t
    private let grace: Double
    private let lock = NSLock()
    private var reason: ProcessOutput.Termination = .exited
    private var exited = false
    private struct Stray { let pid: pid_t; let start: UInt64 }
    private var strays: [Stray] = []
    private var reapTime: UInt64?

    init(pid: pid_t, grace: Double) { self.pid = pid; self.grace = max(0, grace) }

    var termination: ProcessOutput.Termination { lock.lock(); defer { lock.unlock() }; return reason }
    var reapedAt: UInt64? { lock.lock(); defer { lock.unlock() }; return reapTime }

    /// SIGTERM to the whole group (and to descendants that left it), SIGKILL after the grace period.
    func terminate(_ why: ProcessOutput.Termination) {
        lock.lock()
        if exited || reason != .exited { lock.unlock(); return }
        reason = why
        // The leader is not reaped before `exited` is set under this lock, so the pgid still belongs to this run.
        let found = ProcessRunner.descendants(of: pid).compactMap { p in ProcessRunner.startTime(of: p).map { Stray(pid: p, start: $0) } }
        strays = found
        killpg(pid, SIGTERM)
        for s in found { kill(s.pid, SIGTERM) }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            lock.lock(); defer { lock.unlock() }
            if !exited { killpg(pid, SIGKILL) }
            killStrays()
        }
    }

    /// The leader has exited but is not reaped yet: nothing in its group may outlive the call.
    func leaderExited() {
        lock.lock(); defer { lock.unlock() }
        killpg(pid, SIGKILL)
        exited = true
        if reason != .exited { killStrays() }
    }

    /// SIGKILL the recorded descendants that are still the same processes (same pid and start time). Lock held.
    private func killStrays() {
        for s in strays where ProcessRunner.startTime(of: s.pid) == s.start { kill(s.pid, SIGKILL) }
        strays = []
    }

    func reaped() {
        lock.lock(); defer { lock.unlock() }
        reapTime = DispatchTime.now().uptimeNanoseconds
    }
}

extension ProcessRunner {
    /// Start time of a live process in microseconds since the epoch; identifies a process beyond its (reusable) pid.
    static func startTime(of pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_starttime
        return UInt64(tv.tv_sec) * 1_000_000 + UInt64(tv.tv_usec)
    }
}

private final class LiveProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [pid_t: RunState] = [:]
    func add(_ s: RunState) { lock.lock(); states[s.pid] = s; lock.unlock() }
    func remove(_ s: RunState) { lock.lock(); states[s.pid] = nil; lock.unlock() }
    func all() -> [RunState] { lock.lock(); defer { lock.unlock() }; return Array(states.values) }
}
