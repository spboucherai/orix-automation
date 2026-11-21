// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/BuiltIn.swift
// Description: The built-in example automations, loaded from the package resources that mirror Workflows/Examples.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
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
