// ORIX OS Automation
// File: Packages/ORIXCore/Sources/ORIXTestingSupport/TestingSupport.swift
// Description: Test doubles shared by every package: scripted provider, fixed policies, scripted approval broker, collecting sinks, temp directories, closure-backed tool invoker.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

/// A provider that replays scripted turns. Clearly a mock: its id is `scripted` unless stated otherwise.
public final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    public enum Turn: Sendable {
        case response(LLMResponse)
        case failure(LLMError)
        /// Computes the turn from the request (to assert on what the runtime sent).
        case dynamic(@Sendable (LLMRequest) -> LLMResponse)
    }
    public let id: ProviderID
    private let lock = NSLock()
    private var turns: [Turn]
    private var _requests: [LLMRequest] = []
    /// When the script runs out: repeat this turn forever (used for loop/budget tests), else fail.
    public var fallback: Turn?

    public init(id: ProviderID = ProviderID(rawValue: "scripted"), turns: [Turn], fallback: Turn? = nil) {
        self.id = id; self.turns = turns; self.fallback = fallback
    }

    public var requests: [LLMRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    public func listModels() async throws -> [ModelInfo] {
        [ModelInfo(id: "scripted-1", provider: id, inputPricePerMTok: 1, outputPricePerMTok: 2, source: "registry")]
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.lock()
        _requests.append(request)
        let turn: Turn? = turns.isEmpty ? fallback : turns.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            guard let turn else {
                continuation.finish(throwing: LLMError.invalidRequest("ScriptedProvider has no more turns")); return
            }
            let response: LLMResponse
            switch turn {
            case .failure(let e): continuation.finish(throwing: e); return
            case .response(let r): response = r
            case .dynamic(let f): response = f(request)
            }
            for c in response.content {
                switch c {
                case .text(let t): continuation.yield(.textDelta(t))
                case .toolUse(let u): continuation.yield(.toolUse(u))
                default: break
                }
            }
            continuation.yield(.usage(response.usage))
            continuation.yield(.stop(response.stopReason))
            continuation.finish()
        }
    }

    public static func text(_ text: String, usage: TokenUsage = .init(inputTokens: 10, outputTokens: 5)) -> Turn {
        .response(LLMResponse(model: "scripted-1", content: [.text(text)], stopReason: .endTurn, usage: usage))
    }

    public static func tool(_ toolID: String, _ input: JSONValue, id: String = UUID().uuidString, text: String = "",
                            usage: TokenUsage = .init(inputTokens: 10, outputTokens: 5)) -> Turn {
        var content: [LLMContent] = text.isEmpty ? [] : [.text(text)]
        content.append(.toolUse(LLMToolUse(id: id, name: LLMToolSpec.providerName(forToolID: toolID), input: input)))
        return .response(LLMResponse(model: "scripted-1", content: content, stopReason: .toolUse, usage: usage))
    }
}

public struct StaticProviderResolver: ProviderResolving {
    public let provider: any LLMProvider
    public init(_ provider: any LLMProvider) { self.provider = provider }
    public func provider(for id: ProviderID) async throws -> any LLMProvider { provider }
    public func modelInfo(_ ref: ModelRef) async -> ModelInfo? {
        ModelInfo(id: ref.model, provider: ref.provider, inputPricePerMTok: 1, outputPricePerMTok: 2, source: "registry")
    }
}

public struct AllowAllPolicy: PolicyDeciding {
    public init() {}
    public func evaluate(_ request: AccessRequest) async -> PolicyDecision { .allow(grantIDs: []) }
    public func recordApproval(_ response: ApprovalResponse, for request: ApprovalRequest) async -> [String] { [] }
    public func consume(grantIDs: [String], callID: String) async {}
    public func confinement(runID: String, workflowID: String?) async -> Confinement { Confinement(readRoots: ["/"], writeRoots: ["/"], networkHosts: ["*"]) }
}

public struct DenyAllPolicy: PolicyDeciding {
    public init() {}
    public func evaluate(_ request: AccessRequest) async -> PolicyDecision { .deny(reason: "DenyAllPolicy") }
    public func recordApproval(_ response: ApprovalResponse, for request: ApprovalRequest) async -> [String] { [] }
    public func consume(grantIDs: [String], callID: String) async {}
    public func confinement(runID: String, workflowID: String?) async -> Confinement { Confinement() }
}

/// Answers approval requests from a fixed list, then with `fallback`. Records what it was asked.
public actor ScriptedApprovalBroker: ApprovalBroker {
    private var answers: [ApprovalResponse]
    private let fallback: ApprovalResponse
    public private(set) var requests: [ApprovalRequest] = []
    public init(answers: [ApprovalResponse] = [], fallback: ApprovalResponse = .deny(reason: "no scripted answer")) {
        self.answers = answers; self.fallback = fallback
    }
    public func requestApproval(_ request: ApprovalRequest) async -> ApprovalResponse {
        requests.append(request)
        return answers.isEmpty ? fallback : answers.removeFirst()
    }
}

public actor CollectingEventSink: RunEventSink {
    public private(set) var events: [RunEvent] = []
    public init() {}
    public func emit(_ event: RunEvent) async {
        var e = event; e.seq = events.count + 1
        events.append(e)
    }
    public func events(of kind: RunEvent.Kind) -> [RunEvent] { events.filter { $0.kind == kind } }
}

public actor CollectingAuditSink: AuditSink {
    public private(set) var entries: [AuditEntry] = []
    public init() {}
    public func record(_ entry: AuditEntry) async { entries.append(entry) }
}

/// A tool invoker backed by closures, for agent and workflow tests that do not need the real executor.
public actor ClosureToolInvoker: ToolInvoking {
    public typealias Handler = @Sendable (ToolCall, InvocationContext) async -> ToolResult
    private var handlers: [String: Handler] = [:]
    private var specs: [ToolManifest] = []
    public private(set) var calls: [ToolCall] = []
    public init() {}

    public func register(_ id: String, summary: String = "Test tool for unit tests.", schema: JSONSchema = .object([:], additional: true),
                         sideEffect: SideEffect = .read, tier: ApprovalTier = .readOnly, idempotent: Bool = true, handler: @escaping Handler) {
        handlers[id] = handler
        specs.append(ToolManifest(identifier: id, name: id, summary: summary, family: String(id.split(separator: ".").first ?? "test"),
                                  inputSchema: schema, sideEffect: sideEffect, defaultTier: tier, idempotent: idempotent))
    }

    public func manifests() async -> [ToolManifest] { specs }

    public func invoke(_ call: ToolCall, context: InvocationContext) async -> ToolResult {
        calls.append(call)
        guard let h = handlers[call.toolID] else {
            return .failure(.failed, ToolFailure(code: "not_found", message: "Unknown tool \(call.toolID)"))
        }
        return await h(call, context)
    }
}

/// A unique temporary directory removed on `remove()`.
public struct TempDirectory: Sendable {
    public let url: URL
    public init(prefix: String = "orix-test") throws {
        let base = URL(fileURLWithPath: PathResolver.resolveSymlinks(NSTemporaryDirectory()))
        url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func remove() { try? FileManager.default.removeItem(at: url) }
    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    @discardableResult public func write(_ name: String, _ text: String) throws -> URL {
        let f = file(name)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: f, atomically: true, encoding: .utf8)
        return f
    }
    public func invocation(runID: String = "run-test", mode: ExecutionMode = .guided) -> InvocationContext {
        InvocationContext(runID: runID, mode: mode, workingDirectory: url, artifactsDirectory: url.appendingPathComponent("artifacts"))
    }
    public func toolContext(runID: String = "run-test") -> ToolExecutionContext {
        ToolExecutionContext(runID: runID, workingDirectory: url, artifactsDirectory: url.appendingPathComponent("artifacts"),
                             confinement: Confinement(readRoots: [url.path], writeRoots: [url.path]))
    }
}
