// ORIX OS Automation
// File: Packages/ORIXScheduler/Tests/ORIXSchedulerTests/FileWatcherAndTriggerTests.swift
// Description: Real FSEvents integration tests in a temp directory, trigger monitor tests (real file watcher into a real engine, system events through their handlers) and LaunchAgent plist validation with plutil.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import Testing
import ORIXTestingSupport
@testable import ORIXScheduler

/// Thread-safe collector.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []
    func add(_ value: T) { lock.withLock { _values.append(value) } }
    var values: [T] { lock.withLock { _values } }
    func reset() { lock.withLock { _values = [] } }
}

/// Writes without the temporary file an atomic write goes through, so exactly one path changes.
func writePlain(_ dir: TempDirectory, _ name: String, _ text: String) throws {
    let url = dir.file(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: false, encoding: .utf8)
}

/// Polls until `condition` holds; returns false on timeout.
func eventually(timeout: Double = 10, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return await condition()
}

@Suite("FileWatcher (integration: real FSEvents in a temp directory)", .serialized)
struct FileWatcherIntegrationTests {
    @Test func reportsCreateModifyAndDelete() async throws {
        let dir = try TempDirectory(prefix: "orix-fw")
        defer { dir.remove() }
        let events = Collector<FileWatcher.Event>()
        let watcher = try FileWatcher(path: dir.url.path, debounceSeconds: 0.1) { events.add($0) }
        try watcher.start()
        defer { watcher.stop() }
        #expect(watcher.isRunning && watcher.path == dir.url.path)
        let file = dir.file("notes.txt").path

        try writePlain(dir, "notes.txt", "one")
        #expect(await eventually { events.values.contains { $0.paths == [file] } }, "create not reported: \(events.values)")
        events.reset()

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two".utf8))
        try handle.close()
        #expect(await eventually { events.values.contains { $0.paths == [file] } }, "modify not reported: \(events.values)")
        events.reset()

        try FileManager.default.removeItem(atPath: file)
        #expect(await eventually { events.values.contains { $0.paths == [file] } }, "delete not reported: \(events.values)")
        #expect(!FileManager.default.fileExists(atPath: file))

        // After stop() nothing more is reported.
        watcher.stop()
        #expect(!watcher.isRunning)
        events.reset()
        try writePlain(dir, "late.txt", "x")
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(events.values.isEmpty)
    }

    @Test func debounceCoalescesABurstIntoOneEvent() async throws {
        let dir = try TempDirectory(prefix: "orix-fw")
        defer { dir.remove() }
        let events = Collector<FileWatcher.Event>()
        let watcher = try FileWatcher(path: dir.url.path, debounceSeconds: 0.5) { events.add($0) }
        try watcher.start()
        defer { watcher.stop() }
        let started = Date()
        for i in 0..<25 {
            try writePlain(dir, "burst-\(String(format: "%02d", i)).txt", "payload \(i)")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await eventually { !events.values.isEmpty })
        // Leave time for a (wrong) second event to show up.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let all = events.values
        #expect(all.count == 1, "expected one coalesced event, got \(all.count)")
        #expect(all.first?.paths.count == 25)
        #expect(all.first?.paths == all.first?.paths.sorted())
        // It came after the burst ended plus the quiet period, not during the burst.
        #expect((all.first?.date.timeIntervalSince(started) ?? 0) >= 0.9)
    }

    @Test func globFilterKeepsOnlyMatchingNames() async throws {
        let dir = try TempDirectory(prefix: "orix-fw")
        defer { dir.remove() }
        try FileManager.default.createDirectory(at: dir.file("sub"), withIntermediateDirectories: true)
        let events = Collector<FileWatcher.Event>()
        let watcher = try FileWatcher(path: dir.url.path, recursive: true, glob: "*.pdf", debounceSeconds: 0.2) { events.add($0) }
        try watcher.start()
        defer { watcher.stop() }
        try writePlain(dir, "ignored.txt", "x")
        try writePlain(dir, "report.pdf", "%PDF")
        try writePlain(dir, "sub/nested.pdf", "%PDF")
        try writePlain(dir, "sub/ignored.csv", "a,b")
        let expected = [dir.file("report.pdf").path, dir.file("sub/nested.pdf").path]
        #expect(await eventually { Set(events.values.flatMap(\.paths)) == Set(expected) }, "\(events.values)")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(Set(events.values.flatMap(\.paths)) == Set(expected))
        #expect(watcher.accepts(dir.file("a.pdf").path) && !watcher.accepts(dir.file("a.pdfx").path) && !watcher.accepts("/elsewhere/a.pdf"))
    }

    @Test func nonRecursiveIgnoresSubdirectoriesAndPathGlobsMatchRelativePaths() async throws {
        let dir = try TempDirectory(prefix: "orix-fw")
        defer { dir.remove() }
        try FileManager.default.createDirectory(at: dir.file("sub"), withIntermediateDirectories: true)
        let flat = Collector<FileWatcher.Event>()
        let shallow = try FileWatcher(path: dir.url.path, recursive: false, debounceSeconds: 0.2) { flat.add($0) }
        let scoped = Collector<FileWatcher.Event>()
        let byPath = try FileWatcher(path: dir.url.path, recursive: true, glob: "sub/*.csv", debounceSeconds: 0.2) { scoped.add($0) }
        try shallow.start()
        try byPath.start()
        defer { shallow.stop(); byPath.stop() }
        try writePlain(dir, "sub/deep.csv", "a,b")
        try writePlain(dir, "top.csv", "a,b")
        #expect(await eventually { flat.values.flatMap(\.paths).contains(dir.file("top.csv").path) })
        #expect(await eventually { scoped.values.flatMap(\.paths) == [dir.file("sub/deep.csv").path] })
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(!flat.values.flatMap(\.paths).contains { $0.hasPrefix(dir.file("sub").path + "/") })
        #expect(scoped.values.flatMap(\.paths) == [dir.file("sub/deep.csv").path])
    }

    @Test func watchingASingleFileIgnoresItsSiblings() async throws {
        let dir = try TempDirectory(prefix: "orix-fw")
        defer { dir.remove() }
        try writePlain(dir, "config.json", "{}")
        let events = Collector<FileWatcher.Event>()
        let watcher = try FileWatcher(path: dir.file("config.json").path, debounceSeconds: 0.1) { events.add($0) }
        try watcher.start()
        defer { watcher.stop() }
        try writePlain(dir, "other.json", "{}")
        try "{\"a\":1}".write(toFile: dir.file("config.json").path, atomically: false, encoding: .utf8)
        #expect(await eventually { !events.values.isEmpty })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(Set(events.values.flatMap(\.paths)) == [dir.file("config.json").path])
    }

    @Test func missingPathsAndDoubleStartsAreTypedErrors() throws {
        #expect(throws: FileWatcherError.pathNotFound("/nonexistent/orix-\(1)")) {
            _ = try FileWatcher(path: "/nonexistent/orix-\(1)") { _ in }
        }
        let dir = try TempDirectory(prefix: "orix-fw")
        defer { dir.remove() }
        let watcher = try FileWatcher(path: dir.url.path) { _ in }
        try watcher.start()
        #expect(throws: FileWatcherError.alreadyStarted) { try watcher.start() }
        watcher.stop()
        watcher.stop()
        try watcher.start() // restartable
        watcher.stop()
    }
}

@Suite("TriggerMonitor (integration for file changes; unit for system events through their handlers)", .serialized)
struct TriggerMonitorTests {
    private func schedule(_ id: String, _ trigger: TriggerSpec, enabled: Bool = true, paused: Bool = false) -> Schedule {
        Schedule(id: id, workflowID: "wf-\(id)", name: id, trigger: trigger, enabled: enabled, paused: paused, concurrency: .queue)
    }

    @Test func aRealFileChangeBecomesAQueueItemInTheEngine() async throws {
        let dir = try TempDirectory(prefix: "orix-tm")
        defer { dir.remove() }
        let store = InMemoryScheduleStore()
        let recorder = LaunchRecorder()
        let engine = SchedulerEngine(store: store, launcher: { await recorder.launch($0, $1) }, owner: "test",
                                     configuration: SchedulerConfiguration(observesSystemWake: false))
        let inbox = try await engine.save(schedule("inbox", .fileChange(path: dir.url.path, recursive: false, glob: "*.pdf", debounceSeconds: 0.2)))
        let monitor = TriggerMonitor(engine: engine, configuration: .init(observesSystem: false))
        monitor.update(schedules: [inbox])
        defer { monitor.stop() }
        #expect(monitor.fileWatcherCount == 1 && monitor.problems.isEmpty)

        try writePlain(dir, "ignored.txt", "x")
        try writePlain(dir, "invoice.pdf", "%PDF")
        #expect(await eventually { (try? await engine.queue().count) == 1 })
        let item = try #require(try await engine.queue().first)
        #expect(item.scheduleID == "inbox" && item.status == .pending && item.reason == "file change: invoice.pdf")
        await engine.tick()
        await engine.settle()
        #expect(recorder.count == 1)

        // Pausing the schedule removes the watcher; nothing is enqueued any more.
        var paused = inbox
        paused.paused = true
        monitor.update(schedules: [paused])
        #expect(monitor.fileWatcherCount == 0)
        try writePlain(dir, "second.pdf", "%PDF")
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(try await engine.queue().count == 1)
    }

    @Test func aMissingWatchedPathIsReportedNotIgnored() {
        let events = Collector<TriggerEvent>()
        let monitor = TriggerMonitor(configuration: .init(observesSystem: false)) { events.add($0) }
        defer { monitor.stop() }
        monitor.update(schedules: [schedule("gone", .fileChange(path: "/nonexistent/orix-inbox", recursive: true, glob: nil, debounceSeconds: 1))])
        #expect(monitor.fileWatcherCount == 0)
        #expect(monitor.problems["gone"]?.contains("does not exist") == true)
        #expect(events.values.isEmpty)
    }

    @Test func loginFiresOncePerSessionAndOnlyShortlyAfterLogin() {
        let login = utc("2026-06-01T12:00:00Z")
        func monitor(now: String, _ events: Collector<TriggerEvent>) -> TriggerMonitor {
            TriggerMonitor(configuration: .init(loginWindowSeconds: 600, loginDate: { login }, now: { utc(now) }, observesSystem: false)) { events.add($0) }
        }
        let schedules = [schedule("hello", .login), schedule("off", .login, enabled: false), schedule("cron", .cron(expression: "@daily", timezone: nil))]

        let soon = Collector<TriggerEvent>()
        let m1 = monitor(now: "2026-06-01T12:02:00Z", soon)
        m1.update(schedules: schedules)
        m1.update(schedules: schedules) // a second reconcile does not fire again
        #expect(soon.values.map(\.scheduleID) == ["hello"])
        #expect(soon.values.first?.dedupKey == "hello@login-\(Int(login.timeIntervalSince1970))")
        #expect(soon.values.first?.kind == "login" && soon.values.first?.reason == "login: session started 120 s ago")

        // A monitor that starts an hour after login (app relaunched) does not fire.
        let late = Collector<TriggerEvent>()
        monitor(now: "2026-06-01T13:00:00Z", late).update(schedules: schedules)
        #expect(late.values.isEmpty)

        // Unknown login time: reported as a problem, nothing fired.
        let unknown = Collector<TriggerEvent>()
        let m3 = TriggerMonitor(configuration: .init(loginDate: { nil }, observesSystem: false)) { unknown.add($0) }
        m3.update(schedules: schedules)
        #expect(unknown.values.isEmpty && m3.problems["hello"] != nil)
    }

    @Test func aRestartedAgentCannotFireLoginTwiceForOneSession() async throws {
        let login = utc("2026-06-01T12:00:00Z")
        let h = Harness(start: "2026-06-01T12:01:00Z")
        let hello = try await h.engine.save(schedule("hello", .login))
        for _ in 0..<2 { // two agent processes in the same login session
            let monitor = TriggerMonitor(engine: h.engine, configuration: .init(loginDate: { login }, now: { h.clock.now() }, observesSystem: false))
            monitor.update(schedules: [hello])
            _ = await eventually(timeout: 2) { await h.items().count >= 1 }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(await h.items().count == 1)
    }

    @Test func appLaunchPowerAndNetworkFireOnTheRightTransitions() {
        let events = Collector<TriggerEvent>()
        let monitor = TriggerMonitor(configuration: .init(observesSystem: false)) { events.add($0) }
        defer { monitor.stop() }
        monitor.update(schedules: [
            schedule("safari", .appLaunch(bundleID: "com.apple.Safari")), schedule("power", .powerConnected),
            schedule("net", .networkAvailable), schedule("net-paused", .networkAvailable, paused: true),
        ])
        monitor.handleAppLaunch(bundleID: "com.apple.TextEdit")
        monitor.handleAppLaunch(bundleID: "com.apple.Safari")
        #expect(events.values.map(\.scheduleID) == ["safari"])
        #expect(events.values.first?.reason == "app launched: com.apple.Safari")
        events.reset()

        monitor.handlePower(onAC: true)   // initial state: already on AC, no edge
        monitor.handlePower(onAC: true)
        #expect(events.values.isEmpty)
        monitor.handlePower(onAC: false)
        monitor.handlePower(onAC: true)   // battery → AC
        monitor.handlePower(onAC: true)
        #expect(events.values.map(\.kind) == ["powerConnected"])
        events.reset()

        monitor.handleNetwork(satisfied: true)  // initial state
        #expect(events.values.isEmpty)
        monitor.handleNetwork(satisfied: false)
        monitor.handleNetwork(satisfied: true)
        monitor.handleNetwork(satisfied: false)
        monitor.handleNetwork(satisfied: true)
        #expect(events.values.map(\.scheduleID) == ["net", "net"])
    }

    @Test func systemFactsAreReadable() {
        // Real system calls: the values depend on the machine, their shape does not.
        let boot = TriggerMonitor.bootDate()
        #expect(boot != nil && boot! < Date() && boot! > utc("2020-01-01T00:00:00Z"))
        let login = TriggerMonitor.consoleLoginDate()
        #expect(login != nil && login! <= Date())
        _ = TriggerMonitor.isOnACPower()
    }

    @Test func realSystemObserversInstallAndTearDown() async throws {
        // Installs the real NSWorkspace, IOKit and NWPathMonitor observers. No event is expected: this Mac's power and
        // network state do not change during the test, and at start the current state is not an edge.
        let events = Collector<TriggerEvent>()
        let monitor = TriggerMonitor { events.add($0) }
        monitor.update(schedules: [schedule("safari", .appLaunch(bundleID: "ai.orix.never-launched")), schedule("power", .powerConnected), schedule("net", .networkAvailable)])
        try await Task.sleep(nanoseconds: 500_000_000)
        monitor.update(schedules: [])
        monitor.stop()
        #expect(events.values.isEmpty)
    }
}

@Suite("LaunchAgent plist (unit + plutil integration)")
struct LaunchAgentPlistTests {
    private func agent() -> LaunchAgentPlist.Configuration {
        .init(label: "ai.orix.automation.agent", bundleProgram: "Contents/MacOS/ORIXBackgroundAgent",
              programArguments: ["ORIXBackgroundAgent", "--scheduler"],
              standardOutPath: "/Users/Shared/orix-test/agent.out.log", standardErrorPath: "/Users/Shared/orix-test/agent.err.log",
              environment: ["ORIX_AGENT": "1"], throttleIntervalSeconds: 10, associatedBundleIdentifiers: ["ai.orix.automation"])
    }

    @Test func generatesTheExpectedKeys() throws {
        let plist = try LaunchAgentPlist.propertyList(agent())
        #expect(plist["Label"] as? String == "ai.orix.automation.agent")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/ORIXBackgroundAgent")
        #expect(plist["ProgramArguments"] as? [String] == ["ORIXBackgroundAgent", "--scheduler"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["StandardOutPath"] as? String == "/Users/Shared/orix-test/agent.out.log")
        #expect(plist["StandardErrorPath"] as? String == "/Users/Shared/orix-test/agent.err.log")
        #expect(plist["EnvironmentVariables"] as? [String: String] == ["ORIX_AGENT": "1"])
        #expect(plist["ThrottleInterval"] as? Int == 10)
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["ai.orix.automation"])
        #expect(LaunchAgentPlist.plistName(for: agent()) == "ai.orix.automation.agent.plist")

        var minimal = LaunchAgentPlist.Configuration(label: "ai.orix.min", programArguments: ["/usr/bin/true"], runAtLoad: false, keepAliveOnFailure: false)
        minimal.processType = "Standard"
        let small = try LaunchAgentPlist.propertyList(minimal)
        #expect(Set(small.keys) == ["Label", "ProgramArguments", "RunAtLoad", "ProcessType"])
        #expect(small["RunAtLoad"] as? Bool == false)
    }

    @Test func plutilAcceptsTheGeneratedFile() throws {
        let dir = try TempDirectory(prefix: "orix-plist")
        defer { dir.remove() }
        let url = dir.file(LaunchAgentPlist.plistName(for: agent()))
        try LaunchAgentPlist.write(agent(), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("<?xml") && text.contains("<key>SuccessfulExit</key>") && text.contains("<false/>"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-lint", url.path]
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "plutil: \(output)")
        #expect(output.contains("OK"))
        #expect(LaunchAgentPlist.problems(inPlistAt: url).isEmpty)

        // Round trip through the system parser.
        let parsed = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any]
        #expect(parsed?["Label"] as? String == "ai.orix.automation.agent")
        #expect((parsed?["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false)
    }

    @Test func invalidConfigurationsAreRefusedWithReasons() {
        var c = agent()
        c.label = "not a label"
        c.bundleProgram = "/abs/olute"
        c.processType = "Turbo"
        c.standardOutPath = "~/Library/Logs/agent.log"
        c.throttleIntervalSeconds = 0
        c.environment = ["BAD=KEY": "1"]
        let problems = LaunchAgentPlist.problems(c)
        #expect(problems.count == 6, "\(problems)")
        #expect(throws: LaunchAgentPlist.ValidationError.self) { try LaunchAgentPlist.xmlData(c) }

        let relative = LaunchAgentPlist.Configuration(label: "ai.orix.x", programArguments: ["agent"])
        #expect(LaunchAgentPlist.problems(relative).contains { $0.contains("absolute path") })
        #expect(LaunchAgentPlist.problems(.init(label: "ai.orix.x", programArguments: [])).contains("programArguments is empty"))
        #expect(LaunchAgentPlist.problems(.init(label: "ai.orix.x", bundleProgram: "Contents/../../evil", programArguments: ["x"])).count == 1)
    }

    @Test func existingFilesAreChecked() throws {
        let dir = try TempDirectory(prefix: "orix-plist")
        defer { dir.remove() }
        let wrongName = dir.file("other.plist")
        try LaunchAgentPlist.write(agent(), to: wrongName)
        #expect(LaunchAgentPlist.problems(inPlistAt: wrongName) == ["file name must be ai.orix.automation.agent.plist"])
        let garbage = try dir.write("ai.orix.garbage.plist", "not a plist")
        #expect(LaunchAgentPlist.problems(inPlistAt: garbage) == ["not a property list dictionary"])
        let always = dir.file("ai.orix.always.plist")
        try PropertyListSerialization.data(fromPropertyList: ["Label": "ai.orix.always", "KeepAlive": true], format: .xml, options: 0).write(to: always)
        #expect(LaunchAgentPlist.problems(inPlistAt: always).count == 2)
        #expect(LaunchAgentPlist.problems(inPlistAt: dir.file("missing.plist")).first?.hasPrefix("cannot read") == true)
    }
}
