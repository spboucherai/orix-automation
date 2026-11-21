// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/ExpressionEvaluator.swift
// Description      : Evaluation of expressions and `${{ … }}` templates: pure
//                    functions only, bounded work and output, single-pass
//                    interpolation.
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

/// Everything an expression can see. Nothing else is reachable: no files, no network, no process environment.
public struct ExpressionContext: Sendable {
    public var params: [String: JSONValue]
    public var vars: [String: JSONValue]
    /// Step views keyed by id: `{status, output, error}`.
    public var steps: [String: JSONValue]
    /// Loop variables (`item`, `index`, `loop`, `error`, or the name given by `as:`).
    public var locals: [String: JSONValue]
    /// Values behind `env.<NAME>`; only names of `WorkflowExpression.environmentAllowlist` are readable.
    public var environment: [String: String]
    public var now: Date
    public var timeZone: TimeZone

    public init(params: [String: JSONValue] = [:], vars: [String: JSONValue] = [:], steps: [String: JSONValue] = [:],
                locals: [String: JSONValue] = [:], environment: [String: String]? = nil, now: Date = Date(), timeZone: TimeZone = .current) {
        self.params = params; self.vars = vars; self.steps = steps; self.locals = locals
        self.now = now; self.timeZone = timeZone
        self.environment = environment ?? WorkflowExpression.defaultEnvironment(now: now, timeZone: timeZone)
    }
}

public enum WorkflowExpression {
    public static let environmentAllowlist: Set<String> = ["HOME", "USER", "TMPDIR", "DATE", "TIME", "DATETIME", "TIMESTAMP"]

    public static let functionNames: [String] = [
        "len", "contains", "startsWith", "endsWith", "lower", "upper", "trim", "split", "join", "replace", "basename", "dirname",
        "extname", "joinPath", "toJSON", "fromJSON", "number", "string", "default", "keys", "values", "map", "filter", "reduce",
        "count", "sum", "first", "last", "slice", "now", "formatDate", "secret",
    ]

    /// Key of the opaque placeholder object produced by `secret("ref")`: `{"$secret": "ref"}`. Never a secret value.
    public static let secretPlaceholderKey = "$secret"

    public static func defaultEnvironment(now: Date = Date(), timeZone: TimeZone = .current) -> [String: String] {
        func format(_ pattern: String) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = pattern
            return f.string(from: now)
        }
        return [
            "HOME": NSHomeDirectory(), "USER": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
            "DATE": format("yyyy-MM-dd"), "TIME": format("HH:mm:ss"), "DATETIME": format("yyyy-MM-dd'T'HH:mm:ssXXXXX"),
            "TIMESTAMP": String(Int(now.timeIntervalSince1970)),
        ]
    }

    /// Evaluates a bare expression such as `len(steps.list.output.entries) > 0`.
    public static func evaluate(_ source: String, context: ExpressionContext) throws -> JSONValue {
        var evaluator = ExpressionEvaluator(context: context)
        return try evaluator.eval(try ExpressionParser.parse(source))
    }

    /// Interpolates `${{ … }}`. A string that is exactly one interpolation yields the typed value; otherwise a string.
    /// Single pass: text produced by an expression is data and is never scanned for `${{` again.
    public static func interpolate(_ template: String, context: ExpressionContext) throws -> JSONValue {
        guard template.contains("${{") else { return .string(template) }
        let segments = try ExpressionTemplate.segments(template)
        if segments.count == 1, case .expression(let src, let offset) = segments[0] {
            var evaluator = ExpressionEvaluator(context: context)
            return try evaluator.eval(try ExpressionParser.parse(src, base: offset))
        }
        var out = ""
        for s in segments {
            switch s {
            case .text(let t): out += t
            case .expression(let src, let offset):
                var evaluator = ExpressionEvaluator(context: context)
                out += try evaluator.eval(try ExpressionParser.parse(src, base: offset)).displayString
            }
            if out.utf8.count > ExpressionLimits.maxStringBytes {
                throw WorkflowExpressionError(message: "interpolated text is larger than \(ExpressionLimits.maxStringBytes) bytes")
            }
        }
        return .string(out)
    }

    /// For fields that hold an expression (`when`, `if`, `while`, `switch`, `foreach`, `transform`): the text is a
    /// template when it contains `${{`, else a bare expression.
    public static func evaluateField(_ text: String, context: ExpressionContext) throws -> JSONValue {
        text.contains("${{") ? try interpolate(text, context: context) : try evaluate(text, context: context)
    }

    /// Interpolates every string inside a JSON value (object keys are left alone).
    public static func resolve(_ value: JSONValue, context: ExpressionContext) throws -> JSONValue {
        switch value {
        case .string(let s): return try interpolate(s, context: context)
        case .array(let a): return .array(try a.map { try resolve($0, context: context) })
        case .object(let o): return .object(try o.mapValues { try resolve($0, context: context) })
        default: return value
        }
    }

    /// Syntax check without evaluation. Empty means the text parses.
    public static func syntaxErrors(in text: String, isExpressionField: Bool) -> [WorkflowExpressionError] {
        do { _ = try parsed(text, isExpressionField: isExpressionField); return [] }
        catch let e as WorkflowExpressionError { return [e] }
        catch { return [WorkflowExpressionError(message: "\(error)")] }
    }

    /// Names an expression or template refers to. Throws on a syntax error.
    public static func references(in text: String, isExpressionField: Bool) throws -> ExpressionReferences {
        var refs = ExpressionReferences()
        for e in try parsed(text, isExpressionField: isExpressionField) { refs.collect(e) }
        return refs
    }

    static func parsed(_ text: String, isExpressionField: Bool) throws -> [Expr] {
        if text.contains("${{") {
            return try ExpressionTemplate.segments(text).compactMap { seg in
                if case .expression(let src, let offset) = seg { return try ExpressionParser.parse(src, base: offset) }
                return nil
            }
        }
        return isExpressionField ? [try ExpressionParser.parse(text)] : []
    }

    /// Rewrites `steps.<old>` references. Text that does not parse is returned unchanged.
    public static func renamingStep(in text: String, from old: String, to new: String, isExpressionField: Bool) -> String {
        guard let refs = try? references(in: text, isExpressionField: isExpressionField) else { return text }
        var edits: [(range: Range<Int>, replacement: [Character])] = refs.stepRanges.filter { $0.id == old }.map { ($0.range, Array(new)) }
        // `steps["old"]` carries no member range in the syntax tree: find the bracket form in the token stream.
        var sources: [(source: String, base: Int)] = []
        if text.contains("${{") {
            for case .expression(let src, let offset) in (try? ExpressionTemplate.segments(text)) ?? [] { sources.append((src, offset)) }
        } else if isExpressionField { sources.append((text, 0)) }
        for (source, base) in sources {
            guard let tokens = try? ExpressionLexer(source).tokenize(), tokens.count >= 4 else { continue }
            let chars = Array(source)
            for i in 0..<(tokens.count - 3) where tokens[i].kind == .ident("steps") && tokens[i + 1].kind == .lbracket
                && tokens[i + 2].kind == .string(old) && tokens[i + 3].kind == .rbracket && (i == 0 || tokens[i - 1].kind != .dot) {
                let quote = chars[tokens[i + 2].start]
                edits.append(((base + tokens[i + 2].start)..<(base + tokens[i + 2].end), [quote] + Array(new) + [quote]))
            }
        }
        var chars = Array(text)
        for e in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { chars.replaceSubrange(e.range, with: e.replacement) }
        return String(chars)
    }
}

struct ExpressionEvaluator {
    let context: ExpressionContext
    private var scopes: [[String: JSONValue]] = []
    private var work = 0

    init(context: ExpressionContext) { self.context = context }

    private func fail(_ message: String, _ at: Int = 0) -> WorkflowExpressionError { WorkflowExpressionError(message: message, offset: at) }

    private func bounded(_ s: String) throws -> JSONValue {
        guard s.utf8.count <= ExpressionLimits.maxStringBytes else { throw fail("result string is larger than \(ExpressionLimits.maxStringBytes) bytes") }
        return .string(s)
    }

    private func bounded(_ a: [JSONValue]) throws -> JSONValue {
        guard a.count <= ExpressionLimits.maxCollectionCount else { throw fail("result list has more than \(ExpressionLimits.maxCollectionCount) elements") }
        return .array(a)
    }

    /// Dispatch only: each case lives in its own small function so that the recursive path keeps a small stack frame
    /// (expressions are evaluated on 512 kB concurrency-pool stacks).
    mutating func eval(_ e: Expr) throws -> JSONValue {
        work += 1
        if work > ExpressionLimits.maxEvaluationSteps { throw budgetExceeded() }
        switch e {
        case .literal(let v): return v
        case .name(let n, let at): return try evalName(n, at)
        case .member, .index: return try evalPostfix(e)
        case .unary(let op, let x, let at): return try evalUnary(op, x, at)
        case .binary: return try evalBinary(e)
        case .array(let items): return try bounded(try evalAll(items))
        case .lambda: throw fail("a lambda can only be passed to map, filter, reduce, count or sum")
        case .call(let name, let args, let at): return try call(name, args, at)
        }
    }

    private func budgetExceeded() -> WorkflowExpressionError {
        fail("expression exceeded the evaluation budget (\(ExpressionLimits.maxEvaluationSteps) operations)")
    }

    private mutating func evalAll(_ items: [Expr]) throws -> [JSONValue] {
        var out: [JSONValue] = []
        out.reserveCapacity(items.count)
        for item in items { out.append(try eval(item)) }
        return out
    }

    private func evalName(_ n: String, _ at: Int) throws -> JSONValue {
        for s in scopes.reversed() { if let v = s[n] { return v } }
        if let v = context.locals[n] { return v }
        switch n {
        case "params": return .object(context.params)
        case "vars": return .object(context.vars)
        case "steps": return .object(context.steps)
        case "env":
            return .object(context.environment.filter { WorkflowExpression.environmentAllowlist.contains($0.key) }.mapValues(JSONValue.string))
        default: throw fail("unknown name '\(n)'", at)
        }
    }

    /// `a.b[c].d` chains are unwound iteratively: a long chain costs heap, not stack depth.
    private mutating func evalPostfix(_ e: Expr) throws -> JSONValue {
        var links: [Expr] = []
        var node = e
        while true {
            if case .member(let b, _, _) = node { links.append(node); node = b }
            else if case .index(let b, _, _) = node { links.append(node); node = b }
            else { break }
        }
        work += links.count
        if work > ExpressionLimits.maxEvaluationSteps { throw budgetExceeded() }
        var acc = try eval(node)
        for link in links.reversed() {
            if case .member(let b, let name, let range) = link {
                acc = try access(acc, key: name, root: rootName(b), at: range.lowerBound)
            } else if case .index(let b, let i, let at) = link {
                let idx = try eval(i)
                acc = try index(acc, idx, root: rootName(b), at)
            }
        }
        return acc
    }

    private func index(_ base: JSONValue, _ idx: JSONValue, root: String?, _ at: Int) throws -> JSONValue {
        switch (base, idx) {
        case (.array(let a), _):
            guard let n = idx.intValue else { throw fail("a list index must be an integer", at) }
            let k = n < 0 ? a.count + n : n
            return a.indices.contains(k) ? a[k] : .null
        case (.string(let s), _):
            guard let n = idx.intValue else { throw fail("a string index must be an integer", at) }
            let chars = Array(s)
            let k = n < 0 ? chars.count + n : n
            return chars.indices.contains(k) ? .string(String(chars[k])) : .null
        case (_, .string(let key)): return try access(base, key: key, root: root, at: at)
        case (.null, _): return .null
        default: throw fail("cannot index \(typeName(base)) with \(typeName(idx))", at)
        }
    }

    private mutating func evalUnary(_ op: String, _ x: Expr, _ at: Int) throws -> JSONValue {
        let v = try eval(x)
        if op == "!" { return .bool(!v.isTruthy) }
        switch v {
        case .int(let i):
            let (r, o) = (0).subtractingReportingOverflow(i)
            return o ? .number(-Double(i)) : .int(r)
        case .number(let d): return .number(-d)
        default: throw fail("cannot negate \(typeName(v))", at)
        }
    }

    /// Operators of equal precedence parse into a left-deep tree; it is folded iteratively so that `a + b + c + …`
    /// does not recurse once per operator. `&&` and `||` keep their short-circuit behaviour.
    private mutating func evalBinary(_ e: Expr) throws -> JSONValue {
        var links: [Expr] = []
        var node = e
        while case .binary(_, let l, _, _) = node { links.append(node); node = l }
        work += links.count
        if work > ExpressionLimits.maxEvaluationSteps { throw budgetExceeded() }
        var acc = try eval(node)
        for link in links.reversed() {
            guard case .binary(let op, _, let r, let at) = link else { continue }
            switch op {
            case "&&": acc = acc.isTruthy ? .bool(try eval(r).isTruthy) : .bool(false)
            case "||": acc = acc.isTruthy ? .bool(true) : .bool(try eval(r).isTruthy)
            default:
                let rhs = try eval(r)
                acc = try binary(op, acc, rhs, at)
            }
        }
        return acc
    }

    private func rootName(_ e: Expr) -> String? {
        if case .name(let n, _) = e, !scopes.contains(where: { $0[n] != nil }), context.locals[n] == nil { return n }
        return nil
    }

    private func typeName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool: return "a boolean"
        case .int, .number: return "a number"
        case .string: return "a string"
        case .array: return "a list"
        case .object: return "an object"
        }
    }

    /// Property access. Missing properties are null, except unknown steps, parameters and environment names, which are errors.
    private func access(_ base: JSONValue, key: String, root: String?, at: Int) throws -> JSONValue {
        switch base {
        case .object(let o):
            if let v = o[key] { return v }
            switch root {
            case "steps": throw fail("unknown step '\(key)' (not defined, or not visible from this step)", at)
            case "params": throw fail("unknown parameter '\(key)'", at)
            case "env": throw fail("'env.\(key)' is not available; allowed names: \(WorkflowExpression.environmentAllowlist.sorted().joined(separator: ", "))", at)
            default: return .null
            }
        case .array(let a):
            if let i = Int(key) { return a.indices.contains(i) ? a[i] : .null }
            if key == "length" { return .int(a.count) }
            return .null
        case .null: return .null
        default: return .null
        }
    }

    private func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.int, .number), (.number, .int): return a.doubleValue == b.doubleValue
        default: return a == b
        }
    }

    private func binary(_ op: String, _ a: JSONValue, _ b: JSONValue, _ at: Int) throws -> JSONValue {
        switch op {
        case "==": return .bool(equal(a, b))
        case "!=": return .bool(!equal(a, b))
        case "<", "<=", ">", ">=":
            let order: Int
            if let x = a.doubleValue, let y = b.doubleValue { order = x < y ? -1 : (x > y ? 1 : 0) }
            else if case .string(let x) = a, case .string(let y) = b { order = x < y ? -1 : (x > y ? 1 : 0) }
            else { throw fail("cannot compare \(typeName(a)) with \(typeName(b)) using '\(op)'", at) }
            switch op {
            case "<": return .bool(order < 0)
            case "<=": return .bool(order <= 0)
            case ">": return .bool(order > 0)
            default: return .bool(order >= 0)
            }
        case "+":
            if case .array(let x) = a, case .array(let y) = b { return try bounded(x + y) }
            if case .string = a { return try bounded(a.displayString + b.displayString) }
            if case .string = b { return try bounded(a.displayString + b.displayString) }
            fallthrough
        default:
            if case .int(let x) = a, case .int(let y) = b {
                switch op {
                case "+": let (r, o) = x.addingReportingOverflow(y); if !o { return .int(r) }
                case "-": let (r, o) = x.subtractingReportingOverflow(y); if !o { return .int(r) }
                case "*": let (r, o) = x.multipliedReportingOverflow(by: y); if !o { return .int(r) }
                case "/":
                    guard y != 0 else { throw fail("division by zero", at) }
                    if x % y == 0, !(x == .min && y == -1) { return .int(x / y) }
                case "%":
                    guard y != 0 else { throw fail("division by zero", at) }
                    return y == -1 ? .int(0) : .int(x % y)
                default: break
                }
            }
            guard let x = a.doubleValue, let y = b.doubleValue else {
                throw fail("operator '\(op)' needs numbers, got \(typeName(a)) and \(typeName(b))", at)
            }
            switch op {
            case "+": return .number(x + y)
            case "-": return .number(x - y)
            case "*": return .number(x * y)
            case "/":
                guard y != 0 else { throw fail("division by zero", at) }
                return .number(x / y)
            case "%":
                guard y != 0 else { throw fail("division by zero", at) }
                return .number(x.truncatingRemainder(dividingBy: y))
            default: throw fail("unknown operator '\(op)'", at)
            }
        }
    }

    // MARK: Functions

    private mutating func apply(_ fn: Expr, _ args: [JSONValue]) throws -> JSONValue {
        if case .lambda(let params, let body) = fn {
            guard params.count <= args.count else { throw fail("the lambda takes \(params.count) arguments but \(args.count) are available") }
            scopes.append(Dictionary(zip(params, args), uniquingKeysWith: { _, l in l }))
            defer { scopes.removeLast() }
            return try eval(body)
        }
        // A string selects a property path of each element: map(items, "name").
        guard case .string(let path) = try eval(fn) else { throw fail("expected a lambda (x => …) or a property path string") }
        return args.first?.value(atPath: path) ?? .null
    }

    private mutating func call(_ name: String, _ argExprs: [Expr], _ at: Int) throws -> JSONValue {
        if let v = try higherOrder(name, argExprs, at) { return v }
        let args = try evalAll(argExprs)
        return try builtin(name, args, at)
    }

    private func checkArity(_ name: String, _ count: Int, _ range: ClosedRange<Int>, _ at: Int) throws {
        guard range.contains(count) else {
            let want = range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound) to \(range.upperBound)"
            throw fail("\(name)() takes \(want) argument\(range.upperBound == 1 ? "" : "s"), got \(count)", at)
        }
    }

    private func listArgument(_ name: String, _ v: JSONValue, _ at: Int) throws -> [JSONValue] {
        if case .null = v { return [] }
        guard case .array(let a) = v else { throw fail("\(name)() expects a list, got \(typeName(v))", at) }
        return a
    }

    /// Functions that keep an argument unevaluated (lambdas, `secret`'s literal, `default`'s lazy alternatives). Nil for the others.
    private mutating func higherOrder(_ name: String, _ argExprs: [Expr], _ at: Int) throws -> JSONValue? {
        func arity(_ range: ClosedRange<Int>) throws { try checkArity(name, argExprs.count, range, at) }
        func list(_ v: JSONValue) throws -> [JSONValue] { try listArgument(name, v, at) }
        // Higher-order functions keep their function argument unevaluated.
        switch name {
        case "map":
            try arity(2...2)
            let items = try list(try eval(argExprs[0]))
            var out: [JSONValue] = []
            for (i, x) in items.enumerated() { out.append(try apply(argExprs[1], [x, .int(i)])) }
            return try bounded(out)
        case "filter":
            try arity(2...2)
            let items = try list(try eval(argExprs[0]))
            var out: [JSONValue] = []
            for (i, x) in items.enumerated() where try apply(argExprs[1], [x, .int(i)]).isTruthy { out.append(x) }
            return .array(out)
        case "reduce":
            try arity(3...3)
            let items = try list(try eval(argExprs[0]))
            guard case .lambda(let params, _) = argExprs[1], params.count == 2 else {
                throw fail("reduce() expects a two-argument lambda: reduce(list, (acc, x) => …, initial)", at)
            }
            var acc = try eval(argExprs[2])
            for x in items { acc = try apply(argExprs[1], [acc, x]) }
            return acc
        case "count":
            try arity(1...2)
            let items = try list(try eval(argExprs[0]))
            if argExprs.count == 1 { return .int(items.count) }
            var n = 0
            for (i, x) in items.enumerated() where try apply(argExprs[1], [x, .int(i)]).isTruthy { n += 1 }
            return .int(n)
        case "sum":
            try arity(1...2)
            let items = try list(try eval(argExprs[0]))
            var total: JSONValue = .int(0)
            for (i, x) in items.enumerated() {
                let v = argExprs.count == 2 ? try apply(argExprs[1], [x, .int(i)]) : x
                guard v.doubleValue != nil else { throw fail("sum() expects numbers, got \(typeName(v))", at) }
                total = try binary("+", total, v, at)
            }
            return total
        case "secret":
            try arity(1...1)
            guard case .literal(.string(let ref)) = argExprs[0], !ref.isEmpty else {
                throw fail("secret() takes one literal reference name, for example secret(\"smtp-password\")", at)
            }
            return .object([WorkflowExpression.secretPlaceholderKey: .string(ref)])
        case "default":
            guard !argExprs.isEmpty else { throw fail("default() needs at least one argument", at) }
            for a in argExprs { let v = try eval(a); if !v.isNull { return v } }
            return .null
        default: return nil
        }
    }

    /// Pure functions over already evaluated arguments.
    private func builtin(_ name: String, _ args: [JSONValue], _ at: Int) throws -> JSONValue {
        func arity(_ range: ClosedRange<Int>) throws { try checkArity(name, args.count, range, at) }
        func str(_ v: JSONValue, _ what: String = "a string") throws -> String {
            guard case .string(let s) = v else { throw fail("\(name)() expects \(what), got \(typeName(v))", at) }
            return s
        }
        func list(_ v: JSONValue) throws -> [JSONValue] { try listArgument(name, v, at) }
        switch name {
        case "len":
            try arity(1...1)
            switch args[0] {
            case .string(let s): return .int(s.count)
            case .array(let a): return .int(a.count)
            case .object(let o): return .int(o.count)
            case .null: return .int(0)
            default: throw fail("len() expects a string, list or object, got \(typeName(args[0]))", at)
            }
        case "contains":
            try arity(2...2)
            switch args[0] {
            case .string(let s): return .bool(s.contains(try str(args[1], "a string to search for")))
            case .array(let a): return .bool(a.contains { equal($0, args[1]) })
            case .object(let o): return .bool(o[try str(args[1], "a key")] != nil)
            case .null: return .bool(false)
            default: throw fail("contains() expects a string, list or object, got \(typeName(args[0]))", at)
            }
        case "startsWith": try arity(2...2); return .bool(try str(args[0]).hasPrefix(try str(args[1])))
        case "endsWith": try arity(2...2); return .bool(try str(args[0]).hasSuffix(try str(args[1])))
        case "lower": try arity(1...1); return .string(try str(args[0]).lowercased())
        case "upper": try arity(1...1); return .string(try str(args[0]).uppercased())
        case "trim": try arity(1...1); return .string(try str(args[0]).trimmingCharacters(in: .whitespacesAndNewlines))
        case "split":
            try arity(2...2)
            let sep = try str(args[1])
            guard !sep.isEmpty else { throw fail("split() needs a non-empty separator", at) }
            return try bounded(try str(args[0]).components(separatedBy: sep).map(JSONValue.string))
        case "join":
            try arity(1...2)
            let sep = args.count == 2 ? try str(args[1]) : ","
            return try bounded(try list(args[0]).map(\.displayString).joined(separator: sep))
        case "replace":
            try arity(3...3)
            let target = try str(args[1])
            guard !target.isEmpty else { throw fail("replace() needs a non-empty search string", at) }
            return try bounded(try str(args[0]).replacingOccurrences(of: target, with: try str(args[2])))
        case "basename": try arity(1...1); return .string((try str(args[0]) as NSString).lastPathComponent)
        case "dirname": try arity(1...1); return .string((try str(args[0]) as NSString).deletingLastPathComponent)
        case "extname":
            try arity(1...1)
            let ext = (try str(args[0]) as NSString).pathExtension
            return .string(ext.isEmpty ? "" : "." + ext)
        case "joinPath":
            guard !args.isEmpty else { throw fail("joinPath() needs at least one argument", at) }
            var out = ""
            for a in args {
                let part = try str(a)
                if part.isEmpty { continue }
                if out.isEmpty { out = part }
                else { out = (out.hasSuffix("/") ? String(out.dropLast()) : out) + "/" + (part.hasPrefix("/") ? String(part.dropFirst()) : part) }
            }
            return try bounded(out)
        case "toJSON": try arity(1...1); return try bounded(args[0].serialized())
        case "fromJSON":
            try arity(1...1)
            let text = try str(args[0])
            guard text.utf8.count <= ExpressionLimits.maxStringBytes else { throw fail("fromJSON() input is too large", at) }
            do { return try JSONValue.parse(text) } catch { throw fail("fromJSON() could not parse its argument as JSON", at) }
        case "number":
            try arity(1...1)
            switch args[0] {
            case .int, .number: return args[0]
            case .bool(let b): return .int(b ? 1 : 0)
            case .string(let s):
                let t = s.trimmingCharacters(in: .whitespaces)
                if let i = Int(t) { return .int(i) }
                if let d = Double(t), d.isFinite { return .number(d) }
                throw fail("number() cannot convert \"\(s.prefix(40))\"", at)
            default: throw fail("number() cannot convert \(typeName(args[0]))", at)
            }
        case "string": try arity(1...1); return .string(args[0].displayString)
        case "keys":
            try arity(1...1)
            guard case .object(let o) = args[0] else { throw fail("keys() expects an object, got \(typeName(args[0]))", at) }
            return .array(o.keys.sorted().map(JSONValue.string))
        case "values":
            try arity(1...1)
            guard case .object(let o) = args[0] else { throw fail("values() expects an object, got \(typeName(args[0]))", at) }
            return .array(o.keys.sorted().map { o[$0]! })
        case "first": try arity(1...1); return try list(args[0]).first ?? .null
        case "last": try arity(1...1); return try list(args[0]).last ?? .null
        case "slice":
            try arity(2...3)
            guard let start = args[1].intValue, args.count == 2 || args[2].intValue != nil || args[2].isNull else {
                throw fail("slice() bounds must be integers", at)
            }
            func clamp(_ i: Int, _ n: Int) -> Int { max(0, min(n, i < 0 ? n + i : i)) }
            if case .string(let s) = args[0] {
                let chars = Array(s)
                let a = clamp(start, chars.count), b = clamp(args.count == 3 ? (args[2].intValue ?? chars.count) : chars.count, chars.count)
                return .string(a < b ? String(chars[a..<b]) : "")
            }
            let items = try list(args[0])
            let a = clamp(start, items.count), b = clamp(args.count == 3 ? (args[2].intValue ?? items.count) : items.count, items.count)
            return .array(a < b ? Array(items[a..<b]) : [])
        case "now":
            try arity(0...0)
            return .string(ISO8601DateFormatter().string(from: context.now))
        case "formatDate":
            try arity(2...3)
            let date: Date
            switch args[0] {
            case .int, .number: date = Date(timeIntervalSince1970: args[0].doubleValue ?? 0)
            case .string(let s):
                guard let d = Self.parseDate(s, timeZone: context.timeZone) else {
                    throw fail("formatDate() could not read \"\(s.prefix(40))\" as an ISO 8601 date", at)
                }
                date = d
            default: throw fail("formatDate() expects an ISO 8601 string or a Unix timestamp", at)
            }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = context.timeZone
            if args.count == 3 {
                guard let tz = TimeZone(identifier: try str(args[2], "a time zone identifier")) else { throw fail("formatDate(): unknown time zone", at) }
                f.timeZone = tz
            }
            f.dateFormat = try str(args[1], "a date pattern such as \"yyyy-MM-dd\"")
            return .string(f.string(from: date))
        default:
            throw fail("unknown function '\(name)'", at)
        }
    }

    static func parseDate(_ s: String, timeZone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = pattern
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
