// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Expression.swift
// Description: The safe expression language: hand-written tokenizer, Pratt parser, `${{ … }}` template splitting and static reference analysis.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public struct WorkflowExpressionError: Error, Sendable, Hashable, LocalizedError {
    public var message: String
    /// Character offset in the expression (or template) text.
    public var offset: Int
    public init(message: String, offset: Int = 0) { self.message = message; self.offset = offset }
    public var errorDescription: String? { message }
}

indirect enum Expr: Sendable {
    case literal(JSONValue)
    case name(String, at: Int)
    /// `range` covers the member name in the source (used to rewrite step references on rename).
    case member(Expr, String, range: Range<Int>)
    case index(Expr, Expr, at: Int)
    case call(String, [Expr], at: Int)
    case unary(String, Expr, at: Int)
    case binary(String, Expr, Expr, at: Int)
    case array([Expr])
    case lambda([String], Expr)
}

enum ExprToken: Equatable {
    case number(JSONValue)
    case string(String)
    case ident(String)
    case op(String)
    case lparen, rparen, lbracket, rbracket, comma, dot, arrow, eof
}

struct ExprTok {
    var kind: ExprToken
    var start: Int
    var end: Int
}

enum ExpressionLimits {
    static let maxSourceCharacters = 16_384
    static let maxNesting = 64
    /// Binary and postfix operators (`+`, `.name`, `[i]`) in one expression. Chains of them build a tree as deep as they are
    /// long without any bracket, so they are bounded separately from `maxNesting` to keep evaluation off the stack limit.
    static let maxChainedOperators = 256
    static let maxEvaluationSteps = 200_000
    static let maxStringBytes = 1_048_576
    static let maxCollectionCount = 100_000
}

struct ExpressionLexer {
    let chars: [Character]
    let base: Int

    init(_ source: String, base: Int = 0) { chars = Array(source); self.base = base }

    private func fail(_ message: String, _ i: Int) -> WorkflowExpressionError { WorkflowExpressionError(message: message, offset: base + i) }

    func tokenize() throws -> [ExprTok] {
        guard chars.count <= ExpressionLimits.maxSourceCharacters else {
            throw fail("expression is longer than \(ExpressionLimits.maxSourceCharacters) characters", 0)
        }
        var out: [ExprTok] = []
        var i = 0
        func isIdentStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
        func isIdentPart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\r\n" { i += 1; continue }
            let start = i
            let afterDot = out.last?.kind == .dot
            if afterDot, isIdentPart(c) {
                // Member names may start with a digit (`items.0`); after `steps.` they may contain dashes (step ids).
                let stepID = out.count >= 2 && out[out.count - 2].kind == .ident("steps")
                while i < chars.count {
                    if isIdentPart(chars[i]) { i += 1 }
                    else if stepID, chars[i] == "-", i + 1 < chars.count, isIdentPart(chars[i + 1]) { i += 1 }
                    else { break }
                }
                out.append(ExprTok(kind: .ident(String(chars[start..<i])), start: start, end: i))
                continue
            }
            if isDigit(c) {
                while i < chars.count, isDigit(chars[i]) { i += 1 }
                var isFloat = false
                if i + 1 < chars.count, chars[i] == ".", isDigit(chars[i + 1]) {
                    isFloat = true; i += 1
                    while i < chars.count, isDigit(chars[i]) { i += 1 }
                }
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    if j < chars.count, isDigit(chars[j]) {
                        isFloat = true
                        while j < chars.count, isDigit(chars[j]) { j += 1 }
                        i = j
                    }
                }
                let text = String(chars[start..<i])
                if !isFloat, let v = Int(text) { out.append(ExprTok(kind: .number(.int(v)), start: start, end: i)) }
                else if let d = Double(text) { out.append(ExprTok(kind: .number(.number(d)), start: start, end: i)) }
                else { throw fail("invalid number '\(text)'", start) }
                continue
            }
            if isIdentStart(c) {
                while i < chars.count, isIdentPart(chars[i]) { i += 1 }
                out.append(ExprTok(kind: .ident(String(chars[start..<i])), start: start, end: i))
                continue
            }
            if c == "'" || c == "\"" {
                var s = ""
                i += 1
                var closed = false
                while i < chars.count {
                    let ch = chars[i]
                    if ch == c { closed = true; i += 1; break }
                    if ch == "\\" {
                        guard i + 1 < chars.count else { break }
                        let e = chars[i + 1]
                        i += 2
                        switch e {
                        case "n": s.append("\n")
                        case "t": s.append("\t")
                        case "r": s.append("\r")
                        case "0": s.append("\0")
                        case "\\", "'", "\"", "/": s.append(e)
                        case "u":
                            guard i + 4 <= chars.count, let v = UInt32(String(chars[i..<i + 4]), radix: 16), let u = Unicode.Scalar(v) else {
                                throw fail("invalid \\u escape in string literal", i - 2)
                            }
                            s.unicodeScalars.append(u); i += 4
                        default: throw fail("unknown escape '\\\(e)' in string literal", i - 2)
                        }
                        continue
                    }
                    s.append(ch); i += 1
                }
                guard closed else { throw fail("unterminated string literal", start) }
                out.append(ExprTok(kind: .string(s), start: start, end: i))
                continue
            }
            let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
            if ["==", "!=", "<=", ">=", "&&", "||"].contains(two) { i += 2; out.append(ExprTok(kind: .op(two), start: start, end: i)); continue }
            if two == "=>" { i += 2; out.append(ExprTok(kind: .arrow, start: start, end: i)); continue }
            i += 1
            switch c {
            case "(": out.append(ExprTok(kind: .lparen, start: start, end: i))
            case ")": out.append(ExprTok(kind: .rparen, start: start, end: i))
            case "[": out.append(ExprTok(kind: .lbracket, start: start, end: i))
            case "]": out.append(ExprTok(kind: .rbracket, start: start, end: i))
            case ",": out.append(ExprTok(kind: .comma, start: start, end: i))
            case ".": out.append(ExprTok(kind: .dot, start: start, end: i))
            case "<", ">", "!", "+", "-", "*", "/", "%": out.append(ExprTok(kind: .op(String(c)), start: start, end: i))
            case "=": throw fail("assignment is not part of the expression language; use '==' to compare", start)
            case ";", "{", "}", "`", "$", "\\", "@", "#", "&", "|", "?", ":", "^", "~":
                throw fail("unexpected character '\(c)'", start)
            default: throw fail("unexpected character '\(c)'", start)
            }
        }
        out.append(ExprTok(kind: .eof, start: chars.count, end: chars.count))
        return out
    }
}

struct ExpressionParser {
    private let tokens: [ExprTok]
    private let base: Int
    private var p = 0
    private var depth = 0
    private var chained = 0

    static func parse(_ source: String, base: Int = 0) throws -> Expr {
        var parser = ExpressionParser(tokens: try ExpressionLexer(source, base: base).tokenize(), base: base)
        if parser.peek.kind == .eof { throw WorkflowExpressionError(message: "empty expression", offset: base) }
        let e = try parser.expression(0)
        guard parser.peek.kind == .eof else { throw parser.fail("unexpected \(parser.describe(parser.peek.kind))") }
        return e
    }

    private init(tokens: [ExprTok], base: Int) { self.tokens = tokens; self.base = base }

    private var peek: ExprTok { tokens[p] }
    private func peek(_ n: Int) -> ExprToken { p + n < tokens.count ? tokens[p + n].kind : .eof }
    private mutating func advance() -> ExprTok { let t = tokens[p]; if p < tokens.count - 1 { p += 1 }; return t }
    private func fail(_ message: String, at tok: ExprTok? = nil) -> WorkflowExpressionError {
        WorkflowExpressionError(message: message, offset: base + (tok ?? peek).start)
    }
    private func describe(_ k: ExprToken) -> String {
        switch k {
        case .number(let v): return "number \(v.displayString)"
        case .string: return "string literal"
        case .ident(let s): return "'\(s)'"
        case .op(let s): return "'\(s)'"
        case .lparen: return "'('"
        case .rparen: return "')'"
        case .lbracket: return "'['"
        case .rbracket: return "']'"
        case .comma: return "','"
        case .dot: return "'.'"
        case .arrow: return "'=>'"
        case .eof: return "end of expression"
        }
    }
    private mutating func expect(_ k: ExprToken) throws {
        guard peek.kind == k else { throw fail("expected \(describe(k)), found \(describe(peek.kind))") }
        _ = advance()
    }

    private static let precedence: [String: Int] = [
        "||": 1, "&&": 2, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4, "+": 5, "-": 5, "*": 6, "/": 6, "%": 6,
    ]

    private mutating func chain() throws {
        chained += 1
        if chained > ExpressionLimits.maxChainedOperators {
            throw fail("expression has too many chained operators (limit \(ExpressionLimits.maxChainedOperators)); split it into several steps")
        }
    }

    private mutating func nest<T>(_ body: (inout ExpressionParser) throws -> T) throws -> T {
        depth += 1
        defer { depth -= 1 }
        if depth > ExpressionLimits.maxNesting { throw fail("expression is nested too deeply (limit \(ExpressionLimits.maxNesting))") }
        return try body(&self)
    }

    private mutating func expression(_ minPrec: Int) throws -> Expr {
        try nest { s in
            var left = try s.unary()
            while case .op(let op) = s.peek.kind, let prec = Self.precedence[op], prec >= minPrec {
                let tok = s.advance()
                try s.chain()
                let right = try s.expression(prec + 1)
                left = .binary(op, left, right, at: s.base + tok.start)
            }
            return left
        }
    }

    private mutating func unary() throws -> Expr {
        if case .op(let op) = peek.kind, op == "!" || op == "-" {
            let tok = advance()
            return try nest { s in .unary(op, try s.unary(), at: s.base + tok.start) }
        }
        return try postfix(try primary())
    }

    private mutating func postfix(_ start: Expr) throws -> Expr {
        var e = start
        while true {
            switch peek.kind {
            case .dot:
                _ = advance()
                try chain()
                guard case .ident(let name) = peek.kind else { throw fail("expected a property name after '.'") }
                let tok = advance()
                e = .member(e, name, range: (base + tok.start)..<(base + tok.end))
            case .lbracket:
                let tok = advance()
                try chain()
                let idx = try expression(0)
                try expect(.rbracket)
                e = .index(e, idx, at: base + tok.start)
            case .lparen:
                throw fail("only named functions can be called")
            default:
                return e
            }
        }
    }

    private mutating func primary() throws -> Expr {
        let tok = advance()
        switch tok.kind {
        case .number(let v): return .literal(v)
        case .string(let s): return .literal(.string(s))
        case .ident(let name):
            switch name {
            case "true": return .literal(true)
            case "false": return .literal(false)
            case "null": return .literal(.null)
            default: break
            }
            if peek.kind == .lparen {
                _ = advance()
                var args: [Expr] = []
                if peek.kind != .rparen {
                    while true {
                        args.append(try argument())
                        if peek.kind == .comma { _ = advance(); continue }
                        break
                    }
                }
                try expect(.rparen)
                return .call(name, args, at: base + tok.start)
            }
            return .name(name, at: base + tok.start)
        case .lparen:
            let e = try expression(0)
            try expect(.rparen)
            return e
        case .lbracket:
            var items: [Expr] = []
            if peek.kind != .rbracket {
                while true {
                    items.append(try expression(0))
                    if peek.kind == .comma { _ = advance(); continue }
                    break
                }
            }
            try expect(.rbracket)
            return .array(items)
        case .arrow: throw fail("a lambda (x => …) is only allowed as a function argument", at: tok)
        default: throw fail("unexpected \(describe(tok.kind))", at: tok)
        }
    }

    /// A function argument: an expression, or a lambda `x => expr` / `(a, b) => expr`.
    private mutating func argument() throws -> Expr {
        if case .ident(let name) = peek.kind, peek(1) == .arrow {
            _ = advance(); _ = advance()
            return .lambda([name], try expression(0))
        }
        if peek.kind == .lparen {
            var names: [String] = []
            var n = 1
            var isLambda = false
            while true {
                guard case .ident(let name) = peek(n) else { break }
                names.append(name)
                if peek(n + 1) == .comma { n += 2; continue }
                if peek(n + 1) == .rparen, peek(n + 2) == .arrow { isLambda = true; n += 3 }
                break
            }
            if isLambda {
                for _ in 0..<n { _ = advance() }
                return .lambda(names, try expression(0))
            }
        }
        return try expression(0)
    }
}

// MARK: - Templates

enum TemplateSegment {
    case text(String)
    /// `offset` is the character offset of the expression source inside the template.
    case expression(String, offset: Int)
}

enum ExpressionTemplate {
    static func segments(_ template: String) throws -> [TemplateSegment] {
        let chars = Array(template)
        var out: [TemplateSegment] = []
        var text = ""
        var i = 0
        func at(_ j: Int, _ s: String) -> Bool {
            let a = Array(s)
            guard j + a.count <= chars.count else { return false }
            return Array(chars[j..<j + a.count]) == a
        }
        while i < chars.count {
            if at(i, "$${{") { text += "${{"; i += 4; continue }
            if at(i, "${{") {
                var j = i + 3
                var quote: Character?
                var end: Int?
                while j < chars.count {
                    let c = chars[j]
                    if let q = quote {
                        if c == "\\" { j += 2; continue }
                        if c == q { quote = nil }
                    } else if c == "'" || c == "\"" { quote = c }
                    else if c == "}", j + 1 < chars.count, chars[j + 1] == "}" { end = j; break }
                    j += 1
                }
                guard let end else { throw WorkflowExpressionError(message: "unterminated '${{' (missing '}}')", offset: i) }
                if !text.isEmpty { out.append(.text(text)); text = "" }
                out.append(.expression(String(chars[i + 3..<end]), offset: i + 3))
                i = end + 2
                continue
            }
            text.append(chars[i]); i += 1
        }
        if !text.isEmpty { out.append(.text(text)) }
        return out
    }
}

// MARK: - Static analysis

/// What an expression (or template) refers to, found without evaluating it.
public struct ExpressionReferences: Sendable, Hashable {
    public var steps: Set<String> = []
    public var parameters: Set<String> = []
    public var variables: Set<String> = []
    public var secrets: Set<String> = []
    public var environment: Set<String> = []
    public var functions: Set<String> = []
    /// Bare names that are neither a root (`params`, `vars`, `steps`, `env`) nor bound by a lambda: loop variables.
    public var freeNames: Set<String> = []
    /// Source ranges (character offsets) of step ids, for renaming.
    var stepRanges: [(id: String, range: Range<Int>)] = []

    public static func == (a: ExpressionReferences, b: ExpressionReferences) -> Bool {
        a.steps == b.steps && a.parameters == b.parameters && a.variables == b.variables && a.secrets == b.secrets
            && a.environment == b.environment && a.functions == b.functions && a.freeNames == b.freeNames
    }
    public func hash(into h: inout Hasher) { h.combine(steps); h.combine(parameters); h.combine(variables); h.combine(secrets) }

    mutating func collect(_ e: Expr, bound: Set<String> = []) {
        switch e {
        case .literal: break
        case .name(let n, _):
            if !bound.contains(n), !["params", "vars", "steps", "env"].contains(n) { freeNames.insert(n) }
        case .member(let b, let name, let range):
            if case .name(let root, _) = b, !bound.contains(root) {
                switch root {
                case "steps": steps.insert(name); stepRanges.append((name, range))
                case "params": parameters.insert(name)
                case "vars": variables.insert(name)
                case "env": environment.insert(name)
                default: break
                }
            }
            collect(b, bound: bound)
        case .index(let b, let i, _):
            if case .name(let root, _) = b, !bound.contains(root), case .literal(.string(let key)) = i {
                switch root {
                case "steps": steps.insert(key)
                case "params": parameters.insert(key)
                case "vars": variables.insert(key)
                case "env": environment.insert(key)
                default: break
                }
            }
            collect(b, bound: bound); collect(i, bound: bound)
        case .call(let name, let args, _):
            functions.insert(name)
            if name == "secret", args.count == 1, case .literal(.string(let ref)) = args[0] { secrets.insert(ref) }
            for a in args { collect(a, bound: bound) }
        case .unary(_, let x, _): collect(x, bound: bound)
        case .binary(_, let l, let r, _): collect(l, bound: bound); collect(r, bound: bound)
        case .array(let items): for i in items { collect(i, bound: bound) }
        case .lambda(let params, let body): collect(body, bound: bound.union(params))
        }
    }
}
