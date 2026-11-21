// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Sources/ORIXToolRegistry/Tools/DocumentDataTools.swift
// Description: documents.csvRead, documents.csvWrite, documents.jsonQuery, documents.textStats and documents.xlsxRead (zip + XMLParser, honest about what it does not interpret).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

private var fm: FileManager { FileManager.default }
private func show(_ path: String) -> String { PathResolver.display(path) }

/// Reads a whole text file (UTF-8, then UTF-16, then Latin-1), bounded.
private func readText(_ path: String, maxBytes: Int = 50_000_000) throws -> String {
    try ToolSupport.requireFile(path)
    let size = ToolSupport.fileSize(path)
    guard size <= maxBytes else { throw ToolError.unsupported("\(show(path)) is \(size) bytes; files above \(maxBytes) bytes are not supported by this tool") }
    guard let data = fm.contents(atPath: path) else { throw ToolError.io("Cannot read \(show(path))") }
    if let s = String(data: data, encoding: .utf8) { return s }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
    if let s = String(data: data, encoding: .isoLatin1) { return s }
    throw ToolError.unsupported("\(show(path)) is not a text file")
}

/// Writes a new file, or replaces one when `overwrite` (keeping a backup). Returns the backup path.
private func writeNew(_ data: Data, to path: String, overwrite: Bool, context: ToolExecutionContext) throws -> String? {
    let existing = ToolSupport.kind(of: path)
    if existing.isDirectory { throw ToolError.invalidInput("\(show(path)) is a directory") }
    if existing.exists && !overwrite { throw ToolError.invalidInput("\(show(path)) already exists; pass overwrite: true to replace it (a backup is kept)") }
    var backup: String?
    try ToolSupport.io("Writing \(show(path))") {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if existing.exists { backup = try ToolSupport.backup(path, context: context) }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    return backup
}

// MARK: - CSV

/// RFC 4180 reader/writer: quoted fields, doubled quotes, delimiters and line breaks inside quotes, CRLF or LF records.
public enum CSVCodec {
    public static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, fieldWasQuoted = false
        var chars = Substring(text)
        if chars.first == "\u{FEFF}" { chars = chars.dropFirst() }
        var i = chars.startIndex
        func endField() { row.append(field); field = ""; fieldWasQuoted = false }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < chars.endIndex {
            let c = chars[i]
            let next = chars.index(after: i)
            if quoted {
                if c == "\"" {
                    if next < chars.endIndex, chars[next] == "\"" { field.append("\""); i = chars.index(after: next); continue }
                    quoted = false
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty && !fieldWasQuoted { quoted = true; fieldWasQuoted = true }
            else if c == delimiter { endField() }
            else if c == "\n" || c == "\r\n" || c == "\r" { endRow() }
            else { field.append(c) }
            i = next
        }
        if !field.isEmpty || fieldWasQuoted || !row.isEmpty { endRow() }
        return rows
    }

    /// Picks the delimiter that splits the first lines most consistently.
    public static func detectDelimiter(_ text: String) -> Character {
        let sample = text.split(whereSeparator: \.isNewline).prefix(10).map(String.init)
        var best: (Character, Int) = (",", 0)
        for d in [Character(","), ";", "\t", "|"] {
            let counts = sample.map { parse($0, delimiter: d).first?.count ?? 1 }
            guard let first = counts.first, first > 1, counts.allSatisfy({ $0 == first }) else { continue }
            if first > best.1 { best = (d, first) }
        }
        return best.0
    }

    public static func looksLikeHeader(_ rows: [[String]]) -> Bool {
        guard let first = rows.first, !first.isEmpty else { return false }
        let cells = first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.allSatisfy({ !$0.isEmpty && Double($0.replacingOccurrences(of: ",", with: ".")) == nil }), Set(cells).count == cells.count else { return false }
        return true
    }

    public static func encode(_ rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { row in
            row.map { cell -> String in
                if cell.contains(delimiter) || cell.contains("\"") || cell.contains(where: \.isNewline) || cell.hasPrefix(" ") || cell.hasSuffix(" ") {
                    return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return cell
            }.joined(separator: String(delimiter))
        }.joined(separator: "\r\n") + "\r\n"
    }
}

private func delimiter(_ input: ToolInput) throws -> Character? {
    guard let d = input.optionalString("delimiter") else { return nil }
    switch d {
    case ",", ";", "|": return Character(d)
    case "\t", "\\t", "tab": return "\t"
    default: throw ToolError.invalidInput("delimiter must be one of , ; | or tab")
    }
}

public struct DocumentsCSVReadTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "documents.csvRead", name: "Read CSV",
        summary: "Parses a CSV file (RFC 4180 quoting, delimiter and header detected unless stated) and returns the columns and a bounded window of rows.",
        family: "documents",
        inputSchema: Schema.input(["path": Schema.path, "delimiter": .string("One of , ; | or tab. Detected when absent."),
                                   "header": .string("Whether the first row is a header (default auto).", enum: ["auto", "yes", "no"]),
                                   "limit": .integer("Rows returned (default 500).", minimum: 1, maximum: 20_000), "offset": .integer("Data rows to skip.", minimum: 0),
                                   "asObjects": .boolean("Return each row as an object keyed by column name.")], required: ["path"]),
        outputSchema: Schema.output(["columns": .array(of: .string()), "rows": .array(of: .any), "rowCount": .integer(), "totalRows": .integer(),
                                     "truncated": .boolean(), "hasHeader": .boolean(), "delimiter": .string()],
                                    required: ["columns", "rows", "rowCount", "totalRows", "truncated"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 120, maxOutputBytes: 2_000_000, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        _ = try delimiter(input)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Read the CSV file \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        let text = try readText(path)
        let d = try delimiter(input) ?? CSVCodec.detectDelimiter(text)
        var rows = CSVCodec.parse(text, delimiter: d)
        let headerMode = input.optionalString("header") ?? "auto"
        let hasHeader = headerMode == "yes" || (headerMode == "auto" && CSVCodec.looksLikeHeader(rows))
        let width = rows.map(\.count).max() ?? 0
        var columns: [String]
        if hasHeader, !rows.isEmpty { columns = rows.removeFirst() } else { columns = [] }
        while columns.count < width { columns.append("column\(columns.count + 1)") }
        let total = rows.count
        let offset = min(input.int("offset", default: 0), total), limit = input.int("limit", default: 500)
        let window = rows[offset..<min(total, offset + limit)]
        let asObjects = input.bool("asObjects", default: false)
        let out: [JSONValue] = window.map { row in
            if asObjects {
                var o: [String: JSONValue] = [:]
                for (i, name) in columns.enumerated() { o[name] = .string(i < row.count ? row[i] : "") }
                return .object(o)
            }
            return .array(row.map(JSONValue.string))
        }
        let truncated = offset + window.count < total
        var result = ToolResult.success([
            "columns": .array(columns.map(JSONValue.string)), "rows": .array(out), "rowCount": .int(window.count), "totalRows": .int(total),
            "truncated": .bool(truncated), "hasHeader": .bool(hasHeader), "delimiter": .string(d == "\t" ? "tab" : String(d)), "offset": .int(offset),
        ], summary: "\(window.count) of \(total) rows, \(columns.count) columns from \(show(path))")
        result.truncated = truncated
        return result
    }
}

public struct DocumentsCSVWriteTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "documents.csvWrite", name: "Write CSV",
        summary: "Writes rows (arrays, or objects with columns) to a CSV file with RFC 4180 quoting. Refuses to replace an existing file unless overwrite is true (a backup is kept).",
        family: "documents",
        inputSchema: Schema.input(["path": Schema.path, "columns": .array(of: .string(), "Header row; required order for object rows."),
                                   "rows": .array(of: .any, "Arrays of cells, or objects keyed by column."), "delimiter": .string(), "overwrite": .boolean()],
                                  required: ["path", "rows"]),
        outputSchema: Schema.output(["path": .string(), "rows": .integer(), "bytes": .integer()], required: ["path", "rows", "bytes"]),
        sideEffect: .write, defaultTier: .reversibleWrite, supportsDryRun: true)

    static func cell(_ v: JSONValue) -> String {
        switch v {
        case .null: return ""
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .number(let d): return String(d)
        default: return v.serialized()
        }
    }

    func table(_ input: ToolInput) throws -> [[String]] {
        let rows = input.arguments["rows"]?.arrayValue ?? []
        var columns = input.strings("columns")
        let objects = rows.contains { $0.objectValue != nil }
        if objects {
            guard rows.allSatisfy({ $0.objectValue != nil }) else { throw ToolError.invalidInput("rows must be all arrays or all objects") }
            if columns.isEmpty { columns = Array(Set(rows.flatMap { Array(($0.objectValue ?? [:]).keys) })).sorted() }
            return [columns] + rows.map { r in columns.map { Self.cell(r[$0] ?? .null) } }
        }
        guard rows.allSatisfy({ $0.arrayValue != nil }) else { throw ToolError.invalidInput("each row must be an array or an object") }
        let body = rows.map { ($0.arrayValue ?? []).map(Self.cell) }
        return columns.isEmpty ? body : [columns] + body
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        _ = try delimiter(input)
        let t = try table(input)
        return ToolRequirements(capabilities: [.fileWrite(path: path)], tier: .reversibleWrite, summary: "Write \(t.count) CSV lines to \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        let t = try table(input)
        let data = Data(CSVCodec.encode(t, delimiter: try delimiter(input) ?? ",").utf8)
        if input.dryRun {
            return .simulated(["path": .string(path), "lines": .int(t.count), "bytes": .int(data.count), "wouldReplace": .bool(ToolSupport.kind(of: path).exists)],
                              summary: "Would write \(t.count) CSV lines to \(show(path))")
        }
        let backup = try writeNew(data, to: path, overwrite: input.bool("overwrite", default: false), context: context)
        return .success(["path": .string(path), "rows": .int(input.arguments["rows"]?.arrayValue?.count ?? 0), "bytes": .int(data.count),
                         "backupPath": backup.map(JSONValue.string) ?? .null], summary: "Wrote \(t.count) CSV lines to \(show(path))")
    }
}

// MARK: - JSON query

/// A small path language over JSON: `a.b`, `a[0]`, `a[*]`, `a[?price>10]`, `a[?name=="x"].id`. Operators: == != > >= < <= ~= (contains).
public enum JSONQuery {
    enum Step { case key(String), index(Int), all, filter(field: String, op: String, value: JSONValue) }

    static func parse(_ query: String) throws -> [Step] {
        var steps: [Step] = []
        var q = Substring(query.trimmingCharacters(in: .whitespaces))
        if q.hasPrefix("$") { q = q.dropFirst() }
        var key = ""
        func flush() { if !key.isEmpty { steps.append(key == "*" ? .all : .key(key)); key = "" } }
        var i = q.startIndex
        while i < q.endIndex {
            let c = q[i]
            if c == "." { flush(); i = q.index(after: i); continue }
            if c == "[" {
                flush()
                guard let close = q[i...].firstIndex(of: "]") else { throw ToolError.invalidInput("query: missing ]") }
                let inner = q[q.index(after: i)..<close].trimmingCharacters(in: .whitespaces)
                if inner == "*" { steps.append(.all) }
                else if let n = Int(inner) { steps.append(.index(n)) }
                else if inner.hasPrefix("?") { steps.append(try filter(String(inner.dropFirst()))) }
                else { steps.append(.key(inner.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))) }
                i = q.index(after: close); continue
            }
            key.append(c); i = q.index(after: i)
        }
        flush()
        return steps
    }

    static func filter(_ text: String) throws -> Step {
        for op in ["==", "!=", ">=", "<=", "~=", ">", "<"] {
            guard let r = text.range(of: op) else { continue }
            let field = text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let raw = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !field.isEmpty, !raw.isEmpty else { break }
            let value: JSONValue
            if (raw.hasPrefix("\"") && raw.hasSuffix("\"") || raw.hasPrefix("'") && raw.hasSuffix("'")) && raw.count >= 2 { value = .string(String(raw.dropFirst().dropLast())) }
            else if raw == "true" { value = true } else if raw == "false" { value = false } else if raw == "null" { value = .null }
            else if let i = Int(raw) { value = .int(i) } else if let d = Double(raw) { value = .number(d) }
            else { value = .string(raw) }
            return .filter(field: field.hasPrefix("@.") ? String(field.dropFirst(2)) : field, op: op, value: value)
        }
        throw ToolError.invalidInput("query: filter must look like [?field==value]")
    }

    static func matches(_ item: JSONValue, field: String, op: String, value: JSONValue) -> Bool {
        guard let actual = item.value(atPath: field) else { return op == "!=" }
        if let a = actual.doubleValue, let b = value.doubleValue {
            switch op {
            case "==": return a == b
            case "!=": return a != b
            case ">": return a > b
            case ">=": return a >= b
            case "<": return a < b
            case "<=": return a <= b
            default: return false
            }
        }
        let a = actual.displayString, b = value.displayString
        switch op {
        case "==": return actual == value || a == b
        case "!=": return !(actual == value || a == b)
        case "~=": return a.range(of: b, options: .caseInsensitive) != nil
        case ">": return a > b
        case ">=": return a >= b
        case "<": return a < b
        case "<=": return a <= b
        default: return false
        }
    }

    /// Returns the matched values and whether the query can yield several (wildcard or filter).
    public static func evaluate(_ root: JSONValue, query: String) throws -> (values: [JSONValue], multiple: Bool) {
        var current = [root]
        var multiple = false
        for step in try parse(query) {
            var next: [JSONValue] = []
            for v in current {
                switch step {
                case .key(let k):
                    if let child = v[k] { next.append(child) } else if let i = Int(k), let child = v[i] { next.append(child) }
                case .index(let n):
                    if let a = v.arrayValue { let idx = n < 0 ? a.count + n : n; if a.indices.contains(idx) { next.append(a[idx]) } }
                case .all:
                    if let a = v.arrayValue { next += a } else if let o = v.objectValue { next += o.keys.sorted().compactMap { o[$0] } }
                case .filter(let field, let op, let value):
                    if let a = v.arrayValue { next += a.filter { matches($0, field: field, op: op, value: value) } }
                    else if let o = v.objectValue { next += o.keys.sorted().compactMap { o[$0] }.filter { matches($0, field: field, op: op, value: value) } }
                }
            }
            switch step { case .all, .filter: multiple = true; default: break }
            current = next
        }
        return (current, multiple)
    }
}

public struct DocumentsJSONQueryTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "documents.jsonQuery", name: "Query JSON",
        summary: "Reads a JSON file and returns the value at a path such as items[0].name, items[*].id or items[?price>10].name (operators == != > >= < <= ~=). An empty query returns the document outline.",
        family: "documents",
        inputSchema: Schema.input(["path": Schema.path, "query": .string("Path expression; empty for an outline of the top level."),
                                   "limit": .integer("Maximum values returned for wildcard/filter queries (default 200).", minimum: 1, maximum: 10_000)], required: ["path"]),
        outputSchema: Schema.output(["found": .boolean(), "result": .any, "count": .integer()], required: ["found", "result", "count"]),
        sideEffect: .read, defaultTier: .readOnly, maxOutputBytes: 1_000_000, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        _ = try JSONQuery.parse(input.optionalString("query") ?? "")
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Query the JSON file \(show(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        let text = try readText(path)
        let root: JSONValue
        do { root = try JSONValue.parse(text) } catch { throw ToolError.invalidInput("\(show(path)) is not valid JSON") }
        let query = (input.optionalString("query") ?? "").trimmingCharacters(in: .whitespaces)
        if query.isEmpty || query == "$" {
            let outline: JSONValue
            switch root {
            case .object(let o): outline = .object(o.mapValues { v in
                if let a = v.arrayValue { return .string("array(\(a.count))") }
                if let c = v.objectValue { return .string("object(\(c.count) keys)") }
                return .string(v.displayString.truncated(maxBytes: 80).text)
            })
            case .array(let a): outline = ["type": "array", "count": .int(a.count), "first": a.first ?? .null]
            default: outline = root
            }
            return .success(["found": true, "result": outline, "count": 1, "outline": true], summary: "Outline of \(show(path))")
        }
        let (values, multiple) = try JSONQuery.evaluate(root, query: query)
        let limit = input.int("limit", default: 200)
        let result: JSONValue = multiple ? .array(Array(values.prefix(limit))) : (values.first ?? .null)
        var r = ToolResult.success(["found": .bool(!values.isEmpty), "result": result, "count": .int(values.count), "truncated": .bool(multiple && values.count > limit)],
                                   summary: values.isEmpty ? "No value at \(query)" : "\(ToolSupport.plural(values.count, "value")) at \(query)")
        r.truncated = multiple && values.count > limit
        return r
    }
}

// MARK: - text statistics

public struct DocumentsTextStatsTool: ORIXTool {
    public init() {}
    public let manifest = ToolManifest(
        identifier: "documents.textStats", name: "Text statistics",
        summary: "Counts lines, words, characters and bytes of a text file (or of given text) and lists its most frequent terms.",
        family: "documents",
        inputSchema: Schema.input(["path": Schema.path, "content": .string("Text to analyse instead of a file."),
                                   "topTerms": .integer("How many frequent terms (default 10).", minimum: 0, maximum: 200),
                                   "minTermLength": .integer(minimum: 1, maximum: 40)]),
        outputSchema: Schema.output(["lines": .integer(), "words": .integer(), "characters": .integer(), "bytes": .integer(), "topTerms": .array(of: .any)],
                                    required: ["lines", "words", "characters", "bytes", "topTerms"]),
        sideEffect: .read, defaultTier: .readOnly, idempotent: true, outputIsUntrusted: true)

    static let stopWords: Set<String> = ["the", "and", "for", "that", "with", "this", "from", "are", "was", "were", "have", "has", "not", "but", "you", "your",
                                         "les", "des", "une", "que", "qui", "dans", "pour", "pas", "sur", "est", "avec", "par", "aux", "sont", "ces", "ses", "mais", "nous", "vous"]

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        if let path = try input.optionalPath("path", context) {
            guard input.optionalString("content") == nil else { throw ToolError.invalidInput("give path or content, not both") }
            return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Compute text statistics of \(show(path))")
        }
        guard input.optionalString("content") != nil else { throw ToolError.invalidInput("give path or content") }
        return ToolRequirements(capabilities: [], tier: .readOnly, summary: "Compute statistics of the given text")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let text: String
        if let path = try input.optionalPath("path", context) { text = try readText(path, maxBytes: 20_000_000) } else { text = try input.string("content") }
        var lines = 0
        text.enumerateLines { _, _ in lines += 1 }
        let minLength = input.int("minTermLength", default: 3)
        var words = 0
        var counts: [String: Int] = [:]
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { word, _, _, _ in
            guard let word else { return }
            words += 1
            let w = word.lowercased()
            if w.count >= minLength, !Self.stopWords.contains(w), w.contains(where: \.isLetter) { counts[w, default: 0] += 1 }
        }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(input.int("topTerms", default: 10))
        return .success([
            "lines": .int(lines), "words": .int(words), "characters": .int(text.count), "bytes": .int(text.utf8.count),
            "uniqueTerms": .int(counts.count), "topTerms": .array(top.map { ["term": .string($0.key), "count": .int($0.value)] }),
        ], summary: "\(lines) lines, \(words) words, \(text.count) characters")
    }
}

// MARK: - XLSX

public struct DocumentsXLSXReadTool: ORIXTool {
    let runner: ProcessRunner
    public init(runner: ProcessRunner = .shared) { self.runner = runner }
    public let manifest = ToolManifest(
        identifier: "documents.xlsxRead", name: "Read Excel workbook",
        summary: "Reads the cell values of one sheet of an .xlsx workbook (shared strings, numbers, booleans, inline strings, cached formula results). Dates come back as serial numbers; legacy .xls and encrypted workbooks are unsupported.",
        family: "documents",
        inputSchema: Schema.input(["path": Schema.path, "sheet": .string("Sheet name, or its 1-based position (default: first sheet)."),
                                   "limit": .integer("Rows returned (default 500).", minimum: 1, maximum: 20_000)], required: ["path"]),
        outputSchema: Schema.output(["sheet": .string(), "sheets": .array(of: .string()), "rows": .array(of: .any), "rowCount": .integer(),
                                     "truncated": .boolean(), "unsupported": .array(of: .string())],
                                    required: ["sheet", "sheets", "rows", "rowCount", "truncated", "unsupported"]),
        sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 120, maxOutputBytes: 2_000_000, idempotent: true, outputIsUntrusted: true)

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try input.path("path", context)
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "xls" || ext == "xlsb" || ext == "numbers" || ext == "ods" {
            throw ToolError.unsupported(".\(ext) workbooks are not supported; export to .xlsx or .csv first")
        }
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly, summary: "Read the Excel workbook \(show(path))")
    }

    private func member(_ archive: String, _ name: String, context: ToolExecutionContext, required: Bool = true) async throws -> Data? {
        guard name.range(of: #"^[A-Za-z0-9_./ -]+$"#, options: .regularExpression) != nil, !name.contains("..") else {
            throw ToolError.unsupported("The workbook refers to a part with an unexpected name")
        }
        let out = try await ToolSupport.run(ProcessSpec(executable: "/usr/bin/unzip", arguments: ["-p", archive, name], environment: ["LC_ALL": "C"],
                                                        workingDirectory: (archive as NSString).deletingLastPathComponent,
                                                        timeoutSeconds: context.timeoutSeconds, maxOutputBytes: 80_000_000,
                                                        confinement: ToolSupport.profile(context, network: false)), context: context, runner: runner)
        if out.exitCode == 11 && !required { return nil }  // no matching member
        guard out.exitCode == 0 else {
            if out.exitCode == 11 { throw ToolError.unsupported("Not a spreadsheet workbook: \(name) is missing") }
            throw ToolError.unsupported("\(show(archive)) is not a readable .xlsx file (encrypted and legacy workbooks are not supported)")
        }
        if out.stdoutTruncated { throw ToolError.unsupported("Part \(name) is larger than 80 MB; export the sheet to CSV instead") }
        return out.stdout
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try input.path("path", context)
        try ToolSupport.requireFile(path)
        guard let workbookXML = try await member(path, "xl/workbook.xml", context: context) else { throw ToolError.unsupported("Not a spreadsheet workbook") }
        let workbook = XLSXWorkbookParser(); workbook.parse(workbookXML)
        guard !workbook.sheets.isEmpty else { throw ToolError.unsupported("The workbook lists no sheet") }
        let rels = XLSXRelationshipsParser()
        if let data = try await member(path, "xl/_rels/workbook.xml.rels", context: context, required: false) { rels.parse(data) }

        let wanted = input.optionalString("sheet")
        let index: Int
        if let wanted {
            if let i = workbook.sheets.firstIndex(where: { $0.name == wanted }) { index = i }
            else if let n = Int(wanted), workbook.sheets.indices.contains(n - 1) { index = n - 1 }
            else { throw ToolError.notFound("No sheet named \(wanted); sheets: \(workbook.sheets.map(\.name).joined(separator: ", "))") }
        } else { index = 0 }
        let sheet = workbook.sheets[index]
        var target = rels.targets[sheet.relationID] ?? "worksheets/sheet\(index + 1).xml"
        target = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target

        var shared: [String] = []
        if let data = try await member(path, "xl/sharedStrings.xml", context: context, required: false) {
            let p = XLSXSharedStringsParser(); p.parse(data); shared = p.strings
        }
        guard let sheetXML = try await member(path, target, context: context) else { throw ToolError.unsupported("Sheet part \(target) is missing") }
        let limit = input.int("limit", default: 500)
        let parser = XLSXSheetParser(shared: shared, limit: limit)
        parser.parse(sheetXML)
        try Task.checkCancellation()

        var notes: [String] = []
        if parser.styledNumbers > 0 { notes.append("Number formats are not interpreted: dates and times are returned as Excel serial numbers") }
        if parser.formulas > 0 { notes.append("\(parser.formulas) formula cells: cached results are returned, formulas are not evaluated") }
        if parser.merged > 0 { notes.append("\(parser.merged) merged ranges: only the top-left cell carries the value") }
        if parser.errors > 0 { notes.append("\(parser.errors) cells hold Excel errors, returned as text") }
        if parser.skippedColumns > 0 { notes.append("Columns beyond \(XLSXSheetParser.maxColumns) were dropped") }
        let width = parser.rows.map(\.cells.count).max() ?? 0
        let rows: [JSONValue] = parser.rows.map { r in .array(r.cells + Array(repeating: .null, count: width - r.cells.count)) }
        var result = ToolResult.success([
            "sheet": .string(sheet.name), "sheets": .array(workbook.sheets.map { .string($0.name) }), "rows": .array(rows),
            "rowNumbers": .array(parser.rows.map { .int($0.number) }), "rowCount": .int(rows.count), "columnCount": .int(width),
            "truncated": .bool(parser.truncated), "unsupported": .array(notes.map(JSONValue.string)),
        ], summary: "\(rows.count) rows × \(width) columns from sheet \(sheet.name)\(parser.truncated ? " (truncated)" : "")")
        result.truncated = parser.truncated
        return result
    }
}

// XMLParser delegates. Each instance is used by one call on one thread.

final class XLSXWorkbookParser: NSObject, XMLParserDelegate {
    var sheets: [(name: String, relationID: String)] = []
    func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; p.parse() }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if name == "sheet", let n = a["name"] { sheets.append((n, a["r:id"] ?? a["id"] ?? "")) }
    }
}

final class XLSXRelationshipsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]
    func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; p.parse() }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if name == "Relationship", let id = a["Id"], let target = a["Target"] { targets[id] = target }
    }
}

final class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = "", inText = false, phonetic = 0
    func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; p.parse() }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "si" { current = "" }
        else if name == "rPh" { phonetic += 1 }
        else if name == "t" { inText = phonetic == 0 }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        else if name == "rPh" { phonetic -= 1 }
        else if name == "si" { strings.append(current) }
    }
}

final class XLSXSheetParser: NSObject, XMLParserDelegate {
    static let maxColumns = 512
    struct Row { var number: Int; var cells: [JSONValue] }
    var rows: [Row] = []
    var truncated = false
    var formulas = 0, merged = 0, errors = 0, styledNumbers = 0, skippedColumns = 0
    private let shared: [String]
    private let limit: Int
    private var row: Row?
    private var cellType = "", cellRef = "", cellStyled = false, value = "", inline = ""
    private var capture: String?
    private var nextColumn = 0

    init(shared: [String], limit: Int) { self.shared = shared; self.limit = limit }
    func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; p.parse() }

    static func column(_ ref: String) -> Int? {
        var n = 0, seen = false
        for u in ref.unicodeScalars {
            guard u.value >= 65, u.value <= 90 else { break }
            n = n * 26 + Int(u.value - 64); seen = true
        }
        return seen ? n - 1 : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        switch name {
        case "row":
            if rows.count >= limit { truncated = true; parser.abortParsing(); return }
            row = Row(number: Int(a["r"] ?? "") ?? ((rows.last?.number ?? 0) + 1), cells: [])
            nextColumn = 0
        case "c":
            cellType = a["t"] ?? "n"; cellRef = a["r"] ?? ""; cellStyled = (a["s"] ?? "0") != "0"; value = ""; inline = ""
        case "v": capture = "v"
        case "t": if cellType == "inlineStr" { capture = "t" }
        case "f": formulas += 1
        case "mergeCell": merged += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture == "v" { value += string } else if capture == "t" { inline += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v", "t": capture = nil
        case "c":
            guard row != nil else { return }
            let column = Self.column(cellRef) ?? nextColumn
            nextColumn = column + 1
            guard column < Self.maxColumns else { skippedColumns += 1; return }
            let cell: JSONValue
            switch cellType {
            case "s": cell = Int(value).flatMap { shared.indices.contains($0) ? JSONValue.string(shared[$0]) : nil } ?? .null
            case "inlineStr": cell = .string(inline)
            case "str", "d": cell = .string(value)
            case "b": cell = .bool(value == "1")
            case "e": errors += 1; cell = .string(value)
            default:
                if value.isEmpty { cell = .null }
                else {
                    if cellStyled { styledNumbers += 1 }
                    if let i = Int(value) { cell = .int(i) } else if let d = Double(value) { cell = .number(d) } else { cell = .string(value) }
                }
            }
            while row!.cells.count < column { row!.cells.append(.null) }
            if row!.cells.count == column { row!.cells.append(cell) } else { row!.cells[column] = cell }
        case "row":
            if let r = row { rows.append(r) }
            row = nil
        default: break
        }
    }
}
