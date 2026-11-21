// ORIX OS Automation
// File: Packages/ORIXCore/Sources/ORIXCore/JSONValue.swift
// Description: A Sendable JSON value used for tool arguments, tool results, workflow data and provider payloads.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation

/// JSON-compatible value. Integral numbers decode to `.int`, everything else numeric to `.number`.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

public extension JSONValue {
    var isNull: Bool { if case .null = self { return true }; return false }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .number(let d) where d.rounded() == d && abs(d) < 9e15: return Int(d)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .number(let d): return d
        default: return nil
        }
    }

    subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }

    /// Looks up a dotted path such as `steps.fetch.output.items.0.name`.
    func value(atPath path: String) -> JSONValue? {
        var current = self
        for part in path.split(separator: ".") {
            if let idx = Int(part), let next = current[idx] { current = next }
            else if let next = current[String(part)] { current = next }
            else { return nil }
        }
        return current
    }

    /// Truthiness used by workflow conditions: null, false, 0, "" and empty collections are false.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .number(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

    func serialized(pretty: Bool = false) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(self), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    /// Converts any Encodable into a JSONValue.
    static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try parse(try enc.encode(value))
    }

    /// Decodes this value into a Decodable type.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(T.self, from: try enc.encode(self))
    }

    /// Human-readable rendering: strings are returned bare, everything else as compact JSON.
    var displayString: String {
        if case .string(let s) = self { return s }
        return serialized()
    }
}
