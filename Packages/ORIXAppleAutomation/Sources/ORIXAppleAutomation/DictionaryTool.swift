// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/DictionaryTool.swift
// Description: applescript.dictionary: reads an application's scripting definition with /usr/bin/sdef and returns a bounded summary of suites, commands and classes.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public struct ScriptingDictionaryTool: ORIXTool {
    public init() {}

    public var manifest: ToolManifest {
        ToolManifest(
            identifier: "applescript.dictionary", name: "Scripting dictionary",
            summary: "Summarises an application's AppleScript/JXA scripting dictionary (suites, commands with parameters, classes with properties). Reports unsupported when the application is not scriptable.",
            family: "applescript",
            inputSchema: .object([
                "bundleID": bundleIDSchema,
                "path": .string("Path of the application bundle, as an alternative to bundleID."),
                "maxItems": .integer("Maximum commands and classes returned per suite (default 60).", minimum: 1, maximum: 500),
            ]),
            outputSchema: outputObject([
                "application": .string(), "path": .string(),
                "suites": .array(of: outputObject(["name": .string(), "commands": .array(of: .any), "classes": .array(of: .any)], required: ["name"])),
                "commandCount": .integer(), "classCount": .integer(),
            ], required: ["application", "path", "suites"]),
            sideEffect: .read, defaultTier: .readOnly, defaultTimeoutSeconds: 30, idempotent: true, outputIsUntrusted: true,
            examples: [["bundleID": "com.apple.finder"]])
    }

    func appPath(_ input: ToolInput, context: ToolExecutionContext) throws -> String {
        if let raw = input.optionalString("path"), !raw.isEmpty {
            let path = try PathResolver.canonical(raw, relativeTo: context.workingDirectory)
            guard path.hasSuffix(".app") else { throw ToolError.invalidInput("path must be an application bundle (.app)") }
            return path
        }
        guard input.optionalString("bundleID") != nil else { throw ToolError.invalidInput("bundleID or path is required") }
        let id = try input.bundleID()
        guard let url = AppResolver.url(forBundleID: id) else { throw ToolError.notFound("No installed application has the bundle identifier \(id)") }
        return PathResolver.resolveSymlinks(url.path)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let path = try appPath(input, context: context)
        return ToolRequirements(capabilities: [.fileRead(path: path)], tier: .readOnly,
                                summary: "Read the scripting dictionary of \(PathResolver.display(path))")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let path = try appPath(input, context: context)
        guard FileManager.default.fileExists(atPath: path) else { throw ToolError.notFound("No application at \(path)") }
        let timeout = input.timeout(default: 20, context: context)
        let run = try await Subprocess.run("/usr/bin/sdef", [path], timeout: timeout, maxOutputBytes: 16_777_216)
        if run.timedOut { throw ToolError.timeout(seconds: timeout) }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard run.exitCode == 0, !run.stdout.isEmpty else {
            throw ToolError.unsupported("\(name) has no scripting dictionary: it cannot be driven with AppleScript or JXA beyond the standard open/quit events. Use the accessibility tools instead.")
        }
        guard let dictionary = SdefParser.parse(run.stdout, maxItems: input.int("maxItems", default: 60)) else {
            throw ToolError.internalError("The scripting definition of \(name) could not be parsed")
        }
        guard !dictionary.suites.isEmpty else {
            throw ToolError.unsupported("\(name) publishes an empty scripting dictionary")
        }
        var result = ToolResult.success([
            "application": .string(name), "path": .string(path), "suites": .array(dictionary.suites),
            "commandCount": .int(dictionary.commandCount), "classCount": .int(dictionary.classCount), "truncated": .bool(dictionary.truncated),
        ], summary: "\(name): \(dictionary.suites.count) suites, \(dictionary.commandCount) commands, \(dictionary.classCount) classes")
        result.truncated = dictionary.truncated
        result.untrusted = true
        return result
    }
}

/// Reduces sdef XML to a bounded JSON summary.
final class SdefParser: NSObject, XMLParserDelegate {
    struct Summary { var suites: [JSONValue]; var commandCount: Int; var classCount: Int; var truncated: Bool }

    static func parse(_ data: Data, maxItems: Int) -> Summary? {
        let delegate = SdefParser(maxItems: maxItems)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return Summary(suites: delegate.suites, commandCount: delegate.commandCount, classCount: delegate.classCount, truncated: delegate.truncated)
    }

    private let maxItems: Int
    private var suites: [JSONValue] = []
    private var commandCount = 0, classCount = 0
    private var truncated = false
    private var suite: [String: JSONValue]?
    private var commands: [JSONValue] = [], classes: [JSONValue] = [], enumerations: [JSONValue] = []
    private var command: [String: JSONValue]?
    private var parameters: [JSONValue] = []
    private var klass: [String: JSONValue]?
    private var properties: [JSONValue] = [], elements: [JSONValue] = []
    private var enumeration: [String: JSONValue]?
    private var enumerators: [JSONValue] = []

    private init(maxItems: Int) { self.maxItems = maxItems }

    private func text(_ s: String?, limit: Int = 200) -> JSONValue? {
        guard let s, !s.isEmpty else { return nil }
        return .string(s.count > limit ? String(s.prefix(limit)) + "…" : s)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        if a["hidden"] == "yes", name != "suite" { return }
        switch name {
        case "suite":
            suite = ["name": .string(a["name"] ?? "")]
            suite?["description"] = text(a["description"])
            commands = []; classes = []; enumerations = []
        case "command":
            command = ["name": .string(a["name"] ?? "")]
            command?["description"] = text(a["description"])
            parameters = []
        case "direct-parameter" where command != nil:
            var p: [String: JSONValue] = [:]
            p["type"] = text(a["type"]); p["description"] = text(a["description"])
            if a["optional"] == "yes" { p["optional"] = true }
            command?["directParameter"] = .object(p)
        case "parameter" where command != nil:
            var p: [String: JSONValue] = ["name": .string(a["name"] ?? "")]
            p["type"] = text(a["type"]); p["description"] = text(a["description"], limit: 120)
            if a["optional"] == "yes" { p["optional"] = true }
            if parameters.count < 24 { parameters.append(.object(p)) } else { truncated = true }
        case "result" where command != nil:
            command?["result"] = text(a["type"])
        case "type":
            // <type type="x" list="yes"/> children refine the enclosing element's type; keep the first one when none was given.
            guard let t = a["type"] else { break }
            let rendered = JSONValue.string(a["list"] == "yes" ? "list of \(t)" : t)
            if klass != nil, var last = properties.last?.objectValue, last["type"] == nil { last["type"] = rendered; properties[properties.count - 1] = .object(last) }
        case "class", "class-extension":
            klass = ["name": .string(a["name"] ?? a["extends"] ?? "")]
            if name == "class-extension" { klass?["extends"] = text(a["extends"]) }
            klass?["inherits"] = text(a["inherits"]); klass?["plural"] = text(a["plural"]); klass?["description"] = text(a["description"])
            properties = []; elements = []
        case "property" where klass != nil:
            var p: [String: JSONValue] = ["name": .string(a["name"] ?? "")]
            p["type"] = text(a["type"]); p["description"] = text(a["description"], limit: 120)
            if let access = a["access"] { p["access"] = .string(access) }
            if properties.count < 60 { properties.append(.object(p)) } else { truncated = true }
        case "element" where klass != nil:
            if let t = a["type"], elements.count < 40 { elements.append(.string(t)) }
        case "enumeration":
            enumeration = ["name": .string(a["name"] ?? "")]
            enumerators = []
        case "enumerator" where enumeration != nil:
            if let n = a["name"], enumerators.count < 40 { enumerators.append(.string(n)) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "command":
            guard var c = command else { break }
            if !parameters.isEmpty { c["parameters"] = .array(parameters) }
            commandCount += 1
            if commands.count < maxItems { commands.append(.object(c)) } else { truncated = true }
            command = nil
        case "class", "class-extension":
            guard var k = klass else { break }
            if !properties.isEmpty { k["properties"] = .array(properties) }
            if !elements.isEmpty { k["elements"] = .array(elements) }
            classCount += 1
            if classes.count < maxItems { classes.append(.object(k)) } else { truncated = true }
            klass = nil
        case "enumeration":
            guard var e = enumeration else { break }
            e["values"] = .array(enumerators)
            if enumerations.count < maxItems { enumerations.append(.object(e)) } else { truncated = true }
            enumeration = nil
        case "suite":
            guard var s = suite else { break }
            s["commands"] = .array(commands); s["classes"] = .array(classes)
            if !enumerations.isEmpty { s["enumerations"] = .array(enumerations) }
            if suites.count < 40 { suites.append(.object(s)) } else { truncated = true }
            suite = nil
        default: break
        }
    }
}
