// ORIX OS Automation
// File: Packages/ORIXScheduler/Sources/ORIXScheduler/TriggerMonitor.swift
// Description: Turns file changes, app launches, power connection, network availability and login into enqueue requests for the scheduler.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import Foundation
import IOKit.ps
import Network

/// One occurrence of an event trigger, ready to be handed to `SchedulerEngine.fire`.
public struct TriggerEvent: Sendable, Hashable {
    public var scheduleID: String
    /// `fileChange`, `login`, `appLaunch`, `powerConnected`, `networkAvailable`.
    public var kind: String
    /// Plain-words reason stored on the queue item.
    public var reason: String
    /// Changed paths for `fileChange`.
    public var paths: [String]
    /// Set when the occurrence must be enqueued at most once (login).
    public var dedupKey: String?
    public var date: Date
    public init(scheduleID: String, kind: String, reason: String, paths: [String] = [], dedupKey: String? = nil, date: Date = Date()) {
        self.scheduleID = scheduleID; self.kind = kind; self.reason = reason; self.paths = paths; self.dedupKey = dedupKey; self.date = date
    }
}

/// Watches the system for the event triggers of the current schedules.
///
/// Call `update(schedules:)` with the full list whenever schedules change; watchers and observers are created and torn
/// down to match. Disabled and paused schedules are not watched.
///
/// Exact rules:
/// - **fileChange**: one event per debounced burst (see `FileWatcher`). A path that does not exist is reported in
///   `problems` and retried at the next `update`.
/// - **appLaunch**: `NSWorkspace.didLaunchApplicationNotification` whose bundle identifier equals the trigger's.
///   Needs a running main run loop. Apps already running when monitoring starts do not fire.
/// - **powerConnected**: fires on the transition from battery/UPS to AC power (IOKit power-source notification). It does
///   not fire at start when the Mac is already on AC, nor on a Mac that is always on AC.
/// - **networkAvailable**: fires on the transition from "no usable network path" to "satisfied" (`NWPathMonitor`). It
///   does not fire at start when the network is already up.
/// - **login**: fires once per login session, the first time `update` sees the schedule, and only when the monitor
///   observes it within `loginWindowSeconds` of the console login time (from the system's `utmpx` record of the current
///   user's console session; the boot time when no such record exists). The event carries the dedup key
///   `scheduleID@login-<login epoch seconds>`, so a restarted agent cannot fire it again for the same session. A
///   schedule created long after login waits for the next login.
public final class TriggerMonitor: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var loginWindowSeconds: Double
        /// Where the login time comes from. Replaceable in tests.
        public var loginDate: @Sendable () -> Date?
        public var now: @Sendable () -> Date
        /// False disables the NSWorkspace, IOKit and NWPathMonitor observers (file watchers still run).
        public var observesSystem: Bool
        public init(loginWindowSeconds: Double = 600, loginDate: @escaping @Sendable () -> Date? = { TriggerMonitor.consoleLoginDate() },
                    now: @escaping @Sendable () -> Date = { Date() }, observesSystem: Bool = true) {
            self.loginWindowSeconds = loginWindowSeconds; self.loginDate = loginDate; self.now = now; self.observesSystem = observesSystem
        }
    }

    private let configuration: Configuration
    private let sink: @Sendable (TriggerEvent) -> Void
    private let lock = NSLock()
    private var watched: [String: Schedule] = [:]
    private var fileWatchers: [String: (trigger: TriggerSpec, watcher: FileWatcher)] = [:]
    private var loginSeen: Set<String> = []
    private var _problems: [String: String] = [:]
    private var appObserver: (any NSObjectProtocol)?
    private var powerSource: CFRunLoopSource?
    private var pathMonitor: NWPathMonitor?
    private var onACPower: Bool?
    private var networkSatisfied: Bool?

    public init(configuration: Configuration = Configuration(), sink: @escaping @Sendable (TriggerEvent) -> Void) {
        self.configuration = configuration
        self.sink = sink
    }

    /// A monitor that enqueues straight into `engine`.
    public convenience init(engine: SchedulerEngine, configuration: Configuration = Configuration()) {
        self.init(configuration: configuration) { event in
            Task { _ = try? await engine.fire(scheduleID: event.scheduleID, reason: event.reason, dedupKey: event.dedupKey) }
        }
    }

    deinit { stop() }

    /// Schedules whose trigger could not be watched, by schedule id (for example a `fileChange` path that does not exist).
    public var problems: [String: String] { lock.withLock { _problems } }

    /// Number of active file watchers.
    public var fileWatcherCount: Int { lock.withLock { fileWatchers.count } }

    /// Reconciles watchers and observers with `schedules`.
    public func update(schedules: [Schedule]) {
        var loginEvents: [TriggerEvent] = []
        var toStop: [FileWatcher] = []
        lock.withLock {
            let live = schedules.filter { $0.enabled && !$0.paused && !$0.trigger.isTimeBased }
            watched = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            _problems = [:]

            // File watchers.
            for (id, entry) in fileWatchers where watched[id]?.trigger != entry.trigger {
                toStop.append(entry.watcher)
                fileWatchers[id] = nil
            }
            for s in live {
                guard case .fileChange(let path, let recursive, let glob, let debounce) = s.trigger, fileWatchers[s.id] == nil else { continue }
                let id = s.id
                let sink = self.sink
                do {
                    let watcher = try FileWatcher(path: path, recursive: recursive, glob: glob, debounceSeconds: debounce) { event in
                        let shown = event.paths.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                        let more = event.paths.count > 5 ? " and \(event.paths.count - 5) more" : ""
                        sink(TriggerEvent(scheduleID: id, kind: "fileChange", reason: "file change: \(shown)\(more)", paths: event.paths, date: event.date))
                    }
                    try watcher.start()
                    fileWatchers[id] = (s.trigger, watcher)
                } catch {
                    _problems[id] = error.localizedDescription
                }
            }

            // Login: once per schedule per monitor, and once per login session through the dedup key.
            let now = configuration.now()
            let loginSchedules = live.filter { $0.trigger == .login && !loginSeen.contains($0.id) }
            if !loginSchedules.isEmpty {
                let login = configuration.loginDate()
                for s in loginSchedules {
                    loginSeen.insert(s.id)
                    guard let login else { _problems[s.id] = "the login time of this session could not be determined"; continue }
                    let age = now.timeIntervalSince(login)
                    guard age >= 0, age <= configuration.loginWindowSeconds else { continue }
                    loginEvents.append(TriggerEvent(scheduleID: s.id, kind: "login", reason: "login: session started \(Int(age)) s ago",
                                                    dedupKey: "\(s.id)@login-\(Int(login.timeIntervalSince1970))", date: now))
                }
            }

            guard configuration.observesSystem else { return }
            let kinds = Set(live.map(\.trigger.kind))
            setAppObserver(kinds.contains("appLaunch"))
            setPowerObserver(kinds.contains("powerConnected"))
            setNetworkObserver(kinds.contains("networkAvailable"))
        }
        for w in toStop { w.stop() }
        for e in loginEvents { sink(e) }
    }

    /// Stops every watcher and observer.
    public func stop() {
        let watchers: [FileWatcher] = lock.withLock {
            let all = fileWatchers.values.map(\.watcher)
            fileWatchers = [:]
            watched = [:]
            setAppObserver(false)
            setPowerObserver(false)
            setNetworkObserver(false)
            return all
        }
        for w in watchers { w.stop() }
    }

    // MARK: Event handling (also the seams used by unit tests)

    func handleAppLaunch(bundleID: String) {
        let matches: [Schedule] = lock.withLock {
            watched.values.filter { if case .appLaunch(let b) = $0.trigger { return b == bundleID }; return false }
        }
        for s in matches {
            sink(TriggerEvent(scheduleID: s.id, kind: "appLaunch", reason: "app launched: \(bundleID)", date: configuration.now()))
        }
    }

    func handlePower(onAC: Bool) {
        let matches: [Schedule] = lock.withLock {
            let previous = onACPower
            onACPower = onAC
            guard previous == false, onAC else { return [] }
            return watched.values.filter { $0.trigger == .powerConnected }
        }
        for s in matches {
            sink(TriggerEvent(scheduleID: s.id, kind: "powerConnected", reason: "power adapter connected", date: configuration.now()))
        }
    }

    func handleNetwork(satisfied: Bool) {
        let matches: [Schedule] = lock.withLock {
            let previous = networkSatisfied
            networkSatisfied = satisfied
            guard previous == false, satisfied else { return [] }
            return watched.values.filter { $0.trigger == .networkAvailable }
        }
        for s in matches {
            sink(TriggerEvent(scheduleID: s.id, kind: "networkAvailable", reason: "network became available", date: configuration.now()))
        }
    }

    // MARK: System observers (called with the lock held)

    private func setAppObserver(_ wanted: Bool) {
        if wanted, appObserver == nil {
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] note in
                    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          let bundleID = app.bundleIdentifier else { return }
                    self?.handleAppLaunch(bundleID: bundleID)
                }
        } else if !wanted, let observer = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appObserver = nil
        }
    }

    private func setPowerObserver(_ wanted: Bool) {
        if wanted, powerSource == nil {
            onACPower = Self.isOnACPower()
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let monitor = Unmanaged<TriggerMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handlePower(onAC: TriggerMonitor.isOnACPower())
            }, context)?.takeRetainedValue() else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        } else if !wanted, let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = nil
            onACPower = nil
        }
    }

    private func setNetworkObserver(_ wanted: Bool) {
        if wanted, pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.handleNetwork(satisfied: path.status == .satisfied) }
            monitor.start(queue: DispatchQueue(label: "ai.orix.scheduler.network"))
            pathMonitor = monitor
        } else if !wanted, let monitor = pathMonitor {
            monitor.cancel()
            pathMonitor = nil
            networkSatisfied = nil
        }
    }

    // MARK: System facts

    /// True when the Mac currently draws from AC power.
    public static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    /// When the current user's console (GUI) session started, from `utmpx`; the boot time when there is no such record.
    public static func consoleLoginDate() -> Date? {
        let user = NSUserName()
        var found: Date?
        setutxent()
        while let entry = getutxent() {
            let e = entry.pointee
            guard Int32(e.ut_type) == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: e.ut_line) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            let name = withUnsafeBytes(of: e.ut_user) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            guard line == "console", name == user else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(e.ut_tv.tv_sec) + TimeInterval(e.ut_tv.tv_usec) / 1_000_000)
            if found.map({ date > $0 }) ?? true { found = date }
        }
        endutxent()
        return found ?? bootDate()
    }

    /// When the kernel booted (`kern.boottime`).
    public static func bootDate() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
