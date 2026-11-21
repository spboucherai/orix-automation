// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/ToolRegistry.swift
// Description      : The catalogue of installed tools. Rejects duplicate
//                    identifiers and structurally invalid manifests at
//                    registration time.
// Module           : ORIXToolRegistry
// Repository       : https://git.spboucher.ai/orix-automation
// Created          : 2026-11-21
// Last Modified    : 2026-11-21
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : Proprietary, all rights reserved (see license file)
// License File     : LICENSE
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

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
