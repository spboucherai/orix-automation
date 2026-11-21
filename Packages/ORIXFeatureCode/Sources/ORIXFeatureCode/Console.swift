// ORIX OS Automation
// File: Packages/ORIXFeatureCode/Sources/ORIXFeatureCode/Console.swift
// Description: The console pane shared by the code and script tabs: a bounded scrollback (last 20 000 lines) with ANSI colour rendering, search, copy, clear and an auto-scroll toggle.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

public enum ConsoleStream: String, Sendable { case stdout, stderr, status, info }

public struct ConsoleSpan: Hashable, Sendable {
    public var text: String
    /// ANSI colour index 0–15, or nil for the default colour.
    public var color: Int?
    public var bold: Bool
}

public struct ConsoleLine: Identifiable, Hashable, Sendable {
    public var id: Int
    public var stream: ConsoleStream
    public var spans: [ConsoleSpan]
    public var text: String { spans.map(\.text).joined() }
}

/// Turns a stream of text chunks into lines of styled spans. Colour (SGR) sequences are rendered; every other escape
/// sequence is removed. State survives chunk boundaries, including an escape sequence cut in half.
public struct ANSIParser: Sendable {
    private var color: Int?
    private var bold = false
    private var spans: [ConsoleSpan] = []
    private var current = ""
    private var carry = ""

    public init() {}

    private mutating func flushSpan() {
        if !current.isEmpty { spans.append(ConsoleSpan(text: current, color: color, bold: bold)); current = "" }
    }

    private mutating func applySGR(_ parameters: String) {
        flushSpan()
        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        if codes.isEmpty { color = nil; bold = false }
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: color = nil; bold = false
            case 1: bold = true
            case 22: bold = false
            case 30...37: color = c - 30
            case 90...97: color = c - 90 + 8
            case 39: color = nil
            case 38, 48:
                // Extended colour: 38;5;n or 38;2;r;g;b. The 16 base colours are kept, the rest falls back to default.
                if codes[safe: i + 1] == 5 {
                    if c == 38, let n = codes[safe: i + 2] { color = n < 16 ? n : nil }
                    i += 2
                } else if codes[safe: i + 1] == 2 {
                    if c == 38 { color = nil }
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    /// Feeds a chunk and returns the lines it completed.
    public mutating func feed(_ chunk: String) -> [[ConsoleSpan]] {
        var out: [[ConsoleSpan]] = []
        let scalars = Array((carry + chunk).unicodeScalars)
        carry = ""
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            switch s.value {
            case 0x1B:
                guard i + 1 < scalars.count else { carry = String(String.UnicodeScalarView(scalars[i...])); i = scalars.count; continue }
                let next = scalars[i + 1]
                if next == "[" {
                    var j = i + 2
                    while j < scalars.count, !(scalars[j].value >= 0x40 && scalars[j].value <= 0x7E) { j += 1 }
                    guard j < scalars.count else { carry = String(String.UnicodeScalarView(scalars[i...])); i = scalars.count; continue }
                    if scalars[j] == "m" { applySGR(String(String.UnicodeScalarView(scalars[(i + 2)..<j]))) }
                    i = j + 1
                } else if next == "]" {
                    var j = i + 2
                    var closed = false
                    while j < scalars.count {
                        if scalars[j].value == 0x07 { closed = true; j += 1; break }
                        if scalars[j].value == 0x1B, j + 1 < scalars.count, scalars[j + 1] == "\\" { closed = true; j += 2; break }
                        j += 1
                    }
                    guard closed else { carry = String(String.UnicodeScalarView(scalars[i...])); i = scalars.count; continue }
                    i = j
                } else {
                    i += 2
                }
            case 0x0A:
                flushSpan(); out.append(spans); spans = []
                i += 1
            case 0x0D:
                if i + 1 < scalars.count, scalars[i + 1].value == 0x0A { i += 1; continue }
                if i + 1 == scalars.count { carry = "\r"; i += 1; continue }
                current = ""; spans = []   // carriage return: the line is rewritten
                i += 1
            case 0x09: current.unicodeScalars.append(s); i += 1
            case 0..<0x20, 0x7F: i += 1
            default: current.unicodeScalars.append(s); i += 1
            }
        }
        return out
    }

    /// Returns the unfinished line, if any, and resets it.
    public mutating func finish() -> [ConsoleSpan]? {
        carry = ""
        flushSpan()
        defer { spans = [] }
        return spans.isEmpty ? nil : spans
    }
}

@MainActor
@Observable
public final class ConsoleBuffer {
    public static let capacity = 20_000
    public private(set) var lines: [ConsoleLine] = []
    /// Lines removed from the front because the scrollback is full.
    public private(set) var dropped = 0
    @ObservationIgnored private var parsers: [ConsoleStream: ANSIParser] = [:]
    @ObservationIgnored private var nextID = 0
    public let capacity: Int

    public init(capacity: Int = ConsoleBuffer.capacity) { self.capacity = capacity }

    private func push(_ spans: [ConsoleSpan], _ stream: ConsoleStream, into batch: inout [ConsoleLine]) {
        batch.append(ConsoleLine(id: nextID, stream: stream, spans: spans))
        nextID += 1
    }

    /// Appends output. Text without a final newline is held until the rest of the line arrives or `flush` is called.
    public func append(_ text: String, stream: ConsoleStream = .stdout) {
        var parser = parsers[stream] ?? ANSIParser()
        var batch: [ConsoleLine] = []
        for spans in parser.feed(text) { push(spans, stream, into: &batch) }
        parsers[stream] = parser
        commit(batch)
    }

    /// Appends whole lines (a message from the studio itself).
    public func note(_ text: String, stream: ConsoleStream = .info) {
        flush()
        append(text.hasSuffix("\n") ? text : text + "\n", stream: stream)
    }

    /// Ends every unfinished line.
    public func flush() {
        var batch: [ConsoleLine] = []
        for stream in [ConsoleStream.stdout, .stderr, .status, .info] {
            guard var parser = parsers[stream] else { continue }
            if let spans = parser.finish() { push(spans, stream, into: &batch) }
            parsers[stream] = parser
        }
        commit(batch)
    }

    private func commit(_ batch: [ConsoleLine]) {
        guard !batch.isEmpty else { return }
        var all = lines
        all.append(contentsOf: batch)
        if all.count > capacity {
            let extra = all.count - capacity
            all.removeFirst(extra)
            dropped += extra
        }
        lines = all
    }

    public func clear() { lines = []; dropped = 0; parsers = [:] }

    public var plainText: String { lines.map(\.text).joined(separator: "\n") }
}

public struct ConsoleView: View {
    let buffer: ConsoleBuffer
    var showsPolicyNote: Bool
    @State private var query = ""
    @State private var autoScroll = true

    public init(buffer: ConsoleBuffer, showsPolicyNote: Bool = true) { self.buffer = buffer; self.showsPolicyNote = showsPolicyNote }

    static func ansiColor(_ index: Int) -> Color {
        switch index % 8 {
        case 0: return Theme.textTertiary
        case 1: return Theme.danger
        case 2: return Theme.success
        case 3: return Theme.warning
        case 4, 6: return Theme.blue
        case 5: return Theme.violet
        default: return Theme.text
        }
    }

    private func rendered(_ line: ConsoleLine) -> Text {
        let base: Color = line.stream == .stderr ? Theme.danger : (line.stream == .status ? Theme.violet : (line.stream == .info ? Theme.textSecondary : Theme.text))
        var out = AttributedString()
        for span in line.spans {
            var part = AttributedString(span.text)
            part.foregroundColor = span.color.map(Self.ansiColor) ?? base
            if span.bold { part.font = Theme.Font.mono.bold() }
            out.append(part)
        }
        return Text(out)
    }

    private func tag(_ stream: ConsoleStream) -> String {
        switch stream {
        case .stdout: return "out"
        case .stderr: return "err"
        case .status: return "run"
        case .info: return "···"
        }
    }

    public var body: some View {
        let shown = query.isEmpty ? buffer.lines : buffer.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                if showsPolicyNote {
                    Label("Runs through ORIX policy (sandboxed)", systemImage: "lock.shield")
                        .font(Theme.Font.captionStrong).foregroundStyle(Theme.violet).lineLimit(1)
                        .accessibilityIdentifier("code.console.policy")
                }
                Spacer(minLength: Theme.Space.s)
                if !query.isEmpty {
                    Text("\(shown.count) matching lines").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    TextField(String(localized: "Search output"), text: $query).textFieldStyle(.plain).font(Theme.Font.caption)
                        .accessibilityIdentifier("code.console.search")
                }
                .padding(.horizontal, 7).padding(.vertical, 3).frame(width: 170)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                Toggle(isOn: $autoScroll) { Image(systemName: "arrow.down.to.line") }
                    .toggleStyle(.button).controlSize(.small).help(Text("Follow new output"))
                    .accessibilityLabel(Text("Follow new output")).accessibilityIdentifier("code.console.autoscroll")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.map(\.text).joined(separator: "\n"), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .controlSize(.small).disabled(shown.isEmpty).help(Text("Copy the output"))
                    .accessibilityLabel(Text("Copy the output")).accessibilityIdentifier("code.console.copy")
                Button { buffer.clear() } label: { Image(systemName: "trash") }
                    .controlSize(.small).disabled(buffer.lines.isEmpty).help(Text("Clear the console"))
                    .accessibilityLabel(Text("Clear the console")).accessibilityIdentifier("code.console.clear")
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if buffer.dropped > 0 {
                            Text("Only the last \(buffer.capacity) lines are kept: \(buffer.dropped) earlier lines were dropped.")
                                .font(Theme.Font.caption).foregroundStyle(Theme.warning).padding(.bottom, 4)
                        }
                        ForEach(shown) { line in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Text(verbatim: tag(line.stream)).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).frame(width: 24, alignment: .leading)
                                    .accessibilityHidden(true)
                                rendered(line).font(Theme.Font.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                }
                .onChange(of: buffer.lines.last?.id) { _, _ in if autoScroll { proxy.scrollTo("tail", anchor: .bottom) } }
                .onAppear { if autoScroll { proxy.scrollTo("tail", anchor: .bottom) } }
            }
            .overlay {
                if shown.isEmpty {
                    Text(query.isEmpty ? "Nothing has been printed yet." : "No line matches the search.")
                        .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .background(Theme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Console"))
    }
}
