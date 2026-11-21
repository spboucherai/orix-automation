// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/BuiltIn.swift
// Description      : The built-in example automations, loaded from the package
//                    resources that mirror Workflows/Examples.
// Module           : ORIXWorkflowEngine
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

/// One shipped example automation. The YAML is the editable source, comments included.
public struct BuiltInWorkflow: Sendable, Hashable, Identifiable {
    /// File name without the `NN-` prefix and the extension, for example `smart-downloads-organizer`.
    public var slug: String
    /// `metadata.name` of the document.
    public var title: String
    /// `metadata.description` of the document.
    public var summary: String
    public var yaml: String

    public var id: String { slug }

    public init(slug: String, title: String, summary: String, yaml: String) {
        self.slug = slug; self.title = title; self.summary = summary; self.yaml = yaml
    }

    public func document() throws -> WorkflowDocument { try WorkflowCodec.parse(yaml, format: .yaml) }
}

public enum BuiltInWorkflows {
    /// Every example found in the package resources, sorted by file name. A file that does not parse is listed with its
    /// slug as title and an empty summary, so a broken resource is visible rather than silently missing.
    public static func all() -> [BuiltInWorkflow] {
        guard let dir = Bundle.module.url(forResource: "Examples", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "yaml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let slug = Self.slug(fileName: url.lastPathComponent)
                let doc = try? WorkflowCodec.parse(yaml, format: .yaml)
                return BuiltInWorkflow(slug: slug, title: doc?.metadata.name ?? slug, summary: doc?.metadata.description ?? "", yaml: yaml)
            }
    }

    public static func workflow(slug: String) -> BuiltInWorkflow? { all().first { $0.slug == slug } }

    /// `03-weekly-research-digest.yaml` → `weekly-research-digest`.
    static func slug(fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        if let dash = name.firstIndex(of: "-"), name[..<dash].allSatisfy({ $0.isASCII && $0.isNumber }), dash != name.startIndex {
            name = String(name[name.index(after: dash)...])
        }
        return name
    }
}
