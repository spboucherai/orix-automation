// ORIX OS Automation
// File: Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/WorkflowCodeModel.swift
// Description: State of the workflow code editor: the list of stored workflows, the open buffer and its stored source, debounced validation, completion, formatting with round-trip loss, format switching, saving, versions and the diffs between them.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAppUI
import SwiftUI

/// What a diff sheet shows and what accepting it does.
public struct DiffPresentation: Identifiable, Sendable {
    public enum Acceptance: Sendable, Equatable {
        case none
        /// Replace the workflow buffer with `new` (an assistant draft, a format, a restored version).
        case replaceWorkflowBuffer
        /// Replace the script buffer with `new`.
        case replaceScriptBuffer
    }
    public var id = UUID()
    public var title: String
    public var old: String
    public var new: String
    public var oldTitle: String
    public var newTitle: String
    public var changes: [WorkflowChange] = []
    /// Lines shown above the diff (what formatting drops, for example).
    public var notes: [String] = []
    public var acceptance: Acceptance = .none
    public var acceptTitle: String = ""
}

@MainActor
@Observable
public final class WorkflowCodeModel {
    public private(set) var workflows: [WorkflowRow] = []
    public private(set) var openID: String?
    public private(set) var storedSource = ""
    public private(set) var storedVersion = 0
    public var text = "" { didSet { if text != oldValue { textChanged() } } }
    public private(set) var format: WorkflowFormat = .yaml
    public private(set) var diagnostics: [EditorDiagnostic] = []
    public private(set) var hovers: [EditorHover] = []
    public private(set) var isValidating = false
    public private(set) var isSaving = false
    public private(set) var versions: [WorkflowVersionRow] = []
    /// A newer version was saved elsewhere while this buffer has unsaved changes.
    public private(set) var staleNotice: Int?
    public private(set) var tools: [ToolManifest] = []
    public private(set) var agents: [String] = []
    public private(set) var hasLoaded = false
    /// Message shown in the editor's banner (save result, errors).
    public var notice: (kind: Banner.Kind, text: String)?
    public let editor = CodeEditorController()
    /// Milliseconds validation waits after the last keystroke.
    public var debounceMilliseconds: UInt64 = 300

    @ObservationIgnored private var services: ORIXServices?
    @ObservationIgnored private var validation: Task<Void, Never>?
    @ObservationIgnored private var catalogCache: (text: String, catalog: CompletionCatalog)?

    public init() {
        editor.completionProvider = { [weak self] text, cursor, explicit in self?.completions(text: text, cursor: cursor, explicit: explicit) }
    }

    public var isDirty: Bool { text != storedSource }
    public var isUntitled: Bool { openID == nil }
    public var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    public var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
    public var title: String {
        if let id = openID { return workflows.first { $0.id == id }?.name ?? id }
        return String(localized: "Untitled workflow")
    }

    // MARK: Loading

    /// Refreshes the list, the tool catalog and, when the buffer has no unsaved change, the open workflow.
    public func reload(_ services: ORIXServices) async {
        self.services = services
        workflows = await services.workflows.list().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        tools = await services.executor.manifests()
        agents = await services.agents.profileNames()
        if let id = openID {
            if let row = workflows.first(where: { $0.id == id }) {
                if row.currentVersion != storedVersion {
                    if isDirty { staleNotice = row.currentVersion } else { await open(id, services: services) }
                }
                versions = await services.workflows.versions(workflowID: id)
            } else if !isDirty {
                // Deleted elsewhere.
                openID = nil; storedSource = ""; storedVersion = 0; text = ""; versions = []
            }
        }
        hasLoaded = true
    }

    /// Opens a stored workflow in its stored format, discarding the buffer.
    public func open(_ id: String, services: ORIXServices) async {
        self.services = services
        do {
            let source = try await services.workflows.source(workflowID: id)
            let rows = await services.workflows.versions(workflowID: id)
            let latest = rows.max { $0.version < $1.version }
            openID = id
            versions = rows
            storedVersion = latest?.version ?? 0
            format = latest?.format == "json" ? .json : WorkflowCodec.detectFormat(source)
            storedSource = source
            staleNotice = nil
            notice = nil
            text = source
            await validateNow()
        } catch {
            notice = (.error, Self.describe(error))
        }
    }

    /// Starts an unsaved buffer from source (a template, the starter).
    public func startNew(source: String = WorkflowSnippets.starter) {
        openID = nil; storedSource = ""; storedVersion = 0; versions = []; staleNotice = nil; notice = nil
        format = WorkflowCodec.detectFormat(source)
        text = source
    }

    public func revert() {
        staleNotice = nil
        if editor.isAttached { editor.replaceAll(with: storedSource) } else { text = storedSource }
    }

    // MARK: Validation

    private func textChanged() {
        catalogCache = nil
        validation?.cancel()
        guard services != nil else { return }
        let delay = debounceMilliseconds
        validation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.validateNow()
        }
    }

    /// Validates the buffer now, against the tools, agents and workflows that exist.
    public func validateNow() async {
        guard let services else { return }
        let source = text
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { diagnostics = []; hovers = []; return }
        isValidating = true
        let result = await services.workflows.diagnose(source, format: format)
        isValidating = false
        guard source == text else { return }   // typed again meanwhile
        diagnostics = result.diagnostics.map(EditorDiagnostic.init).sorted { ($0.severity, $0.line, $0.column) < ($1.severity, $1.line, $1.column) }
        let byID = Dictionary(tools.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        hovers = ToolDocs.ranges(in: source).compactMap { hit in byID[hit.id].map { EditorHover(range: hit.range, text: ToolDocs.text($0)) } }
    }

    // MARK: Completion and tool documentation

    public func catalog(for text: String) -> CompletionCatalog {
        if let c = catalogCache, c.text == text { return c.catalog }
        let c = CompletionCatalog.scrape(text, tools: tools, agents: agents)
        catalogCache = (text, c)
        return c
    }

    public func completions(text: String, cursor: Int, explicit: Bool) -> CompletionResult? {
        let request = CompletionAnalyzer.analyze(text: text, cursor: cursor, format: format)
        guard explicit || request.automatic else { return nil }
        let items = CompletionEngine.candidates(request.context, catalog: catalog(for: text))
        return items.isEmpty ? nil : CompletionResult(items: items, replaceRange: request.replaceRange)
    }

    /// The manifest of the tool whose id is at a UTF-16 offset of the buffer.
    public func tool(at offset: Int) -> ToolManifest? {
        guard let hit = ToolDocs.toolID(in: text, at: offset) else { return nil }
        return tools.first { $0.identifier == hit.id }
    }

    // MARK: Format

    /// The canonical text of the buffer and what rewriting would drop. Throws when the buffer does not parse.
    public func formatted(as target: WorkflowFormat? = nil) throws -> (text: String, loss: [String]) {
        let doc = try WorkflowCodec.parse(text, format: format)
        let target = target ?? format
        var loss = WorkflowCodec.roundTripLoss(source: text, format: target)
        if target != format { loss.removeAll { $0.hasPrefix("the text would be rewritten") } }
        return (WorkflowCodec.emit(doc, format: target), loss)
    }

    /// Replaces the buffer with formatted text (one undoable edit) and records the format it is now in.
    public func apply(_ newText: String, format newFormat: WorkflowFormat? = nil) {
        if let newFormat { format = newFormat }
        if editor.isAttached { editor.replaceAll(with: newText) } else { text = newText }
    }

    // MARK: Save

    /// Saves a new version. Errors block saving and are shown; a change of declared permissions is announced.
    @discardableResult
    public func save(note: String = "") async -> SavedWorkflow? {
        guard let services, !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        await validateNow()
        if errorCount > 0 {
            notice = (.error, String(localized: "Not saved: fix the \(errorCount) errors listed under Problems first."))
            return nil
        }
        let source = text
        do {
            let saved = try await services.workflows.save(source: source, format: format, note: note)
            openID = saved.id
            storedSource = source
            storedVersion = saved.version
            staleNotice = nil
            workflows = await services.workflows.list().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            versions = await services.workflows.versions(workflowID: saved.id)
            diagnostics = saved.diagnostics.map(EditorDiagnostic.init).sorted { ($0.severity, $0.line, $0.column) < ($1.severity, $1.line, $1.column) }
            if saved.permissionsReset {
                notice = (.warning, String(localized: "Saved version \(saved.version). The declared permissions changed, so the earlier acceptance was withdrawn: review and accept them again before the next run."))
            } else {
                notice = (.success, String(localized: "Saved version \(saved.version)."))
            }
            return saved
        } catch {
            notice = (.error, Self.describe(error))
            return nil
        }
    }

    // MARK: Diffs

    static func changes(old: String, new: String) -> [WorkflowChange] {
        guard let a = try? WorkflowCodec.parse(old, format: WorkflowCodec.detectFormat(old)),
              let b = try? WorkflowCodec.parse(new, format: WorkflowCodec.detectFormat(new)) else { return [] }
        return WorkflowDiff.diff(a, b)
    }

    /// Unsaved changes against the stored source.
    public func unsavedDiff() -> DiffPresentation {
        DiffPresentation(title: String(localized: "Unsaved changes"), old: storedSource, new: text,
                         oldTitle: storedVersion > 0 ? String(localized: "Stored · version \(storedVersion)") : String(localized: "Stored (nothing yet)"),
                         newTitle: String(localized: "Editor"), changes: Self.changes(old: storedSource, new: text))
    }

    /// Two stored versions.
    public func versionDiff(from: Int, to: Int) -> DiffPresentation? {
        guard let a = versions.first(where: { $0.version == from }), let b = versions.first(where: { $0.version == to }) else { return nil }
        return DiffPresentation(title: String(localized: "Version \(from) compared with version \(to)"), old: a.source, new: b.source,
                                oldTitle: String(localized: "Version \(from)"), newTitle: String(localized: "Version \(to)"),
                                changes: Self.changes(old: a.source, new: b.source))
    }

    /// A draft that would replace the buffer, for review.
    public func draftDiff(_ draft: String, title: String, notes: [String] = [], acceptTitle: String) -> DiffPresentation {
        DiffPresentation(title: title, old: text, new: draft, oldTitle: String(localized: "Editor"), newTitle: String(localized: "Proposed"),
                         changes: Self.changes(old: text, new: draft), notes: notes, acceptance: .replaceWorkflowBuffer, acceptTitle: acceptTitle)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? WorkflowParseError, let d = e.diagnostics.first {
            return d.line > 0 ? "Line \(d.line): \(d.message)" : d.message
        }
        return Redactor.shared.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
}
