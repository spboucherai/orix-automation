// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXCore/Sources/ORIXCore/JSONSchema.swift
// Description      : JSON Schema subset (type, properties, required,
//                    additionalProperties, items, enum, bounds, pattern) with a
//                    validator used on every tool call.
// Module           : ORIXCore
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

public struct SchemaViolation: Sendable, Hashable, CustomStringConvertible {
    public let path: String
    public let message: String
    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

/// A JSON Schema document. Only the keywords listed in the file description are enforced; unknown keywords are ignored.
public struct JSONSchema: Sendable, Hashable, Codable {
    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }
    public init(from decoder: Decoder) throws { raw = try JSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    // MARK: Builders

    public static let any = JSONSchema(raw: .object([:]))

    public static func string(_ description: String? = nil, enum values: [String]? = nil, pattern: String? = nil) -> JSONSchema {
        var o: [String: JSONValue] = ["type": "string"]
        if let description { o["description"] = .string(description) }
        if let values { o["enum"] = .array(values.map(JSONValue.string)) }
        if let pattern { o["pattern"] = .string(pattern) }
        return JSONSchema(raw: .object(o))
    }

    public static func integer(_ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> JSONSchema {
        var o: [String: JSONValue] = ["type": "integer"]
        if let description { o["description"] = .string(description) }
        if let minimum { o["minimum"] = .int(minimum) }
        if let maximum { o["maximum"] = .int(maximum) }
        return JSONSchema(raw: .object(o))
    }

    public static func number(_ description: String? = nil) -> JSONSchema {
        var o: [String: JSONValue] = ["type": "number"]
        if let description { o["description"] = .string(description) }
        return JSONSchema(raw: .object(o))
    }

    public static func boolean(_ description: String? = nil) -> JSONSchema {
        var o: [String: JSONValue] = ["type": "boolean"]
        if let description { o["description"] = .string(description) }
        return JSONSchema(raw: .object(o))
    }

    public static func array(of items: JSONSchema, _ description: String? = nil) -> JSONSchema {
        var o: [String: JSONValue] = ["type": "array", "items": items.raw]
        if let description { o["description"] = .string(description) }
        return JSONSchema(raw: .object(o))
    }

    public static func object(_ properties: [String: JSONSchema], required: [String] = [], additional: Bool = false,
                              description: String? = nil) -> JSONSchema {
        var o: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties.mapValues(\.raw)),
            "required": .array(required.sorted().map(JSONValue.string)),
            "additionalProperties": .bool(additional),
        ]
        if let description { o["description"] = .string(description) }
        return JSONSchema(raw: .object(o))
    }

    // MARK: Validation

    public func validate(_ value: JSONValue) -> [SchemaViolation] {
        var out: [SchemaViolation] = []
        Self.validate(value, schema: raw, path: "", into: &out)
        return out
    }

    private static func typeName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func matches(_ v: JSONValue, type: String) -> Bool {
        switch (type, v) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object): return true
        case ("integer", .int): return true
        case ("integer", .number(let d)): return d.rounded() == d
        case ("number", .int), ("number", .number): return true
        default: return false
        }
    }

    private static func validate(_ v: JSONValue, schema: JSONValue, path: String, into out: inout [SchemaViolation]) {
        guard case .object(let s) = schema else { return }
        if let t = s["type"] {
            let allowed: [String] = t.stringValue.map { [$0] } ?? (t.arrayValue?.compactMap(\.stringValue) ?? [])
            if !allowed.isEmpty, !allowed.contains(where: { matches(v, type: $0) }) {
                out.append(.init(path: path, message: "expected \(allowed.joined(separator: " or ")), got \(typeName(v))"))
                return
            }
        }
        if let e = s["enum"]?.arrayValue, !e.contains(v) {
            out.append(.init(path: path, message: "value is not one of the allowed values"))
        }
        switch v {
        case .string(let str):
            if let min = s["minLength"]?.intValue, str.count < min { out.append(.init(path: path, message: "shorter than \(min) characters")) }
            if let max = s["maxLength"]?.intValue, str.count > max { out.append(.init(path: path, message: "longer than \(max) characters")) }
            if let p = s["pattern"]?.stringValue, let re = try? NSRegularExpression(pattern: p),
               re.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) == nil {
                out.append(.init(path: path, message: "does not match pattern \(p)"))
            }
        case .int, .number:
            let d = v.doubleValue ?? 0
            if let min = s["minimum"]?.doubleValue, d < min { out.append(.init(path: path, message: "less than minimum \(min)")) }
            if let max = s["maximum"]?.doubleValue, d > max { out.append(.init(path: path, message: "greater than maximum \(max)")) }
        case .array(let items):
            if let min = s["minItems"]?.intValue, items.count < min { out.append(.init(path: path, message: "fewer than \(min) items")) }
            if let max = s["maxItems"]?.intValue, items.count > max { out.append(.init(path: path, message: "more than \(max) items")) }
            if let itemSchema = s["items"] {
                for (i, item) in items.enumerated() { validate(item, schema: itemSchema, path: join(path, "\(i)"), into: &out) }
            }
        case .object(let obj):
            let props = s["properties"]?.objectValue ?? [:]
            for req in s["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where obj[req] == nil {
                out.append(.init(path: join(path, req), message: "required property is missing"))
            }
            for (k, child) in obj {
                if let ps = props[k] { validate(child, schema: ps, path: join(path, k), into: &out) }
                else if let ap = s["additionalProperties"] {
                    if ap == .bool(false) { out.append(.init(path: join(path, k), message: "unexpected property")) }
                    else if case .object = ap { validate(child, schema: ap, path: join(path, k), into: &out) }
                }
            }
        default: break
        }
    }

    private static func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : "\(a).\(b)" }
}
