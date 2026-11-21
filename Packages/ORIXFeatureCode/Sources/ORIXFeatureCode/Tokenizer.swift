// ORIX OS Automation
// File: Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/Tokenizer.swift
// Description: Line-based syntax tokenizers for YAML, JSON, Python, Bash, AppleScript, Swift and JavaScript, with ${{ … }} workflow expressions inside YAML/JSON strings. Each line is tokenized from a small carried state so edits re-tokenize only what changed.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation

public enum CodeLanguage: String, Sendable, CaseIterable, Identifiable, Codable {
    case yaml, json, python, bash, applescript, swift, javascript
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .yaml: return "YAML"
        case .json: return "JSON"
        case .python: return "Python"
        case .bash: return "Bash"
        case .applescript: return "AppleScript"
        case .swift: return "Swift"
        case .javascript: return "JavaScript"
        }
    }

    /// Soft-tab width: 2 for data formats, 4 for programming languages.
    public var indentWidth: Int {
        switch self {
        case .yaml, .json, .bash, .javascript: return self == .yaml || self == .json ? 2 : 4
        default: return 4
        }
    }

    /// Prefix used by "toggle comment". JSON has no comments.
    public var lineComment: String? {
        switch self {
        case .yaml, .python, .bash: return "#"
        case .applescript: return "--"
        case .swift, .javascript: return "//"
        case .json: return nil
        }
    }
}

public enum TokenKind: UInt8, Sendable, CaseIterable {
    case comment, string, number, keyword, type, key, function, variable, constant, op, punctuation, interpolation, attribute
}

public struct SyntaxToken: Sendable, Hashable {
    /// UTF-16 range in the document.
    public var range: NSRange
    public var kind: TokenKind
    public init(range: NSRange, kind: TokenKind) { self.range = range; self.kind = kind }
}

public struct HeredocMarker: Sendable, Hashable {
    public var delimiter: String
    public var stripTabs: Bool
}

/// What a line leaves open for the next one.
public enum LineState: Sendable, Hashable {
    case normal
    case blockComment(depth: Int)
    /// Inside a string that spans lines; the delimiter that closes it (`"""`, `'''`, `'`, `"`, `` ` ``).
    case string(delimiter: String)
    case heredoc([HeredocMarker])
    /// Inside a YAML `|` / `>` block scalar whose parent key sits at this column.
    case yamlBlock(indent: Int)
}

// MARK: - Characters

private enum Ch {
    static let tab: unichar = 9, cr: unichar = 13, space: unichar = 32, bang: unichar = 33, dq: unichar = 34, hash: unichar = 35
    static let dollar: unichar = 36, sq: unichar = 39, lparen: unichar = 40, rparen: unichar = 41, star: unichar = 42
    static let comma: unichar = 44, dash: unichar = 45, dot: unichar = 46, slash: unichar = 47, colon: unichar = 58, semicolon: unichar = 59
    static let lt: unichar = 60, eq: unichar = 61, gt: unichar = 62, at: unichar = 64, lbrack: unichar = 91, bslash: unichar = 92
    static let rbrack: unichar = 93, underscore: unichar = 95, backtick: unichar = 96, lbrace: unichar = 123, pipe: unichar = 124, rbrace: unichar = 125
    static let plus: unichar = 43, tilde: unichar = 126

    @inline(__always) static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) static func isLetter(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == underscore || c > 127 }
    @inline(__always) static func isWord(_ c: unichar) -> Bool { isLetter(c) || isDigit(c) }
    @inline(__always) static func isSpace(_ c: unichar) -> Bool { c == space || c == tab || c == cr }
    @inline(__always) static func isUpper(_ c: unichar) -> Bool { c >= 65 && c <= 90 }
    @inline(__always) static func isHex(_ c: unichar) -> Bool { isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }
}

private func units(_ s: String) -> [unichar] { Array(s.utf16) }

// MARK: - Scanner

struct LineScanner {
    let c: [unichar]
    let base: Int
    var i = 0
    var tokens: [SyntaxToken] = []
    var n: Int { c.count }

    init(_ line: [unichar], base: Int) { c = line; self.base = base; tokens.reserveCapacity(8) }

    @inline(__always) func at(_ j: Int) -> unichar { j >= 0 && j < c.count ? c[j] : 0 }

    mutating func emit(_ from: Int, _ to: Int, _ kind: TokenKind) {
        guard to > from else { return }
        tokens.append(SyntaxToken(range: NSRange(location: base + from, length: to - from), kind: kind))
    }

    func matches(_ s: [unichar], at j: Int) -> Bool {
        guard j >= 0, j + s.count <= c.count else { return false }
        for k in 0..<s.count where c[j + k] != s[k] { return false }
        return true
    }

    func find(_ s: [unichar], from j: Int, to end: Int? = nil) -> Int? {
        let limit = (end ?? c.count) - s.count
        guard !s.isEmpty, j <= limit else { return nil }
        var k = j
        while k <= limit { if matches(s, at: k) { return k }; k += 1 }
        return nil
    }

    func text(_ from: Int, _ to: Int) -> String { String(utf16CodeUnits: Array(c[from..<to]), count: to - from) }
}

// MARK: - Tokenizer

public enum SyntaxTokenizer {
    /// Tokenizes one line (without its terminator). `offset` is the line's UTF-16 position in the document.
    public static func tokenize(line: [unichar], offset: Int, state: LineState, language: CodeLanguage) -> (tokens: [SyntaxToken], state: LineState) {
        var sc = LineScanner(line, base: offset)
        let out: LineState
        switch language {
        case .yaml: out = yamlLine(&sc, state)
        case .json: out = jsonLine(&sc)
        case .python: out = scriptLine(&sc, state, Specs.python)
        case .bash: out = scriptLine(&sc, state, Specs.bash)
        case .applescript: out = scriptLine(&sc, state, Specs.applescript)
        case .swift: out = scriptLine(&sc, state, Specs.swift)
        case .javascript: out = scriptLine(&sc, state, Specs.javascript)
        }
        return (sc.tokens, out)
    }

    /// Tokenizes a whole document.
    public static func tokenize(_ text: String, language: CodeLanguage) -> [SyntaxToken] {
        let all = Array(text.utf16)
        var out: [SyntaxToken] = []
        var state = LineState.normal
        var start = 0
        var i = 0
        while i <= all.count {
            if i == all.count || all[i] == 10 {
                let r = tokenize(line: Array(all[start..<i]), offset: start, state: state, language: language)
                out.append(contentsOf: r.tokens); state = r.state
                start = i + 1
            }
            i += 1
        }
        return out
    }

    // MARK: Workflow expressions

    static let expressionRoots: Set<String> = ["params", "vars", "steps", "env", "item", "index", "loop", "error"]
    private static let exprOpen = units("${{"), exprClose = units("}}")

    /// Emits `kind` for the text outside `${{ … }}` and expression tokens inside.
    static func emitWithExpressions(_ sc: inout LineScanner, _ from: Int, _ to: Int, _ kind: TokenKind?) {
        var p = from
        while p < to {
            guard let open = sc.find(exprOpen, from: p, to: to) else { break }
            if sc.at(open - 1) == Ch.dollar {   // `$${{` is a literal
                if let kind { sc.emit(p, open + 3, kind) }
                p = open + 3; continue
            }
            if let kind { sc.emit(p, open, kind) }
            sc.emit(open, open + 3, .interpolation)
            let close = sc.find(exprClose, from: open + 3, to: to)
            expression(&sc, open + 3, close ?? to)
            if let close { sc.emit(close, close + 2, .interpolation); p = close + 2 } else { p = to }
        }
        if let kind, p < to { sc.emit(p, to, kind) }
    }

    static func expression(_ sc: inout LineScanner, _ from: Int, _ to: Int) {
        var j = from
        while j < to {
            let ch = sc.c[j]
            if Ch.isSpace(ch) { j += 1; continue }
            if Ch.isDigit(ch) {
                var k = j + 1
                while k < to, Ch.isDigit(sc.c[k]) || sc.c[k] == Ch.dot { k += 1 }
                sc.emit(j, k, .number); j = k; continue
            }
            if ch == Ch.dq || ch == Ch.sq {
                var k = j + 1
                while k < to, sc.c[k] != ch { if sc.c[k] == Ch.bslash { k += 1 }; k += 1 }
                k = min(k + 1, to)
                sc.emit(j, k, .string); j = k; continue
            }
            if Ch.isLetter(ch) {
                var k = j + 1
                let afterDot = sc.at(j - 1) == Ch.dot
                // After `steps.` a name may contain dashes.
                while k < to, Ch.isWord(sc.c[k]) || (afterDot && sc.c[k] == Ch.dash && k + 1 < to && Ch.isWord(sc.c[k + 1])) { k += 1 }
                let word = sc.text(j, k)
                if sc.at(k) == Ch.lparen && !afterDot { sc.emit(j, k, .function) }
                else if word == "true" || word == "false" || word == "null" { sc.emit(j, k, .constant) }
                else if !afterDot && expressionRoots.contains(word) { sc.emit(j, k, .variable) }
                j = k; continue
            }
            switch ch {
            case Ch.plus, Ch.dash, Ch.star, Ch.slash, 37, Ch.eq, Ch.bang, Ch.lt, Ch.gt, 38, Ch.pipe: sc.emit(j, j + 1, .op)
            default: break
            }
            j += 1
        }
    }

    // MARK: YAML

    static func isNumber(_ sc: LineScanner, _ from: Int, _ to: Int) -> Bool {
        var j = from
        if sc.at(j) == Ch.dash || sc.at(j) == Ch.plus { j += 1 }
        guard j < to, Ch.isDigit(sc.c[j]) else { return false }
        if sc.c[j] == 48, j + 1 < to, Ch.isDigit(sc.c[j + 1]) { return false }   // leading zeros are strings
        while j < to, Ch.isDigit(sc.c[j]) { j += 1 }
        if j < to, sc.c[j] == Ch.dot { j += 1; while j < to, Ch.isDigit(sc.c[j]) { j += 1 } }
        if j < to, sc.c[j] == 101 || sc.c[j] == 69 {
            j += 1
            if j < to, sc.c[j] == Ch.dash || sc.c[j] == Ch.plus { j += 1 }
            guard j < to, Ch.isDigit(sc.c[j]) else { return false }
            while j < to, Ch.isDigit(sc.c[j]) { j += 1 }
        }
        return j == to
    }

    private static let yamlConstants: Set<String> = ["null", "Null", "NULL", "~", "true", "True", "TRUE", "false", "False", "FALSE", ".inf", "-.inf", ".nan"]

    static func yamlLine(_ sc: inout LineScanner, _ state: LineState) -> LineState {
        let n = sc.n
        var indent = 0
        while indent < n, sc.c[indent] == Ch.space { indent += 1 }
        var blank = true
        for k in indent..<n where !Ch.isSpace(sc.c[k]) { blank = false; break }
        if case .yamlBlock(let parent) = state {
            if blank { return state }
            if indent > parent { emitWithExpressions(&sc, indent, n, .string); return state }
        }
        if blank { return .normal }
        var i = indent
        if indent == 0, sc.matches(units("---"), at: 0), n == 3 || Ch.isSpace(sc.c[3]) { sc.emit(0, 3, .punctuation); i = 3 }
        var dashColumn: Int?
        while i < n, sc.c[i] == Ch.dash, i + 1 == n || Ch.isSpace(sc.c[i + 1]) {
            sc.emit(i, i + 1, .punctuation); dashColumn = i
            i += 1
            while i < n, sc.c[i] == Ch.space { i += 1 }
        }
        let firstColumn = i
        var sawKey = false
        var lastKey = ""
        var flowDepth = 0
        var block: Int?
        while i < n {
            let ch = sc.c[i]
            if Ch.isSpace(ch) { i += 1; continue }
            if ch == Ch.hash, i == 0 || Ch.isSpace(sc.c[i - 1]) { sc.emit(i, n, .comment); break }
            if ch == Ch.lbrack || ch == Ch.lbrace { flowDepth += 1; sc.emit(i, i + 1, .punctuation); i += 1; continue }
            if ch == Ch.rbrack || ch == Ch.rbrace { flowDepth = max(0, flowDepth - 1); sc.emit(i, i + 1, .punctuation); i += 1; continue }
            if ch == Ch.comma, flowDepth > 0 { sc.emit(i, i + 1, .punctuation); i += 1; continue }
            if ch == Ch.dq || ch == Ch.sq {
                var j = i + 1
                while j < n {
                    if ch == Ch.dq, sc.c[j] == Ch.bslash { j += 2; continue }
                    if sc.c[j] == ch {
                        if ch == Ch.sq, sc.at(j + 1) == Ch.sq { j += 2; continue }
                        break
                    }
                    j += 1
                }
                let end = min(j + 1, n)
                var k = end
                while k < n, sc.c[k] == Ch.space { k += 1 }
                if sc.at(k) == Ch.colon, k + 1 >= n || Ch.isSpace(sc.c[k + 1]) || flowDepth > 0 {
                    sc.emit(i, end, .key); sc.emit(k, k + 1, .punctuation)
                    lastKey = sc.text(min(i + 1, end), max(i + 1, end - 1)); sawKey = true
                    i = k + 1
                } else {
                    emitWithExpressions(&sc, i, end, .string); i = end
                }
                continue
            }
            if ch == Ch.pipe || ch == Ch.gt {
                // Block scalar indicator: `|`, `>`, with optional chomping/indent, then nothing but a comment.
                var j = i + 1
                var extras = 0
                while j < n, extras < 2, sc.c[j] == Ch.dash || sc.c[j] == Ch.plus || Ch.isDigit(sc.c[j]) { j += 1; extras += 1 }
                var k = j
                while k < n, Ch.isSpace(sc.c[k]) { k += 1 }
                if k == n || sc.c[k] == Ch.hash {
                    sc.emit(i, j, .punctuation)
                    if k < n { sc.emit(k, n, .comment) }
                    block = sawKey ? firstColumn : (dashColumn ?? max(0, indent - 1))
                    break
                }
            }
            // Plain scalar, possibly a key.
            var j = i
            var isKey = false
            while j < n {
                let cj = sc.c[j]
                if cj == Ch.dollar, sc.matches(exprOpen, at: j) {
                    j = (sc.find(exprClose, from: j + 3).map { $0 + 2 }) ?? n; continue
                }
                if cj == Ch.colon, j + 1 >= n || Ch.isSpace(sc.c[j + 1]) { isKey = true; break }
                if cj == Ch.hash, j > 0, Ch.isSpace(sc.c[j - 1]) { break }
                if flowDepth > 0, cj == Ch.comma || cj == Ch.rbrack || cj == Ch.rbrace { break }
                j += 1
            }
            var end = j
            while end > i, Ch.isSpace(sc.c[end - 1]) { end -= 1 }
            if isKey {
                sc.emit(i, end, .key); sc.emit(j, j + 1, .punctuation)
                lastKey = sc.text(i, end); sawKey = true
                i = j + 1
            } else {
                if end > i {
                    let word = sc.text(i, end)
                    if isNumber(sc, i, end) { sc.emit(i, end, .number) }
                    else if yamlConstants.contains(word) { sc.emit(i, end, .constant) }
                    else if lastKey == "tool" || lastKey == "agent" || lastKey == "subworkflow" { emitWithExpressions(&sc, i, end, .function) }
                    else { emitWithExpressions(&sc, i, end, nil) }
                }
                i = max(j, i + 1)
            }
        }
        if let block { return .yamlBlock(indent: block) }
        return .normal
    }

    // MARK: JSON

    static func jsonLine(_ sc: inout LineScanner) -> LineState {
        let n = sc.n
        var i = 0
        while i < n {
            let ch = sc.c[i]
            if Ch.isSpace(ch) { i += 1; continue }
            if ch == Ch.dq {
                var j = i + 1
                while j < n, sc.c[j] != Ch.dq { if sc.c[j] == Ch.bslash { j += 1 }; j += 1 }
                let end = min(j + 1, n)
                var k = end
                while k < n, Ch.isSpace(sc.c[k]) { k += 1 }
                if sc.at(k) == Ch.colon { sc.emit(i, end, .key) } else { emitWithExpressions(&sc, i, end, .string) }
                i = end; continue
            }
            if Ch.isDigit(ch) || (ch == Ch.dash && Ch.isDigit(sc.at(i + 1))) {
                var j = i + 1
                while j < n, Ch.isDigit(sc.c[j]) || sc.c[j] == Ch.dot || sc.c[j] == 101 || sc.c[j] == 69 || sc.c[j] == Ch.plus || sc.c[j] == Ch.dash { j += 1 }
                sc.emit(i, j, .number); i = j; continue
            }
            if Ch.isLetter(ch) {
                var j = i + 1
                while j < n, Ch.isWord(sc.c[j]) { j += 1 }
                let w = sc.text(i, j)
                if w == "true" || w == "false" || w == "null" { sc.emit(i, j, .constant) }
                i = j; continue
            }
            switch ch {
            case Ch.lbrace, Ch.rbrace, Ch.lbrack, Ch.rbrack, Ch.comma, Ch.colon: sc.emit(i, i + 1, .punctuation)
            default: break
            }
            i += 1
        }
        return .normal
    }

    // MARK: Programming languages

    struct Spec {
        var keywords: Set<String>
        var builtins: Set<String> = []
        var constants: Set<String> = []
        var lineComments: [[unichar]]
        /// `#` starts a comment only at the start of a word (Bash) or of the line (AppleScript).
        var hashNeedsBoundary = false
        var hashOnlyAtLineStart = false
        var blockOpen: [unichar] = []
        var blockClose: [unichar] = []
        var blockNests = false
        var quotes: Set<unichar>
        var multilineQuotes: Set<unichar> = []
        /// Quotes without backslash escapes (Bash single quotes).
        var rawQuotes: Set<unichar> = []
        var tripleQuotes = false
        var stringPrefixes = false
        var dollarVariables = false
        var heredocs = false
        var capitalizedTypes = false
        var atAttributes = false
        var hashDirectives = false
        var caseInsensitive = false
        var regexLiterals = false
        var swiftInterpolation = false
        var definitions: [String: TokenKind] = [:]
    }

    enum Specs {
        static let python = Spec(
            keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from",
                       "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case"],
            builtins: ["print", "len", "range", "open", "str", "int", "float", "bool", "list", "dict", "set", "tuple", "enumerate", "zip", "map", "filter", "sorted",
                       "sum", "min", "max", "abs", "any", "all", "isinstance", "type", "repr", "input", "super", "getattr", "setattr", "hasattr", "round", "reversed", "iter", "next"],
            constants: ["True", "False", "None", "self", "cls"],
            lineComments: [units("#")], quotes: [Ch.dq, Ch.sq], tripleQuotes: true, stringPrefixes: true, atAttributes: true,
            definitions: ["def": .function, "class": .type])

        static let bash = Spec(
            keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "in", "select", "return", "exit",
                       "local", "export", "readonly", "declare", "set", "unset", "shift", "break", "continue", "trap", "time"],
            builtins: ["echo", "printf", "cd", "pwd", "read", "test", "source", "eval", "exec", "command", "type", "wait", "kill", "true", "false", "mkdir", "rm",
                       "cp", "mv", "ls", "cat", "grep", "sed", "awk", "find", "sort", "uniq", "wc", "head", "tail", "cut", "tr", "xargs", "date", "basename", "dirname",
                       "touch", "chmod", "curl", "tee", "sleep", "env", "which"],
            lineComments: [units("#")], hashNeedsBoundary: true, quotes: [Ch.dq, Ch.sq, Ch.backtick], multilineQuotes: [Ch.dq, Ch.sq, Ch.backtick],
            rawQuotes: [Ch.sq], dollarVariables: true, heredocs: true, definitions: ["function": .function])

        static let applescript = Spec(
            keywords: ["tell", "end", "if", "then", "else", "repeat", "set", "to", "of", "on", "return", "try", "error", "with", "without", "considering",
                       "ignoring", "property", "script", "global", "local", "copy", "exit", "times", "while", "until", "from", "by", "in", "is", "not", "and",
                       "or", "as", "my", "me", "it", "its", "the", "application", "using", "terms", "timeout", "transaction", "get", "every", "whose", "where",
                       "contains", "equals", "greater", "less", "than", "does", "thru", "through", "into", "after", "before", "back", "front", "div", "mod", "ref",
                       "reference", "a", "an", "put", "given", "use", "framework", "scripting", "additions"],
            builtins: ["display", "dialog", "notification", "activate", "launch", "quit", "open", "close", "count", "exists", "make", "delete", "duplicate",
                       "move", "run", "log", "delay", "say", "beep", "choose", "do", "shell", "path", "length", "item", "items", "text", "date", "current",
                       "string", "integer", "real", "list", "record", "boolean", "number", "name", "class", "result"],
            constants: ["true", "false", "missing", "value", "null", "pi", "return", "tab", "space", "quote", "linefeed"],
            lineComments: [units("--"), units("#")], hashOnlyAtLineStart: true, blockOpen: units("(*"), blockClose: units("*)"), blockNests: true,
            quotes: [Ch.dq], caseInsensitive: true, definitions: ["on": .function])

        static let swift = Spec(
            keywords: ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do",
                       "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "indirect", "init", "inout",
                       "internal", "is", "lazy", "let", "mutating", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat",
                       "rethrows", "return", "some", "static", "struct", "subscript", "switch", "throw", "throws", "try", "typealias", "var", "weak", "where", "while"],
            builtins: ["print", "debugPrint", "fatalError", "precondition", "assert", "min", "max", "abs", "zip", "stride", "exit"],
            constants: ["true", "false", "nil", "self", "Self", "super"],
            lineComments: [units("//")], blockOpen: units("/*"), blockClose: units("*/"), blockNests: true, quotes: [Ch.dq], tripleQuotes: true,
            capitalizedTypes: true, atAttributes: true, hashDirectives: true, swiftInterpolation: true,
            definitions: ["func": .function, "class": .type, "struct": .type, "enum": .type, "protocol": .type, "actor": .type, "extension": .type, "typealias": .type])

        static let javascript = Spec(
            keywords: ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends",
                       "finally", "for", "function", "if", "import", "in", "instanceof", "let", "new", "of", "return", "static", "switch", "throw", "try", "typeof",
                       "var", "void", "while", "with", "yield", "from"],
            builtins: ["print", "console", "JSON", "Math", "Object", "Array", "String", "Number", "Boolean", "Date", "Promise", "Map", "Set", "RegExp", "Error",
                       "parseInt", "parseFloat", "isNaN", "Application", "ObjC", "Path", "Library", "delay", "readFile", "require"],
            constants: ["true", "false", "null", "undefined", "this", "super", "NaN", "Infinity", "arguments"],
            lineComments: [units("//")], blockOpen: units("/*"), blockClose: units("*/"), quotes: [Ch.dq, Ch.sq, Ch.backtick], multilineQuotes: [Ch.backtick],
            regexLiterals: true, definitions: ["function": .function, "class": .type])
    }

    /// Finds the end (index after the closing delimiter) of a string body starting at `j`, or nil when it stays open.
    private static func closeString(_ sc: LineScanner, from start: Int, delimiter: [unichar], raw: Bool, swiftInterpolation: Bool = false) -> Int? {
        var j = start
        let n = sc.n
        while j < n {
            let ch = sc.c[j]
            if !raw, ch == Ch.bslash {
                if swiftInterpolation, sc.at(j + 1) == Ch.lparen {
                    var depth = 1
                    j += 2
                    while j < n, depth > 0 {
                        let cj = sc.c[j]
                        if cj == Ch.lparen { depth += 1 }
                        else if cj == Ch.rparen { depth -= 1 }
                        else if cj == Ch.dq {
                            j += 1
                            while j < n, sc.c[j] != Ch.dq { if sc.c[j] == Ch.bslash { j += 1 }; j += 1 }
                        }
                        j += 1
                    }
                    continue
                }
                j += 2; continue
            }
            if ch == delimiter[0], sc.matches(delimiter, at: j) { return j + delimiter.count }
            j += 1
        }
        return nil
    }

    /// Emits a Bash double-quoted string, colouring `$name` and `${…}` inside it.
    private static func emitBashString(_ sc: inout LineScanner, _ from: Int, _ to: Int) {
        var p = from
        var j = from
        while j < to {
            if sc.c[j] == Ch.bslash { j += 2; continue }
            if sc.c[j] == Ch.dollar, let end = bashVariableEnd(sc, j, limit: to) {
                sc.emit(p, j, .string); sc.emit(j, end, .variable)
                p = end; j = end; continue
            }
            j += 1
        }
        sc.emit(p, to, .string)
    }

    private static func bashVariableEnd(_ sc: LineScanner, _ j: Int, limit: Int) -> Int? {
        let next = sc.at(j + 1)
        if next == Ch.lbrace {
            var k = j + 2
            while k < limit, sc.c[k] != Ch.rbrace { k += 1 }
            return min(k + 1, limit)
        }
        if Ch.isLetter(next) && next < 128 {
            var k = j + 2
            while k < limit, Ch.isWord(sc.c[k]), sc.c[k] < 128 { k += 1 }
            return k
        }
        if Ch.isDigit(next) || next == Ch.at || next == Ch.star || next == Ch.hash || next == 63 || next == Ch.bang || next == Ch.dollar { return j + 2 }
        return nil
    }

    static func scriptLine(_ sc: inout LineScanner, _ state: LineState, _ spec: Spec) -> LineState {
        let n = sc.n
        var i = 0

        // Whatever the previous line left open.
        switch state {
        case .blockComment(var depth):
            var j = 0
            while j < n, depth > 0 {
                if spec.blockNests, sc.matches(spec.blockOpen, at: j) { depth += 1; j += spec.blockOpen.count }
                else if sc.matches(spec.blockClose, at: j) { depth -= 1; j += spec.blockClose.count }
                else { j += 1 }
            }
            sc.emit(0, j, .comment)
            if depth > 0 { return .blockComment(depth: depth) }
            i = j
        case .string(let delimiter):
            let d = units(delimiter)
            let raw = d.count == 1 && spec.rawQuotes.contains(d[0])
            guard let end = closeString(sc, from: 0, delimiter: d, raw: raw, swiftInterpolation: spec.swiftInterpolation) else {
                if spec.dollarVariables, delimiter == "\"" { emitBashString(&sc, 0, n) } else { sc.emit(0, n, .string) }
                return state
            }
            if spec.dollarVariables, delimiter == "\"" { emitBashString(&sc, 0, end) } else { sc.emit(0, end, .string) }
            i = end
        case .heredoc(var markers):
            guard let m = markers.first else { break }
            var start = 0
            if m.stripTabs { while start < n, sc.c[start] == Ch.tab { start += 1 } }
            var end = n
            if end > start, sc.c[end - 1] == Ch.cr { end -= 1 }
            if sc.text(start, end) == m.delimiter {
                sc.emit(start, end, .constant)
                markers.removeFirst()
                return markers.isEmpty ? .normal : .heredoc(markers)
            }
            sc.emit(0, n, .string)
            return state
        case .normal, .yamlBlock: break
        }

        var pending: [HeredocMarker] = []
        var lastSignificant: unichar = 0
        var lastWord = ""
        var lastWordWasKeyword = false

        while i < n {
            let ch = sc.c[i]
            if Ch.isSpace(ch) { i += 1; continue }

            // Line comments.
            var commented = false
            for prefix in spec.lineComments where sc.matches(prefix, at: i) {
                if prefix.count == 1, prefix[0] == Ch.hash {
                    if spec.hashOnlyAtLineStart, lastSignificant != 0 { continue }
                    if spec.hashNeedsBoundary, i > 0, !(Ch.isSpace(sc.c[i - 1]) || sc.c[i - 1] == Ch.semicolon || sc.c[i - 1] == Ch.lparen) { continue }
                }
                sc.emit(i, n, .comment); commented = true; break
            }
            if commented { break }

            // Block comments.
            if !spec.blockOpen.isEmpty, sc.matches(spec.blockOpen, at: i) {
                var depth = 1
                var j = i + spec.blockOpen.count
                while j < n, depth > 0 {
                    if spec.blockNests, sc.matches(spec.blockOpen, at: j) { depth += 1; j += spec.blockOpen.count }
                    else if sc.matches(spec.blockClose, at: j) { depth -= 1; j += spec.blockClose.count }
                    else { j += 1 }
                }
                sc.emit(i, j, .comment)
                if depth > 0 { return .blockComment(depth: depth) }
                i = j; continue
            }

            // Strings (with Python prefixes such as r"", f"", rb"").
            var quoteAt = i
            if spec.stringPrefixes, Ch.isLetter(ch), !Ch.isWord(sc.at(i - 1)) {
                var k = i
                while k < n, k - i < 2, [114, 82, 98, 66, 102, 70, 117, 85].contains(sc.c[k]) { k += 1 }
                if k > i, sc.at(k) == Ch.dq || sc.at(k) == Ch.sq { quoteAt = k }
            }
            let q = sc.at(quoteAt)
            if spec.quotes.contains(q), quoteAt == i || quoteAt > i {
                if quoteAt == i || spec.stringPrefixes {
                    let isRawPrefix = quoteAt > i && (i..<quoteAt).contains { sc.c[$0] == 114 || sc.c[$0] == 82 }
                    if spec.tripleQuotes, sc.at(quoteAt + 1) == q, sc.at(quoteAt + 2) == q {
                        let d = [q, q, q]
                        if let end = closeString(sc, from: quoteAt + 3, delimiter: d, raw: false, swiftInterpolation: spec.swiftInterpolation) {
                            sc.emit(i, end, .string); i = end
                        } else {
                            sc.emit(i, n, .string)
                            return .string(delimiter: String(utf16CodeUnits: d, count: 3))
                        }
                    } else {
                        let raw = spec.rawQuotes.contains(q) || isRawPrefix
                        let bashDouble = spec.dollarVariables && q == Ch.dq
                        if let end = closeString(sc, from: quoteAt + 1, delimiter: [q], raw: raw, swiftInterpolation: spec.swiftInterpolation) {
                            if bashDouble { emitBashString(&sc, i, end) } else { sc.emit(i, end, .string) }
                            i = end
                        } else {
                            if bashDouble { emitBashString(&sc, i, n) } else { sc.emit(i, n, .string) }
                            if spec.multilineQuotes.contains(q) { return .string(delimiter: String(utf16CodeUnits: [q], count: 1)) }
                            i = n
                        }
                    }
                    lastSignificant = q; lastWord = ""; lastWordWasKeyword = false
                    continue
                }
            }

            // Shell variables.
            if spec.dollarVariables, ch == Ch.dollar {
                if let end = bashVariableEnd(sc, i, limit: n) { sc.emit(i, end, .variable); i = end } else { i += 1 }
                lastSignificant = ch; continue
            }

            // Here-documents: <<EOF, <<-EOF, <<'EOF', <<"EOF" (not the <<< here-string).
            if spec.heredocs, ch == Ch.lt, sc.at(i + 1) == Ch.lt {
                if sc.at(i + 2) == Ch.lt { i += 3; lastSignificant = ch; continue }
                var j = i + 2
                let strip = sc.at(j) == Ch.dash
                if strip { j += 1 }
                while j < n, sc.c[j] == Ch.space { j += 1 }
                var name = ""
                var end = j
                if sc.at(j) == Ch.sq || sc.at(j) == Ch.dq {
                    let quote = sc.c[j]
                    var k = j + 1
                    while k < n, sc.c[k] != quote { k += 1 }
                    name = sc.text(j + 1, min(k, n)); end = min(k + 1, n)
                } else {
                    var k = j
                    while k < n, Ch.isWord(sc.c[k]) { k += 1 }
                    name = sc.text(j, k); end = k
                }
                if !name.isEmpty {
                    sc.emit(i, j, .op); sc.emit(j, end, .constant)
                    pending.append(HeredocMarker(delimiter: name, stripTabs: strip))
                    i = end; lastSignificant = ch; continue
                }
            }

            // Numbers.
            if Ch.isDigit(ch), !Ch.isWord(sc.at(i - 1)) {
                var j = i + 1
                if ch == 48, sc.at(j) == 120 || sc.at(j) == 88 {
                    j += 1
                    while j < n, Ch.isHex(sc.c[j]) || sc.c[j] == Ch.underscore { j += 1 }
                } else {
                    while j < n {
                        let cj = sc.c[j]
                        if Ch.isDigit(cj) || cj == Ch.underscore { j += 1 }
                        else if cj == Ch.dot, Ch.isDigit(sc.at(j + 1)) { j += 1 }
                        else if cj == 101 || cj == 69, Ch.isDigit(sc.at(j + 1)) || ((sc.at(j + 1) == Ch.dash || sc.at(j + 1) == Ch.plus) && Ch.isDigit(sc.at(j + 2))) { j += 2 }
                        else { break }
                    }
                }
                sc.emit(i, j, .number); i = j; lastSignificant = ch; lastWord = ""; lastWordWasKeyword = false
                continue
            }

            // Attributes and compiler directives.
            if spec.atAttributes, ch == Ch.at, Ch.isLetter(sc.at(i + 1)) {
                var j = i + 1
                while j < n, Ch.isWord(sc.c[j]) || sc.c[j] == Ch.dot { j += 1 }
                sc.emit(i, j, .attribute); i = j; lastSignificant = ch; continue
            }
            if spec.hashDirectives, ch == Ch.hash, Ch.isLetter(sc.at(i + 1)) {
                var j = i + 1
                while j < n, Ch.isWord(sc.c[j]) { j += 1 }
                sc.emit(i, j, .keyword); i = j; lastSignificant = ch; continue
            }

            // Identifiers.
            if Ch.isLetter(ch) {
                var j = i + 1
                while j < n, Ch.isWord(sc.c[j]) { j += 1 }
                let word = sc.text(i, j)
                let lookup = spec.caseInsensitive ? word.lowercased() : word
                let member = sc.at(i - 1) == Ch.dot && !spec.dollarVariables
                var k = j
                while k < n, sc.c[k] == Ch.space { k += 1 }
                let called = sc.at(k) == Ch.lparen
                var isKeyword = false
                if let kind = spec.definitions[lastWord], lastWordWasKeyword, !spec.keywords.contains(lookup) { sc.emit(i, j, kind) }
                else if member { if called { sc.emit(i, j, .function) } }
                else if spec.keywords.contains(lookup) { sc.emit(i, j, .keyword); isKeyword = true }
                else if spec.constants.contains(lookup) { sc.emit(i, j, .constant) }
                else if spec.builtins.contains(lookup) { sc.emit(i, j, .function) }
                else if spec.capitalizedTypes, Ch.isUpper(ch) { sc.emit(i, j, .type) }
                else if called { sc.emit(i, j, .function) }
                lastWord = lookup; lastWordWasKeyword = isKeyword
                lastSignificant = sc.c[j - 1]
                i = j; continue
            }

            // JavaScript regular expression literals.
            if spec.regexLiterals, ch == Ch.slash {
                let operatorBefore = lastSignificant == 0 || [Ch.lparen, Ch.comma, Ch.eq, Ch.colon, Ch.lbrack, Ch.bang, 38, Ch.pipe, 63, Ch.lbrace, Ch.rbrace, Ch.semicolon].contains(lastSignificant)
                if operatorBefore || (lastWordWasKeyword && Ch.isWord(lastSignificant)) {
                    var j = i + 1
                    var inClass = false
                    var closed = false
                    while j < n {
                        let cj = sc.c[j]
                        if cj == Ch.bslash { j += 2; continue }
                        if cj == Ch.lbrack { inClass = true } else if cj == Ch.rbrack { inClass = false }
                        else if cj == Ch.slash, !inClass { closed = true; break }
                        j += 1
                    }
                    if closed {
                        j += 1
                        while j < n, Ch.isLetter(sc.c[j]) { j += 1 }
                        sc.emit(i, j, .string); i = j; lastSignificant = Ch.slash; lastWord = ""; lastWordWasKeyword = false
                        continue
                    }
                }
            }

            lastSignificant = ch
            if ch != Ch.dot { lastWord = ""; lastWordWasKeyword = false }
            i += 1
        }
        return pending.isEmpty ? .normal : .heredoc(pending)
    }
}
