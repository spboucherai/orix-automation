// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/ToolRegistry.swift
// Description: The catalogue of installed tools. Rejects duplicate identifiers and structurally invalid manifests at registration time.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public enum ToolRegistryError: Error, Sendable, Hashable, LocalizedError {
    case duplicateIdentifier(String)
    case invalidManifest(identifier: String, problems: [String])

    public var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let id): return "A tool named \(id) is already registered"
        case .invalidManifest(let id, let problems): return "Manifest of \(id) is invalid: \(problems.joined(separator: "; "))"
        }
    }
}

public actor ToolRegistry {
    private var tools: [String: any ORIXTool] = [:]

    public init() {}

    /// Registers one tool. Throws on a duplicate identifier or when `manifest.problems()` is not empty.
    public func register(_ tool: any ORIXTool) throws {
        try Self.check(tool)
        guard tools[tool.identifier] == nil else { throw ToolRegistryError.duplicateIdentifier(tool.identifier) }
        tools[tool.identifier] = tool
    }

    /// Registers every tool or none: the whole batch is validated before anything is added.
    public func registerAll(_ batch: [any ORIXTool]) throws {
        var seen = Set<String>()
        for tool in batch {
            try Self.check(tool)
            guard tools[tool.identifier] == nil, seen.insert(tool.identifier).inserted else {
                throw ToolRegistryError.duplicateIdentifier(tool.identifier)
            }
        }
        for tool in batch { tools[tool.identifier] = tool }
    }

    @discardableResult
    public func unregister(id: String) -> Bool { tools.removeValue(forKey: id) != nil }

    public func tool(id: String) -> (any ORIXTool)? { tools[id] }

    /// Every manifest, sorted by identifier.
    public func manifests() -> [ToolManifest] {
        tools.values.map(\.manifest).sorted { $0.identifier < $1.identifier }
    }

    public func manifests(family: String) -> [ToolManifest] {
        manifests().filter { $0.family == family }
    }

    public var count: Int { tools.count }

    private static func check(_ tool: any ORIXTool) throws {
        var problems = tool.manifest.problems()
        if tool.identifier != tool.manifest.identifier { problems.append("identifier differs from manifest.identifier") }
        if !problems.isEmpty { throw ToolRegistryError.invalidManifest(identifier: tool.identifier, problems: problems) }
    }
}
