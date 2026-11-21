// ORIX OS Automation
// File: Packages/ORIXServices/Sources/ORIXServices/Interaction.swift
// Description: Data locations, the approval centre (pending approvals answered by the UI, never by a model) and the interaction centre (questions and plan reviews).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAgentRuntime
import ORIXCore

/// Where ORIX keeps its data. Tests and `orixctl --data` point it at a temporary folder.
public struct ORIXPaths: Sendable, Hashable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public static var `default`: ORIXPaths {
        if let override = ProcessInfo.processInfo.environment["ORIX_DATA_DIR"], !override.isEmpty {
            return ORIXPaths(root: URL(fileURLWithPath: override))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ORIXPaths(root: base.appendingPathComponent("ORIX Automation"))
    }

    public var database: URL { root.appendingPathComponent("orix.sqlite") }
    public var auditLog: URL { root.appendingPathComponent("audit.jsonl") }
    public var artifacts: URL { root.appendingPathComponent("artifacts") }
    public var skills: URL { root.appendingPathComponent("skills") }
    public var pythonEnv: URL { root.appendingPathComponent("python-env") }
    public var scratch: URL { root.appendingPathComponent("workspace") }

    public func prepare() throws {
        for d in [root, artifacts, skills, scratch] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        // Owner-only: run history and artifacts are private.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}

/// Holds approval requests until a person answers. In a headless process nobody can, so requests return `.unanswered`
/// at once and the call does not run.
public actor ApprovalCenter: ApprovalBroker {
    public let interactive: Bool
    private var waiting: [String: (ApprovalRequest, CheckedContinuation<ApprovalResponse, Never>)] = [:]
    private var order: [String] = []
    private var observers: [UUID: AsyncStream<[ApprovalRequest]>.Continuation] = [:]

    public init(interactive: Bool) { self.interactive = interactive }

    public func requestApproval(_ request: ApprovalRequest) async -> ApprovalResponse {
        guard interactive else { return .unanswered }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<ApprovalResponse, Never>) in
                if Task.isCancelled { c.resume(returning: .unanswered); return }
                waiting[request.id] = (request, c)
                order.append(request.id)
                publish()
            }
        } onCancel: { Task { await self.resolve(id: request.id, response: .unanswered) } }
    }

    public func pending() -> [ApprovalRequest] { order.compactMap { waiting[$0]?.0 } }

    public func resolve(id: String, response: ApprovalResponse) {
        guard let (_, c) = waiting.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        c.resume(returning: response)
        publish()
    }

    /// Emergency stop: every pending request is refused.
    public func denyAll(reason: String) {
        for id in order { waiting.removeValue(forKey: id)?.1.resume(returning: .deny(reason: reason)) }
        order = []
        publish()
    }

    public func denyAll(runID: String, reason: String) {
        for id in order where waiting[id]?.0.access.runID == runID { resolve(id: id, response: .deny(reason: reason)) }
    }

    private func publish() { let p = pending(); for o in observers.values { o.yield(p) } }

    public nonisolated func updates() -> AsyncStream<[ApprovalRequest]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.add(id, continuation) }
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }
    private func add(_ id: UUID, _ c: AsyncStream<[ApprovalRequest]>.Continuation) { observers[id] = c; c.yield(pending()) }
    private func remove(_ id: UUID) { observers[id] = nil }
}

public struct PendingQuestion: Sendable, Hashable, Identifiable {
    public let id: String
    public let runID: String
    public let question: String
}

public struct PendingPlan: Sendable, Hashable, Identifiable {
    public let id: String
    public let runID: String
    public let plan: AgentPlan
}

/// Questions from an agent and guided-mode plan reviews, answered by the UI.
public actor InteractionCenter: UserInteracting {
    public enum Item: Sendable, Hashable { case question(PendingQuestion), plan(PendingPlan) }
    public let interactive: Bool
    private var questions: [String: (PendingQuestion, CheckedContinuation<String?, Never>)] = [:]
    private var plans: [String: (PendingPlan, CheckedContinuation<PlanReview, Never>)] = [:]
    private var observers: [UUID: AsyncStream<[Item]>.Continuation] = [:]

    public init(interactive: Bool) { self.interactive = interactive }

    public func ask(question: String, runID: String) async -> String? {
        guard interactive else { return nil }
        let q = PendingQuestion(id: UUID().uuidString, runID: runID, question: question)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if Task.isCancelled { c.resume(returning: nil); return }
                questions[q.id] = (q, c); publish()
            }
        } onCancel: { Task { await self.answer(questionID: q.id, nil) } }
    }

    public func review(plan: AgentPlan, runID: String) async -> PlanReview {
        guard interactive else { return .approved }
        let p = PendingPlan(id: UUID().uuidString, runID: runID, plan: plan)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if Task.isCancelled { c.resume(returning: .rejected); return }
                plans[p.id] = (p, c); publish()
            }
        } onCancel: { Task { await self.review(planID: p.id, .rejected) } }
    }

    public func answer(questionID: String, _ text: String?) {
        questions.removeValue(forKey: questionID)?.1.resume(returning: text); publish()
    }

    public func review(planID: String, _ decision: PlanReview) {
        plans.removeValue(forKey: planID)?.1.resume(returning: decision); publish()
    }

    public func pending() -> [Item] { questions.values.map { .question($0.0) } + plans.values.map { .plan($0.0) } }

    public func cancelAll() {
        for (_, c) in questions.values { c.resume(returning: nil) }
        for (_, c) in plans.values { c.resume(returning: .rejected) }
        questions = [:]; plans = [:]; publish()
    }

    private func publish() { let p = pending(); for o in observers.values { o.yield(p) } }

    public nonisolated func updates() -> AsyncStream<[Item]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.add(id, continuation) }
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }
    private func add(_ id: UUID, _ c: AsyncStream<[Item]>.Continuation) { observers[id] = c; c.yield(pending()) }
    private func remove(_ id: UUID) { observers[id] = nil }
}
