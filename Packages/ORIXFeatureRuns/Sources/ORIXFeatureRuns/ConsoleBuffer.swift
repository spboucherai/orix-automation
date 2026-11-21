// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/ConsoleBuffer.swift
// Description: The console's bounded line store (keeps the newest lines, counts what it dropped), its text search, and the translation of run events and live updates into log lines.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXAppUI

public struct ConsoleLine: Identifiable, Sendable, Hashable {
    public enum Level: String, CaseIterable, Sendable, Identifiable {
        case status, user, agent, reasoning, tool, stdout, stderr, approval, verification, usage, error, info
        public var id: String { rawValue }

        /// Fixed-width tag printed on every line, so a stream is recognisable without colour.
        public var tag: String {
            switch self {
            case .status: return "STATUS"
            case .user: return "USER"
            case .agent: return "AGENT"
            case .reasoning: return "THINK"
            case .tool: return "TOOL"
            case .stdout: return "OUT"
            case .stderr: return "ERR"
            case .approval: return "ASK"
            case .verification: return "VERIFY"
            case .usage: return "USAGE"
            case .error: return "ERROR"
            case .info: return "INFO"
            }
        }
    }

    public let id: Int
    public let time: Date
    public let level: Level
    public let text: String
}

/// Keeps the newest `capacity` lines. Older ones are dropped and counted, never silently.
public struct ConsoleBuffer: Sendable {
    public static let defaultCapacity = 20_000
    /// Longest line kept; the rest is cut and marked.
    public static let maxLineLength = 4000

    public let capacity: Int
    public private(set) var lines: [ConsoleLine] = []
    public private(set) var dropped = 0
    private var nextID = 0

    public init(capacity: Int = ConsoleBuffer.defaultCapacity) { self.capacity = max(1, capacity) }

    /// Appends text as one line per newline. Empty text adds nothing.
    public mutating func append(_ text: String, level: ConsoleLine.Level, time: Date = Date()) {
        guard !text.isEmpty else { return }
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var piece = String(raw)
            if piece.count > Self.maxLineLength { piece = String(piece.prefix(Self.maxLineLength)) + " … [line cut]" }
            let line = ConsoleLine(id: nextID, time: time, level: level, text: piece)
            nextID += 1
            if let last = lines.last, last.time > time {
                // A recorded event that arrives after newer live output goes where its time says (after equal times).
                var lo = 0, hi = lines.count
                while lo < hi { let mid = (lo + hi) / 2; if lines[mid].time <= time { lo = mid + 1 } else { hi = mid } }
                lines.insert(line, at: lo)
            } else { lines.append(line) }
        }
        trim()
    }

    public mutating func append(contentsOf entries: [(text: String, level: ConsoleLine.Level, time: Date)]) {
        for e in entries { append(e.text, level: e.level, time: e.time) }
    }

    private mutating func trim() {
        let extra = lines.count - capacity
        guard extra > 0 else { return }
        lines.removeFirst(extra)
        dropped += extra
    }

    /// Empties the view. Dropped-line count restarts; line ids keep increasing.
    public mutating func clear() { lines.removeAll(keepingCapacity: true); dropped = 0 }

    public func visible(levels: Set<ConsoleLine.Level>) -> [ConsoleLine] {
        levels.count == ConsoleLine.Level.allCases.count ? lines : lines.filter { levels.contains($0.level) }
    }

    /// Ids of the lines containing `query` (case- and accent-insensitive), oldest first, among the given levels.
    public func search(_ query: String, levels: Set<ConsoleLine.Level> = Set(ConsoleLine.Level.allCases)) -> [Int] {
        guard let matcher = Matcher(query) else { return [] }
        return lines.compactMap { levels.contains($0.level) && matcher.matches($0.text) ? $0.id : nil }
    }

    /// Case- and accent-insensitive "contains". Plain ASCII, the common case in logs, is compared byte by byte;
    /// anything else goes through Foundation's comparison.
    public struct Matcher: Sendable {
        let query: String
        let ascii: [UInt8]?

        public init?(_ query: String) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return nil }
            self.query = q
            ascii = q.utf8.allSatisfy { $0 < 128 } ? q.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 } : nil
        }

        public func matches(_ text: String) -> Bool {
            guard let ascii else { return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            var sawNonASCII = false
            var text = text
            let hit = text.withUTF8 { bytes -> Bool in
                let n = bytes.count, m = ascii.count
                guard n >= m else { sawNonASCII = bytes.contains { $0 >= 128 }; return false }
                let first = ascii[0]
                var i = 0
                while i <= n - m {
                    let b = bytes[i]
                    if b >= 128 { sawNonASCII = true }
                    if (b >= 65 && b <= 90 ? b + 32 : b) == first {
                        var j = 1
                        while j < m, { let c = bytes[i + j]; return (c >= 65 && c <= 90 ? c + 32 : c) == ascii[j] }() { j += 1 }
                        if j == m { return true }
                    }
                    i += 1
                }
                if !sawNonASCII { sawNonASCII = bytes[max(0, n - m)...].contains { $0 >= 128 } }
                return false
            }
            if hit { return true }
            // "resume" must still find "résumé".
            return sawNonASCII && text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public static func render(_ line: ConsoleLine) -> String { "\(timestamp(line.time))  \(line.level.tag.padding(toLength: 6, withPad: " ", startingAt: 0))  \(line.text)" }

    public static func timestamp(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        var seconds = time_t(t)
        var tmv = tm()
        localtime_r(&seconds, &tmv)
        return String(format: "%02d:%02d:%02d.%03d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, Int((t - t.rounded(.down)) * 1000))
    }
}

/// Turns persisted events and live updates into console lines, without showing the same thing twice.
/// Streaming fragments are joined into whole lines; an unfinished line is released by `flushPartials`.
public struct ConsoleAssembler: Sendable {
    public typealias Entry = (text: String, level: ConsoleLine.Level, time: Date)

    private var partial: [String: (text: String, level: ConsoleLine.Level)] = [:]
    private var partialOrder: [String] = []
    private var streamedAgentText = false
    private var streamedReasoning = false
    private var liveStarted = Set<String>()
    private var liveFinished = Set<String>()
    private var persistedStarted = Set<String>()
    private var persistedFinished = Set<String>()
    private var lastStatus: String?
    private var lastUsage: String?

    public init() {}

    // MARK: Persisted events

    public mutating func lines(for event: RunEvent) -> [Entry] {
        let t = event.timestamp
        let step = event.stepID.map { "[\($0)] " } ?? ""
        switch event.kind {
        case .statusChanged:
            let status = event.data["to"]?.stringValue ?? event.data["status"]?.stringValue ?? event.text
            guard status != lastStatus else { return [] }
            lastStatus = status
            return [(event.text, .status, t)]
        case .userMessage: return [(event.text, .user, t)]
        case .assistantText:
            if streamedAgentText { streamedAgentText = false; return flushPartials(keys: ["text"], time: t) }
            return [(event.text, .agent, t)]
        case .reasoningSummary:
            if streamedReasoning { streamedReasoning = false; return flushPartials(keys: ["reasoning"], time: t) }
            return [(event.text, .reasoning, t)]
        case .planUpdated: return [("Plan\n" + event.text, .info, t)]
        case .toolRequested:
            let callID = event.data["callID"]?.stringValue ?? event.id
            persistedStarted.insert(callID)
            guard !liveStarted.contains(callID) else { return [] }
            return [(Self.started(toolID: event.data["toolID"]?.stringValue ?? event.text, arguments: event.data["arguments"] ?? .null), .tool, t)]
        case .toolProgress:
            return [(event.text, event.data["stream"]?.stringValue == "stderr" ? .stderr : .stdout, t)]
        case .toolFinished:
            let callID = event.data["callID"]?.stringValue ?? event.id
            persistedFinished.insert(callID)
            guard !liveFinished.contains(callID) else { return [] }
            let status = event.data["status"]?.stringValue ?? ""
            return [(Self.finished(toolID: event.data["toolID"]?.stringValue ?? "?", status: status, durationMs: event.data["durationMs"]?.intValue, summary: event.text),
                     Self.isFailure(status) ? .error : .tool, t)]
        case .approvalRequested: return [(step + "Approval requested: " + event.text, .approval, t)]
        case .approvalResolved: return [(step + "Approval answered: " + event.text, .approval, t)]
        case .stepStarted, .stepFinished: return [(step + event.text, .info, t)]
        case .verification: return [(step + event.text, .verification, t)]
        case .usage:
            let text = event.text.isEmpty ? Self.usageText(event.data) : step + event.text
            guard let text, text != lastUsage else { return [] }
            lastUsage = text
            return [(text, .usage, t)]
        case .retry, .checkpoint, .memory, .log: return [(step + event.text, .info, t)]
        case .error: return [(step + event.text, .error, t)]
        case .receipt: return [("Execution receipt recorded", .info, t)]
        }
    }

    // MARK: Live updates

    public mutating func lines(for update: LiveUpdate, time: Date = Date()) -> [Entry] {
        switch update {
        case .text(let delta):
            streamedAgentText = true
            return feed("text", delta, level: .agent, time: time)
        case .reasoning(let delta):
            streamedReasoning = true
            return feed("reasoning", delta, level: .reasoning, time: time)
        case .toolStarted(let call):
            liveStarted.insert(call.id)
            var out = flushPartials(time: time)
            if !persistedStarted.contains(call.id) {
                out.append((Self.started(toolID: call.toolID, arguments: Redactor.shared.redact(call.arguments)), .tool, time))
            }
            return out
        case .toolProgress(let callID, let progress):
            switch progress.stream {
            case .stdout: return feed("out:" + callID, progress.text, level: .stdout, time: time)
            case .stderr: return feed("err:" + callID, progress.text, level: .stderr, time: time)
            case .status: return [(progress.text, .info, time)]
            }
        case .toolFinished(let call, let result):
            liveFinished.insert(call.id)
            var out = flushPartials(keys: ["out:" + call.id, "err:" + call.id], time: time)
            if !persistedFinished.contains(call.id) {
                out.append((Self.finished(toolID: call.toolID, status: result.status.rawValue, durationMs: result.durationMs, summary: result.summary),
                            Self.isFailure(result.status.rawValue) ? .error : .tool, time))
            }
            return out
        case .plan: return []   // the persisted planUpdated event carries the same plan
        case .status(let s), .finished(let s):
            var out = flushPartials(time: time)
            if s.rawValue != lastStatus { lastStatus = s.rawValue; out.append((s.rawValue, .status, time)) }
            return out
        case .usage(let u):
            let text = Self.usageText(turns: u.turns, toolCalls: u.toolCalls, tokens: u.tokens.totalTokens, cost: u.costUSD, complete: u.costIsComplete)
            guard text != lastUsage else { return [] }
            lastUsage = text
            return [(text, .usage, time)]
        case .stepStatus(let stepID, let status):
            return [("[\(stepID)] \(status)", .info, time)]
        }
    }

    /// Releases unfinished lines (all of them, or those of the given streams).
    public mutating func flushPartials(keys: [String]? = nil, time: Date = Date()) -> [Entry] {
        var out: [Entry] = []
        for key in keys ?? partialOrder {
            if let p = partial.removeValue(forKey: key), !p.text.isEmpty { out.append((p.text, p.level, time)) }
        }
        partialOrder.removeAll { partial[$0] == nil }
        return out
    }

    public var hasPartials: Bool { !partial.isEmpty }

    private mutating func feed(_ key: String, _ chunk: String, level: ConsoleLine.Level, time: Date) -> [Entry] {
        var text = (partial[key]?.text ?? "") + chunk
        var out: [Entry] = []
        while let nl = text.firstIndex(where: \.isNewline) {
            out.append((String(text[..<nl]).isEmpty ? " " : String(text[..<nl]), level, time))
            text = String(text[text.index(after: nl)...])
        }
        if text.isEmpty { partial[key] = nil; partialOrder.removeAll { $0 == key } }
        else {
            if partial[key] == nil { partialOrder.append(key) }
            partial[key] = (text, level)
        }
        return out
    }

    static func isFailure(_ status: String) -> Bool { !["succeeded", "simulated", ""].contains(status) }

    static func started(toolID: String, arguments: JSONValue) -> String {
        let args = arguments.isNull ? "" : " " + String(arguments.serialized().prefix(600))
        return "▶ \(toolID)\(args)"
    }

    static func finished(toolID: String, status: String, durationMs: Int?, summary: String) -> String {
        let d = durationMs.map { " in \(Format.duration(Double($0) / 1000))" } ?? ""
        return "■ \(toolID) \(status.isEmpty ? "finished" : status)\(d)" + (summary.isEmpty ? "" : " — \(summary)")
    }

    static func usageText(_ data: JSONValue) -> String? {
        guard let usage = try? JSONDecoder().decode(RunUsage.self, from: Data(data.serialized().utf8)) else { return nil }
        return usageText(turns: usage.turns, toolCalls: usage.toolCalls, tokens: usage.tokens.totalTokens, cost: usage.costUSD, complete: usage.costIsComplete)
    }

    static func usageText(turns: Int, toolCalls: Int, tokens: Int, cost: Double, complete: Bool) -> String {
        "turns \(turns) · tool calls \(toolCalls) · tokens \(tokens) · cost \(Format.cost(cost, complete: complete))"
    }
}
