// ORIX OS Automation
// File: Packages/ORIXServices/Tests/ORIXServicesTests/ExamplesEndToEndTests.swift
// Description: Runs each of the 15 built-in example automations for real (real services on a temporary data folder, real tools, sample data copied into a temporary workspace) and checks the artifacts by content.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Network
import PDFKit
import Testing
import ORIXAppleAutomation
import ORIXCore
import ORIXServices
import ORIXWorkflowEngine

// MARK: - Support

/// What the test's "person at the screen" answered. Manual gates of a workflow are approved (or refused on request);
/// a *tool* approval is always refused and recorded: with the declared permissions accepted, no tool call of an
/// example may need one. This is stricter than `orixctl --approve all`, which would hide a missing permission.
final class ApprovalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _gates: [String] = []
    private var _tools: [String] = []
    var gates: [String] { lock.lock(); defer { lock.unlock() }; return _gates }
    var toolRequests: [String] { lock.lock(); defer { lock.unlock() }; return _tools }
    func gate(_ text: String) { lock.lock(); _gates.append(text); lock.unlock() }
    func tool(_ text: String) { lock.lock(); _tools.append(text); lock.unlock() }
}

/// A loopback-only HTTP/1.1 server for the tests (GET only, one request per connection).
final class LoopbackServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ path: String) -> (status: Int, type: String, body: Data)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "orix.tests.loopback")
    private let lock = NSLock()
    private var _requests: [String] = []
    private var handler: Handler
    private(set) var port: UInt16 = 0

    /// Request targets (path and query) received so far, in order.
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
    func setHandler(_ h: @escaping Handler) { lock.lock(); handler = h; lock.unlock() }

    init(handler: @escaping Handler) async throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let started = AsyncStream<Bool>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: started.continuation.yield(true); started.continuation.finish()
            case .failed, .cancelled: started.continuation.yield(false); started.continuation.finish()
            default: break
            }
        }
        listener.start(queue: queue)
        var ready = false
        for await ok in started.stream { ready = ok }
        guard ready, let p = listener.port?.rawValue else { throw CocoaError(.fileNoSuchFile) }
        port = p
    }

    /// Serves the files of one folder (no directory listing, no path outside the folder).
    static func site(_ folder: URL) async throws -> LoopbackServer {
        let root = folder.resolvingSymlinksInPath().path
        return try await LoopbackServer { target in
            let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            let file = URL(fileURLWithPath: root + path).standardizedFileURL.path
            guard file.hasPrefix(root + "/"), let data = FileManager.default.contents(atPath: file) else { return (404, "text/plain", Data("not found".utf8)) }
            let type = file.hasSuffix(".css") ? "text/css; charset=utf-8" : "text/html; charset=utf-8"
            return (200, type, data)
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || buffer.count > 262_144 { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let parts = (head.split(separator: "\r\n").first ?? "").split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : "/"
            self.lock.lock(); self._requests.append(target); let handler = self.handler; self.lock.unlock()
            let reply = parts.first == "GET" ? handler(target) : (405, "text/plain", Data("GET only".utf8))
            var out = Data("HTTP/1.1 \(reply.0) \(reply.0 == 200 ? "OK" : "Error")\r\nContent-Type: \(reply.1)\r\nContent-Length: \(reply.2.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            out.append(reply.2)
            connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() { listener.cancel() }
}

enum Repo {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()
    static var examples: URL { root.appendingPathComponent("Workflows/Examples") }
    static var mirror: URL { root.appendingPathComponent("Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Resources/Examples") }
    static var samples: URL { root.appendingPathComponent("Workflows/Samples") }

    static func exampleFile(slug: String) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil).filter { $0.pathExtension == "yaml" }
        guard let f = files.first(where: { $0.deletingPathExtension().lastPathComponent.dropFirst(3) == slug }) else { throw CocoaError(.fileNoSuchFile) }
        return f
    }
}

enum Files {
    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Relative path → SHA-256 for every regular file under a folder (hidden files included); folders map to "dir".
    static func tree(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(atPath: base) else { return out }
        while let rel = walker.nextObject() as? String {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: base + "/" + rel, isDirectory: &isDir)
            out[rel] = isDir.boolValue ? "dir" : ((try? sha256(URL(fileURLWithPath: base + "/" + rel))) ?? "unreadable")
        }
        return out
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    static func imageSize(_ url: URL) -> (width: Int, height: Int, type: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height, (CGImageSourceGetType(source) as String?) ?? "")
    }

    /// Runs a program the test itself needs (git, ditto, the sample setup script) and returns its output.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil) throws -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = cwd
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": NSTemporaryDirectory()]
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct FinishedRun {
    let record: RunRecord
    let receipt: RunReceipt
    let outcome: WorkflowOutcome
    var status: RunStatus { record.status }
    func output(_ name: String) -> JSONValue? { outcome.outputs[name] }
    func step(_ id: String) -> StepResult? { outcome.step(id) }
    /// Why a run did not end as expected: errors, failed verifications and tool calls that did not succeed.
    var diagnosis: String {
        let checks = receipt.verifications.filter { !$0.passed }.map { "FAIL \($0.assertion) — \($0.evidence)" }
        let calls = receipt.toolCalls.filter { $0.status != .succeeded }.map { "\($0.toolID) \($0.status.rawValue): \($0.summary) \($0.arguments.serialized().prefix(300))" }
        return (receipt.errors + checks + calls).joined(separator: "\n")
    }
    /// Steps that ended in anything else than succeeded / skipped / simulated.
    var failedSteps: [String] { outcome.steps.filter { !$0.status.isSuccess && $0.status != .skipped }.map(\.stepID) }
}

/// Real services on a temporary data folder plus a temporary workspace for the sample data.
final class ExampleHarness: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let services: ORIXServices
    let approvals = ApprovalLog()
    private var tasks: [Task<Void, Never>] = []
    private var saved: Set<String> = []

    static let devKeyName = "ORIX_DEV_ANTHROPIC_API_KEY"
    static var hasDevKey: Bool { !(ProcessInfo.processInfo.environment[devKeyName] ?? "").isEmpty }
    static let testModel = ModelRef(provider: .anthropic, model: "claude-haiku-5-5")

    /// - Parameters:
    ///   - interactive: false = a headless process: nobody answers approvals.
    ///   - approveGates: what the simulated person answers to a workflow's manual gate.
    ///   - live: use the development provider key from the environment and Haiku as the default model.
    init(interactive: Bool = true, approveGates: Bool = true, live: Bool = false) async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("orix-examples-\(UUID().uuidString.prefix(8))")
        root = base
        workspace = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var options = ServiceOptions()
        options.interactive = interactive
        options.allowDevelopmentCredentials = live
        options.keychainService = "ai.spboucher.orix.tests.examples.\(UUID().uuidString.prefix(8))"   // never the user's real items
        services = try await ORIXServices.bootstrap(paths: ORIXPaths(root: base.appendingPathComponent("data")), options: options)
        if live {
            var settings = await services.runs.settings()
            settings.defaultModel = Self.testModel
            settings.dailySpendLimitUSD = 0.25
            try await services.runs.save(settings)
        }
        guard interactive else { return }
        let center = services.approvals, interaction = services.interaction, log = approvals
        tasks.append(Task {
            for await pending in center.updates() {
                for p in pending {
                    if p.access.toolID == "workflow.approval" {
                        log.gate(p.access.summary)
                        await center.resolve(id: p.id, response: approveGates ? .approveOnce : .deny(reason: "refused by the test"))
                    } else {
                        log.tool("\(p.access.toolID): \(p.reason)")
                        await center.resolve(id: p.id, response: .deny(reason: "the declared permissions of an example must be sufficient"))
                    }
                }
            }
        })
        tasks.append(Task {
            for await items in interaction.updates() {
                for item in items {
                    switch item {
                    case .plan(let p): await interaction.review(planID: p.id, .approved)
                    case .question(let q): await interaction.answer(questionID: q.id, nil)
                    }
                }
            }
        })
    }

    func tearDown() async {
        for t in tasks { t.cancel() }
        await services.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    /// Copies `Workflows/Samples/<slug>` into the workspace and returns the copy.
    func copySample(_ slug: String) throws -> URL {
        let target = workspace.appendingPathComponent(slug)
        try FileManager.default.copyItem(at: Repo.samples.appendingPathComponent(slug), to: target)
        return target
    }

    /// Saves the example exactly as shipped (once) — or a variant with a tighter cost budget for live agent runs.
    @discardableResult
    func save(_ slug: String, costBudgetUSD: Double? = nil) async throws -> SavedWorkflow {
        var source = try String(contentsOf: Repo.exampleFile(slug: slug), encoding: .utf8)
        if let costBudgetUSD {
            // Same workflow, smaller spending ceiling: a test must not be able to spend what a user's real run may.
            let pattern = #"maxProviderCostUSD: [0-9.]+"#
            guard let range = source.range(of: pattern, options: .regularExpression) else { throw CocoaError(.formatting) }
            source.replaceSubrange(range, with: "maxProviderCostUSD: \(costBudgetUSD)")
        }
        let s = try await services.workflows.save(source: source)
        saved.insert(slug)
        return s
    }

    func run(_ slug: String, _ parameters: [String: JSONValue] = [:], accept: Bool = true, dryRun: Bool = false, mode: ExecutionMode = .guided) async throws -> FinishedRun {
        if !saved.contains(slug) { try await save(slug) }
        if accept { try await services.workflows.acceptPermissions(workflowID: slug, parameters: parameters) }
        var request = WorkflowRunRequest(workflowID: slug)
        request.parameters = parameters
        request.dryRun = dryRun
        request.mode = mode
        request.startPaused = true   // hold the run until the test has its handle, so the outcome (outputs, step results) can be read
        let runID = try await services.workflows.startRun(request)
        let handle = try #require(await services.workflows.handle(runID: runID))
        await handle.resume()
        let outcome = await handle.outcome()
        let record = try #require(await services.runs.wait(runID: runID))
        let receipt = try #require(try await services.store.receipt(runID: runID))
        if ProcessInfo.processInfo.environment["ORIX_TEST_DUMP_EVENTS"] == "1" {
            // Debugging aid: the persisted (already redacted) event log of the run.
            for e in (try? await services.store.events(runID: runID, afterSeq: 0, limit: 5000)) ?? [] {
                print("EVENT \(slug) \(e.seq) \(e.kind.rawValue) \(e.stepID ?? "-") \(e.text.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(700)) \(e.data.serialized().prefix(500))")
            }
        }
        return FinishedRun(record: record, receipt: receipt, outcome: outcome)
    }

    func path(_ url: URL) -> JSONValue { .string(url.path) }
}

/// The notification step of an example cannot work under `swift test` (no application bundle): it fails by itself,
/// honestly, and the run ends PARTIALLY_SUCCEEDED. This checks that it is the only thing that went wrong.
func expectOnlyTheNotificationFailed(_ run: FinishedRun, step: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(run.status == .partiallySucceeded, "\(run.diagnosis)", sourceLocation: sourceLocation)
    #expect(run.failedSteps == [step], sourceLocation: sourceLocation)
    #expect(run.step(step)?.error?.contains("application bundle") == true, "\(run.step(step)?.error ?? "nil")", sourceLocation: sourceLocation)
    #expect(run.step(step)?.continued == true, sourceLocation: sourceLocation)
}

let allExampleSlugs = [
    "smart-downloads-organizer", "pdf-to-structured-report", "weekly-research-digest", "git-test-and-review", "csv-cleanup-and-charts",
    "batch-image-conversion", "calendar-preparation", "folder-backup-and-verify", "website-change-monitor", "system-health-report",
    "meeting-notes-organizer", "document-metadata-catalog", "scheduled-window-screenshot", "spreadsheet-validation", "browser-data-entry",
]

// MARK: - Tests

/// The suite's type name is a raw identifier so that `swift test --filter "Integration · examples"` selects it
/// (the filter matches identifiers, not display names). Real services, real tools, sample data; a live model and the
/// macOS privacy permissions are used only when they are available, and every skip prints `SKIPPED(<reason>)`.
@Suite(.serialized, .timeLimit(.minutes(10)))
struct `Integration · examples` {

    // MARK: Validation against the real manifests

    @Test("All 15 examples validate with zero errors and zero warnings against the registered tools, and the mirror is identical")
    func examplesValidateAgainstRealManifests() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let registered = Set(await h.services.executor.manifests().map(\.identifier))
        for slug in allExampleSlugs {
            let file = try Repo.exampleFile(slug: slug)
            let source = try String(contentsOf: file, encoding: .utf8)
            let (doc, diagnostics) = await h.services.workflows.diagnose(source)
            let problems = diagnostics.filter { $0.severity == .error || $0.severity == .warning }
            #expect(problems.isEmpty, "\(slug): \(problems.map { "line \($0.line): \($0.message)" }.joined(separator: "\n"))")
            let document = try #require(doc, "\(slug) does not parse")
            #expect(document.metadata.id == slug)
            for located in document.allSteps {
                if case .tool(let t) = located.step.kind { #expect(registered.contains(t.tool), "\(slug): \(t.tool) is not a registered tool") }
                if case .agent(let a) = located.step.kind, case .inline(let inline) = a.agent {
                    #expect(inline.tools.allSatisfy(registered.contains), "\(slug): agent tools \(inline.tools)")
                }
            }
            #expect(try Data(contentsOf: file) == Data(contentsOf: Repo.mirror.appendingPathComponent(file.lastPathComponent)), "\(slug): resource copy differs")
            #expect(Files.exists(Repo.samples.appendingPathComponent(slug)), "\(slug) has no sample folder")
            // Saving is what the template gallery does: it must accept the example as shipped.
            let saved = try await h.save(slug)
            #expect(saved.id == slug && saved.version == 1)
        }
    }

    // MARK: 1 · Smart Downloads Organizer

    @Test("01 smart-downloads-organizer: every file is moved to its category, nothing is deleted or altered")
    func smartDownloadsOrganizer() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("smart-downloads-organizer")
        let source = ws.appendingPathComponent("Downloads"), destination = ws.appendingPathComponent("Sorted")
        let before = Files.tree(source)
        let run = try await h.run("smart-downloads-organizer", ["source": h.path(source), "destination": h.path(destination)])
        #expect(run.status == .succeeded, "\(run.diagnosis)")

        let expected: [String: [String]] = [
            "Documents": ["notes.txt", "reading-list.md", "SCAN 2026.TXT", "memo.pdf"], "Spreadsheets": ["budget.csv"], "Images": ["photo.png"],
            "Archives": ["old-project.zip"], "Audio": ["jingle.mp3"], "Video": ["clip.mov"], "Other": ["LICENSE", "data.xyz"],
        ]
        let after = Files.tree(destination)
        for (category, names) in expected {
            for name in names { #expect(after["\(category)/\(name)"] == before[name], "\(name) should be in \(category) with the same content") }
        }
        let moved = expected.values.reduce(0) { $0 + $1.count }
        #expect(after.values.filter { $0 != "dir" }.count == moved, "exactly the moved files are in the destination: \(after.keys.sorted())")
        // What stays: the subfolder and its content, untouched. Nothing was deleted: moved + remaining == before.
        let remaining = Files.tree(source)
        #expect(remaining == ["Projects": "dir", "Projects/keep-me.txt": before["Projects/keep-me.txt"]!])
        #expect(Set(after.values.filter { $0 != "dir" }).union(remaining.values.filter { $0 != "dir" }) == Set(before.values.filter { $0 != "dir" }))
        #expect(run.output("moved") == .int(moved))
        #expect(h.approvals.gates.count == 1, "the manual gate was asked once")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
        #expect(run.receipt.verifications.count == 2 && run.receipt.verifications.allSatisfy(\.passed))
    }

    @Test("01 smart-downloads-organizer, headless and without accepted permissions: waits for approval and moves nothing")
    func smartDownloadsOrganizerWithoutPermissions() async throws {
        let h = try await ExampleHarness(interactive: false)
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("smart-downloads-organizer")
        let before = Files.tree(ws)
        let run = try await h.run("smart-downloads-organizer", ["source": h.path(ws.appendingPathComponent("Downloads")), "destination": h.path(ws.appendingPathComponent("Sorted"))], accept: false)
        #expect(run.status == .waitingApproval || run.status == .blockedPermission, "\(run.status)")
        #expect(Files.tree(ws) == before, "nothing may change on disk")
        #expect(!run.receipt.toolCalls.contains { $0.status == .succeeded }, "no tool call may have run")
    }

    // MARK: 2 · PDF to structured data and report

    @Test("02 pdf-to-structured-report: CSV catalogue rows match the PDFs and the report PDF is readable")
    func pdfToStructuredReport() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("pdf-to-structured-report")
        let input = ws.appendingPathComponent("Input"), output = ws.appendingPathComponent("Output")
        let before = Files.tree(input)
        let run = try await h.run("pdf-to-structured-report", ["inputFolder": h.path(input), "outputFolder": h.path(output)])
        #expect(run.status == .succeeded, "\(run.diagnosis)")

        let lines = try Files.text(output.appendingPathComponent("catalog.csv")).split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.first == "file,pages,title,textCharacters")
        var rows: [String: [String]] = [:]
        for line in lines.dropFirst() { let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init); rows[c[0]] = c }
        #expect(rows.count == 4 && lines.count == 5)
        #expect(rows["field-notes.pdf"]?[1] == "3" && rows["field-notes.pdf"]?[2] == "Field notes")
        #expect(rows["quarterly-summary.pdf"]?[1] == "1" && rows["quarterly-summary.pdf"]?[2] == "Quarterly summary Q3")
        #expect(rows["untitled-memo.pdf"]?[2] == "", "a PDF without a Title property has an empty title")
        #expect(rows["scan-without-text.pdf"]?[3] == "0", "a page without a text layer has no text")
        for name in ["field-notes.pdf", "quarterly-summary.pdf", "untitled-memo.pdf"] { #expect((Int(rows[name]?[3] ?? "") ?? 0) > 20, "\(name) has a text layer") }
        // Page counts are checked against PDFKit directly, independently of the tool.
        for (rel, _) in before where rel.hasSuffix(".pdf") {
            let pages = PDFDocument(url: input.appendingPathComponent(rel))?.pageCount
            #expect(rows[(rel as NSString).lastPathComponent]?[1] == pages.map(String.init))
        }
        let report = try #require(PDFDocument(url: output.appendingPathComponent("report.pdf")))
        #expect(report.pageCount == 1)
        let text = report.string ?? ""
        #expect(text.contains("PDF report") && text.contains("field-notes.pdf") && text.contains("Documents: 4"))
        #expect(try Files.text(output.appendingPathComponent("report.md")).contains("| field-notes.pdf | 3 | Field notes |"))
        #expect(run.output("documents") == .int(4) && run.output("pages") == .int(6))
        #expect(Files.tree(input) == before, "the input folder is read only")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
    }

    // MARK: 3, 4, 11 · Examples with an agent step

    /// How a dry run accounts for the agent step of an example. A dry run executes no read tool either, so what the
    /// agent step depends on decides how far the simulation gets.
    enum DryAgent {
        /// The step is reached and reported as "the agent was not run".
        case simulated
        /// The step's `when` reads the (not executed) listing and is false: reported as skipped.
        case skipped
        /// The step lives in a `foreach` over items a dry run cannot know: the loop body is not entered at all.
        case notEntered
    }

    /// Dry run of an agent example: nothing is written, no model is called, and the report accounts for the agent step.
    private func expectDryRunSkipsTheAgent(_ h: ExampleHarness, slug: String, parameters: [String: JSONValue], agentStep: String, expecting: DryAgent, workspace: URL) async throws {
        let before = Files.tree(workspace)
        let dry = try await h.run(slug, parameters, dryRun: true)
        #expect(dry.outcome.dryRun)
        let report = dry.receipt.limitations
        #expect(report.first?.hasPrefix("Dry run: nothing was changed") == true, "\(report)")
        switch expecting {
        case .simulated:
            #expect(dry.step(agentStep)?.status == .simulated)
            #expect(report.contains { $0.hasPrefix("\(agentStep): simulated: the agent was not run") }, "\(report)")
        case .skipped:
            #expect(dry.step(agentStep)?.status == .skipped)
            #expect(report.contains { $0.hasPrefix("Step \(agentStep) was skipped") }, "\(report)")
        case .notEntered:
            #expect(dry.outcome.results(for: agentStep).isEmpty, "the loop body is not entered in a dry run")
        }
        #expect(!dry.outcome.steps.contains { $0.stepID == agentStep && $0.status == .succeeded }, "the agent step was not executed")
        #expect(dry.receipt.usage.turns == 0 && dry.receipt.usage.tokens.totalTokens == 0 && dry.receipt.usage.costUSD == 0, "a dry run calls no model")
        #expect(!dry.receipt.toolCalls.contains { $0.status == .succeeded }, "a dry run executes no tool: \(dry.receipt.toolCalls.map(\.toolID))")
        #expect(Files.tree(workspace) == before, "a dry run changes nothing on disk")
    }

    @Test("03 weekly-research-digest: dry run never calls the model; live run (dev key) writes a cited digest and its PDF")
    func weeklyResearchDigest() async throws {
        let live = ExampleHarness.hasDevKey
        let h = try await ExampleHarness(live: live)
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("weekly-research-digest")
        let research = ws.appendingPathComponent("Research"), reports = ws.appendingPathComponent("Reports")
        let parameters: [String: JSONValue] = ["researchFolder": h.path(research), "reportsFolder": h.path(reports), "maxDocuments": 5]
        try await h.save("weekly-research-digest", costBudgetUSD: 0.04)
        try await expectDryRunSkipsTheAgent(h, slug: "weekly-research-digest", parameters: parameters, agentStep: "analyze", expecting: .skipped, workspace: ws)
        guard live else { print("SKIPPED(no ORIX_DEV_ANTHROPIC_API_KEY): weekly-research-digest live agent run; dry run verified"); return }

        let before = Files.tree(research)
        let run = try await h.run("weekly-research-digest", parameters)
        expectOnlyTheNotificationFailed(run, step: "announce")
        let digestPath = try #require(run.output("digest")?.stringValue)
        let digest = try Files.text(URL(fileURLWithPath: digestPath))
        #expect(digest.contains("Highlights") && digest.count > 200)
        let cited = ["battery-storage-brief", "interview-operator", "field-notes"].filter(digest.contains)
        #expect(cited.count >= 2, "the digest names its source files (text and PDF): \(cited)")
        #expect(digest.lowercased().contains("inverter"), "the digest reflects the content of the sample documents")
        // The workflow read the documents itself; the agent's only tool call is the write of the digest.
        #expect(run.outcome.results(for: "content").count == 2 && run.outcome.results(for: "pdfContent").count == 1)
        #expect(run.step("pdfContent")?.output["pageCount"] == .int(3))
        #expect(!run.receipt.toolCalls.contains { $0.status != .succeeded && $0.toolID != "notifications.post" }, "\(run.diagnosis)")
        let pdfPath = try #require(run.output("pdf")?.stringValue)
        let pdf = try #require(PDFDocument(url: URL(fileURLWithPath: pdfPath)))
        #expect(pdf.pageCount >= 1 && (pdf.string ?? "").contains("Highlights"))
        #expect(run.output("documents") == .int(3))
        #expect(Files.tree(research) == before, "the research folder is read only")
        #expect(run.receipt.usage.tokens.totalTokens > 0 && run.receipt.usage.costUSD < 0.04, "cost \(run.receipt.usage.costUSD)")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
        print(String(format: "VERIFIED(live anthropic:claude-haiku-5-5): weekly-research-digest, %d tokens, $%.4f", run.receipt.usage.tokens.totalTokens, run.receipt.usage.costUSD))
    }

    @Test("04 git-test-and-review: tests run, patch saved, repository untouched; live review (dev key) reports the failing tests")
    func gitTestAndReview() async throws {
        let live = ExampleHarness.hasDevKey
        let h = try await ExampleHarness(live: live)
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("git-test-and-review")
        let setup = try Files.run("/bin/bash", [ws.appendingPathComponent("setup.sh").path, ws.path])
        #expect(setup.code == 0, "\(setup.out)")
        let repo = ws.appendingPathComponent("repo"), reviews = ws.appendingPathComponent("Reviews")
        func git(_ args: String...) throws -> String { try Files.run("/usr/bin/git", ["-C", repo.path] + args).out }
        let head = try git("rev-parse", "HEAD"), status = try git("status", "--porcelain"), commits = try git("rev-list", "--count", "HEAD")
        #expect(commits.trimmingCharacters(in: .whitespacesAndNewlines) == "2" && status.contains(" M slugify.sh"))
        let parameters: [String: JSONValue] = ["repository": h.path(repo), "reviewsFolder": h.path(reviews)]
        try await h.save("git-test-and-review", costBudgetUSD: 0.04)
        try await expectDryRunSkipsTheAgent(h, slug: "git-test-and-review", parameters: parameters, agentStep: "review", expecting: .simulated, workspace: ws)
        guard live else {
            // Without a model the non-agent half still runs for real: status, diff, log, the test command and the patch.
            let run = try await h.run("git-test-and-review", parameters)
            #expect(run.status == .failed, "the agent step cannot run without a model: \(run.status)")
            #expect(run.failedSteps == ["review"], "\(run.failedSteps)")
            #expect(run.step("tests")?.output["exitCode"] == .int(1), "the sample's uncommitted change breaks its tests")
            #expect(run.step("tests")?.output["stdout"]?.stringValue?.contains("FAIL - slugify 'Hello World'") == true)
            #expect(run.step("status")?.output["branch"] == .string("main") && run.step("status")?.output["clean"] == .bool(false))
            #expect(try Files.text(reviews.appendingPathComponent("changes.patch")).contains("tr -s ' ' '_'"))
            #expect(!Files.exists(reviews.appendingPathComponent("review.md")))
            #expect(try git("rev-parse", "HEAD") == head && git("status", "--porcelain") == status, "the repository is never modified")
            print("SKIPPED(no ORIX_DEV_ANTHROPIC_API_KEY): git-test-and-review agent review; git, test and patch steps verified for real")
            return
        }
        let run = try await h.run("git-test-and-review", parameters)
        #expect(run.status == .succeeded, "\(run.diagnosis)")
        #expect(run.output("testsPassed") == .bool(false) && run.output("branch") == .string("main") && run.output("patchWritten") == .bool(true))
        #expect(run.step("tests")?.output["exitCode"] == .int(1))
        let review = try Files.text(reviews.appendingPathComponent("review.md"))
        #expect(review.contains("## Tests") && review.lowercased().contains("fail"), "the review states that the tests failed")
        #expect(review.contains("slugify"), "the review talks about the changed file")
        let patch = try Files.text(reviews.appendingPathComponent("changes.patch"))
        #expect(patch.contains("diff --git a/slugify.sh b/slugify.sh") && patch.contains("tr -s ' ' '_'") && !patch.contains("notes.tmp"))
        #expect(try git("rev-parse", "HEAD") == head && git("status", "--porcelain") == status, "never commits, never changes the working tree")
        #expect(try git("rev-list", "--count", "HEAD") == commits)
        #expect(run.receipt.usage.tokens.totalTokens > 0 && run.receipt.usage.costUSD < 0.04, "cost \(run.receipt.usage.costUSD)")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
        print(String(format: "VERIFIED(live anthropic:claude-haiku-5-5): git-test-and-review, %d tokens, $%.4f", run.receipt.usage.tokens.totalTokens, run.receipt.usage.costUSD))
    }

    @Test("11 meeting-notes-organizer: dry run never calls the model; live run (dev key) writes notes per transcript and the index")
    func meetingNotesOrganizer() async throws {
        let live = ExampleHarness.hasDevKey
        let h = try await ExampleHarness(live: live)
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("meeting-notes-organizer")
        let transcripts = ws.appendingPathComponent("Transcripts"), notes = ws.appendingPathComponent("Notes")
        let parameters: [String: JSONValue] = ["transcriptsFolder": h.path(transcripts), "notesFolder": h.path(notes)]
        try await h.save("meeting-notes-organizer", costBudgetUSD: 0.05)
        try await expectDryRunSkipsTheAgent(h, slug: "meeting-notes-organizer", parameters: parameters, agentStep: "summarize", expecting: .notEntered, workspace: ws)
        guard live else { print("SKIPPED(no ORIX_DEV_ANTHROPIC_API_KEY): meeting-notes-organizer live agent run; dry run verified"); return }

        let before = Files.tree(transcripts)
        let run = try await h.run("meeting-notes-organizer", parameters)
        #expect(run.status == .succeeded, "\(run.diagnosis)")
        let sync = try Files.text(notes.appendingPathComponent("2026-11-03-product-sync-notes.md"))
        let budget = try Files.text(notes.appendingPathComponent("2026-11-10-budget-review-notes.md"))
        for text in [sync, budget] { #expect(text.contains("## Summary") && text.contains("## Decisions") && text.contains("## Action items")) }
        #expect(sync.contains("2.4") && sync.contains("Sam"), "decisions and owners come from the transcript")
        #expect(budget.lowercased().contains("staging"))
        let index = try Files.text(notes.appendingPathComponent("index.md"))
        #expect(index.contains("# Meeting notes") && index.contains("2 meeting(s)"))
        #expect(index.contains("(2026-11-03-product-sync-notes.md)") && index.contains("(2026-11-10-budget-review-notes.md)"))
        #expect(Files.tree(transcripts) == before, "transcripts are read only")
        #expect(run.outcome.results(for: "summarize").count == 2)
        #expect(run.receipt.usage.tokens.totalTokens > 0 && run.receipt.usage.costUSD < 0.05, "cost \(run.receipt.usage.costUSD)")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
        print(String(format: "VERIFIED(live anthropic:claude-haiku-5-5): meeting-notes-organizer, %d tokens, $%.4f", run.receipt.usage.tokens.totalTokens, run.receipt.usage.costUSD))
    }

    // MARK: 5 · CSV cleanup and charts

    @Test("05 csv-cleanup-and-charts: the sandboxed Python script cleans the dirty rows and draws one bar per row")
    func csvCleanupAndCharts() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("csv-cleanup-and-charts")
        let input = ws.appendingPathComponent("input.csv"), output = ws.appendingPathComponent("Output")
        let inputHash = try Files.sha256(input)
        let run = try await h.run("csv-cleanup-and-charts", ["inputFile": h.path(input), "outputFolder": h.path(output)])
        #expect(run.status == .succeeded, "\(run.receipt.errors) \(run.step("clean")?.output["stderr"]?.stringValue ?? "")")

        let cleaned = try Files.text(output.appendingPathComponent("cleaned.csv")).replacingOccurrences(of: "\r\n", with: "\n")
        #expect(cleaned == "region,units,revenue\nNorth,12,1200\nSouth,7,\"1,050\"\nEast,3,\nWest,9,810\nCentral,15,2250\n")
        let svg = try Files.text(output.appendingPathComponent("chart.svg"))
        #expect(svg.hasPrefix("<svg") && svg.contains(">units</text>") && svg.components(separatedBy: "<rect ").count - 1 == 5)
        #expect(run.output("rows") == .int(5) && run.output("rowsBefore") == .int(9))
        #expect(run.output("log")?.stringValue == "rows_in=7 rows_out=5 charted_column=units bars=5")
        #expect(try Files.sha256(input) == inputHash, "the input file is never modified")
        #expect(Set(Files.tree(output).keys) == ["cleaned.csv", "chart.svg"], "the sandbox let the script write only what it should")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
    }

    // MARK: 6 · Batch image conversion

    @Test("06 batch-image-conversion: one JPEG per image with sequential names and the original pixel sizes")
    func batchImageConversion() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("batch-image-conversion")
        let originals = ws.appendingPathComponent("Originals"), converted = ws.appendingPathComponent("Converted")
        let before = Files.tree(originals)
        let run = try await h.run("batch-image-conversion", ["sourceFolder": h.path(originals), "outputFolder": h.path(converted), "format": "jpeg", "prefix": "shot"])
        #expect(run.status == .succeeded, "\(run.diagnosis)")
        // Listing order is the order of the names as bytes: upper case first.
        let expected = [("Icon Large.PNG", 96, 96), ("badge.gif", 120, 80), ("diagram.png", 320, 200), ("sunset.jpg", 640, 360), ("tile.tiff", 200, 200)]
        for (i, (name, w, hgt)) in expected.enumerated() {
            let size = try #require(Files.imageSize(converted.appendingPathComponent("shot-\(i + 1).jpeg")), "shot-\(i + 1).jpeg (\(name)) is not a readable image")
            #expect(size.width == w && size.height == hgt && size.type == "public.jpeg", "\(name) → \(size)")
        }
        #expect(Set(Files.tree(converted).keys) == Set((1...5).map { "shot-\($0).jpeg" }), "captions.txt is not an image and is left out")
        #expect(Files.tree(originals) == before, "originals are never modified or removed")
        #expect(run.output("converted") == .int(5))
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
    }

    // MARK: 7 · Calendar preparation (Apple Events)

    @Test("07 calendar-preparation: read-only; runs for real only when Automation consent for Calendar is already granted")
    func calendarPreparation() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let folder = h.workspace.appendingPathComponent("calendar-preparation/Briefings")
        let parameters: [String: JSONValue] = ["outputFolder": h.path(folder), "daysAhead": 2]

        // Read-only by construction: the only script addresses Calendar and contains no command that changes anything.
        let document = try await h.save("calendar-preparation").document
        let scripts = document.allSteps.compactMap { located -> String? in
            if case .tool(let t) = located.step.kind, t.tool == "applescript.run" { return t.arguments["script"]?.stringValue }; return nil
        }
        #expect(scripts.count == 1)
        for verb in ["make new", "delete", "duplicate", "move ", "set summary", "set start date", "set end date", "set description", "do shell script", "save"] {
            #expect(!scripts[0].lowercased().contains(verb), "the calendar script must stay read-only (found “\(verb)”)")
        }
        let review = try await h.services.workflows.permissionReview(workflowID: "calendar-preparation", parameters: parameters)
        #expect(review.proposed.map(\.capability).contains(.appAutomation(bundleID: "com.apple.iCal")))
        #expect(!review.proposed.contains { $0.capability.kind.hasPrefix("file.read") || $0.capability.kind.hasPrefix("file.delete") })

        let status = MacPermissions.automationStatus(bundleID: "com.apple.iCal")
        switch status {
        case .granted:
            let run = try await h.run("calendar-preparation", parameters)
            expectOnlyTheNotificationFailed(run, step: "announce")
            let briefingPath = try #require(run.output("briefing")?.stringValue)
            let briefing = try Files.text(URL(fileURLWithPath: briefingPath))
            let events = try #require(run.output("events")?.intValue)
            #expect(briefing.contains("# Briefing for") && briefing.contains("Events in the next 2 day(s): \(events)"))
            #expect(briefing.components(separatedBy: "- [ ] ").count - 1 == events, "one checklist line per event")
            #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
            print("VERIFIED(appleEvents → Calendar granted): calendar-preparation read \(events) event(s), briefing written")
        case .denied:
            let run = try await h.run("calendar-preparation", parameters)
            #expect(run.status == .blockedPermission, "\(run.status)")
            #expect(run.step("events")?.status == .blockedPermission)
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty, "no briefing without consent")
            print("SKIPPED(appleEvents not granted): Automation consent for Calendar was refused; BLOCKED_PERMISSION verified")
        case .notDetermined, .unknown:
            // Running the script would make macOS show its consent prompt (or launch Calendar): not in a test. Dry run instead.
            let dry = try await h.run("calendar-preparation", parameters, dryRun: true)
            #expect(dry.step("events")?.status == .simulated)
            #expect(dry.receipt.limitations.contains { $0.contains("events") && $0.contains("AppleScript") && $0.contains("Calendar") }, "\(dry.receipt.limitations)")
            #expect(!Files.exists(folder), "a dry run writes nothing")
            print("SKIPPED(appleEvents not granted): Automation consent for Calendar is \(status.rawValue) (Calendar not running or never asked); dry run verified, no prompt triggered")
        }
    }

    // MARK: 8 · Folder backup and verification

    @Test("08 folder-backup-and-verify: the archive restores to an identical tree and its recorded checksum is right")
    func folderBackupAndVerify() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("folder-backup-and-verify")
        let source = ws.appendingPathComponent("Documents"), backups = ws.appendingPathComponent("Backups")
        let before = Files.tree(source)
        #expect(before[".settings"] != nil, "the sample has a hidden file")
        let run = try await h.run("folder-backup-and-verify", ["source": h.path(source), "backupRoot": h.path(backups)])
        // The temporary restore went to the user's Trash: take the test's own item out again, whatever happens next.
        let trashed = run.step("cleanup")?.output["trashPath"]?.stringValue
        defer { if let trashed, trashed.contains("/.Trash/"), (trashed as NSString).lastPathComponent.hasPrefix(".verify-") { try? FileManager.default.removeItem(atPath: trashed) } }
        expectOnlyTheNotificationFailed(run, step: "announce")

        let archivePath = try #require(run.output("archive")?.stringValue)
        let archive = URL(fileURLWithPath: archivePath)
        #expect(archive.lastPathComponent.hasPrefix("backup-") && archive.pathExtension == "zip")
        let digest = try Files.sha256(archive)
        #expect(run.output("sha256") == .string(digest))
        #expect(try Files.text(URL(fileURLWithPath: archive.path + ".sha256")) == "\(digest)  \(archive.lastPathComponent)\n")
        // Independent restore with ditto: the archive really holds the whole tree, hidden file included.
        let check = h.root.appendingPathComponent("independent-restore")
        #expect(try Files.run("/usr/bin/ditto", ["-x", "-k", archive.path, check.path]).code == 0)
        #expect(Files.tree(check.appendingPathComponent("Documents")) == before)
        #expect(Files.tree(source) == before, "the source is read only")
        #expect(run.output("identical") == .bool(true) && run.output("entries")?.intValue == before.count + 1)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: backups.path)) == [archive.lastPathComponent, archive.lastPathComponent + ".sha256"],
                "the temporary restore folder is gone from the backup root")
        #expect(trashed != nil && Files.exists(URL(fileURLWithPath: trashed ?? "/nonexistent")), "the temporary copy was moved to the Trash, not erased")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
    }

    @Test("08 folder-backup-and-verify, headless and without accepted permissions: waits for approval and writes nothing")
    func folderBackupWithoutPermissions() async throws {
        let h = try await ExampleHarness(interactive: false)
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("folder-backup-and-verify")
        let before = Files.tree(ws)
        let run = try await h.run("folder-backup-and-verify", ["source": h.path(ws.appendingPathComponent("Documents")), "backupRoot": h.path(ws.appendingPathComponent("Backups"))],
                                  accept: false, mode: .scheduled)
        #expect(run.status == .waitingApproval || run.status == .blockedPermission, "\(run.status)")
        #expect(Files.tree(ws) == before, "nothing may change on disk")
        #expect(!run.receipt.toolCalls.contains { $0.status == .succeeded })
    }

    // MARK: 9 · Website change monitoring (loopback only)

    @Test("09 website-change-monitor: baseline, unchanged and changed runs against a loopback server; the network permission follows the parameter")
    func websiteChangeMonitor() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("website-change-monitor")
        let v1 = try Data(contentsOf: ws.appendingPathComponent("site/page-v1.html")), v2 = try Data(contentsOf: ws.appendingPathComponent("site/page-v2.html"))
        let server = try await LoopbackServer { _ in (200, "text/html; charset=utf-8", v1) }
        defer { server.stop() }
        let state = ws.appendingPathComponent("State")
        let url = "http://127.0.0.1:\(server.port)/page.html"
        let parameters: [String: JSONValue] = ["host": "127.0.0.1", "url": .string(url), "stateFolder": h.path(state)]

        try await h.save("website-change-monitor")
        let review = try await h.services.workflows.permissionReview(workflowID: "website-change-monitor", parameters: parameters)
        let hosts = review.proposed.compactMap { g -> String? in if case .network(let host) = g.capability { return host }; return nil }
        #expect(hosts == ["127.0.0.1"], "the declared network permission is the host parameter, not example.com: \(hosts)")

        let first = try await h.run("website-change-monitor", parameters)
        #expect(first.status == .succeeded, "\(first.receipt.errors)")
        #expect(first.output("firstRun") == .bool(true) && first.output("changed") == .bool(false) && first.output("status") == .int(200))
        #expect(try Data(contentsOf: state.appendingPathComponent("previous.html")) == v1)

        let second = try await h.run("website-change-monitor", parameters)
        #expect(second.status == .succeeded, "\(second.receipt.errors)")
        #expect(second.output("firstRun") == .bool(false) && second.output("changed") == .bool(false))
        #expect(second.step("alert")?.status == .skipped)

        server.setHandler { _ in (200, "text/html; charset=utf-8", v2) }
        let third = try await h.run("website-change-monitor", parameters)
        #expect(third.output("changed") == .bool(true), "the change is detected")
        expectOnlyTheNotificationFailed(third, step: "alert")   // the alert is a notification: no app bundle under swift test
        #expect(try Data(contentsOf: state.appendingPathComponent("previous.html")) == v2, "the new copy became the reference")
        #expect(try Data(contentsOf: state.appendingPathComponent("current.html")) == v2)
        #expect(third.output("sha256")?.stringValue == SHA256.hash(data: v2).map { String(format: "%02x", $0) }.joined())
        #expect(server.requests == ["/page.html", "/page.html", "/page.html"], "exactly one GET per run: \(server.requests)")

        // A URL on a host the accepted permission does not cover is not fetched.
        var elsewhere = parameters
        elsewhere["url"] = .string("http://localhost:\(server.port)/page.html")
        let refused = try await h.run("website-change-monitor", elsewhere)
        #expect(refused.status == .waitingApproval, "\(refused.status)")
        #expect(refused.step("fetch")?.status == .notApproved)
        #expect(server.requests.count == 3, "no request left for the other host")
        #expect(h.approvals.toolRequests.count == 1 && h.approvals.toolRequests.first?.hasPrefix("http.request") == true)
    }

    @Test("09 website-change-monitor, headless and without accepted permissions: no request is sent and nothing is written")
    func websiteChangeMonitorWithoutPermissions() async throws {
        let h = try await ExampleHarness(interactive: false)
        defer { Task { await h.tearDown() } }
        let server = try await LoopbackServer { _ in (200, "text/html", Data("<p>never fetched</p>".utf8)) }
        defer { server.stop() }
        let state = h.workspace.appendingPathComponent("website-change-monitor/State")
        let run = try await h.run("website-change-monitor", ["host": "127.0.0.1", "url": .string("http://127.0.0.1:\(server.port)/page.html"), "stateFolder": h.path(state)],
                                  accept: false, mode: .scheduled)
        #expect(run.status == .waitingApproval || run.status == .blockedPermission, "\(run.status)")
        #expect(server.requests.isEmpty, "nothing may be sent without the network permission")
        #expect(!Files.exists(state), "nothing may be written")
    }

    // MARK: 10 · System health report

    @Test("10 system-health-report: the report holds the real machine facts and a plausible free-space fraction")
    func systemHealthReport() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let folder = h.workspace.appendingPathComponent("system-health-report/Reports")
        let run = try await h.run("system-health-report", ["outputFolder": h.path(folder)])
        let fraction = try #require(run.output("freeFraction")?.doubleValue)
        let low = fraction < 0.1
        if low { expectOnlyTheNotificationFailed(run, step: "warn") } else { #expect(run.status == .succeeded, "\(run.diagnosis)"); #expect(run.step("warn")?.status == .skipped) }
        #expect(run.output("lowDisk") == .bool(low))
        // The same figure, read by the test straight from the system.
        let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let expected = Double(values.volumeAvailableCapacityForImportantUsage ?? 0) / Double(values.volumeTotalCapacity ?? 1)
        #expect(fraction > 0 && fraction <= 1 && abs(fraction - expected) < 0.05, "free fraction \(fraction) vs \(expected)")
        let reportPath = try #require(run.output("report")?.stringValue)
        let report = try Files.text(URL(fileURLWithPath: reportPath))
        for section in ["# System health", "## Machine", "## Disk", "## Busiest processes", "## Power", "## Network"] { #expect(report.contains(section)) }
        #expect(report.contains("\"cores\":\(ProcessInfo.processInfo.processorCount)") || report.contains("\"cores\": \(ProcessInfo.processInfo.processorCount)"))
        #expect(report.contains("\"memoryBytes\"") && report.contains("\"cpuPercent\"") && report.contains("\"onACPower\"") && report.contains("\"online\""))
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #expect(run.output("osVersion")?.stringValue?.hasPrefix("\(v.majorVersion).\(v.minorVersion)") == true, "\(String(describing: run.output("osVersion")))")
        #expect(Set(Files.tree(folder).keys).count == 1, "the report is the only file written")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
    }

    // MARK: 12 · Document metadata catalogue

    @Test("12 document-metadata-catalog: one row per file with the right size and SHA-256")
    func documentMetadataCatalog() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("document-metadata-catalog")
        let documents = ws.appendingPathComponent("Documents"), catalog = ws.appendingPathComponent("catalog.csv")
        let before = Files.tree(documents).filter { $0.value != "dir" }
        let run = try await h.run("document-metadata-catalog", ["documentsFolder": h.path(documents), "catalogFile": h.path(catalog)])
        #expect(run.status == .succeeded, "\(run.diagnosis)")
        let lines = try Files.text(catalog).split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.first == "path,extension,bytes,modified,contentType,sha256" && lines.count == before.count + 1)
        var total = 0
        for line in lines.dropFirst() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            #expect(c.count == 6, "\(line)")
            let file = documents.appendingPathComponent(c[0])
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
            #expect(before[c[0]] == c[5], "\(c[0]): SHA-256 in the catalogue matches the file")
            #expect(Int(c[2]) == size && c[1] == "." + file.pathExtension.lowercased())
            #expect(ISO8601DateFormatter().date(from: c[3]) != nil, "modified is an ISO 8601 date: \(c[3])")
            total += size
        }
        #expect(Set(lines.dropFirst().map { String($0.split(separator: ",")[0]) }) == Set(before.keys))
        #expect(run.output("files") == .int(before.count) && run.output("totalBytes") == .int(total))
        #expect(Files.tree(documents).filter { $0.value != "dir" } == before, "the documents are read only")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
    }

    // MARK: 13 · Scheduled window screenshot (Screen Recording)

    /// An application that has a normal window on screen right now and is not one the capture tool refuses. Finder and
    /// Terminal are preferred over whatever else is open: the picture is deleted right after the assertion, but a
    /// file-manager or terminal window is the least personal thing to capture.
    private func applicationWithAWindow() -> String? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var found: [String] = []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
            let bounds = w[kCGWindowBounds as String] as? [String: Any]
            guard (bounds?["Width"] as? Double ?? 0) > 100, (bounds?["Height"] as? Double ?? 0) > 100 else { continue }
            if !ScreenCaptureTool.defaultSensitiveBundleIDs.contains(id.lowercased()), !found.contains(id) { found.append(id) }
        }
        return ["com.apple.finder", "com.apple.Terminal"].first(where: found.contains) ?? found.first
    }

    @Test("13 scheduled-window-screenshot: skips cleanly without a window; captures a real window only when Screen Recording is granted")
    func scheduledWindowScreenshot() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let folder = h.workspace.appendingPathComponent("scheduled-window-screenshot/Captures")

        // An application that is not running: the run succeeds, says so, launches nothing and writes no picture.
        let absent = try await h.run("scheduled-window-screenshot", ["bundleID": "ai.spboucher.orix.tests.not-installed", "outputFolder": h.path(folder)])
        #expect(absent.status == .succeeded, "\(absent.receipt.errors)")
        #expect(absent.output("captured") == .bool(false) && absent.step("capture")?.status == .skipped)
        #expect(Files.tree(folder).isEmpty)
        let review = try await h.services.workflows.permissionReview(workflowID: "scheduled-window-screenshot", parameters: ["bundleID": "com.apple.finder", "outputFolder": h.path(folder)])
        #expect(review.proposed.map(\.capability).contains(.screenCapture(scope: "window:com.apple.finder")), "the screen scope follows the parameter, one window, never the display")

        let granted = MacPermissions.status(.screenRecording) == .granted
        guard let bundleID = applicationWithAWindow() else {
            print("SKIPPED(no application window on screen): scheduled-window-screenshot capture; the no-window path was verified (screenRecording \(granted ? "granted" : "not granted"))")
            return
        }
        let run = try await h.run("scheduled-window-screenshot", ["bundleID": .string(bundleID), "outputFolder": h.path(folder)])
        if granted {
            #expect(run.status == .succeeded, "\(run.diagnosis)")
            #expect(run.output("captured") == .bool(true))
            let filePath = try #require(run.output("file")?.stringValue)
            let file = URL(fileURLWithPath: filePath)
            let size = try #require(Files.imageSize(file), "the capture is not a readable image")
            #expect(size.type == "public.png" && size.width > 50 && size.height > 50)
            #expect(run.step("capture")?.output["pixelWidth"] == .int(size.width) && run.step("capture")?.output["pixelHeight"] == .int(size.height))
            #expect(Files.tree(folder).count == 1)
            #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
            try? FileManager.default.removeItem(at: file)   // a picture of a real window: not kept a moment longer than the assertion
            print("VERIFIED(screenRecording granted): scheduled-window-screenshot captured a \(size.width)×\(size.height) px window of \(bundleID)")
        } else {
            #expect(run.status == .blockedPermission, "\(run.status)")
            #expect(run.step("capture")?.status == .blockedPermission)
            #expect(Files.tree(folder).isEmpty, "no picture without Screen Recording")
            print("SKIPPED(screenRecording not granted): scheduled-window-screenshot; BLOCKED_PERMISSION verified, no prompt triggered")
        }
    }

    // MARK: 14 · Spreadsheet validation

    @Test("14 spreadsheet-validation: a valid workbook passes; a broken one fails the run and the report says why")
    func spreadsheetValidation() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("spreadsheet-validation")
        let reports = ws.appendingPathComponent("Reports")
        let good = ws.appendingPathComponent("data.xlsx"), bad = ws.appendingPathComponent("data-invalid.xlsx")
        let hashes = [try Files.sha256(good), try Files.sha256(bad)]

        let valid = try await h.run("spreadsheet-validation", ["workbook": h.path(good), "reportFolder": h.path(reports)])
        #expect(valid.status == .succeeded, "\(valid.receipt.errors)")
        #expect(valid.output("valid") == .bool(true) && valid.output("rows") == .int(4) && valid.output("columns") == ["id", "name", "amount"])
        var report = try Files.text(reports.appendingPathComponent("validation.md"))
        #expect(report.contains("Sheet: Orders") && report.contains("Data rows read: 4") && report.contains("Valid: true"))
        #expect(valid.step("read")?.output["rows"]?.arrayValue?.last == [1004, "Delta", 195.5], "a formula cell is read as its cached value")

        let invalid = try await h.run("spreadsheet-validation", ["workbook": h.path(bad), "reportFolder": h.path(reports)])
        #expect(invalid.status == .failed, "a broken workbook fails the run on purpose")
        #expect(invalid.failedSteps == ["check"] && invalid.output("valid") == nil)
        report = try Files.text(reports.appendingPathComponent("validation.md"))
        #expect(report.contains("Missing required columns: 1 amount") && report.contains("Fully empty rows: 1") && report.contains("Rows without a key value: 2") && report.contains("Valid: false"))
        let failed = invalid.receipt.verifications.filter { !$0.passed }
        #expect(failed.count == 3, "\(failed.map(\.assertion))")
        #expect([try Files.sha256(good), try Files.sha256(bad)] == hashes, "workbooks are never modified")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
    }

    // MARK: 15 · Browser data entry (WKWebView against a loopback test site)

    @Test("15 browser-data-entry: fills both pages of the test site in the real WKWebView, submits after approval, keeps a screenshot")
    func browserDataEntry() async throws {
        let h = try await ExampleHarness()
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("browser-data-entry")
        let server = try await LoopbackServer.site(ws.appendingPathComponent("site"))
        defer { server.stop() }
        let evidence = ws.appendingPathComponent("Evidence")
        let parameters: [String: JSONValue] = ["host": "127.0.0.1", "pageURL": .string("http://127.0.0.1:\(server.port)/form.html"),
                                               "fullName": "Grace Hopper", "email": "grace@example.org", "plan": "company", "evidenceFolder": h.path(evidence)]
        let run = try await h.run("browser-data-entry", parameters)
        #expect(run.status == .succeeded, "\(run.diagnosis)")
        #expect(run.output("confirmation")?.stringValue?.contains("Registered Grace Hopper <grace@example.org> on plan company.") == true, "\(String(describing: run.output("confirmation")))")
        #expect(run.output("page")?.stringValue?.contains("/done.html?") == true)
        let pages = server.requests.filter { $0.contains(".html") }
        #expect(pages.count == 3 && pages[0] == "/form.html", "\(pages)")
        #expect(pages[1].hasPrefix("/details.html?") && pages[1].contains("name=Grace") && pages[1].contains("email=grace%40example.org"), "\(pages)")
        #expect(pages[2].hasPrefix("/done.html?") && pages[2].contains("plan=company") && pages[2].contains("terms=yes") && pages[2].contains("name=Grace"), "\(pages)")
        let shot = evidence.appendingPathComponent("confirmation.png")
        let size = try #require(Files.imageSize(shot))
        #expect(size.type == "public.png" && size.width > 100 && size.height > 100)
        #expect(run.output("screenshotSha256")?.stringValue == (try Files.sha256(shot)))
        #expect(h.approvals.gates.count == 1 && h.approvals.gates.first?.contains("Grace Hopper") == true, "the gate names what will be submitted")
        #expect(h.approvals.toolRequests.isEmpty, "\(h.approvals.toolRequests)")
        #expect(await h.services.browser.session(runID: run.record.id) == nil, "the browser session is closed")
    }

    @Test("15 browser-data-entry: a refused approval submits nothing")
    func browserDataEntryRefused() async throws {
        let h = try await ExampleHarness(approveGates: false)
        defer { Task { await h.tearDown() } }
        let ws = try h.copySample("browser-data-entry")
        let server = try await LoopbackServer.site(ws.appendingPathComponent("site"))
        defer { server.stop() }
        let evidence = ws.appendingPathComponent("Evidence")
        let run = try await h.run("browser-data-entry", ["host": "127.0.0.1", "pageURL": .string("http://127.0.0.1:\(server.port)/form.html"), "evidenceFolder": h.path(evidence)])
        #expect(run.status == .failed, "a denied gate fails the run: \(run.status)")
        #expect(run.failedSteps == ["confirm"] && run.step("submit")?.status != .succeeded)
        #expect(!server.requests.contains { $0.hasPrefix("/done.html") }, "the form was not submitted: \(server.requests)")
        #expect(server.requests.contains { $0.hasPrefix("/details.html?") }, "the first page was filled before the gate")
        #expect(!Files.exists(evidence.appendingPathComponent("confirmation.png")))
        #expect(await h.services.browser.session(runID: run.record.id) == nil, "the browser session is closed when the run ends")
    }
}
