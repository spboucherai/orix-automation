// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/SystemTools.swift
// Description: Read-only system observation: system.info, system.processes, system.diskUsage, system.powerState (IOKit power sources) and system.networkState (NWPathMonitor snapshot).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import IOKit.ps
import Network
import ORIXCore

private func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

private func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
}

public struct SystemInfoTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "system.info", name: "System information",
        summary: "Reports the macOS version, Mac model, processor, core counts, memory and uptime of this Mac.",
        family: "system", inputSchema: Schema.input([:]),
        outputSchema: Schema.output(["osVersion": .string(), "model": .string(), "cpu": .string(), "cores": .integer(), "memoryBytes": .integer(), "uptimeSeconds": .integer()],
                                    required: ["osVersion", "model", "cpu", "cores", "memoryBytes", "uptimeSeconds"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "Read system information")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        var out: [String: JSONValue] = [
            "osVersion": .string(version), "osBuild": .string(sysctlString("kern.osversion") ?? ""),
            "model": .string(sysctlString("hw.model") ?? "unknown"), "cpu": .string(sysctlString("machdep.cpu.brand_string") ?? "unknown"),
            "architecture": .string(sysctlString("hw.machine") ?? "unknown"),
            "cores": .int(info.processorCount), "activeCores": .int(info.activeProcessorCount),
            "memoryBytes": .int(Int(info.physicalMemory)), "uptimeSeconds": .int(Int(info.systemUptime)),
            "thermalState": .string(["nominal", "fair", "serious", "critical"][min(3, info.thermalState.rawValue)]),
            "lowPowerMode": .bool(info.isLowPowerModeEnabled),
        ]
        if let p = sysctlInt("hw.perflevel0.physicalcpu") { out["performanceCores"] = .int(p) }
        if let e = sysctlInt("hw.perflevel1.physicalcpu") { out["efficiencyCores"] = .int(e) }
        return .success(.object(out), summary: "macOS \(version), \(out["model"]?.stringValue ?? ""), \(info.processorCount) cores, \(info.physicalMemory / 1_073_741_824) GB")
    }
}

public struct SystemProcessesTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ToolManifest(
        identifier: "system.processes", name: "Top processes",
        summary: "Lists the processes using the most CPU or memory (pid, parent, CPU %, memory %, resident size, user, name).",
        family: "system",
        inputSchema: Schema.input(["sortBy": .string("cpu (default) or memory.", enum: ["cpu", "memory"]), "limit": .integer("Default 15.", minimum: 1, maximum: 200)]),
        outputSchema: Schema.output(["processes": .array(of: .any), "total": .integer()], required: ["processes", "total"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "List the top processes by \(input.optionalString("sortBy") ?? "cpu")")
    }

    static func parse(_ text: String) -> [[String: JSONValue]] {
        text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true).map(String.init)
            guard f.count == 7, let pid = Int(f[0]), let ppid = Int(f[1]) else { return nil }
            return ["pid": .int(pid), "ppid": .int(ppid), "cpuPercent": .number(Double(f[2]) ?? 0), "memoryPercent": .number(Double(f[3]) ?? 0),
                    "residentBytes": .int((Int(f[4]) ?? 0) * 1024), "user": .string(f[5]), "name": .string(f[6].trimmingCharacters(in: .whitespaces))]
        }
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let byMemory = input.optionalString("sortBy") == "memory"
        // /bin/ps is setuid root and macOS refuses to start setuid programs under sandbox-exec, so this fixed,
        // argument-free listing is the one subprocess of the package that runs unconfined.
        let out = try await ToolSupport.run(ProcessSpec(executable: "/bin/ps", arguments: ["-Aceo", "pid,ppid,pcpu,pmem,rss,user,comm"], environment: ["LC_ALL": "C"],
                                                        workingDirectory: "/", timeoutSeconds: min(20, context.timeoutSeconds), maxOutputBytes: 4_000_000),
                                            context: context, runner: runner)
        try out.requireSuccess(timeoutSeconds: 20)
        let all = Self.parse(out.stdoutText)
        let key = byMemory ? "residentBytes" : "cpuPercent"
        let sorted = all.sorted { ($0[key]?.doubleValue ?? 0) > ($1[key]?.doubleValue ?? 0) }.prefix(input.int("limit", default: 15))
        return .success(["processes": .array(sorted.map(JSONValue.object)), "total": .int(all.count), "sortedBy": .string(byMemory ? "memory" : "cpu")],
                        summary: "Top \(sorted.count) of \(all.count) processes by \(byMemory ? "memory" : "CPU")")
    }
}

public struct SystemDiskUsageTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "system.diskUsage", name: "Disk usage",
        summary: "Lists mounted volumes with total and available capacity.",
        family: "system", inputSchema: Schema.input(["includeHidden": .boolean("Include system volumes hidden from the Finder.")]),
        outputSchema: Schema.output(["volumes": .array(of: .any)], required: ["volumes"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "Read the capacity of mounted volumes")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey, .volumeIsLocalKey]
        let options: FileManager.VolumeEnumerationOptions = input.bool("includeHidden", default: false) ? [] : [.skipHiddenVolumes]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: options) ?? []
        let volumes: [JSONValue] = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let available = v.volumeAvailableCapacityForImportantUsage.map(Int.init) ?? v.volumeAvailableCapacity ?? 0
            return ["name": .string(v.volumeName ?? url.lastPathComponent), "path": .string(url.path), "totalBytes": .int(total),
                    "availableBytes": .int(available), "usedPercent": .number((Double(total - min(available, total)) / Double(total) * 1000).rounded() / 10),
                    "internal": .bool(v.volumeIsInternal ?? false), "removable": .bool(v.volumeIsRemovable ?? false),
                    "readOnly": .bool(v.volumeIsReadOnly ?? false), "local": .bool(v.volumeIsLocal ?? true),
                    "format": .string(v.volumeLocalizedFormatDescription ?? "")]
        }
        return .success(["volumes": .array(volumes)], summary: "\(ToolSupport.plural(volumes.count, "volume"))")
    }
}

public struct SystemPowerStateTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "system.powerState", name: "Power state",
        summary: "Reports whether the Mac runs on AC power or battery, and the charge and charging state of each battery (a desktop Mac has none).",
        family: "system", inputSchema: Schema.input([:]),
        outputSchema: Schema.output(["source": .string(), "onACPower": .boolean(), "hasBattery": .boolean(), "batteries": .array(of: .any)],
                                    required: ["source", "onACPower", "hasBattery", "batteries"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "Read the power state")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { throw ToolError.unsupported("Power source information is not available") }
        let providing = (IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?) ?? "AC Power"
        let list = (IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        var batteries: [JSONValue] = []
        for item in list {
            guard let d = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0, maxCap = d[kIOPSMaxCapacityKey] as? Int ?? 100
            var b: [String: JSONValue] = [
                "name": .string(d[kIOPSNameKey] as? String ?? "Battery"), "percent": .int(maxCap > 0 ? Int((Double(current) / Double(maxCap) * 100).rounded()) : 0),
                "charging": .bool(d[kIOPSIsChargingKey] as? Bool ?? false), "charged": .bool(d[kIOPSIsChargedKey] as? Bool ?? false),
                "powerSource": .string(d[kIOPSPowerSourceStateKey] as? String ?? ""),
            ]
            if let t = d[kIOPSTimeToEmptyKey] as? Int, t >= 0 { b["minutesToEmpty"] = .int(t) }
            if let t = d[kIOPSTimeToFullChargeKey] as? Int, t >= 0 { b["minutesToFull"] = .int(t) }
            batteries.append(.object(b))
        }
        let onAC = providing == kIOPSACPowerValue
        let percent = batteries.first?["percent"]?.intValue
        return .success(["source": .string(providing), "onACPower": .bool(onAC), "hasBattery": .bool(!batteries.isEmpty), "batteries": .array(batteries),
                         "lowPowerMode": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)],
                        summary: batteries.isEmpty ? "On AC power, no battery" : "\(onAC ? "On AC power" : "On battery"), \(percent ?? 0) %")
    }
}

public struct SystemNetworkStateTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "system.networkState", name: "Network state",
        summary: "Reports whether the Mac currently has a usable network path and through which interface types (Wi-Fi, wired, cellular), without contacting any host.",
        family: "system", inputSchema: Schema.input([:]),
        outputSchema: Schema.output(["status": .string(), "online": .boolean(), "interfaces": .array(of: .any)], required: ["status", "online", "interfaces"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        ToolRequirements(capabilities: [], tier: .readOnly, summary: "Read the network state")
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<NWPath?, Never>?
        init(_ c: CheckedContinuation<NWPath?, Never>) { continuation = c }
        func resume(_ p: NWPath?) { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(returning: p) }
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "ai.orix.tools.network-state")
        let path: NWPath? = await withCheckedContinuation { cont in
            let once = Once(cont)
            monitor.pathUpdateHandler = { once.resume($0) }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { once.resume(nil) }
        }
        monitor.cancel()
        guard let path else { throw ToolError.unsupported("The system did not report a network path within 3 seconds") }
        func name(_ t: NWInterface.InterfaceType) -> String {
            switch t {
            case .wifi: return "wifi"
            case .wiredEthernet: return "wired"
            case .cellular: return "cellular"
            case .loopback: return "loopback"
            default: return "other"
            }
        }
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .requiresConnection: status = "requiresConnection"
        default: status = "unsatisfied"
        }
        let interfaces: [JSONValue] = path.availableInterfaces.map { ["name": .string($0.name), "type": .string(name($0.type))] }
        let used = [NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular, .loopback, .other].filter { path.usesInterfaceType($0) }.map(name)
        return .success(["status": .string(status), "online": .bool(path.status == .satisfied), "interfaces": .array(interfaces),
                         "usedInterfaceTypes": .array(used.map(JSONValue.string)), "expensive": .bool(path.isExpensive), "constrained": .bool(path.isConstrained),
                         "supportsIPv4": .bool(path.supportsIPv4), "supportsIPv6": .bool(path.supportsIPv6), "supportsDNS": .bool(path.supportsDNS)],
                        summary: path.status == .satisfied ? "Online via \(used.isEmpty ? "an unknown interface" : used.joined(separator: ", "))" : "Offline (\(status))")
    }
}
