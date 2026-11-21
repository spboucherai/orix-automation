// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/ArgumentForm.swift
// Description: Turns a tool's input schema into editable fields: text to value and back, expression pass-through, schema validation messages and argument stubs for new steps.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAppUI

/// One top-level property of a tool's input schema.
struct SchemaField: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case string, integer, number, boolean, array, object, any
        case enumeration([String])

        var label: String {
            switch self {
            case .string: return "text"
            case .integer: return "integer"
            case .number: return "number"
            case .boolean: return "true / false"
            case .array: return "list"
            case .object: return "object"
            case .any: return "any"
            case .enumeration: return "choice"
            }
        }
    }

    var name: String
    var kind: Kind
    var required: Bool
    var summary: String
    /// The raw property schema, used to validate a literal value.
    var schema: JSONValue
    var id: String { name }
}

struct FormError: Error, Hashable, Sendable {
    var message: String
}

enum ArgumentForm {
    /// True when the text holds a `${{ … }}` expression; such values are stored as text and checked by the validator.
    static func isExpression(_ text: String) -> Bool { text.contains("${{") }

    static func kind(of schema: JSONValue) -> SchemaField.Kind {
        if let values = schema["enum"]?.arrayValue {
            let strings = values.compactMap(\.stringValue)
            if strings.count == values.count, !strings.isEmpty { return .enumeration(strings) }
        }
        var type = schema["type"]?.stringValue
        if type == nil, let list = schema["type"]?.arrayValue { type = list.compactMap(\.stringValue).first { $0 != "null" } }
        switch type {
        case "string": return .string
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "array": return .array
        case "object": return .object
        default: return .any
        }
    }

    /// Fields of an object schema: required ones first, then by name.
    static func fields(of schema: JSONSchema) -> [SchemaField] {
        let props = schema.raw["properties"]?.objectValue ?? [:]
        let required = Set(schema.raw["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return props.map { name, raw in
            SchemaField(name: name, kind: kind(of: raw), required: required.contains(name), summary: raw["description"]?.stringValue ?? "", schema: raw)
        }
        .sorted { a, b in a.required != b.required ? a.required : a.name < b.name }
    }

    /// The text shown in a field for a stored value.
    static func text(for value: JSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .null: return ""
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .number(let d): return JSONValue.number(d).intValue.map(String.init) ?? String(d)
        case .array(let items):
            // A list of plain strings reads better one per line; anything else stays JSON.
            let strings = items.compactMap(\.stringValue)
            if strings.count == items.count, !strings.contains(where: { $0.contains("\n") || $0.contains(",") || $0.isEmpty }) {
                return strings.joined(separator: "\n")
            }
            return value.serialized()
        case .object: return value.serialized(pretty: true)
        }
    }

    /// Reads free text the way YAML would: JSON literals keep their type, everything else is text.
    static func parseLoose(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isExpression(text) { return .string(text) }
        if trimmed.isEmpty { return .string("") }
        if let first = trimmed.first, "[{\"".contains(first) || trimmed == "true" || trimmed == "false" || trimmed == "null"
            || first.isNumber || first == "-", let v = try? JSONValue.parse(trimmed) { return normalized(v) }
        return .string(text)
    }

    /// Whole doubles become integers so `3` stays `3` after a round trip.
    static func normalized(_ v: JSONValue) -> JSONValue {
        switch v {
        case .number(let d): if let i = JSONValue.number(d).intValue { return .int(i) }; return v
        case .array(let a): return .array(a.map(normalized))
        case .object(let o): return .object(o.mapValues(normalized))
        default: return v
        }
    }

    /// Converts field text to a value. Empty text means "not set" (nil). An expression is kept as text. A literal is
    /// converted to the field's type and checked against the property schema.
    static func parse(_ text: String, field: SchemaField) -> Result<JSONValue?, FormError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // An empty required text field is a real (empty) value; anything else empty is "not set".
            return .success(nil)
        }
        if isExpression(text) { return .success(.string(text)) }
        let value: JSONValue
        switch field.kind {
        case .string, .enumeration: value = .string(text)
        case .integer:
            guard let i = Int(trimmed) else { return .failure(FormError(message: "Enter a whole number, or an expression such as ${{ params.count }}.")) }
            value = .int(i)
        case .number:
            guard let d = Double(trimmed.replacingOccurrences(of: ",", with: ".")), d.isFinite else {
                return .failure(FormError(message: "Enter a number, or an expression such as ${{ params.ratio }}."))
            }
            value = normalized(.number(d))
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "yes": value = .bool(true)
            case "false", "no": value = .bool(false)
            default: return .failure(FormError(message: "Enter true or false, or an expression."))
            }
        case .array:
            if trimmed.hasPrefix("[") {
                guard let v = try? JSONValue.parse(trimmed), v.arrayValue != nil else { return .failure(FormError(message: "This is not a valid JSON list.")) }
                value = normalized(v)
            } else {
                let itemKind = field.schema["items"].map(kind(of:)) ?? .string
                let parts = trimmed.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                var items: [JSONValue] = []
                for p in parts {
                    switch itemKind {
                    case .integer:
                        guard let i = Int(p) else { return .failure(FormError(message: "“\(p)” is not a whole number.")) }
                        items.append(.int(i))
                    case .number:
                        guard let d = Double(p) else { return .failure(FormError(message: "“\(p)” is not a number.")) }
                        items.append(normalized(.number(d)))
                    case .boolean:
                        guard p == "true" || p == "false" else { return .failure(FormError(message: "“\(p)” is not true or false.")) }
                        items.append(.bool(p == "true"))
                    default: items.append(.string(p))
                    }
                }
                value = .array(items)
            }
        case .object:
            guard let v = try? JSONValue.parse(trimmed), v.objectValue != nil else { return .failure(FormError(message: "Enter a JSON object, for example {\"key\": \"value\"}.")) }
            value = normalized(v)
        case .any: value = parseLoose(text)
        }
        if let problem = violation(value, field: field) { return .failure(FormError(message: problem)) }
        return .success(value)
    }

    /// The first schema violation of a literal value, as a sentence; nil when it fits (expressions are not checked here).
    static func violation(_ value: JSONValue, field: SchemaField) -> String? {
        if case .string(let s) = value, isExpression(s) { return nil }
        guard let first = JSONSchema(raw: field.schema).validate(value).first else { return nil }
        return first.description
    }

    // MARK: Stubs

    /// A value that satisfies a property schema as far as a blank can: the first choice, the minimum, an empty text or list.
    static func stubValue(_ schema: JSONValue) -> JSONValue {
        if let d = schema["default"], !d.isNull { return d }
        switch kind(of: schema) {
        case .enumeration(let values): return .string(values[0])
        case .string: return .string("")
        case .integer: return .int(schema["minimum"]?.intValue ?? 0)
        case .number: return schema["minimum"].flatMap { $0.doubleValue }.map { normalized(.number($0)) } ?? .int(0)
        case .boolean: return .bool(false)
        case .array: return .array([])
        case .object:
            var out: [String: JSONValue] = [:]
            let props = schema["properties"]?.objectValue ?? [:]
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] { out[name] = stubValue(props[name] ?? .object([:])) }
            return .object(out)
        case .any: return .string("")
        }
    }

    /// Arguments for a new step of this tool: every required argument present. A value from the tool's own first example
    /// is used when the blank would not pass the schema (a pattern or a minimum length, for instance).
    static func stub(for manifest: ToolManifest) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let example = manifest.examples.first?.objectValue ?? [:]
        for field in fields(of: manifest.inputSchema) where field.required {
            let blank = stubValue(field.schema)
            if violation(blank, field: field) == nil { out[field.name] = blank }
            else if let e = example[field.name], violation(e, field: field) == nil { out[field.name] = e }
            else { out[field.name] = blank }
        }
        return out
    }

    /// One line per property: `name: type` with a marker for required ones.
    static func summaryLines(of schema: JSONSchema) -> [(name: String, type: String, required: Bool, summary: String)] {
        fields(of: schema).map { f in
            var type = f.kind.label
            if case .enumeration(let values) = f.kind { type = values.joined(separator: " | ") }
            return (f.name, type, f.required, f.summary)
        }
    }
}
