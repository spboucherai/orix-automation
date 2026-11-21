// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Tests/ORIXAppleAutomationTests/UnitTests.swift
// Description: Unit tests (no system interaction): manifests, script target scanner, AppleScript value parser, error parsing, typing steps, recorder semantics, notification mapping.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore
import ORIXTestingSupport
import Testing
@testable import ORIXAppleAutomation

@Suite("Unit · manifests")
struct ManifestTests {
    @Test func everyCanonicalIdentifierIsPresentOnce() {
        let ids = ORIXAppleAutomationTools.all().map(\.identifier)
        #expect(ids.count == 22)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == Set(ORIXAppleAutomationTools.identifiers))
    }

    @Test func everyManifestIsStructurallyValid() {
        for tool in ORIXAppleAutomationTools.all() {
            #expect(tool.manifest.problems().isEmpty, "\(tool.identifier): \(tool.manifest.problems())")
            #expect(tool.manifest.identifier == tool.identifier)
            for example in tool.manifest.examples {
                #expect(tool.manifest.inputSchema.validate(example).isEmpty, "example of \(tool.identifier) does not match its schema")
            }
        }
    }

    @Test func tiersConcurrencyAndTrustFlagsFollowTheContract() throws {
        let tools = Dictionary(uniqueKeysWithValues: ORIXAppleAutomationTools.all().map { ($0.identifier, $0.manifest) })
        for id in ["accessibility.status", "accessibility.tree", "accessibility.find", "accessibility.waitFor", "system.apps", "system.frontmost", "system.windows", "screen.ocr", "applescript.dictionary"] {
            #expect(tools[id]?.defaultTier == .readOnly, "\(id)")
            #expect(tools[id]?.sideEffect == .read, "\(id)")
        }
        for id in ["accessibility.press", "accessibility.setValue", "accessibility.focus", "accessibility.typeText"] {
            #expect(tools[id]?.defaultTier == .consequential, "\(id)")
            #expect(tools[id]?.concurrency == .exclusive, "\(id)")
            #expect(tools[id]?.macPermissions == [.accessibility], "\(id)")
        }
        for id in ["applescript.run", "jxa.run", "system.launchApp", "system.quitApp"] { #expect(tools[id]?.defaultTier == .consequential, "\(id)") }
        for id in ["screen.capture", "clipboard.write", "notifications.post"] { #expect(tools[id]?.defaultTier == .reversibleWrite, "\(id)") }
        for id in ["applescript.run", "jxa.run", "applescript.dictionary", "accessibility.tree", "accessibility.find", "screen.ocr", "clipboard.read", "system.windows"] {
            #expect(tools[id]?.outputIsUntrusted == true, "\(id)")
        }
    }

    @Test func requirementsDeclareTheExactCapabilities() throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let ctx = dir.toolContext()
        func req(_ tool: any ORIXTool, _ args: JSONValue) throws -> ToolRequirements { try tool.requirements(for: ToolInput(arguments: args), context: ctx) }

        let read = try req(ClipboardReadTool(), [:])
        #expect(read.capabilities == [.clipboardRead] && read.tier == .reversibleWrite)
        let write = try req(ClipboardWriteTool(), ["content": "x"])
        #expect(write.capabilities == [.clipboardWrite] && write.tier == .reversibleWrite)
        #expect(throws: ToolError.self) { try req(ClipboardWriteTool(), [:]) }

        #expect(try req(AccessibilityStatusTool(), [:]).capabilities.isEmpty)
        let tree = try req(AccessibilityTreeTool(), ["bundleID": "com.apple.finder"])
        #expect(tree.capabilities == [.accessibility(bundleID: "com.apple.finder")] && tree.tier == .readOnly)
        let press = try req(AccessibilityPressTool(), ["bundleID": "com.apple.finder", "element": "AXApplication/AXWindow[0]"])
        #expect(press.capabilities == [.accessibility(bundleID: "com.apple.finder")] && press.tier == .consequential)
        let type = try req(AccessibilityTypeTextTool(), ["bundleID": "com.apple.finder", "element": "AXApplication/AXWindow[0]", "text": "hi"])
        #expect(type.tier == .consequential)
        #expect(throws: ToolError.self) { try req(AccessibilityFindTool(), ["bundleID": "com.apple.finder"]) }
        #expect(throws: ToolError.self) { try req(AccessibilityTreeTool(), ["bundleID": "not a bundle id!"]) }
        #expect(throws: ToolError.self) { try req(AccessibilityWaitForTool(), ["bundleID": "com.apple.finder", "condition": "valueEquals", "role": "AXButton"]) }

        let capture = try req(ScreenCaptureTool(), ["scope": "window", "bundleID": "com.apple.finder"])
        #expect(capture.capabilities.first == .screenCapture(scope: "window:com.apple.finder"))
        #expect(capture.tier == .reversibleWrite)
        if case .fileWrite(let path)? = capture.capabilities.last {
            #expect(path.hasPrefix(dir.url.path + "/artifacts/") && path.hasSuffix(".png"))
        } else { Issue.record("screen.capture must declare the file it writes") }
        let display = try req(ScreenCaptureTool(), ["scope": "display", "path": "shots/a.png"])
        #expect(display.capabilities == [.screenCapture(scope: "display"), .fileWrite(path: dir.url.path + "/shots/a.png")])
        let region = try req(ScreenCaptureTool(), ["scope": "region", "region": ["x": 0, "y": 0, "width": 10, "height": 10]])
        #expect(region.capabilities.first == .screenCapture(scope: "region"))
        #expect(throws: ToolError.self) { try req(ScreenCaptureTool(), ["scope": "region"]) }
        // Password managers are never a capture target.
        do {
            _ = try req(ScreenCaptureTool(), ["scope": "window", "bundleID": "com.apple.keychainaccess"])
            Issue.record("capturing Keychain Access must be refused")
        } catch let e as ToolError {
            if case .permissionDenied = e {} else { Issue.record("expected permissionDenied, got \(e)") }
        }
        #expect(throws: ToolError.self) { try req(ScreenCaptureTool(additionalSensitiveBundleIDs: ["com.example.Vault"]), ["scope": "window", "bundleID": "com.example.vault"]) }

        let ocr = try req(ScreenOCRTool(), ["path": "a/../b.png"])
        #expect(ocr.capabilities == [.fileRead(path: dir.url.path + "/b.png")] && ocr.tier == .readOnly)
        let compare = try req(ScreenCompareTool(), ["before": "a.png", "after": "b.png", "diffPath": "d.png"])
        #expect(compare.capabilities == [.fileRead(path: dir.url.path + "/a.png"), .fileRead(path: dir.url.path + "/b.png"), .fileWrite(path: dir.url.path + "/d.png")])

        let launch = try req(SystemLaunchAppTool(), ["bundleID": "com.apple.finder"])
        #expect(launch.capabilities == [.appControl(bundleID: "com.apple.finder")] && launch.tier == .consequential)
        let byPath = try req(SystemLaunchAppTool(), ["path": "/System/Library/CoreServices/Finder.app"])
        #expect(byPath.capabilities == [.appControl(bundleID: "com.apple.finder")])
        let quit = try req(SystemQuitAppTool(), ["bundleID": "com.apple.finder"])
        #expect(quit.capabilities == [.appControl(bundleID: "com.apple.finder")] && quit.tier == .consequential)
        let notify = try req(NotificationsPostTool(), ["title": "Done", "body": "ok"])
        #expect(notify.capabilities == [.notify] && notify.tier == .reversibleWrite)
        #expect(try req(SystemAppsTool(), [:]).tier == .readOnly)
    }
}

@Suite("Unit · script target scanner")
struct ScannerTests {
    let resolve: (String) -> String? = { name in
        ["finder": "com.apple.finder", "mail": "com.apple.mail", "system events": "com.apple.systemevents", "safari": "com.apple.Safari",
         "/applications/safari.app": "com.apple.Safari", "com.apple.mail": "com.apple.mail"][name.lowercased()]
    }
    func targets(_ script: String, _ language: ScriptLanguage, declared: [String]) throws -> [String] {
        try ScriptTargetScanner.verifiedTargets(ScriptTargetScanner.scan(script, language: language), declared: declared, resolve: resolve, canonical: { $0 })
    }

    @Test func appleScriptTargetShapes() {
        func refs(_ s: String) -> ([String], [String]) { let r = ScriptTargetScanner.scan(s, language: .applescript); return (r.applicationReferences, r.bundleIDReferences) }
        #expect(refs("tell application \"Finder\" to get name of startup disk").0 == ["Finder"])
        #expect(refs("tell app \"Mail\"\n  activate\nend tell").0 == ["Mail"])
        #expect(refs("tell application id \"com.apple.mail\" to activate").1 == ["com.apple.mail"])
        #expect(refs("tell application id \"com.apple.mail\" to activate").0.isEmpty)
        #expect(refs("set n to name of application \"Safari\"\nactivate application \"Finder\"").0 == ["Safari", "Finder"])
        #expect(refs("tell application \"System Events\" to tell application process \"Finder\" to get windows").0 == ["System Events"])
        #expect(refs("using terms from application \"Mail\"\nend using terms from").0 == ["Mail"])
        #expect(refs("tell  APPLICATION   \"Finder\" to beep").0 == ["Finder"])
        #expect(refs("tell application ¬\n \"Finder\" to beep").0 == ["Finder"])
        #expect(refs("tell application \"Finder\"\n tell application \"Finder\" to beep\nend tell").0 == ["Finder"])
    }

    @Test func appleScriptIgnoresStringsAndComments() {
        let scan = ScriptTargetScanner.scan("""
        -- tell application "Mail" to delete every message
        # tell application "Safari" to quit
        (* tell application "Notes" (* nested *) to quit *)
        set s to "tell application \\"Terminal\\" to do shell script \\"rm\\""
        return s & " and the application is fine"
        """, language: .applescript)
        #expect(scan.applicationReferences.isEmpty)
        #expect(!scan.usesShell)
        #expect(scan.dynamicConstructs.isEmpty)
        #expect(!scan.hasTargets)
    }

    @Test func appleScriptPureComputationHasNoTargets() {
        for s in ["2 + 2", "set x to 3\nreturn x * x", "(current date) as string", "count of {1, 2, 3}", "tell current application to return 1",
                  "path to frontmost application", "tell me to return 5", "name of current application"] {
            let scan = ScriptTargetScanner.scan(s, language: .applescript)
            #expect(!scan.hasTargets, "\(s)")
            #expect(scan.dynamicConstructs.isEmpty, "\(s): \(scan.dynamicConstructs)")
            #expect(!scan.needsShellRuntime, "\(s)")
        }
    }

    @Test func appleScriptDynamicTargetsAreRefused() {
        for s in ["set a to \"Mail\"\ntell application a to quit", "tell application (\"Ma\" & \"il\") to quit", "tell application id theID to quit",
                  "tell app someVariable to activate", "run script \"tell application \\\"Mail\\\" to quit\"", "load script file \"x.scpt\""] {
            let scan = ScriptTargetScanner.scan(s, language: .applescript)
            #expect(!scan.dynamicConstructs.isEmpty, "\(s)")
            #expect(throws: ToolError.self, "\(s)") { try ScriptTargetScanner.verifiedTargets(scan, declared: ["com.apple.mail"], resolve: resolve, canonical: { $0 }) }
        }
    }

    @Test func appleScriptEscapesAreDetected() {
        #expect(ScriptTargetScanner.scan("do shell script \"ls\"", language: .applescript).usesShell)
        #expect(ScriptTargetScanner.scan("do  shell\tscript \"ls\"", language: .applescript).needsShellRuntime)
        #expect(ScriptTargetScanner.scan("use framework \"Foundation\"\nreturn 1", language: .applescript).usesObjCBridge)
        #expect(ScriptTargetScanner.scan("set f to open for access POSIX file \"/tmp/x\" with write permission", language: .applescript).usesFileIO)
        #expect(ScriptTargetScanner.scan("set the clipboard to \"x\"", language: .applescript).writesClipboard)
        #expect(!ScriptTargetScanner.scan("set the clipboard to \"x\"", language: .applescript).readsClipboard)
        #expect(ScriptTargetScanner.scan("return the clipboard", language: .applescript).readsClipboard)
        #expect(ScriptTargetScanner.scan("open location \"https://example.com\"", language: .applescript).opensLocation)
        #expect(!ScriptTargetScanner.scan("return \"do shell script\"", language: .applescript).usesShell)
    }

    @Test func jxaTargetShapes() {
        func scan(_ s: String) -> ScriptScan { ScriptTargetScanner.scan(s, language: .jxa) }
        #expect(scan("Application(\"Finder\").startupDisk.name()").applicationReferences == ["Finder"])
        #expect(scan("const m = Application('com.apple.mail'); m.activate()").applicationReferences == ["com.apple.mail"])
        #expect(scan("Application ( `Safari` ).windows()").applicationReferences == ["Safari"])
        #expect(scan("var a = Application('/Applications/Safari.app')\nvar f = Application(\"Finder\")").applicationReferences == ["/Applications/Safari.app", "Finder"])
        let current = scan("var app = Application.currentApplication(); app.includeStandardAdditions = true; app.displayName")
        #expect(current.usesCurrentApplication && !current.hasTargets && current.dynamicConstructs.isEmpty)
        let commented = scan("// Application('Mail').quit()\n/* Application(\"Notes\") */\nvar s = \"Application('Terminal')\"; 1 + 1")
        #expect(!commented.hasTargets && commented.dynamicConstructs.isEmpty)
        for s in ["1 + 2", "JSON.stringify({a: [1, 2]})", "new Date(0).toISOString()", "'abc'.toUpperCase()", "function run() { return 42 }"] {
            let r = scan(s)
            #expect(!r.hasTargets && r.dynamicConstructs.isEmpty && !r.needsShellRuntime, "\(s)")
        }
    }

    @Test func jxaDynamicTargetsAreRefused() {
        for s in ["var n = 'Mail'; Application(n).quit()", "Application(`${name}`)", "const A = Application; A('Mail')", "Application('Ma' + 'il')",
                  "eval(\"Application('Mail').quit()\")", "new Function('return 1')()", "globalThis['Appl' + 'ication']('Mail')", "this['Application']('Mail')"] {
            let scan = ScriptTargetScanner.scan(s, language: .jxa)
            #expect(!scan.dynamicConstructs.isEmpty, "\(s)")
            #expect(throws: ToolError.self, "\(s)") { try ScriptTargetScanner.verifiedTargets(scan, declared: ["com.apple.mail"], resolve: resolve, canonical: { $0 }) }
        }
    }

    @Test func jxaEscapesAreDetected() {
        func scan(_ s: String) -> ScriptScan { ScriptTargetScanner.scan(s, language: .jxa) }
        #expect(scan("var a = Application.currentApplication(); a.includeStandardAdditions = true; a.doShellScript('ls')").usesShell)
        #expect(scan("ObjC.import('stdlib'); $.system('ls')").usesShell)
        #expect(scan("ObjC.import('Foundation'); $.NSTask.alloc.init").usesObjCBridge)
        #expect(scan("$('x')").needsShellRuntime)
        #expect(scan("Path('/etc/hosts')").usesFileIO)
        #expect(scan("app.setTheClipboardTo('x')").writesClipboard)
        #expect(scan("app.theClipboard()").readsClipboard)
        #expect(!scan("var s = 'doShellScript'; `costs $5`").needsShellRuntime)
    }

    @Test func undeclaredTargetsAreRefusedAndDeclaredOnesPass() throws {
        #expect(try targets("tell application \"Finder\" to beep", .applescript, declared: ["com.apple.finder"]) == ["com.apple.finder"])
        #expect(try targets("tell application \"Finder\" to beep", .applescript, declared: ["COM.APPLE.FINDER", "com.apple.finder"]).count == 1)
        #expect(try targets("tell application id \"com.apple.mail\" to beep", .applescript, declared: ["com.apple.mail"]) == ["com.apple.mail"])
        #expect(try targets("Application('Safari').windows()", .jxa, declared: ["com.apple.Safari"]) == ["com.apple.Safari"])
        #expect(try targets("Application('/Applications/Safari.app').windows()", .jxa, declared: ["com.apple.safari"]) == ["com.apple.safari"])
        #expect(try targets("1 + 1", .applescript, declared: []).isEmpty)
        // Declared but unused targets remain declared (they still need the capability).
        #expect(try targets("1 + 1", .jxa, declared: ["com.apple.mail"]) == ["com.apple.mail"])

        #expect(throws: ToolError.self) { try targets("tell application \"Mail\" to beep", .applescript, declared: []) }
        #expect(throws: ToolError.self) { try targets("tell application \"Mail\" to beep", .applescript, declared: ["com.apple.finder"]) }
        #expect(throws: ToolError.self) { try targets("tell application \"Finder\" to tell application \"Mail\" to beep", .applescript, declared: ["com.apple.finder"]) }
        #expect(throws: ToolError.self) { try targets("tell application id \"com.apple.mail\" to beep", .applescript, declared: ["com.apple.finder"]) }
        #expect(throws: ToolError.self) { try targets("Application('Mail').quit()", .jxa, declared: ["com.apple.finder"]) }
        #expect(throws: ToolError.self) { try targets("tell application \"NoSuchApp12345\" to beep", .applescript, declared: ["com.apple.finder"]) }
        #expect(throws: ToolError.self) { try targets("1", .applescript, declared: ["not a bundle id"]) }
    }

    @Test func requirementsCarryRuntimeTargetsAndShellEscalation() throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let ctx = dir.toolContext()
        let apple = ScriptRunTool(language: .applescript), jxa = ScriptRunTool(language: .jxa)

        let pure = try apple.requirements(for: ToolInput(arguments: ["script": "2 + 2"]), context: ctx)
        #expect(pure.capabilities == [.scriptRuntime(name: "applescript")] && pure.tier == .reversibleWrite)
        let targeted = try apple.requirements(for: ToolInput(arguments: ["script": "tell application \"Finder\" to get name of startup disk", "targets": ["com.apple.finder"]]), context: ctx)
        #expect(targeted.capabilities == [.scriptRuntime(name: "applescript"), .appAutomation(bundleID: "com.apple.finder")] && targeted.tier == .consequential)
        let shell = try apple.requirements(for: ToolInput(arguments: ["script": "do shell script \"date\""]), context: ctx)
        #expect(shell.capabilities == [.scriptRuntime(name: "applescript"), .scriptRuntime(name: "bash")] && shell.tier == .consequential)
        let jxaShell = try jxa.requirements(for: ToolInput(arguments: ["script": "ObjC.import('stdlib'); $.system('date')"]), context: ctx)
        #expect(jxaShell.capabilities == [.scriptRuntime(name: "jxa"), .scriptRuntime(name: "bash")] && jxaShell.tier == .consequential)
        let jxaPure = try jxa.requirements(for: ToolInput(arguments: ["script": "1 + 1"]), context: ctx)
        #expect(jxaPure.capabilities == [.scriptRuntime(name: "jxa")] && jxaPure.tier == .reversibleWrite)
        let clip = try apple.requirements(for: ToolInput(arguments: ["script": "return the clipboard"]), context: ctx)
        #expect(clip.capabilities.contains(.clipboardRead))

        #expect(throws: ToolError.self) { try apple.requirements(for: ToolInput(arguments: ["script": "tell application \"Finder\" to beep"]), context: ctx) }
        #expect(throws: ToolError.self) { try jxa.requirements(for: ToolInput(arguments: ["script": "Application('Finder').name()", "targets": ["com.apple.mail"]]), context: ctx) }
        #expect(throws: ToolError.self) { try apple.requirements(for: ToolInput(arguments: ["script": "   "]), context: ctx) }
    }
}

@Suite("Unit · parsers and pure helpers")
struct ParserTests {
    @Test func appleScriptSourceFormBecomesJSON() {
        #expect(AppleScriptValueParser.parse("4") == .int(4))
        #expect(AppleScriptValueParser.parse("-3.5") == .number(-3.5))
        #expect(AppleScriptValueParser.parse("3,5") == .number(3.5))
        #expect(AppleScriptValueParser.parse("1.0E+10") == .number(1.0e10))
        #expect(AppleScriptValueParser.parse("\"a\\\"b\\nc\"") == .string("a\"b\nc"))
        #expect(AppleScriptValueParser.parse("true") == .bool(true))
        #expect(AppleScriptValueParser.parse("missing value") == .null)
        #expect(AppleScriptValueParser.parse("{}") == .array([]))
        #expect(AppleScriptValueParser.parse("{1, 2.5, \"x\", false, {3, 4}}") == [1, 2.5, "x", false, [3, 4]])
        #expect(AppleScriptValueParser.parse("{1,5, 2}") == [1.5, 2])
        #expect(AppleScriptValueParser.parse("{a:1, b:missing value, |my key|:\"v\"}") == ["a": 1, "b": .null, "my key": "v"])
        #expect(AppleScriptValueParser.parse("date \"samedi 21 novembre 2026\"") == nil)
        #expect(AppleScriptValueParser.parse("application \"Finder\"") == nil)
        #expect(AppleScriptValueParser.parse("{1, date \"x\"}") == nil)
        #expect(AppleScriptValueParser.parse("") == nil)
    }

    @Test func osascriptErrorsAreParsedByNumberNotByLanguage() {
        let script = "set x to 1\ntell application \"Finder\" to get nme of\n"
        let syntax = ScriptError.parseOsascript("50:51: syntax error: expression prévu(s) mais fin de ligne trouvé(s). (-2741)", script: script)
        #expect(syntax.isSyntax && syntax.number == -2741 && syntax.line == 2 && syntax.column == 40)
        let exec = ScriptError.parseOsascript("6:12: execution error: boom (42)", script: "error \"boom\" number 42")
        #expect(!exec.isSyntax && exec.number == 42 && exec.message == "boom" && exec.line == 1)
        let tcc = ScriptError.parseOsascript("0:10: execution error: Not authorized to send Apple events to Finder. (-1743)", script: "x")
        #expect(tcc.number == -1743)
        let jxa = ScriptError.fromJXA(["ok": false, "name": "SyntaxError", "message": "Unexpected token ';'", "line": 3, "column": 9, "errorNumber": .null])
        #expect(jxa.isSyntax && jxa.line == 3 && jxa.column == 9)
        let jxaTCC = ScriptError.fromJXA(["ok": false, "name": "Error", "message": "Not authorized to send Apple events to Finder. (-1743)", "line": 1, "column": .null, "errorNumber": .null])
        #expect(jxaTCC.number == -1743)
    }

    @Test func typingStepsSplitUnicodeAndControlKeys() {
        typealias Step = AccessibilityTypeTextTool.Step
        #expect(AccessibilityTypeTextTool.steps(for: "ab\tc\nd") == [.text("ab"), .key(48), .text("c"), .key(36), .text("d")])
        #expect(AccessibilityTypeTextTool.steps(for: "a\r\nb") == [.text("a"), .key(36), .text("b")])
        let long = String(repeating: "é👍", count: 20)
        let steps = AccessibilityTypeTextTool.steps(for: long)
        var rebuilt = ""
        for case .text(let t) in steps { #expect(t.utf16.count <= 16); rebuilt += t }
        #expect(rebuilt == long)
    }

    @Test func secureFieldsAreRecognisedAndNeverDescribed() {
        #expect(AX.isSecure(role: "AXSecureTextField", subrole: nil))
        #expect(AX.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        #expect(!AX.isSecure(role: "AXTextField", subrole: nil))
        var info = AX.Info(); info.role = "AXTextField"; info.subrole = "AXSecureTextField"; info.value = .string(AX.securePlaceholder)
        #expect(info.json(path: "p", depth: 0)["value"] == .string("«secure»"))
        #expect(info.json(path: "p", depth: 0)["secure"] == true)
        // A value filter never matches a secure field.
        let filter = AX.Filter(ToolInput(arguments: ["value": "secure"]))
        #expect(!filter.matches(info))

        let secure = InputRecorder.describeValueChange(role: "AXSecureTextField", subrole: nil, title: "Password", value: .string("hunter2"), captureText: true)
        #expect(secure.value == nil && !secure.summary.contains("hunter2") && !secure.summary.contains("7"))
        let text = InputRecorder.describeValueChange(role: "AXTextField", subrole: nil, title: "Subject", value: .string("Hello world"), captureText: false)
        #expect(text.summary == "typed text of length 11 in field \"Subject\"" && text.value == nil)
        let opted = InputRecorder.describeValueChange(role: "AXTextField", subrole: nil, title: "Subject", value: .string("Hello"), captureText: true)
        #expect(opted.value == .string("Hello"))
        let box = InputRecorder.describeValueChange(role: "AXCheckBox", subrole: nil, title: "Remember", value: .int(1), captureText: false)
        #expect(box.value == .int(1) && box.summary.contains("Remember"))
    }

    @Test func accessibilityFilterMatchesRoleTitleIdentifierValue() {
        var info = AX.Info(); info.role = "AXButton"; info.title = "Save As…"; info.identifier = "save-button"; info.value = .string("on")
        #expect(AX.Filter(ToolInput(arguments: ["role": "AXButton", "title": "save"])).matches(info))
        #expect(AX.Filter(ToolInput(arguments: ["identifier": "save-button", "value": "ON"])).matches(info))
        #expect(!AX.Filter(ToolInput(arguments: ["role": "AXCheckBox"])).matches(info))
        #expect(!AX.Filter(ToolInput(arguments: ["identifier": "save"])).matches(info))
        #expect(AX.Filter(ToolInput(arguments: [:])).isEmpty)
    }

    @Test func notificationResponsesMapToActions() {
        typealias B = NotificationCenterBridge
        let approve = B.interpret(actionIdentifier: B.approveActionID, notificationID: "n1", userInfo: [B.runIDKey: "run-1", B.approvalIDKey: "ap-1"])
        #expect(approve.action == .approve && approve.runID == "run-1" && approve.approvalID == "ap-1" && approve.notificationID == "n1")
        #expect(B.interpret(actionIdentifier: B.denyActionID, notificationID: "n", userInfo: [:]).action == .deny)
        #expect(B.interpret(actionIdentifier: B.openActionID, notificationID: "n", userInfo: [:]).action == .open)
        #expect(B.interpret(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", notificationID: "n", userInfo: [:]).action == .open)
        #expect(B.interpret(actionIdentifier: "com.apple.UNNotificationDismissActionIdentifier", notificationID: "n", userInfo: [:]).action == .dismissed)
        #expect(B.interpret(actionIdentifier: "x", notificationID: "n", userInfo: [:]).action == .other)
        let ids = B.categories().map(\.identifier).sorted()
        #expect(ids == [B.approvalCategoryID, B.infoCategoryID].sorted())
        let actions = B.categories().first { $0.identifier == B.approvalCategoryID }?.actions.map(\.identifier)
        #expect(actions == [B.approveActionID, B.denyActionID, B.openActionID])
    }

    @Test func settingsLinksAndBundleIdentifierValidation() {
        for p in MacPermission.allCases {
            let url = MacPermissions.settingsURL(for: p)
            #expect(url.scheme == "x-apple.systempreferences")
            #expect(!MacPermissions.howToEnable(p).isEmpty)
        }
        #expect(MacPermissions.settingsURL(for: .accessibility).absoluteString.hasSuffix("Privacy_Accessibility"))
        #expect(MacPermissions.settingsURL(for: .screenRecording).absoluteString.hasSuffix("Privacy_ScreenCapture"))
        #expect(MacPermissions.settingsURL(for: .appleEvents).absoluteString.hasSuffix("Privacy_Automation"))
        #expect(MacPermissions.settingsURL(for: .fullDiskAccess).absoluteString.hasSuffix("Privacy_AllFiles"))
        #expect(AppResolver.isValidBundleID("com.apple.finder"))
        #expect(!AppResolver.isValidBundleID("com.apple finder"))
        #expect(!AppResolver.isValidBundleID("../etc"))
        #expect(!AppResolver.isValidBundleID(""))
    }
}
