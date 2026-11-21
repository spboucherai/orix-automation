// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Tests/ORIXAppleAutomationTests/IntegrationTests.swift
// Description: Integration tests against the real system: osascript, sdef, NSWorkspace, window server, Vision, pasteboard, Accessibility and ScreenCaptureKit (the last two gated on the actual TCC status, never prompting).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ORIXCore
import ORIXTestingSupport
import Testing
@testable import ORIXAppleAutomation

@Suite("Integration · permissions (real TCC status, no prompt)")
struct PermissionIntegrationTests {
    @Test func everyPermissionHasAStatus() {
        var lines: [String] = []
        for p in MacPermission.allCases {
            let s = MacPermissions.status(p)
            #expect(PermissionStatus.allCases.contains(s))
            lines.append("\(p.rawValue)=\(s.rawValue)")
        }
        let finder = MacPermissions.automationStatus(bundleID: "com.apple.finder")
        lines.append("appleEvents(com.apple.finder)=\(finder.rawValue)")
        print("TCC status of the test process: " + lines.joined(separator: ", "))
        #expect(MacPermissions.status(.accessibility) == (AXIsProcessTrusted() ? .granted : .denied))
        #expect(MacPermissions.status(.screenRecording) == (CGPreflightScreenCaptureAccess() ? .granted : .denied))
        // `swift test` is not an application bundle: notifications cannot be evaluated, and that is what is reported.
        #expect(MacPermissions.hasAppBundle == false)
        #expect(MacPermissions.status(.notifications) == .unknown)
        #expect(MacPermissions.status(.appleEvents) == .unknown)
        #expect(MacPermissions.automationStatus(bundleID: "com.example.not-running-\(UUID().uuidString.prefix(6))") == .unknown)
        #expect(MacPermissions.snapshot().count == MacPermission.allCases.count)
    }

    @Test func applicationResolutionUsesInstalledBundles() {
        #expect(AppResolver.bundleID(forName: "Finder") == "com.apple.finder")
        #expect(AppResolver.bundleID(forReference: "System Events") == "com.apple.systemevents")
        #expect(AppResolver.bundleID(forReference: "/System/Library/CoreServices/Finder.app") == "com.apple.finder")
        #expect(AppResolver.bundleID(forReference: "com.apple.finder") == "com.apple.finder")
        #expect(AppResolver.bundleID(forReference: "NoSuchApp-\(UUID().uuidString)") == nil)
        #expect(AppResolver.canonicalBundleID("COM.APPLE.FINDER") == "com.apple.finder")
    }
}

@Suite("Integration · applescript.run / jxa.run (real osascript)")
struct ScriptIntegrationTests {
    let apple = ScriptRunTool(language: .applescript)
    let jxa = ScriptRunTool(language: .jxa)

    @Test func appleScriptArithmeticStringsListsAndDates() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        var o = await invoke(apple, ["script": "(6 * 7) + 0.5"], in: dir)
        #expect(o.result.status == .succeeded, "\(o.result.failure?.message ?? "")")
        #expect(o.result.output["value"] == .number(42.5))
        #expect(o.result.output["parsed"] == true)
        #expect(o.result.untrusted)

        o = await invoke(apple, ["script": "set s to \"orix\" & \" \" & \"automation\"\nreturn (count of s) as string & \":\" & s"], in: dir)
        #expect(o.result.output["value"] == "15:orix automation")
        #expect(o.result.output["result"] == "\"15:orix automation\"")

        o = await invoke(apple, ["script": "set out to {}\nrepeat with i from 1 to 3\n set end of out to i * i\nend repeat\nreturn {squares:out, ok:true, label:\"é\"}"], in: dir)
        #expect(o.result.output["value"] == ["squares": [1, 4, 9], "ok": true, "label": "é"])

        o = await invoke(apple, ["script": "return (year of (current date)) >= 2026"], in: dir)
        #expect(o.result.output["value"] == true)
        let year = Calendar.current.component(.year, from: Date())
        o = await invoke(apple, ["script": "year of ((current date) + 0)"], in: dir)
        #expect(o.result.output["value"] == .int(year))

        // A date is not representable as JSON: the text is returned and the tool says it was not parsed.
        o = await invoke(apple, ["script": "current date"], in: dir)
        #expect(o.result.status == .succeeded)
        #expect(o.result.output["parsed"] == false)
        #expect(o.result.output["result"]?.stringValue?.hasPrefix("date ") == true)
    }

    @Test func appleScriptSyntaxAndRuntimeErrorsAreTyped() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        var o = await invoke(apple, ["script": "set x to 1\nset y to (2 +\nreturn x"], in: dir)
        #expect(o.result.status == .failed)
        #expect(o.result.failure?.code == "syntax_error")
        #expect(o.result.output["line"]?.intValue == 2 || o.result.output["line"]?.intValue == 3, "line \(String(describing: o.result.output["line"]))")
        #expect(o.result.output["errorNumber"]?.intValue == -2741)
        #expect(o.result.failure?.message.contains("line") == true)

        o = await invoke(apple, ["script": "error \"boom\" number 4242"], in: dir)
        #expect(o.result.failure?.code == "script_error")
        #expect(o.result.output["errorNumber"] == 4242)
        #expect(o.result.failure?.message.contains("boom") == true)

        o = await invoke(apple, ["script": "return 1 / 0"], in: dir)
        #expect(o.result.failure?.code == "script_error")
        #expect(o.result.output["errorNumber"] == -2701)
    }

    @Test func scriptsAreStoppedAtTheTimeout() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let started = Date()
        var o = await invoke(apple, ["script": "repeat\nend repeat", "timeoutSeconds": 1.5], in: dir)
        #expect(o.result.status == .timedOut)
        #expect(o.error == .timeout(seconds: 1.5))
        o = await invoke(jxa, ["script": "while (true) {}", "timeoutSeconds": 1.5], in: dir)
        #expect(o.result.status == .timedOut)
        #expect(Date().timeIntervalSince(started) < 12)
    }

    @Test func runningScriptIsTerminatedOnCancellation() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let tool = apple
        let task = Task { await invoke(tool, ["script": "repeat\nend repeat", "timeoutSeconds": 25], in: dir) }
        try await Task.sleep(nanoseconds: 700_000_000)
        let started = Date()
        task.cancel()
        let o = await task.value
        #expect(o.result.status == .canceled)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func jxaReturnsStructuredJSON() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        var o = await invoke(jxa, ["script": "const xs = [1, 2, 3].map(x => x * x); ({sum: xs.reduce((a, b) => a + b, 0), xs: xs, name: 'orix'.toUpperCase()})"], in: dir)
        #expect(o.result.status == .succeeded, "\(o.result.failure?.message ?? "")")
        #expect(o.result.output["value"] == ["sum": 14, "xs": [1, 4, 9], "name": "ORIX"])
        #expect(o.result.output["parsed"] == true)

        o = await invoke(jxa, ["script": "new Date(86400000).toISOString()"], in: dir)
        #expect(o.result.output["value"] == "1970-01-02T00:00:00.000Z")
        #expect(o.result.output["result"] == "1970-01-02T00:00:00.000Z")

        o = await invoke(jxa, ["script": "function run(argv) { return 6 * 7 }"], in: dir)
        #expect(o.result.output["value"] == 42)

        o = await invoke(jxa, ["script": "var nothing; nothing"], in: dir)
        #expect(o.result.status == .succeeded)
        #expect(o.result.output["value"] == .null && o.result.output["parsed"] == false)
    }

    @Test func jxaErrorsCarryLineInformation() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        var o = await invoke(jxa, ["script": "var a = 1;\nvar b = (;\na"], in: dir)
        #expect(o.result.failure?.code == "syntax_error", "\(String(describing: o.result.failure))")
        #expect(o.result.output["line"] == 2)

        // A SyntaxError raised while running (not while compiling) is a script error, not a syntax error.
        o = await invoke(jxa, ["script": "JSON.parse('{')"], in: dir)
        #expect(o.result.failure?.code == "script_error")

        o = await invoke(jxa, ["script": "var a = 1;\n\nundefinedFunction(a)"], in: dir)
        #expect(o.result.failure?.code == "script_error")
        #expect(o.result.output["line"] == 3)
        #expect(o.result.failure?.message.contains("undefinedFunction") == true)
    }

    @Test func undeclaredTargetNeverRuns() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let marker = dir.file("ran.txt")
        // If the refusal were not static, the shell command would create the marker before the Finder call.
        let script = "do shell script \"touch \" & quoted form of \"\(marker.path)\"\ntell application \"Finder\" to get name of startup disk"
        let o = await invoke(apple, ["script": .string(script), "targets": []], in: dir)
        #expect(o.result.status == .invalidInput)
        #expect(o.result.failure?.message.contains("Finder") == true)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        let j = await invoke(jxa, ["script": "Application('Finder').startupDisk.name()", "targets": ["com.apple.mail"]], in: dir)
        #expect(j.result.status == .invalidInput)
    }

    @Test func dryRunDoesNotExecute() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let marker = dir.file("ran.txt")
        let o = await invoke(apple, ["script": .string("do shell script \"touch \" & quoted form of \"\(marker.path)\"")], in: dir, dryRun: true)
        #expect(o.result.status == .simulated)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func shellEscapeRunsOnlyThroughTheDeclaredRuntime() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(apple, ["script": "do shell script \"printf orix-shell\""], in: dir)
        #expect(o.requirements?.capabilities.contains(.scriptRuntime(name: "bash")) == true)
        #expect(o.requirements?.tier == .consequential)
        #expect(o.result.output["value"] == "orix-shell")
    }

    @Test func finderScriptSucceedsOrReportsTheAppleEventsBlock() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let status = MacPermissions.automationStatus(bundleID: "com.apple.finder")
        if status == .notDetermined {
            // Running it would make macOS show the Automation consent dialog: tests never prompt.
            skipped("apple events consent for Finder is undetermined for this test process; running the script would show the system prompt")
            return
        }
        for (tool, script) in [(apple, "tell application \"Finder\" to get name of startup disk"), (jxa, "Application('Finder').startupDisk.name()")] {
            let o = await invoke(tool, ["script": .string(script), "targets": ["com.apple.finder"], "timeoutSeconds": 20], in: dir, timeout: 20)
            if o.result.status == .succeeded {
                let name = o.result.output["value"]?.stringValue ?? ""
                #expect(!name.isEmpty)
                #expect(o.result.output["targets"] == ["com.apple.finder"])
                verified("\(tool.identifier) talked to Finder: startup disk is \"\(name)\"")
            } else if case .tccBlocked(let permission, let message)? = o.error {
                #expect(permission == .appleEvents)
                #expect(message.contains("Finder"))
                #expect(o.result.status == .blockedPermission)
                skipped("apple events not authorized for this test process (\(tool.identifier))")
            } else {
                Issue.record("\(tool.identifier): expected success or tccBlocked(.appleEvents), got \(o.result.status) \(o.result.failure?.message ?? "")")
            }
        }
    }
}

@Suite("Integration · applescript.dictionary (real sdef)")
struct DictionaryIntegrationTests {
    @Test func finderDictionaryIsSummarised() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(ScriptingDictionaryTool(), ["bundleID": "com.apple.finder"], in: dir)
        #expect(o.result.status == .succeeded, "\(o.result.failure?.message ?? "")")
        #expect(o.requirements?.capabilities == [.fileRead(path: "/System/Library/CoreServices/Finder.app")])
        let suites = o.result.output["suites"]?.arrayValue ?? []
        #expect(suites.count >= 3)
        #expect(suites.contains { $0["name"] == "Standard Suite" })
        let commands = suites.flatMap { $0["commands"]?.arrayValue ?? [] }
        let open = commands.first { $0["name"] == "open" }
        #expect(open != nil)
        #expect(open?["parameters"]?.arrayValue?.contains { $0["name"] == "using" } == true)
        let classes = suites.flatMap { $0["classes"]?.arrayValue ?? [] }
        let withProperties = classes.filter { !($0["properties"]?.arrayValue ?? []).isEmpty }
        #expect(!withProperties.isEmpty)
        #expect((o.result.output["commandCount"]?.intValue ?? 0) > 10)
        #expect(o.result.untrusted)
        #expect(o.result.output.serialized().utf8.count < 262_144)
    }

    @Test func boundIsHonoured() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(ScriptingDictionaryTool(), ["path": "/System/Library/CoreServices/Finder.app", "maxItems": 2], in: dir)
        #expect(o.result.status == .succeeded)
        for suite in o.result.output["suites"]?.arrayValue ?? [] {
            #expect((suite["commands"]?.arrayValue?.count ?? 0) <= 2)
            #expect((suite["classes"]?.arrayValue?.count ?? 0) <= 2)
        }
        #expect(o.result.truncated)
    }

    @Test func appWithoutDictionaryIsReportedUnsupported() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(ScriptingDictionaryTool(), ["path": "/System/Applications/Calculator.app"], in: dir)
        #expect(o.result.status == .unsupported, "\(o.result.status) \(o.result.failure?.message ?? "")")
        let missing = await invoke(ScriptingDictionaryTool(), ["bundleID": "com.example.absent.app"], in: dir)
        #expect(missing.result.failure?.code == "not_found")
    }
}

// Serialized: one test launches Calculator while another asserts that a dry run launched nothing.
@Suite("Integration · system.* (real NSWorkspace and window server)", .serialized)
struct SystemIntegrationTests {
    @Test func runningApplicationsIncludeFinder() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(SystemAppsTool(), ["includeBackground": true], in: dir)
        #expect(o.result.status == .succeeded)
        let apps = o.result.output["applications"]?.arrayValue ?? []
        let finder = apps.first { $0["bundleID"] == "com.apple.finder" }
        #expect(finder != nil)
        #expect((finder?["pid"]?.intValue ?? 0) > 0)
        #expect(finder?["name"]?.stringValue?.isEmpty == false)
        let regular = await invoke(SystemAppsTool(), [:], in: dir)
        #expect((regular.result.output["applications"]?.arrayValue?.count ?? 0) <= apps.count)
    }

    @Test func frontmostDegradesHonestly() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(SystemFrontmostTool(), [:], in: dir)
        #expect(o.result.status == .succeeded)
        let source = o.result.output["titleSource"]?.stringValue
        if AXIsProcessTrusted() { #expect(source == "accessibility") }
        else if CGPreflightScreenCaptureAccess() { #expect(source == "windowList") }
        else {
            #expect(source == "none")
            #expect(o.result.output["windowTitle"] == .null)
            #expect(o.result.output["note"]?.stringValue?.contains("Accessibility") == true)
        }
        print("system.frontmost: app=\(o.result.output["application"]?["name"]?.stringValue ?? "none") titleSource=\(source ?? "?")")
    }

    @Test func windowsSayWhetherTitlesAreAvailable() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(SystemWindowsTool(), ["includeAllLayers": true], in: dir)
        #expect(o.result.status == .succeeded)
        let titles = CGPreflightScreenCaptureAccess()
        #expect(o.result.output["titlesAvailable"] == .bool(titles))
        let windows = o.result.output["windows"]?.arrayValue ?? []
        if !titles {
            #expect(windows.allSatisfy { $0["title"] == nil })
            #expect(o.result.output["note"]?.stringValue?.contains("Screen Recording") == true)
        }
        for w in windows.prefix(20) {
            #expect((w["pid"]?.intValue ?? 0) > 0)
            #expect(w["bounds"]?["width"]?.doubleValue != nil)
        }
        #expect((o.result.output["displays"]?.arrayValue?.count ?? 0) >= (CGMainDisplayID() != 0 && !Displays.active().isEmpty ? 1 : 0))
        print("system.windows: \(windows.count) window(s), titlesAvailable=\(titles)")
        let filtered = await invoke(SystemWindowsTool(), ["bundleID": "com.apple.finder", "includeAllLayers": true], in: dir)
        #expect(filtered.result.output["windows"]?.arrayValue?.allSatisfy { $0["bundleID"] == "com.apple.finder" } == true)
    }

    @Test func launchAndQuitDryRunsChangeNothing() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let before = AppResolver.running("com.apple.calculator").count
        let launch = await invoke(SystemLaunchAppTool(), ["bundleID": "com.apple.calculator"], in: dir, dryRun: true)
        #expect(launch.result.status == .simulated)
        let quit = await invoke(SystemQuitAppTool(), ["bundleID": "com.apple.finder"], in: dir, dryRun: true)
        #expect(quit.result.status == .simulated)
        #expect(quit.result.output["wasRunning"] == true)
        #expect(AppResolver.running("com.apple.calculator").count == before)
        #expect(!AppResolver.running("com.apple.finder").isEmpty)
        let absent = await invoke(SystemLaunchAppTool(), ["bundleID": "com.example.absent.app"], in: dir)
        #expect(absent.result.failure?.code == "not_found")
        let notRunning = await invoke(SystemQuitAppTool(), ["bundleID": "com.example.absent.app"], in: dir)
        #expect(notRunning.result.status == .succeeded && notRunning.result.output["wasRunning"] == false)
    }

    @Test func launchWaitsForTheAppAndQuitIsPolite() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let id = "com.apple.calculator"
        guard AppResolver.url(forBundleID: id) != nil else { skipped("Calculator is not installed"); return }
        guard AppResolver.running(id).isEmpty else {
            skipped("Calculator is already running; the test will not quit an application the user opened")
            return
        }
        let launch = await invoke(SystemLaunchAppTool(), ["bundleID": .string(id), "activate": false, "timeoutSeconds": 20], in: dir)
        #expect(launch.result.status == .succeeded, "\(launch.result.failure?.message ?? "")")
        #expect(launch.result.output["alreadyRunning"] == false)
        #expect(launch.result.output["finishedLaunching"] == true)
        let pid = pid_t(launch.result.output["pid"]?.intValue ?? 0)
        #expect(pid > 0 && kill(pid, 0) == 0)

        if AXIsProcessTrusted() { await pressRoundTrip(in: dir) }
        else { skipped("accessibility not granted to this test process: accessibility.press not exercised on a live application") }

        let quit = await invoke(SystemQuitAppTool(), ["bundleID": .string(id), "timeoutSeconds": 15], in: dir)
        #expect(quit.result.status == .succeeded)
        #expect(quit.result.output["wasRunning"] == true)
        #expect(quit.result.output["terminated"] == true && quit.result.output["refused"] == false)
        #expect(kill(pid, 0) != 0)
        verified("system.launchApp started Calculator (pid \(pid)) in the background and system.quitApp ended it")
    }
}

extension SystemIntegrationTests {
    /// find → press → observe → press back, on the Calculator this test launched in the background. The sidebar toggle is
    /// used because pressing it twice leaves the application exactly as it was (no calculation is entered or cleared).
    func pressRoundTrip(in dir: TempDirectory) async {
        let id = "com.apple.calculator"
        let ready = await invoke(AccessibilityWaitForTool(), ["bundleID": .string(id), "role": "AXToolbar", "timeoutSeconds": 10], in: dir)
        guard ready.result.output["satisfied"] == true, let toolbar = ready.result.output["element"]?["path"]?.stringValue else {
            skipped("this Calculator version exposes no toolbar through Accessibility: press round trip not exercised"); return
        }
        let button = toolbar + "/AXButton[0]"
        let tree = await invoke(AccessibilityTreeTool(), ["bundleID": .string(id), "element": .string(button), "maxDepth": 0], in: dir)
        let splitter = await invoke(AccessibilityFindTool(), ["bundleID": .string(id), "role": "AXSplitter", "maxResults": 1], in: dir)
        guard let label = tree.result.output["nodes"]?[0]?["description"]?.stringValue, !label.isEmpty,
              let splitterPath = splitter.result.output["matches"]?[0]?["path"]?.stringValue,
              let closedValue = splitter.result.output["matches"]?[0]?["value"]?.displayString else {
            skipped("this Calculator version has no labelled sidebar button or splitter: press round trip not exercised"); return
        }
        let dry = await invoke(AccessibilityPressTool(), ["bundleID": .string(id), "element": .string(button), "expectedTitle": .string(label)], in: dir, dryRun: true)
        #expect(dry.result.status == .simulated)
        let untouched = await invoke(AccessibilityWaitForTool(), ["bundleID": .string(id), "element": .string(splitterPath), "condition": "valueEquals", "expected": .string(closedValue), "timeoutSeconds": 1], in: dir)
        #expect(untouched.result.output["satisfied"] == true)

        let press = await invoke(AccessibilityPressTool(), ["bundleID": .string(id), "element": .string(button), "expectedTitle": .string(label)], in: dir)
        #expect(press.result.status == .succeeded, "\(press.result.failure?.message ?? "")")
        #expect(press.result.output["pressed"] == true)
        // Observable postcondition: the button no longer carries its original label (it now offers the opposite action).
        let opened = await invoke(AccessibilityWaitForTool(), ["bundleID": .string(id), "role": "AXButton", "title": .string(label), "condition": "absent", "timeoutSeconds": 5], in: dir)
        #expect(opened.result.output["satisfied"] == true, "pressing the sidebar button changed nothing observable")
        // Same path, different meaning now: the expectedTitle guard refuses to press it.
        let guarded = await invoke(AccessibilityPressTool(), ["bundleID": .string(id), "element": .string(button), "expectedTitle": .string(label)], in: dir)
        #expect(guarded.result.failure?.code == "element_changed")
        let back = await invoke(AccessibilityPressTool(), ["bundleID": .string(id), "element": .string(button)], in: dir)
        #expect(back.result.status == .succeeded)
        let closed = await invoke(AccessibilityWaitForTool(), ["bundleID": .string(id), "role": "AXButton", "title": .string(label), "condition": "exists", "timeoutSeconds": 5], in: dir)
        #expect(closed.result.output["satisfied"] == true)
        let restored = await invoke(AccessibilityWaitForTool(), ["bundleID": .string(id), "element": .string(splitterPath), "condition": "valueEquals", "expected": .string(closedValue), "timeoutSeconds": 5], in: dir)
        #expect(restored.result.output["satisfied"] == true, "the sidebar did not return to its initial state")
        // A static text is not pressable, and its value cannot be set: both are honest refusals.
        let text = await invoke(AccessibilityFindTool(), ["bundleID": .string(id), "role": "AXStaticText", "maxResults": 1], in: dir)
        if let path = text.result.output["matches"]?[0]?["path"]?.stringValue {
            let p = await invoke(AccessibilityPressTool(), ["bundleID": .string(id), "element": .string(path)], in: dir)
            #expect(p.result.status == .unsupported)
            let s = await invoke(AccessibilitySetValueTool(), ["bundleID": .string(id), "element": .string(path), "value": "1"], in: dir)
            #expect(s.result.status == .unsupported)
        }
        verified("accessibility.press toggled Calculator's sidebar and back in the background; waitFor observed both states and expectedTitle refused the changed button")
    }
}

@Suite("Integration · screen.ocr / screen.compare (real Vision and CoreGraphics)")
struct ScreenFileIntegrationTests {
    @Test func ocrRecognisesRenderedWords() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let image = dir.file("words.png")
        try TestImages.text(["ORIX AUTOMATION", "Invoice 48213 approved"], to: image)
        let o = await invoke(ScreenOCRTool(), ["path": "words.png", "languages": ["en-US"]], in: dir, timeout: 90)
        #expect(o.result.status == .succeeded, "\(o.result.failure?.message ?? "")")
        let text = o.result.output["text"]?.stringValue ?? ""
        for word in ["ORIX", "AUTOMATION", "Invoice", "48213", "approved"] { #expect(text.contains(word), "missing \(word) in \(text)") }
        #expect(o.result.untrusted)
        #expect(o.result.output["imageWidth"] == 1100 && o.result.output["imageHeight"] == 320)
        let blocks = o.result.output["blocks"]?.arrayValue ?? []
        #expect(blocks.count >= 2)
        // First line is above the second one (top-left origin), both inside the image.
        let first = blocks.first { $0["text"]?.stringValue?.contains("ORIX") == true }
        let second = blocks.first { $0["text"]?.stringValue?.contains("Invoice") == true }
        let y1 = first?["pixels"]?["y"]?.doubleValue ?? -1, y2 = second?["pixels"]?["y"]?.doubleValue ?? -1
        #expect(y1 >= 0 && y2 > y1 && y2 < 320)
        let n = first?["normalized"]
        #expect((n?["x"]?.doubleValue ?? -1) >= 0 && (n?["width"]?.doubleValue ?? 2) <= 1)
        #expect((first?["confidence"]?.doubleValue ?? 0) > 0.3)
    }

    @Test func ocrRejectsMissingAndNonImageFiles() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let missing = await invoke(ScreenOCRTool(), ["path": "nope.png"], in: dir)
        #expect(missing.result.failure?.code == "not_found")
        try dir.write("text.png", "this is not an image")
        let bad = await invoke(ScreenOCRTool(), ["path": "text.png"], in: dir)
        #expect(bad.result.status == .invalidInput)
    }

    @Test func compareFindsTheChangedRegion() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        try TestImages.blocks(width: 200, height: 100, background: 1, rects: [], to: dir.file("a.png"))
        try TestImages.blocks(width: 200, height: 100, background: 1, rects: [(CGRect(x: 50, y: 20, width: 40, height: 30), 0)], to: dir.file("b.png"))
        try TestImages.blocks(width: 200, height: 100, background: 1, rects: [], to: dir.file("same.png"))
        try TestImages.blocks(width: 100, height: 100, background: 1, rects: [], to: dir.file("small.png"))

        var o = await invoke(ScreenCompareTool(), ["before": "a.png", "after": "b.png", "diffPath": "out/diff.png"], in: dir)
        #expect(o.result.status == .succeeded, "\(o.result.failure?.message ?? "")")
        #expect(o.result.output["identical"] == false)
        #expect(o.result.output["changedPixels"] == 1200)
        #expect(o.result.output["totalPixels"] == 20000)
        #expect(o.result.output["changedRatio"] == .number(0.06))
        #expect(o.result.output["boundingBox"] == ["x": .number(50), "y": .number(20), "width": .number(40), "height": .number(30)])
        let diff = dir.file("out/diff.png").path
        #expect(o.result.artifacts.first?.path == diff)
        #expect((o.result.artifacts.first?.bytes ?? 0) > 0 && o.result.artifacts.first?.sha256?.count == 64)
        // The annotated image is a real PNG of the same size, red where the change is.
        let rendered = try ImageIOHelper.rgba(try ImageIOHelper.load(diff))
        #expect(rendered.width == 200 && rendered.height == 100)
        let centre = (35 * 200 + 70) * 4
        #expect(rendered.pixels[centre] > 100 && rendered.pixels[centre + 1] < 40 && rendered.pixels[centre + 2] < 40)

        o = await invoke(ScreenCompareTool(), ["before": "a.png", "after": "same.png"], in: dir)
        #expect(o.result.output["identical"] == true && o.result.output["changedPixels"] == 0)
        #expect(o.result.output["boundingBox"] == nil)
        #expect(o.requirements?.tier == .readOnly)

        o = await invoke(ScreenCompareTool(), ["before": "a.png", "after": "small.png"], in: dir)
        #expect(o.result.failure?.code == "size_mismatch")

        // An existing diff file is not replaced without overwrite.
        o = await invoke(ScreenCompareTool(), ["before": "a.png", "after": "b.png", "diffPath": "out/diff.png"], in: dir)
        #expect(o.result.failure?.code == "io")
    }
}

@Suite("Integration · screen.capture (gated on Screen Recording)")
struct ScreenCaptureIntegrationTests {
    @Test func captureDisplayOrReportTheBlock() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(ScreenCaptureTool(), ["scope": "display", "displayIndex": 0, "path": "shot.png"], in: dir)
        guard CGPreflightScreenCaptureAccess() else {
            #expect(o.error.map { if case .tccBlocked(.screenRecording, _) = $0 { return true } else { return false } } == true)
            #expect(o.result.status == .blockedPermission)
            #expect(!FileManager.default.fileExists(atPath: dir.file("shot.png").path))
            skipped("screen recording not granted to this test process: screen.capture returned tccBlocked(.screenRecording) as required")
            return
        }
        if case .permissionDenied? = o.error { skipped("secure keyboard input is active: capture correctly refused"); return }
        #expect(o.result.status == .succeeded, "\(o.result.failure?.message ?? "")")
        let w = o.result.output["pixelWidth"]?.intValue ?? 0, h = o.result.output["pixelHeight"]?.intValue ?? 0
        #expect(w > 0 && h > 0 && (o.result.output["scale"]?.doubleValue ?? 0) >= 1)
        let image = try ImageIOHelper.load(dir.file("shot.png").path)
        #expect(image.width == w && image.height == h)
        #expect(o.result.artifacts.first?.kind == "screenshot")

        let region = await invoke(ScreenCaptureTool(), ["scope": "region", "region": ["x": 10, "y": 10, "width": 120, "height": 80]], in: dir)
        #expect(region.result.status == .succeeded, "\(region.result.failure?.message ?? "")")
        let scale = region.result.output["scale"]?.doubleValue ?? 1
        #expect(region.result.output["pixelWidth"]?.intValue == Int(120 * scale))
        #expect(region.result.output["path"]?.stringValue?.hasPrefix(dir.url.path + "/artifacts/") == true)
        verified("screen.capture wrote a \(w)×\(h) px display screenshot and a region screenshot")
    }
}

@Suite("Integration · clipboard (real pasteboard, restored afterwards)", .serialized)
struct ClipboardIntegrationTests {
    /// Every item and type on the pasteboard, to put back exactly what the user had.
    static func snapshot() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
    }

    static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    @Test func textAndFilesRoundTripAndConcealedEntriesAreWithheld() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let saved = Self.snapshot()
        defer { Self.restore(saved) }

        let text = "orix clipboard \(UUID().uuidString) é✓"
        let dry = await invoke(ClipboardWriteTool(), ["content": .string(text)], in: dir, dryRun: true)
        #expect(dry.result.status == .simulated)
        #expect(NSPasteboard.general.string(forType: .string) != text)

        let write = await invoke(ClipboardWriteTool(), ["content": .string(text)], in: dir)
        #expect(write.result.status == .succeeded)
        var read = await invoke(ClipboardReadTool(), [:], in: dir)
        #expect(read.result.output["text"] == .string(text))
        #expect(read.result.output["concealed"] == false)
        #expect(read.result.untrusted)
        #expect(read.result.output["changeCount"] == write.result.output["changeCount"])

        let small = await invoke(ClipboardReadTool(), ["maxBytes": 8], in: dir)
        #expect(small.result.truncated)
        #expect(small.result.output["text"]?.stringValue?.hasPrefix("orix cli") == true)

        let file = try dir.write("note.txt", "hello")
        let files = await invoke(ClipboardWriteTool(), ["paths": ["note.txt"]], in: dir)
        #expect(files.result.status == .succeeded)
        #expect(files.requirements?.capabilities == [.clipboardWrite, .fileRead(path: file.path)])
        read = await invoke(ClipboardReadTool(), [:], in: dir)
        #expect(read.result.output["fileURLs"] == [.string(file.path)])

        // A password manager's entry: named, never read.
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("s3cret-password-value", forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.writeObjects([item])
        read = await invoke(ClipboardReadTool(), [:], in: dir)
        #expect(read.result.output["concealed"] == true)
        #expect(read.result.output["text"] == .null)
        #expect(!read.result.output.serialized().contains("s3cret"))

        let missing = await invoke(ClipboardWriteTool(), ["paths": ["absent.bin"]], in: dir)
        #expect(missing.result.failure?.code == "not_found")
    }
}

@Suite("Integration · accessibility (gated on Accessibility trust)")
struct AccessibilityIntegrationTests {
    @Test func statusReportsTheRealTrust() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(AccessibilityStatusTool(), [:], in: dir)
        #expect(o.result.status == .succeeded)
        #expect(o.result.output["trusted"] == .bool(AXIsProcessTrusted()))
        #expect(o.result.output["settingsURL"]?.stringValue?.contains("Privacy_Accessibility") == true)
    }

    @Test func withoutTrustEveryToolIsBlockedNotWorkedAround() async throws {
        guard !AXIsProcessTrusted() else { skipped("accessibility is granted to this test process: the not-trusted path cannot be exercised"); return }
        let dir = try TempDirectory(); defer { dir.remove() }
        let path = "AXApplication/AXWindow[0]"
        let calls: [(any ORIXTool, JSONValue)] = [
            (AccessibilityTreeTool(), ["bundleID": "com.apple.finder"]),
            (AccessibilityFindTool(), ["bundleID": "com.apple.finder", "role": "AXWindow"]),
            (AccessibilityPressTool(), ["bundleID": "com.apple.finder", "element": .string(path)]),
            (AccessibilitySetValueTool(), ["bundleID": "com.apple.finder", "element": .string(path), "value": "x"]),
            (AccessibilityFocusTool(), ["bundleID": "com.apple.finder", "element": .string(path), "activate": false]),
            (AccessibilityTypeTextTool(), ["bundleID": "com.apple.finder", "element": .string(path), "text": "x"]),
            (AccessibilityWaitForTool(), ["bundleID": "com.apple.finder", "role": "AXWindow", "timeoutSeconds": 1]),
        ]
        for (tool, args) in calls {
            let o = await invoke(tool, args, in: dir)
            #expect(o.result.status == .blockedPermission, "\(tool.identifier): \(o.result.status)")
            if case .tccBlocked(let p, _)? = o.error { #expect(p == .accessibility) } else { Issue.record("\(tool.identifier) must return tccBlocked(.accessibility)") }
        }
        skipped("accessibility not granted to this test process: tree/find/press/setValue/focus/typeText/waitFor verified only up to their tccBlocked(.accessibility) result")
    }

    @Test func treeFindAndWaitForOnFinder() async throws {
        guard AXIsProcessTrusted() else { skipped("accessibility not granted to this test process: live tree/find/waitFor not exercised"); return }
        let dir = try TempDirectory(); defer { dir.remove() }
        let tree = await invoke(AccessibilityTreeTool(), ["bundleID": "com.apple.finder", "maxDepth": 3, "maxNodes": 80, "includeMenuBar": true], in: dir)
        #expect(tree.result.status == .succeeded, "\(tree.result.failure?.message ?? "")")
        let nodes = tree.result.output["nodes"]?.arrayValue ?? []
        #expect(nodes.first?["path"] == "AXApplication" && nodes.first?["role"] == "AXApplication")
        #expect(nodes.count > 1 && nodes.count <= 80)
        #expect(nodes.allSatisfy { ($0["depth"]?.intValue ?? 99) <= 3 })
        #expect(nodes.filter { $0["secure"] == true }.allSatisfy { $0["value"] == "«secure»" })

        let find = await invoke(AccessibilityFindTool(), ["bundleID": "com.apple.finder", "role": "AXMenuBarItem", "includeMenuBar": true, "maxResults": 5, "maxDepth": 3], in: dir)
        #expect(find.result.status == .succeeded, "\(find.result.status) \(find.result.failure?.message ?? "") \(find.result.output.serialized().prefix(300))")
        let matches = find.result.output["matches"]?.arrayValue ?? []
        #expect(!matches.isEmpty)
        guard let path = matches.first?["path"]?.stringValue else { return }
        #expect(path.hasPrefix("AXApplication/AXMenuBar[0]/AXMenuBarItem["))

        // The path resolves again to the same element, and waitFor sees it without sleeping.
        let wait = await invoke(AccessibilityWaitForTool(), ["bundleID": "com.apple.finder", "element": .string(path), "condition": "exists", "timeoutSeconds": 3], in: dir)
        #expect(wait.result.output["satisfied"] == true)
        #expect(wait.result.output["element"]?["title"] == matches.first?["title"])
        let absent = await invoke(AccessibilityWaitForTool(), ["bundleID": "com.apple.finder", "identifier": "orix-no-such-element", "condition": "exists", "timeoutSeconds": 1], in: dir)
        #expect(absent.result.status == .timedOut && absent.result.output["satisfied"] == false)
        let gone = await invoke(AccessibilityWaitForTool(), ["bundleID": "com.apple.finder", "element": "AXApplication/AXWindow[97]", "condition": "absent", "timeoutSeconds": 2], in: dir)
        #expect(gone.result.output["satisfied"] == true)

        // Stale or wrong paths are typed failures, and a title mismatch stops an action before it happens.
        let stale = await invoke(AccessibilityPressTool(), ["bundleID": "com.apple.finder", "element": "AXApplication/AXWindow[97]/AXButton[0]"], in: dir)
        #expect(stale.result.failure?.code == "element_not_found")
        let changed = await invoke(AccessibilityPressTool(), ["bundleID": "com.apple.finder", "element": .string(path), "expectedTitle": "orix-not-this-title"], in: dir, dryRun: true)
        #expect(changed.result.failure?.code == "element_changed")
        // Typing is refused because Finder's keyboard focus is not on that menu bar item (and Finder is usually not in front).
        let type = await invoke(AccessibilityTypeTextTool(), ["bundleID": "com.apple.finder", "element": .string(path), "text": "never typed"], in: dir)
        #expect(type.result.failure?.code == "focus_changed", "\(type.result.status) \(type.result.failure?.message ?? "")")
        verified("accessibility.tree/find/waitFor read Finder live (\(nodes.count) nodes); stale path, changed title and unfocused typing were refused")
    }

    @Test func notRunningApplicationIsATypedFailure() async throws {
        guard AXIsProcessTrusted() else { skipped("accessibility not granted to this test process: app_not_running path not exercised"); return }
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(AccessibilityTreeTool(), ["bundleID": "com.example.absent.app"], in: dir)
        #expect(o.result.failure?.code == "app_not_running")
    }
}

@Suite("Integration · notifications (no app bundle under swift test)")
struct NotificationIntegrationTests {
    @Test func postIsHonestlyUnsupportedWithoutABundle() async throws {
        let dir = try TempDirectory(); defer { dir.remove() }
        let o = await invoke(NotificationsPostTool(), ["title": "Run finished", "body": "3 files organised", "runID": "run-1", "approvalID": "ap-1"], in: dir)
        #expect(o.result.status == .unsupported)
        #expect(o.error == .unsupported(NotificationsPostTool.noBundleReason))
        #expect(o.result.failure?.message == "Notifications need an application bundle: this process has no bundle identifier.")
        #expect(o.requirements?.capabilities == [.notify])
        let bridge = NotificationCenterBridge { _ in }
        #expect(throws: ToolError.unsupported(NotificationsPostTool.noBundleReason)) { try bridge.register() }
        let empty = await invoke(NotificationsPostTool(), ["title": " ", "body": "x"], in: dir)
        #expect(empty.result.status == .invalidInput)
    }
}

@Suite("Integration · InputRecorder (real NSWorkspace observers)")
@MainActor
struct InputRecorderIntegrationTests {
    @Test func startAndStopRecordTheirOwnLimits() async throws {
        let recorder = InputRecorder()
        #expect(recorder.state == .idle)
        #expect(throws: ToolError.self) { try recorder.start(targetBundleIDs: []) }
        #expect(throws: ToolError.self) { try recorder.start(targetBundleIDs: ["not a bundle id"]) }
        let seen = LockedBox<Int>(0)
        recorder.onAction = { _ in seen.mutate { $0 += 1 } }
        let limits = try recorder.start(targetBundleIDs: ["com.apple.finder"])
        #expect(recorder.state == .recording)
        #expect(recorder.targetBundleIDs == ["com.apple.finder"])
        #expect(!limits.isEmpty)
        #expect(limits.contains { $0.contains("Keystrokes") })
        if AXIsProcessTrusted() {
            #expect(!limits.contains { $0.contains("Accessibility is not enabled") })
            print("InputRecorder: accessibility granted, interface events of Finder are observed")
        } else {
            #expect(limits.contains { $0.contains("Accessibility is not enabled") && $0.contains("only application activations") })
            skipped("accessibility not granted to this test process: InputRecorder recorded app-level events and its limitation only")
        }
        #expect(throws: ToolError.self) { try recorder.start(targetBundleIDs: ["com.apple.finder"]) }

        recorder.pause()
        #expect(recorder.state == .paused)
        recorder.resume()
        #expect(recorder.state == .recording)
        let actions = recorder.stop()
        #expect(recorder.state == .stopped)
        #expect(actions.first?.kind == .recordingStarted && actions.last?.kind == .recordingStopped)
        #expect(actions.contains { $0.kind == .recordingPaused } && actions.contains { $0.kind == .recordingResumed })
        #expect(actions.filter { $0.kind == .limitation }.count >= limits.count)
        #expect(actions.map(\.sequence) == Array(1...actions.count))
        #expect(zip(actions, actions.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp })
        #expect(seen.get() == actions.count)
        // Only the chosen application appears, and nothing carries a value.
        #expect(actions.allSatisfy { $0.bundleID == nil || $0.bundleID == "com.apple.finder" })
        #expect(actions.allSatisfy { $0.value == nil })

        let decoded = try { () -> [RecordedAction] in
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            return try d.decode([RecordedAction].self, from: try recorder.exportJSON())
        }()
        #expect(decoded.map(\.id) == actions.map(\.id) && decoded.map(\.kind) == actions.map(\.kind))
        #expect(recorder.stop().count == actions.count)
        // A stopped recorder can start a fresh recording.
        _ = try recorder.start(targetBundleIDs: ["com.apple.finder"])
        #expect(recorder.actions.first?.kind == .recordingStarted && recorder.actions.count < actions.count + 1)
        recorder.stop()
    }

    @Test func activationsOfOtherApplicationsAreIgnored() async throws {
        let recorder = InputRecorder(options: .init(maxActions: 6))
        _ = try recorder.start(targetBundleIDs: ["com.apple.finder"])
        // Real notifications posted on the workspace centre: one for an application outside the targets, one for Finder.
        let center = NSWorkspace.shared.notificationCenter
        let finder = try #require(AppResolver.running("com.apple.finder").first)
        if let other = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier != nil && $0.bundleIdentifier != "com.apple.finder" }) {
            center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: other])
        }
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: finder])
        recorder.pause()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: finder])
        recorder.resume()
        let activations = recorder.actions.filter { $0.kind == .appActivated }
        #expect(activations.count == 1)
        #expect(activations.first?.bundleID == "com.apple.finder")
        // The action cap is enforced and recorded as a limitation.
        for _ in 0..<10 {
            center.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared, userInfo: [NSWorkspace.applicationUserInfoKey: finder])
        }
        let actions = recorder.stop()
        #expect(actions.count <= 8 && actions.last?.kind == .recordingStopped)
        #expect(recorder.limitations.contains { $0.contains("reached its limit") })
    }
}
