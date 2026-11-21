// ORIX OS Automation
// File: Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/Completion.swift
// Description: Completion for workflow source: detects what the cursor is in (a tool id, a `with:` block, `needs:`, a `${{ }}` expression, a step or a top-level mapping) and builds candidates from tool manifests and the document itself.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAppUI

public struct CompletionItem: Hashable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case tool, argument, step, function, variable, keyword, key, value }
    public var label: String
    public var insertText: String
    /// Short right-hand note: a type, a tier, "required".
    public var detail: String
    public var documentation: String
    public var kind: Kind
    public var id: String { kind.rawValue + ":" + label }

    public init(label: String, insertText: String? = nil, detail: String = "", documentation: String = "", kind: Kind) {
        self.label = label; self.insertText = insertText ?? label; self.detail = detail; self.documentation = documentation; self.kind = kind
    }
}

public enum CompletionContext: Equatable, Sendable {
    /// After `tool: `.
    case toolID(prefix: String)
    /// A key inside the `with:` block of a step that uses `tool`.
    case argumentName(tool: String, prefix: String, existing: [String])
    /// An entry of `needs:`.
    case stepReference(prefix: String, listed: [String], currentStep: String?)
    /// A bare name inside `${{ … }}`.
    case expressionRoot(prefix: String)
    /// After a dot inside `${{ … }}`: `path` is what precedes the dot (`["steps", "fetch"]`).
    case expressionMember(path: [String], prefix: String)
    /// A key of a step.
    case stepKey(prefix: String, existing: [String])
    /// A key of a known mapping: `""` (document), `metadata`, `spec`, `permissions`, `budget`, `retry`, `filesystem`.
    case mappingKey(parent: String, prefix: String, existing: [String])
    case none
}

public struct CompletionRequest: Equatable, Sendable {
    public var context: CompletionContext
    /// The text the accepted candidate replaces (UTF-16).
    public var replaceRange: NSRange
    /// True for the contexts that open the list while typing; the others need ⌃Space.
    public var automatic: Bool
}

/// What completion knows about the tools and about the document being edited.
public struct CompletionCatalog: Sendable {
    public var tools: [ToolManifest]
    public var stepIDs: [String]
    public var stepTools: [String: String]
    public var parameters: [String]
    public var variables: [String]
    public var agents: [String]

    public init(tools: [ToolManifest] = [], stepIDs: [String] = [], stepTools: [String: String] = [:], parameters: [String] = [],
                variables: [String] = [], agents: [String] = []) {
        self.tools = tools; self.stepIDs = stepIDs; self.stepTools = stepTools; self.parameters = parameters
        self.variables = variables; self.agents = agents
    }

    /// Reads step ids, their tools, parameter and variable names straight from the text, so completion keeps working
    /// while the document does not parse.
    public static func scrape(_ text: String, tools: [ToolManifest], agents: [String] = []) -> CompletionCatalog {
        var c = CompletionCatalog(tools: tools, agents: agents)
        let lines = YAMLLines(text)
        var lastStep: String?
        var section = ""           // "parameters" or "variables" while inside that block
        var sectionColumn = -1
        for l in lines.lines where !l.blank {
            if sectionColumn >= 0, l.keyColumn <= sectionColumn, l.dashColumn.map({ $0 < sectionColumn }) ?? true { section = ""; sectionColumn = -1 }
            if l.key == "parameters" || l.key == "variables", l.value.isEmpty { section = l.key; sectionColumn = l.keyColumn; continue }
            if section == "parameters" {
                if l.key == "name", !l.value.isEmpty { c.parameters.append(unquote(l.value)) }
                continue
            }
            if section == "variables" {
                if !l.key.isEmpty, l.keyColumn == sectionColumn + 2 { c.variables.append(l.key) }
                continue
            }
            if l.key == "id", l.dashColumn != nil, !l.value.isEmpty {
                let id = unquote(l.value)
                if !c.stepIDs.contains(id) { c.stepIDs.append(id) }
                lastStep = id
            } else if l.key == "tool", let s = lastStep, !l.value.isEmpty { c.stepTools[s] = unquote(l.value) }
        }
        // JSON form.
        if c.stepIDs.isEmpty, text.contains("\"steps\"") {
            let ns = text as NSString
            if let re = try? NSRegularExpression(pattern: #""id"\s*:\s*"([A-Za-z_][A-Za-z0-9_-]*)""#) {
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let id = ns.substring(with: m.range(at: 1))
                    if !c.stepIDs.contains(id) { c.stepIDs.append(id) }
                }
            }
        }
        return c
    }
}

func unquote(_ s: String) -> String {
    var t = s
    if let hash = t.range(of: " #") { t = String(t[..<hash.lowerBound]) }
    t = t.trimmingCharacters(in: .whitespaces)
    if t.count >= 2, let f = t.first, f == "\"" || f == "'", t.last == f { t = String(t.dropFirst().dropLast()) }
    return t
}

/// A light structural reading of YAML lines: indentation, list dash, first key and its value.
struct YAMLLines {
    struct Line {
        var text: String
        var indent: Int
        var dashColumn: Int?
        /// Column of the first key (after any dashes); equals the content column when the line has no key.
        var keyColumn: Int
        var key: String
        var value: String
        var blank: Bool
    }
    var lines: [Line] = []

    init(_ text: String) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) { lines.append(Self.parse(String(raw))) }
    }

    static func parse(_ raw: String) -> Line {
        let chars = Array(raw)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        let indent = i
        var dash: Int?
        while i < chars.count, chars[i] == "-", i + 1 == chars.count || chars[i + 1] == " " {
            dash = i
            i += 1
            while i < chars.count, chars[i] == " " { i += 1 }
        }
        let rest = String(chars[i...])
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        let blank = (trimmed.isEmpty && dash == nil) || trimmed.hasPrefix("#")
        var key = "", value = ""
        if !blank {
            // First `:` followed by a space or the end, outside quotes.
            var j = i
            var quote: Character?
            while j < chars.count {
                let c = chars[j]
                if let q = quote { if c == q { quote = nil } }
                else if c == "\"" || c == "'" { quote = c }
                else if c == ":" && (j + 1 == chars.count || chars[j + 1] == " ") {
                    key = unquote(String(chars[i..<j]))
                    value = String(chars[(j + 1)...]).trimmingCharacters(in: .whitespaces)
                    break
                } else if c == "#" && j > 0 && chars[j - 1] == " " { break }
                j += 1
            }
            if key.contains(" ") || key.contains("{") || key.contains("[") { key = ""; value = "" }
        }
        return Line(text: raw, indent: indent, dashColumn: dash, keyColumn: i, key: key, value: value, blank: blank)
    }
}

public enum CompletionAnalyzer {
    static let stepListKeys: Set<String> = ["steps", "onError"]
    static let knownMappings: Set<String> = ["metadata", "spec", "permissions", "budget", "retry", "filesystem", "apps", "clipboard"]

    /// What the cursor (a UTF-16 offset) is in.
    public static func analyze(text: String, cursor: Int, format: WorkflowFormat = .yaml) -> CompletionRequest {
        let ns = text as NSString
        let cursor = max(0, min(cursor, ns.length))
        let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
        let prefix = ns.substring(with: NSRange(location: lineRange.location, length: cursor - lineRange.location))
        func request(_ c: CompletionContext, _ typed: String, automatic: Bool) -> CompletionRequest {
            let n = (typed as NSString).length
            return CompletionRequest(context: c, replaceRange: NSRange(location: cursor - n, length: n), automatic: automatic)
        }
        let none = CompletionRequest(context: .none, replaceRange: NSRange(location: cursor, length: 0), automatic: false)

        // 1. Inside an open ${{ … }}.
        if let open = prefix.range(of: "${{", options: .backwards), prefix.range(of: "}}", range: open.upperBound..<prefix.endIndex) == nil {
            let inside = String(prefix[open.upperBound...])
            // Inside a string literal of the expression nothing is offered.
            var quote: Character?
            for ch in inside { if let q = quote { if ch == q { quote = nil } } else if ch == "\"" || ch == "'" { quote = ch } }
            if quote != nil { return none }
            var tail = ""
            for ch in inside.reversed() {
                if ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "-" { tail.insert(ch, at: tail.startIndex) } else { break }
            }
            if tail.hasPrefix("-") { tail = String(tail.drop { $0 == "-" }) }
            var parts = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if parts.count <= 1 {
                // A dash only belongs to a name after `steps.`.
                let word = String((parts.first ?? "").split(separator: "-", omittingEmptySubsequences: false).last ?? "")
                return request(.expressionRoot(prefix: word), word, automatic: true)
            }
            let last = parts.removeLast()
            return request(.expressionMember(path: parts, prefix: last), last, automatic: true)
        }

        if format == .json || WorkflowCodec.detectFormat(text) == .json {
            if let m = firstMatch(#""tool"\s*:\s*"([A-Za-z0-9_.]*)$"#, prefix) { return request(.toolID(prefix: m), m, automatic: true) }
            return none
        }

        // 2. `tool: <id>`.
        if let m = firstMatch(#"^\s*(?:-\s+)*tool:\s+([A-Za-z0-9_.]*)$"#, prefix) { return request(.toolID(prefix: m), m, automatic: true) }

        let lines = YAMLLines(ns.substring(to: lineRange.location) + prefix)
        let index = lines.lines.count - 1
        let below = YAMLLines(ns.substring(from: NSMaxRange(lineRange)))

        // 3. `needs: [a, b` on one line.
        if let m = firstMatch(#"^\s*(?:-\s+)*needs:\s*\[([^\]]*)$"#, prefix) {
            let entries = m.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let typed = entries.last ?? ""
            return request(.stepReference(prefix: typed, listed: Array(entries.dropLast()).filter { !$0.isEmpty }, currentStep: enclosingStepID(lines, index)),
                           typed, automatic: true)
        }

        // Only key positions from here: indentation, optional dashes, a partial word.
        guard let word = firstMatch(#"^\s*(?:-\s+)*([A-Za-z_][A-Za-z0-9_-]*)?$"#, prefix, group: 1, allowEmpty: true) else { return none }
        let current = YAMLLines.parse(prefix)
        let column = current.keyColumn

        // 4. `needs:` written as a block list.
        if current.dashColumn != nil {
            var listed: [String] = []
            var j = index - 1
            while j >= 0 {
                let l = lines.lines[j]
                if l.blank { j -= 1; continue }
                if l.dashColumn == current.dashColumn, l.key.isEmpty { listed.append(unquote(String(l.text.dropFirst(l.keyColumn)))); j -= 1; continue }
                if l.key == "needs", l.value.isEmpty, l.keyColumn <= (current.dashColumn ?? 0) {
                    return request(.stepReference(prefix: word, listed: listed, currentStep: enclosingStepID(lines, j)), word, automatic: true)
                }
                break
            }
        }

        // Walk up: siblings of this mapping, then its parent.
        var existing: [String] = []
        var itemDash = current.dashColumn
        var parentIndex: Int?
        var j = index - 1
        while j >= 0 {
            let l = lines.lines[j]
            j -= 1
            if l.blank { continue }
            if let d = itemDash {
                // This mapping is a list item: its parent is the key that owns the list.
                if l.keyColumn <= d { parentIndex = j + 1; break }
                continue
            }
            if l.keyColumn > column { continue }
            if l.keyColumn == column {
                if !l.key.isEmpty { existing.append(l.key) }
                if let d = l.dashColumn { itemDash = d }
                continue
            }
            parentIndex = j + 1
            break
        }
        // Siblings below the cursor.
        for l in below.lines {
            if l.blank || l.keyColumn > column { continue }
            if l.keyColumn < column || l.dashColumn != nil { break }
            if !l.key.isEmpty { existing.append(l.key) }
        }

        let all = lines.lines + below.lines
        let parentKey = parentIndex.map { all[$0].key } ?? ""
        if itemDash != nil {
            if stepListKeys.contains(parentKey) { return request(.stepKey(prefix: word, existing: existing), word, automatic: false) }
            if parentKey == "parameters" { return request(.mappingKey(parent: "parameter", prefix: word, existing: existing), word, automatic: false) }
            if parentKey == "triggers" || parentKey == "trigger" { return request(.mappingKey(parent: "trigger", prefix: word, existing: existing), word, automatic: false) }
            return none
        }
        guard let parentIndex else {
            return column == 0 ? request(.mappingKey(parent: "", prefix: word, existing: existing), word, automatic: false) : none
        }
        if parentKey == "with" {
            let tool = siblingValue("tool", at: parentIndex, in: all)
            return request(.argumentName(tool: tool ?? "", prefix: word, existing: existing), word, automatic: true)
        }
        if knownMappings.contains(parentKey) { return request(.mappingKey(parent: parentKey, prefix: word, existing: existing), word, automatic: false) }
        return none
    }

    private static func firstMatch(_ pattern: String, _ text: String, group: Int = 1, allowEmpty: Bool = true) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let r = m.range(at: group)
        if r.location == NSNotFound { return allowEmpty ? "" : nil }
        return ns.substring(with: r)
    }

    /// The id of the step that contains line `index`.
    static func enclosingStepID(_ lines: YAMLLines, _ index: Int) -> String? {
        guard index >= 0, index < lines.lines.count else { return nil }
        var column = lines.lines[index].keyColumn
        var j = index
        while j >= 0 {
            let l = lines.lines[j]
            if !l.blank, l.keyColumn <= column {
                if l.key == "id" { return unquote(l.value) }
                column = l.keyColumn
                if l.dashColumn != nil, l.key != "id" {
                    // The item started without `id` first: look at its other keys below.
                    var k = j + 1
                    while k < lines.lines.count, lines.lines[k].blank || lines.lines[k].keyColumn >= column {
                        if lines.lines[k].keyColumn == column, lines.lines[k].key == "id" { return unquote(lines.lines[k].value) }
                        k += 1
                    }
                    return nil
                }
            }
            j -= 1
        }
        return nil
    }

    /// Value of the key `name` in the mapping that contains line `at` (searching its siblings above and below).
    private static func siblingValue(_ name: String, at: Int, in all: [YAMLLines.Line]) -> String? {
        let column = all[at].keyColumn
        if all[at].key == name { return unquote(all[at].value) }
        if all[at].dashColumn == nil {
            var j = at - 1
            while j >= 0 {
                let l = all[j]
                j -= 1
                if l.blank || l.keyColumn > column { continue }
                if l.keyColumn < column { break }
                if l.key == name { return unquote(l.value) }
                if l.dashColumn != nil { break }
            }
        }
        for l in all[(at + 1)...] {
            if l.blank || l.keyColumn > column { continue }
            if l.keyColumn < column || l.dashColumn != nil { break }
            if l.key == name { return unquote(l.value) }
        }
        return nil
    }
}

public enum CompletionEngine {
    static let stepKinds: [(String, String)] = [
        ("tool", "Calls a tool with the arguments in with:"), ("agent", "Runs an agent profile on an objective"),
        ("if", "Chooses then: or else: steps from a condition"), ("switch", "Chooses the steps of the first matching case"),
        ("foreach", "Runs the body once per item"), ("parallel", "Runs branches at the same time and joins them"),
        ("while", "Repeats the body while a condition holds (maxIterations required)"), ("approval", "Waits for a person to approve"),
        ("delay", "Waits a number of seconds"), ("set", "Assigns workflow variables"), ("transform", "Computes a value from an expression"),
        ("verify", "Checks assertions; a failed one fails the step"), ("subworkflow", "Runs another workflow inline"),
        ("notify", "Posts a notification"), ("fail", "Fails with a message"), ("output", "Declares workflow outputs and artifacts"),
    ]
    static let commonStepFields: [(String, String)] = [
        ("id", "Unique identifier of the step"), ("name", "Display name"), ("needs", "Steps of the same list that must finish first"),
        ("when", "Expression; the step is skipped when it is false"), ("retry", "maxAttempts, backoffSeconds, backoffMultiplier, force"),
        ("timeoutSeconds", "Time limit for one attempt"), ("continueOnError", "A failure does not stop the list"),
        ("onError", "Step of the same list that handles the failure"),
    ]
    static let kindFields: [String: [(String, String)]] = [
        "tool": [("with", "Arguments of the tool")],
        "agent": [("objective", "What the agent must achieve"), ("inputs", "Values passed to the agent"), ("expect", "File assertions the result must meet")],
        "if": [("then", "Step ids that run when true"), ("else", "Step ids that run when false")],
        "switch": [("cases", "List of {value, steps}"), ("default", "Step ids when no case matches")],
        "foreach": [("as", "Name of the item variable (default item)"), ("concurrency", "Items at the same time (default 1)"),
                    ("collect", "Step whose output becomes each result"), ("steps", "Body")],
        "while": [("maxIterations", "Upper bound, required"), ("steps", "Body")],
        "transform": [("into", "Variable that also receives the value")],
        "subworkflow": [("inputs", "Parameters of the called workflow")],
        "notify": [("title", "Notification title")],
        "output": [("artifacts", "Files declared as artifacts")],
    ]
    static let mappingKeys: [String: [(String, String)]] = [
        "": [("apiVersion", "orix.ai/v1"), ("kind", "Automation"), ("metadata", "id, name, description, tags"), ("spec", "Triggers, parameters, permissions, steps")],
        "metadata": [("id", "Identifier used to store the workflow"), ("name", "Title"), ("description", "One sentence"), ("tags", "List of labels")],
        "spec": [("triggers", "manual, schedule, once, interval, fileChange, login, appLaunch"), ("parameters", "Inputs of a run"),
                 ("permissions", "The least the steps need"), ("budget", "Limits of a run"), ("variables", "Initial workflow variables"),
                 ("steps", "The step list"), ("onError", "Steps that run after the workflow failed"), ("layout", "Positions in the visual editor")],
        "permissions": [("filesystem", "read, write, delete paths"), ("processes", "Executables for shell.run"), ("scripts", "bash python swift javascript applescript jxa"),
                        ("apps", "automation, accessibility, control bundle ids"), ("network", "Hosts"), ("browser", "Hosts opened in the browser"),
                        ("secrets", "Keychain reference names"), ("clipboard", "read, write"), ("notifications", "true to post notifications"), ("screen", "display or window:<bundle id>")],
        "filesystem": [("read", "Paths that may be read"), ("write", "Paths that may be written"), ("delete", "Paths where moving to the Trash is allowed")],
        "apps": [("automation", "Bundle ids scripted with Apple Events"), ("accessibility", "Bundle ids operated through Accessibility"), ("control", "Bundle ids opened or quit")],
        "clipboard": [("read", "true to read the clipboard"), ("write", "true to replace it")],
        "budget": [("maxDurationSeconds", "Wall-clock limit"), ("maxProviderCostUSD", "Spending limit"), ("maxToolCalls", "Tool call limit"), ("maxTokens", "Token limit")],
        "retry": [("maxAttempts", "Total attempts"), ("backoffSeconds", "Delay before the second attempt"), ("backoffMultiplier", "Growth of the delay"), ("force", "Retry even when the step is not idempotent")],
        "parameter": [("name", "Read as params.<name>"), ("type", "string number integer boolean path array object"), ("default", "Value when none is supplied"),
                      ("description", "Shown when the run starts"), ("required", "true when a value must be supplied")],
        "trigger": [("type", "manual schedule once interval fileChange login appLaunch"), ("cron", "Five-field cron expression"), ("timezone", "IANA time zone"),
                    ("at", "ISO 8601 date-time"), ("seconds", "Interval"), ("path", "Folder to watch"), ("glob", "File pattern"), ("debounceSeconds", "Quiet time before firing"), ("bundleID", "Application")],
    ]
    static let expressionRootDocs: [(String, String)] = [
        ("params", "Parameters of this run"), ("vars", "Workflow variables"), ("steps", "Results of upstream steps"), ("env", "HOME USER TMPDIR DATE TIME DATETIME TIMESTAMP"),
    ]

    static func typeDescription(_ schema: JSONValue?) -> String {
        guard let schema else { return "" }
        if let t = schema["type"]?.stringValue {
            if t == "array", let item = schema["items"]?["type"]?.stringValue { return "[\(item)]" }
            if let e = schema["enum"]?.arrayValue { return e.compactMap(\.stringValue).joined(separator: " | ") }
            return t
        }
        return "any"
    }

    private static func rank(_ items: [CompletionItem], _ prefix: String) -> [CompletionItem] {
        guard !prefix.isEmpty else { return items }
        let p = prefix.lowercased()
        let starts = items.filter { $0.label.lowercased().hasPrefix(p) }
        let contains = items.filter { !$0.label.lowercased().hasPrefix(p) && $0.label.lowercased().contains(p) }
        let out = starts + contains
        // Nothing to offer when the only candidate is already typed.
        if out.count == 1, out[0].insertText == prefix { return [] }
        return out
    }

    public static func candidates(_ context: CompletionContext, catalog: CompletionCatalog) -> [CompletionItem] {
        switch context {
        case .none: return []
        case .toolID(let prefix):
            let items = catalog.tools.sorted { $0.identifier < $1.identifier }.map {
                CompletionItem(label: $0.identifier, detail: "tier \($0.defaultTier.rawValue) · \($0.sideEffect.rawValue)", documentation: $0.summary, kind: .tool)
            }
            return rank(items, prefix)
        case .argumentName(let tool, let prefix, let existing):
            guard let m = catalog.tools.first(where: { $0.identifier == tool }) else { return [] }
            let props = m.inputSchema.raw["properties"]?.objectValue ?? [:]
            let required = m.inputSchema.raw["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let names = required.filter { props[$0] != nil } + props.keys.filter { !required.contains($0) }.sorted()
            let items = names.filter { !existing.contains($0) }.map { name -> CompletionItem in
                let type = typeDescription(props[name])
                return CompletionItem(label: name, insertText: name + ": ", detail: required.contains(name) ? "\(type) · required" : type,
                                      documentation: props[name]?["description"]?.stringValue ?? "", kind: .argument)
            }
            return rank(items, prefix)
        case .stepReference(let prefix, let listed, let current):
            let items = catalog.stepIDs.filter { $0 != current && !listed.contains($0) }.map {
                CompletionItem(label: $0, detail: catalog.stepTools[$0] ?? "step", kind: .step)
            }
            return rank(items, prefix)
        case .expressionRoot(let prefix):
            var items = expressionRootDocs.map { CompletionItem(label: $0.0, insertText: $0.0 + ".", detail: "root", documentation: $0.1, kind: .variable) }
            items += WorkflowExpression.functionNames.map { CompletionItem(label: $0, insertText: $0 + "(", detail: "function", kind: .function) }
            items += ["true", "false", "null"].map { CompletionItem(label: $0, detail: "constant", kind: .keyword) }
            return rank(items, prefix)
        case .expressionMember(let path, let prefix):
            var items: [CompletionItem] = []
            switch path.first {
            case "params": if path.count == 1 { items = catalog.parameters.map { CompletionItem(label: $0, detail: "parameter", kind: .variable) } }
            case "vars": if path.count == 1 { items = catalog.variables.map { CompletionItem(label: $0, detail: "variable", kind: .variable) } }
            case "env": if path.count == 1 { items = WorkflowExpression.environmentAllowlist.sorted().map { CompletionItem(label: $0, detail: "environment", kind: .variable) } }
            case "steps":
                if path.count == 1 {
                    items = catalog.stepIDs.map { CompletionItem(label: $0, detail: catalog.stepTools[$0] ?? "step", kind: .step) }
                } else if path.count == 2 {
                    items = [("output", "The step's output"), ("status", "succeeded, failed, skipped …"), ("error", "Failure message, when any"), ("attempts", "Number of attempts")]
                        .map { CompletionItem(label: $0.0, detail: "step result", documentation: $0.1, kind: .variable) }
                } else if path.count == 3, path[2] == "output", let tool = catalog.stepTools[path[1]],
                          let m = catalog.tools.first(where: { $0.identifier == tool }) {
                    let props = m.outputSchema.raw["properties"]?.objectValue ?? [:]
                    items = props.keys.sorted().map {
                        CompletionItem(label: $0, detail: typeDescription(props[$0]), documentation: props[$0]?["description"]?.stringValue ?? "", kind: .variable)
                    }
                }
            default: break
            }
            return rank(items, prefix)
        case .stepKey(let prefix, let existing):
            let kind = stepKinds.map(\.0).first { existing.contains($0) }
            var fields: [(String, String, String)] = []
            if !existing.contains("id") { fields.append(("id", "Unique identifier of the step", "field")) }
            if let kind { fields += (kindFields[kind] ?? []).map { ($0.0, $0.1, kind) } } else { fields += stepKinds.map { ($0.0, $0.1, "step kind") } }
            fields += commonStepFields.filter { $0.0 != "id" }.map { ($0.0, $0.1, "field") }
            let items = fields.filter { !existing.contains($0.0) }.map {
                CompletionItem(label: $0.0, insertText: $0.0 + ": ", detail: $0.2, documentation: $0.1, kind: $0.2 == "step kind" ? .keyword : .key)
            }
            return rank(items, prefix)
        case .mappingKey(let parent, let prefix, let existing):
            let items = (mappingKeys[parent] ?? []).filter { !existing.contains($0.0) }.map {
                CompletionItem(label: $0.0, insertText: $0.0 + ": ", detail: parent.isEmpty ? "document" : parent, documentation: $0.1, kind: .key)
            }
            return rank(items, prefix)
        }
    }
}

public enum ToolDocs {
    /// Plain-text documentation of a tool, shown on hover.
    public static func text(_ m: ToolManifest) -> String {
        var out = ["\(m.identifier) — \(m.name)", m.summary]
        let props = m.inputSchema.raw["properties"]?.objectValue ?? [:]
        let required = m.inputSchema.raw["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let names = required.filter { props[$0] != nil } + props.keys.filter { !required.contains($0) }.sorted()
        if !names.isEmpty {
            out.append("Arguments: " + names.map { "\($0)\(required.contains($0) ? "*" : ""): \(CompletionEngine.typeDescription(props[$0]))" }.joined(separator: ", "))
        }
        out.append("\(m.defaultTier.label) · side effect: \(m.sideEffect.rawValue)")
        if !m.macPermissions.isEmpty { out.append("macOS permissions: " + m.macPermissions.map(\.rawValue).joined(separator: ", ")) }
        return out.joined(separator: "\n")
    }

    /// The tool id under a UTF-16 offset, when the offset is inside the value of a `tool:` key.
    public static func toolID(in text: String, at offset: Int) -> (id: String, range: NSRange)? {
        ranges(in: text).first { NSLocationInRange(offset, $0.range) || offset == NSMaxRange($0.range) }
    }

    /// Every `tool: <id>` value in the text (YAML and JSON forms).
    public static func ranges(in text: String) -> [(id: String, range: NSRange)] {
        guard let re = try? NSRegularExpression(pattern: #"(?m)(?:^\s*(?:-\s+)*tool:\s+|"tool"\s*:\s*")["']?([a-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9_]*)+)"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { (ns.substring(with: $0.range(at: 1)), $0.range(at: 1)) }
    }
}
