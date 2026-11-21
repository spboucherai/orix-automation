// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Sources/ORIXFeatureManage/ManageSupport.swift
// Description: Shared pieces of the management screens: the background-agent hook, the release-location constant, tab bars, setting rows, state pills, code blocks, file panels and error text.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: Hooks the app shell provides

/// How the app shell registers the background agent. The shell implements both closures with `SMAppService`;
/// Settings only stores the preference and calls them. Without a hook the toggle is disabled.
public struct BackgroundAgentControl: Sendable {
    /// One plain sentence describing the current registration state, for display.
    public var status: @MainActor @Sendable () -> String
    /// Registers or unregisters the agent. Throws with the reason when macOS refuses.
    public var setEnabled: @MainActor @Sendable (Bool) async throws -> Void

    public init(status: @escaping @MainActor @Sendable () -> String, setEnabled: @escaping @MainActor @Sendable (Bool) async throws -> Void) {
        self.status = status; self.setEnabled = setEnabled
    }
}

private struct BackgroundAgentControlKey: EnvironmentKey {
    static let defaultValue: BackgroundAgentControl? = nil
}

public extension EnvironmentValues {
    /// Set by the app shell: `.environment(\.backgroundAgentControl, BackgroundAgentControl(...))`.
    var backgroundAgentControl: BackgroundAgentControl? {
        get { self[BackgroundAgentControlKey.self] }
        set { self[BackgroundAgentControlKey.self] = newValue }
    }
}

/// Values the app shell sets once at launch.
@MainActor
public enum ManageConfiguration {
    /// Where releases are published. Empty: Settings › Updates says updates are installed manually.
    public static var releasesURL = ""
}

// MARK: Text helpers

enum ManageText {
    /// A message for a person, with anything secret-shaped removed.
    static func describe(_ error: Error) -> String {
        Redactor.shared.redact((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    static func scopeLabel(_ scope: GrantScope) -> String {
        switch scope {
        case .persistent: return String(localized: "Until revoked")
        case .workflow: return String(localized: "One workflow")
        case .run: return String(localized: "One run")
        case .once: return String(localized: "One call")
        }
    }

    static func sideEffectLabel(_ effect: SideEffect) -> String {
        switch effect {
        case .read: return String(localized: "Reads")
        case .write: return String(localized: "Writes")
        case .external: return String(localized: "Sends outside this Mac")
        case .destructive: return String(localized: "Destructive")
        case .privileged: return String(localized: "Privileged")
        }
    }

    static func sideEffectColor(_ effect: SideEffect) -> Color {
        switch effect {
        case .read: return Theme.success
        case .write: return Theme.blue
        case .external: return Theme.warning
        case .destructive, .privileged: return Theme.danger
        }
    }

    static func modeTitle(_ mode: ExecutionMode) -> String {
        switch mode {
        case .quick: return String(localized: "Quick")
        case .guided: return String(localized: "Guided")
        case .autonomous: return String(localized: "Autonomous")
        case .scheduled: return String(localized: "Scheduled")
        case .review: return String(localized: "Review")
        }
    }

    static func modeExplanation(_ mode: ExecutionMode) -> String {
        switch mode {
        case .quick: return String(localized: "One short task. ORIX asks before anything that is not already allowed.")
        case .guided: return String(localized: "You see the plan first, approve it, then approve each consequential step.")
        case .autonomous: return String(localized: "ORIX works without asking inside what you already allowed. It still asks for anything consequential that no grant covers.")
        case .scheduled: return String(localized: "Started by a trigger with nobody present. Anything not allowed in advance waits for you.")
        case .review: return String(localized: "Read-only. Nothing is changed; steps that would change something are refused or simulated.")
        }
    }

    static func permissionTitle(_ p: MacPermission) -> String {
        switch p {
        case .accessibility: return String(localized: "Accessibility")
        case .screenRecording: return String(localized: "Screen recording")
        case .appleEvents: return String(localized: "Automation (Apple Events)")
        case .fullDiskAccess: return String(localized: "Full Disk Access")
        case .notifications: return String(localized: "Notifications")
        }
    }

    static func permissionSymbol(_ p: MacPermission) -> String {
        switch p {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .appleEvents: return "applescript"
        case .fullDiskAccess: return "internaldrive"
        case .notifications: return "bell.badge"
        }
    }

    static func permissionPurpose(_ p: MacPermission) -> String {
        switch p {
        case .accessibility: return String(localized: "Read and operate the interface of the apps you name: find a button, press it, set a field, wait for a window.")
        case .screenRecording: return String(localized: "Capture a window or the screen when a step asks for it, and read text from the capture.")
        case .appleEvents: return String(localized: "Send scripting commands to an app. macOS asks once per app, the first time ORIX controls it.")
        case .fullDiskAccess: return String(localized: "Read folders macOS protects (Mail, Safari, Messages data). Not needed for ordinary folders you grant.")
        case .notifications: return String(localized: "Tell you when a run finishes or waits for your approval.")
        }
    }

    static func permissionStatus(_ s: PermissionStatus) -> (label: String, symbol: String, color: Color) {
        switch s {
        case .granted: return (String(localized: "Granted"), "checkmark.circle.fill", Theme.success)
        case .denied: return (String(localized: "Not granted"), "xmark.circle.fill", Theme.danger)
        case .notDetermined: return (String(localized: "Not asked yet"), "questionmark.circle.fill", Theme.warning)
        case .unknown: return (String(localized: "Cannot be checked here"), "minus.circle.fill", Theme.neutral)
        }
    }

    static func auditKind(_ k: AuditEntry.Kind) -> (label: String, symbol: String, color: Color) {
        switch k {
        case .toolAllowed: return (String(localized: "Allowed"), "checkmark.shield", Theme.success)
        case .toolDenied: return (String(localized: "Denied"), "nosign", Theme.danger)
        case .approvalRequested: return (String(localized: "Approval asked"), "hand.raised", Theme.violet)
        case .approvalGranted: return (String(localized: "Approved"), "hand.thumbsup", Theme.success)
        case .approvalDenied: return (String(localized: "Refused"), "hand.thumbsdown", Theme.warning)
        case .grantCreated: return (String(localized: "Grant added"), "plus.circle", Theme.blue)
        case .grantRevoked: return (String(localized: "Grant revoked"), "minus.circle", Theme.warning)
        case .toolExecuted: return (String(localized: "Executed"), "wrench.and.screwdriver", Theme.textSecondary)
        case .toolFailed: return (String(localized: "Failed"), "exclamationmark.triangle", Theme.danger)
        case .secretUsed: return (String(localized: "Secret used"), "key", Theme.warning)
        case .emergencyStop: return (String(localized: "Emergency stop"), "stop.circle.fill", Theme.danger)
        case .skillInstalled: return (String(localized: "Skill installed"), "puzzlepiece.extension", Theme.blue)
        case .skillRemoved: return (String(localized: "Skill removed"), "puzzlepiece.extension", Theme.warning)
        case .policyViolation: return (String(localized: "Policy violation"), "exclamationmark.shield", Theme.danger)
        }
    }

    /// Entries a person should be able to review later: everything except routine read-only executions.
    static func isConsequential(_ e: AuditEntry) -> Bool {
        switch e.kind {
        case .toolAllowed: return false
        case .toolExecuted: return (e.tier ?? .readOnly) >= .consequential
        default: return true
        }
    }

    static func price(_ m: ModelInfo) -> String {
        guard let i = m.inputPricePerMTok, let o = m.outputPricePerMTok else { return String(localized: "price unknown") }
        return String(format: "$%.2f / $%.2f per M", i, o)
    }

    static func context(_ m: ModelInfo) -> String {
        guard let c = m.contextWindow else { return "—" }
        return Format.tokens(c)
    }
}

// MARK: Small components

/// A coloured symbol with words: state is never colour alone.
struct StatePill: View {
    let text: String
    let symbol: String
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(Theme.Font.captionStrong).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct TabItem<T: Hashable>: Identifiable {
    let value: T
    let title: LocalizedStringKey
    let symbol: String
    var count: Int?
    var id: T { value }
}

/// A horizontal tab bar that scrolls rather than clips in a narrow window.
struct ManageTabBar<T: Hashable>: View {
    let items: [TabItem<T>]
    @Binding var selection: T
    let identifierPrefix: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(items) { item in
                    let selected = item.value == selection
                    Button {
                        withAnimation(Theme.spring(reduceMotion)) { selection = item.value }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.symbol).font(.system(size: 11, weight: .medium))
                            Text(item.title).font(Theme.Font.bodyStrong).lineLimit(1)
                            if let c = item.count {
                                Text(verbatim: String(c)).font(Theme.Font.captionStrong).monospacedDigit()
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background((selected ? Theme.violet : Theme.textTertiary).opacity(0.18), in: Capsule())
                            }
                        }
                        .foregroundStyle(selected ? Theme.violet : Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(selected ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("\(identifierPrefix).tab.\(String(describing: item.value))")
                }
            }
            .padding(4)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// One setting: a title, a sentence that explains it, and the control. Stacks vertically when the control is wide.
struct SettingRow<Control: View>: View {
    let title: LocalizedStringKey
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                labels
                Spacer(minLength: Theme.Space.m)
                control
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                labels
                control
            }
        }
        .padding(.vertical, 2)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
            if let detail {
                Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
    }
}

/// Read-only monospaced text with selection, for source code, schemas and YAML.
struct CodeBlock: View {
    let text: String
    var maxHeight: CGFloat = 260
    var body: some View {
        ScrollView(.vertical) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).padding(Theme.Space.m)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// A monospaced editor with the same frame as `CodeBlock`.
struct CodeEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120
    var body: some View {
        TextEditor(text: $text).font(Theme.Font.mono).scrollContentBackground(.hidden)
            .autocorrectionDisabled()
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// A caption label above a form control.
struct FieldLabel: View {
    let title: LocalizedStringKey
    var body: some View { Text(title).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary) }
}

/// A sentence of explanation under a heading.
struct Explanation: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A scrolling page with the standard margins.
struct ManagePage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) { content }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}

struct BusyLabel: View {
    let title: LocalizedStringKey
    let busy: Bool
    var symbol: String?
    var body: some View {
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) } else if let symbol { Image(systemName: symbol) }
            Text(title)
        }
    }
}

// MARK: Panels

@MainActor
enum FilePanels {
    static func chooseFolder(message: String, startingAt: String? = nil) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.canCreateDirectories = true
        p.message = message; p.prompt = String(localized: "Choose")
        if let startingAt { p.directoryURL = URL(fileURLWithPath: startingAt) }
        return p.runModal() == .OK ? p.url : nil
    }

    static func chooseFile(message: String, types: [UTType]) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = false; p.canChooseFiles = true; p.allowsMultipleSelection = false
        p.allowedContentTypes = types; p.message = message
        return p.runModal() == .OK ? p.url : nil
    }

    static func chooseApplication() -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = false; p.canChooseFiles = true; p.allowsMultipleSelection = false
        p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.message = String(localized: "Choose an application")
        return p.runModal() == .OK ? p.url : nil
    }

    static func saveFile(name: String, message: String, types: [UTType]) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = name; p.message = message; p.allowedContentTypes = types; p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
