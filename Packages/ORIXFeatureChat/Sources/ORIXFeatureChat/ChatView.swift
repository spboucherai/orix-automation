// ORIX OS Automation
// File: Packages/ORIXFeatureChat/Sources/ORIXFeatureChat/ChatView.swift
// Description: The Agent section: session list, streaming transcript with tool activity, plan, approvals and verified outcome, execution side panel, and the composer.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

public struct AgentChatView: View {
    @Environment(AppModel.self) private var app
    @State private var chat: ChatModel?

    public init() {}

    public var body: some View {
        Group {
            if let chat { ChatContent(chat: chat) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task {
            if chat == nil { let c = ChatModel(app: app); chat = c; await c.load() }
        }
        .task(id: app.revision) { await chat?.load() }
    }
}

struct ChatContent: View {
    @Environment(AppModel.self) private var app
    @Bindable var chat: ChatModel
    @State private var showSessions = true
    @State private var showExecution = true

    var body: some View {
        HStack(spacing: 0) {
            if showSessions { SessionList(chat: chat).frame(width: 230).transition(.move(edge: .leading)) ; Divider() }
            VStack(spacing: 0) {
                header
                Divider()
                Transcript(chat: chat)
                Divider()
                Composer(chat: chat)
            }
            .frame(minWidth: 420, maxWidth: .infinity)
            if showExecution, chat.isRunning || chat.currentPlan != nil || chat.liveUsage != nil {
                Divider()
                ExecutionPanel(chat: chat).frame(width: 270)
            }
        }
        .background(Theme.canvas)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            Button { withAnimation(Theme.spring(false)) { showSessions.toggle() } } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(.borderless).accessibilityLabel(Text("Show or hide conversations")).help(Text("Show or hide conversations"))
            Text(chat.current?.session.title ?? String(localized: "New conversation")).font(Theme.Font.heading).lineLimit(1)
            if let s = chat.activeStatus, chat.isRunning { StatusBadge(s) }
            Spacer()
            if chat.isRunning {
                Button { Task { await chat.togglePause() } } label: { Label(chat.isPaused ? "Resume" : "Pause", systemImage: chat.isPaused ? "play.fill" : "pause.fill") }
                    .buttonStyle(SecondaryButtonStyle()).help(Text("Pause before the next action that changes something"))
                    .accessibilityIdentifier("chat.pause")
                Button { chat.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.danger)).keyboardShortcut(".", modifiers: .command)
                    .accessibilityIdentifier("chat.stop")
            }
            Button { withAnimation(Theme.spring(false)) { showExecution.toggle() } } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless).accessibilityLabel(Text("Show or hide the execution panel")).help(Text("Show or hide the execution panel"))
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s + 2)
        .background(Theme.surface)
    }
}

struct SessionList: View {
    @Bindable var chat: ChatModel
    @State private var pendingDelete: ChatSessionRecord?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversations").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { Task { await chat.newSession() } } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless).disabled(chat.isRunning).keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel(Text("New conversation")).accessibilityIdentifier("chat.new")
            }
            .padding(Theme.Space.m)
            if chat.sessions.isEmpty {
                Text("Conversations you start appear here.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else {
                List(selection: Binding(get: { chat.currentID }, set: { id in Task { await chat.select(id) } })) {
                    ForEach(chat.sessions) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.session.title).font(Theme.Font.body).lineLimit(1)
                            Text(Format.relative(s.session.updatedAt) + " · " + String(localized: "\(s.runIDs.count) runs")).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        }
                        .tag(s.id as String?)
                        .contextMenu { Button("Delete conversation…", role: .destructive) { pendingDelete = s } }
                    }
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
            }
        }
        .background(Theme.surface)
        .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { s in
            Button("Delete", role: .destructive) { Task { await chat.delete(s.id) } }
        } message: { _ in Text("The conversation and its context are removed. Its runs stay in Runs.") }
    }
}

struct Transcript: View {
    @Environment(AppModel.self) private var app
    @Bindable var chat: ChatModel

    var body: some View {
        if chat.items.isEmpty && !chat.isRunning {
            EmptyState(symbol: "sparkles", title: "Say what you want done",
                       message: "The agent plans, asks before anything that matters, acts through tools on this Mac, and checks the result. Choose the folder it may work in below.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(chat.items) { item in ChatItemView(item: item, chat: chat).id(item.id) }
                        if !chat.streamingReasoning.isEmpty {
                            Label { Text(chat.streamingReasoning).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) } icon: { Image(systemName: "brain") }
                        }
                        if !chat.streamingText.isEmpty { AssistantBubble(text: chat.streamingText, streaming: true) }
                        if let id = chat.activeRunID { AttentionStack(runID: id) }
                        if chat.isRunning && chat.streamingText.isEmpty {
                            HStack(spacing: 6) { PulseDot(color: Theme.blue, active: true); Text(statusLine).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .padding(Theme.Space.l)
                    .frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
                }
                .onChange(of: chat.items.count) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
                .onChange(of: chat.streamingText.count / 80) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
                .onChange(of: app.pendingApprovals.count) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    private var statusLine: String {
        switch chat.activeStatus {
        case .waitingApproval: return String(localized: "Waiting for you")
        case .paused: return String(localized: "Paused before the next change")
        case .recovering: return String(localized: "Retrying after a provider error")
        default: return String(localized: "Working")
        }
    }
}

struct AssistantBubble: View {
    let text: String
    var streaming = false
    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accentGradient).frame(width: 22, height: 22)
                .background(Theme.accentSoft, in: Circle())
            Text(Self.markdown(text)).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled).lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine).accessibilityLabel(Text("Agent")).accessibilityValue(Text(text))
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct ChatItemView: View {
    @Environment(AppModel.self) private var app
    let item: ChatItem
    let chat: ChatModel

    var body: some View {
        switch item {
        case .user(_, let text, _):
            HStack {
                Spacer(minLength: 60)
                Text(text).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled)
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            }
            .accessibilityElement(children: .combine).accessibilityLabel(Text("You"))
        case .assistant(_, let text, _): AssistantBubble(text: text)
        case .reasoning(_, let text):
            DisclosureGroup { Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                label: { Label("Reasoning summary from the provider", systemImage: "brain").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
        case .plan(_, let plan): PlanCard(plan: plan)
        case .tool(let t): ToolRow(tool: t)
        case .notice(_, let kind, let text):
            Label { Text(text).font(Theme.Font.caption).foregroundStyle(kind == .error ? Theme.danger : Theme.textSecondary).textSelection(.enabled) }
                icon: { Image(systemName: kind.symbol).foregroundStyle(kind.tint) }
        case .verification(_, let passed, let text):
            Label { Text(text).font(Theme.Font.caption).foregroundStyle(Theme.text).textSelection(.enabled) }
                icon: { Image(systemName: passed ? "checkmark.seal.fill" : "xmark.seal.fill").foregroundStyle(passed ? Theme.success : Theme.danger) }
                .accessibilityLabel(Text(passed ? "Check passed" : "Check failed")).accessibilityValue(Text(text))
        case .outcome(let o): OutcomeCard(outcome: o, chat: chat)
        }
    }
}

struct PlanCard: View {
    let plan: AgentPlan
    var body: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Plan", systemImage: "list.bullet.clipboard").font(Theme.Font.captionStrong).foregroundStyle(Theme.violet)
                ForEach(plan.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol(step.status)).font(.system(size: 11)).foregroundStyle(color(step.status)).frame(width: 14)
                        Text(step.title).font(Theme.Font.body).foregroundStyle(step.status == .done ? Theme.textSecondary : Theme.text)
                            .strikethrough(step.status == .skipped)
                    }
                    .accessibilityElement(children: .combine).accessibilityValue(Text(step.status.rawValue))
                }
            }
        }
    }
    func symbol(_ s: PlanStep.Status) -> String {
        switch s { case .pending: return "circle"; case .inProgress: return "circle.lefthalf.filled"; case .done: return "checkmark.circle.fill"; case .failed: return "xmark.circle.fill"; case .skipped: return "minus.circle" }
    }
    func color(_ s: PlanStep.Status) -> Color {
        switch s { case .pending: return Theme.textTertiary; case .inProgress: return Theme.blue; case .done: return Theme.success; case .failed: return Theme.danger; case .skipped: return Theme.textTertiary }
    }
}

struct ToolRow: View {
    let tool: ToolActivity
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(Theme.spring(false)) { expanded.toggle() } } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary).frame(width: 10)
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Text(tool.toolID).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                    if let s = tool.status { StatusBadge(tool: s, compact: s == .succeeded) } else { PulseDot(color: Theme.blue, active: true) }
                    Text(tool.summary).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let ms = tool.durationMs { Text(Format.duration(Double(ms) / 1000)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Tool \(tool.toolID)")).accessibilityValue(Text(tool.summary))
            if expanded || (tool.status == nil && !tool.liveOutput.isEmpty) {
                VStack(alignment: .leading, spacing: 4) {
                    if expanded, let t = tool.tier { TierBadge(tier: t) }
                    if expanded, !tool.arguments.isNull {
                        Text(tool.arguments.serialized(pretty: true)).font(Theme.Font.monoSmall).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    if !tool.liveOutput.isEmpty { Text(tool.liveOutput).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(12) }
                }
                .padding(Theme.Space.s).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                .padding(.leading, 20)
            }
        }
    }
}

struct OutcomeCard: View {
    @Environment(AppModel.self) private var app
    let outcome: RunOutcomeSummary
    let chat: ChatModel

    var body: some View {
        Card(padding: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    StatusBadge(outcome.status)
                    Text(Format.duration(outcome.duration)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    Text("\(outcome.usage.toolCalls) tool calls").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    Text(Format.tokens(outcome.usage.tokens.totalTokens) + " " + String(localized: "tokens")).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    Text(Format.cost(outcome.usage.costUSD, complete: outcome.usage.costIsComplete)).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if outcome.status != .succeeded {
                        Button { Task { await chat.retryLast() } } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(.borderless)
                            .disabled(chat.isRunning).accessibilityIdentifier("chat.retry")
                    }
                    Button { app.open(.run(outcome.runID)) } label: { Label("Receipt", systemImage: "doc.text") }.buttonStyle(.borderless)
                        .help(Text("Open the full execution receipt in Runs"))
                }
                ForEach(outcome.artifacts) { a in
                    HStack(spacing: 6) {
                        Image(systemName: "doc").foregroundStyle(Theme.textSecondary)
                        Text(PathResolver.display(a.path)).font(Theme.Font.monoSmall).lineLimit(1).truncationMode(.middle)
                        Text(Format.bytes(a.bytes)).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) } label: { Text("Reveal") }
                            .buttonStyle(.borderless).disabled(!FileManager.default.fileExists(atPath: a.path))
                    }
                }
                ForEach(outcome.errors, id: \.self) { e in Label(e, systemImage: "exclamationmark.triangle.fill").font(Theme.Font.caption).foregroundStyle(Theme.danger).textSelection(.enabled) }
                ForEach(outcome.limitations.prefix(4), id: \.self) { l in Label(l, systemImage: "info.circle").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
            }
        }
    }
}

struct ExecutionPanel: View {
    @Bindable var chat: ChatModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SectionHeader("Execution")
                if let u = chat.liveUsage {
                    VStack(alignment: .leading, spacing: 6) {
                        KeyValueRow(key: "Turns", value: "\(u.turns)")
                        KeyValueRow(key: "Tool calls", value: "\(u.toolCalls)")
                        KeyValueRow(key: "Tokens", value: Format.tokens(u.tokens.totalTokens))
                        KeyValueRow(key: "Cost", value: Format.cost(u.costUSD, complete: u.costIsComplete))
                    }
                }
                if let plan = chat.currentPlan { PlanCard(plan: plan) }
                if chat.liveUsage == nil && chat.currentPlan == nil {
                    Text("Plan and usage appear here while the agent works.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.surface)
    }
}

struct Composer: View {
    @Environment(AppModel.self) private var app
    @Bindable var chat: ChatModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField(chat.isRunning ? String(localized: "Add an instruction for the agent…") : String(localized: "Describe what you want done…"), text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.Font.body).lineLimit(1...8).focused($focused)
                .onSubmit { Task { await chat.send() } }
                .padding(Theme.Space.m)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(focused ? Theme.violet.opacity(0.6) : Theme.stroke))
                .accessibilityIdentifier("chat.composer")
            HStack(spacing: Theme.Space.s) {
                modelMenu
                Picker("Mode", selection: $chat.mode) {
                    Text("Quick").tag(ExecutionMode.quick); Text("Guided").tag(ExecutionMode.guided)
                    Text("Autonomous").tag(ExecutionMode.autonomous); Text("Review (read-only)").tag(ExecutionMode.review)
                }
                .labelsHidden().fixedSize().disabled(chat.isRunning).help(Text(modeHelp)).accessibilityIdentifier("chat.mode")
                Picker("Agent", selection: $chat.agent) { ForEach(chat.agentNames, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().fixedSize().disabled(chat.isRunning).accessibilityIdentifier("chat.agent")
                workspaceMenu
                Spacer(minLength: 0)
                Button { Task { await chat.send() } } label: {
                    Label(chat.isRunning ? "Queue" : "Send", systemImage: chat.isRunning ? "text.badge.plus" : "arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(!chat.canSend).keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("chat.send")
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.surface)
        .onAppear { focused = true }
    }

    private var modeHelp: LocalizedStringKey {
        switch chat.mode {
        case .quick: return "Quick: one task, asks for anything not already allowed."
        case .guided: return "Guided: you review the plan before anything is changed."
        case .autonomous: return "Autonomous: acts inside what you already allowed; still asks beyond that."
        case .review: return "Review: read-only analysis; nothing is changed."
        case .scheduled: return "Scheduled"
        }
    }

    private var modelMenu: some View {
        let ref = chat.modelChoice ?? app.settings.defaultModel
        return HStack(spacing: 4) {
            if let ref { ProviderGlyph(provider: ref.provider, size: 16) } else { Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
            Menu(ref?.model ?? String(localized: "No model")) {
                Button { chat.modelChoice = nil } label: { Text("Default model from Settings") }
                ForEach(app.configuredProviders, id: \.self) { p in
                    Section(p.displayName) {
                        ForEach(chat.modelOptions.filter { $0.provider == p }) { m in
                            Button { chat.modelChoice = ModelRef(provider: p, model: m.id) } label: { Text(m.displayName) }
                        }
                    }
                }
                Divider()
                Button { app.open(.section(.settings)) } label: { Text("Providers and models…") }
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(chat.isRunning).accessibilityIdentifier("chat.model")
        }
    }

    private var workspaceMenu: some View {
        Menu {
            Button("Choose folder…") { chooseFolder() }
            Divider()
            Picker("Access", selection: $chat.access) {
                Text("Ask every time").tag(WorkspaceAccess.none)
                Text("May read this folder").tag(WorkspaceAccess.read)
                Text("May read and change this folder").tag(WorkspaceAccess.readWrite)
            }
            .pickerStyle(.inline)
        } label: {
            Label(Self.shortPath(chat.workspace), systemImage: chat.access == .readWrite ? "folder.badge.gearshape" : "folder")
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(chat.isRunning)
        .help(Text("The folder this run works in. What you choose here is the permission the agent starts with."))
        .accessibilityIdentifier("chat.workspace")
    }

    /// The last two components of a path, enough to recognise the folder in a narrow control.
    static func shortPath(_ path: String) -> String {
        let shown = PathResolver.display(path)
        let parts = shown.split(separator: "/")
        return parts.count <= 3 ? shown : "…/" + parts.suffix(2).joined(separator: "/")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = String(localized: "Use this folder")
        if panel.runModal() == .OK, let url = panel.url { chat.workspace = url.path }
    }
}
