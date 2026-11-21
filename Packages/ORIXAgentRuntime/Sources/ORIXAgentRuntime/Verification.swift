// ORIX OS Automation
// File: Packages/ORIXAgentRuntime/Sources/ORIXAgentRuntime/Verification.swift
// Description: Postcondition checks performed by the runtime against real state, and the rule that turns evidence (not model claims) into a run status.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import CryptoKit
import Foundation
import ORIXCore

public enum Verifier {
    /// Evaluates one declared expectation against the filesystem.
    public static func check(_ e: Expectation, workingDirectory: URL) -> VerificationResult {
        let fm = FileManager.default
        guard let path = try? PathResolver.canonical(e.path, relativeTo: workingDirectory) else {
            return .init(assertion: "\(e.kind) \(e.path)", kind: e.kind, passed: false, evidence: "path could not be resolved")
        }
        let shown = PathResolver.display(path)
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        switch e.kind {
        case "file_exists":
            return .init(assertion: "\(shown) exists", kind: e.kind, passed: exists, evidence: exists ? "found" : "not found")
        case "file_nonempty":
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let ok = exists && !isDir.boolValue && size > 0
            return .init(assertion: "\(shown) exists and is not empty", kind: e.kind, passed: ok, evidence: exists ? "\(size) bytes" : "not found")
        case "file_contains":
            let needle = e.text ?? ""
            guard exists, !isDir.boolValue, let data = fm.contents(atPath: path), data.count <= 20_000_000,
                  let text = String(data: data, encoding: .utf8) else {
                return .init(assertion: "\(shown) contains \"\(needle)\"", kind: e.kind, passed: false, evidence: exists ? "not readable as UTF-8 text under 20 MB" : "not found")
            }
            let ok = !needle.isEmpty && text.contains(needle)
            return .init(assertion: "\(shown) contains \"\(needle)\"", kind: e.kind, passed: ok, evidence: ok ? "text found" : "text not found")
        case "dir_nonempty":
            let count = (try? fm.contentsOfDirectory(atPath: path).filter { !$0.hasPrefix(".") }.count) ?? 0
            let ok = exists && isDir.boolValue && count > 0
            return .init(assertion: "\(shown) is a folder with at least one item", kind: e.kind, passed: ok, evidence: exists ? "\(count) items" : "not found")
        default:
            return .init(assertion: "\(e.kind) \(shown)", kind: e.kind, passed: false, evidence: "unknown expectation kind")
        }
    }

    /// Checks a file the agent claims to have produced. Only paths under `allowedRoots` are inspected, so a claim cannot be
    /// used to probe arbitrary locations.
    public static func checkClaimedArtifact(_ rawPath: String, workingDirectory: URL, allowedRoots: [String]) -> (VerificationResult, Artifact?) {
        guard let path = try? PathResolver.canonical(rawPath, relativeTo: workingDirectory) else {
            return (.init(assertion: "Claimed artifact \(rawPath) exists", kind: "file_nonempty", passed: false, evidence: "path could not be resolved"), nil)
        }
        let shown = PathResolver.display(path)
        guard allowedRoots.contains(where: { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else {
            return (.init(assertion: "Claimed artifact \(shown) exists", kind: "file_nonempty", passed: false,
                          evidence: "outside the folders this run worked in; not inspected"), nil)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return (.init(assertion: "Claimed artifact \(shown) exists", kind: "file_nonempty", passed: false, evidence: "not found"), nil)
        }
        if isDir.boolValue {
            let n = (try? FileManager.default.contentsOfDirectory(atPath: path).count) ?? 0
            return (.init(assertion: "Claimed artifact \(shown) exists", kind: "dir_nonempty", passed: n > 0, evidence: "folder, \(n) items"),
                    Artifact(path: path, kind: "folder", bytes: 0))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        var hash: String?
        if size <= 200_000_000, let data = FileManager.default.contents(atPath: path) {
            hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let v = VerificationResult(assertion: "Claimed artifact \(shown) exists and is not empty", kind: "file_nonempty", passed: size > 0,
                                   evidence: "\(size) bytes" + (hash.map { ", sha256 \($0.prefix(16))…" } ?? ""))
        return (v, Artifact(path: path, kind: "file", bytes: size, sha256: hash))
    }

    /// Status from evidence. `claimedDone` is the model saying it finished; it can never raise the status on its own.
    static func status(claimedDone: Bool, verifications: [VerificationResult], calls: [ToolCallRecord], mode: ExecutionMode) -> (RunStatus, [String]) {
        var notes: [String] = []
        // A failed call is unresolved when no later call of the same tool succeeded.
        var unresolved: [ToolCallRecord] = []
        for (i, c) in calls.enumerated() where !(c.status == .succeeded || c.status == .simulated) {
            let recovered = calls[(i + 1)...].contains { $0.toolID == c.toolID && ($0.status == .succeeded || $0.status == .simulated) }
            if !recovered { unresolved.append(c) }
        }
        let succeeded = calls.filter { $0.status == .succeeded || $0.status == .simulated }
        let failedChecks = verifications.filter { !$0.passed }
        let passedChecks = verifications.filter(\.passed)

        if !unresolved.isEmpty {
            notes.append("\(unresolved.count) tool call(s) failed and were not recovered: " + Set(unresolved.map(\.toolID)).sorted().joined(separator: ", "))
        }
        if !claimedDone { notes.append("The agent stopped without declaring the task complete.") }

        if !failedChecks.isEmpty {
            notes.append("\(failedChecks.count) of \(verifications.count) postcondition(s) failed.")
            return (passedChecks.isEmpty && succeeded.isEmpty ? .failed : (passedChecks.isEmpty ? .failed : .partiallySucceeded), notes)
        }
        if !unresolved.isEmpty {
            if succeeded.isEmpty && passedChecks.isEmpty {
                if unresolved.allSatisfy({ $0.status == .blockedPermission }) { return (.blockedPermission, notes) }
                if unresolved.allSatisfy({ $0.status == .notApproved }) {
                    return (mode == .scheduled ? .waitingApproval : .failed, notes)
                }
                return (.failed, notes)
            }
            return (.partiallySucceeded, notes)
        }
        if !claimedDone { return (succeeded.isEmpty && passedChecks.isEmpty ? .failed : .partiallySucceeded, notes) }
        if verifications.isEmpty {
            notes.append("No postcondition was declared, so success rests on tool results only.")
        }
        return (.succeeded, notes)
    }
}
