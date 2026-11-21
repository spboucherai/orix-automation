// ORIX OS Automation
// File: App/Sources/DesignSystem/Components.swift
// Description: Shared SwiftUI components: cards, status badges, live pulse, metric tiles, empty states, pills, section headers, key-value rows, button styles, provider glyphs.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXCore
import SwiftUI

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Space.l
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// A dot that breathes while something is live. Static under Reduce Motion.
struct PulseDot: View {
    var color: Color
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    var body: some View {
        ZStack {
            if active && !reduceMotion {
                Circle().fill(color.opacity(0.35)).frame(width: 14, height: 14).scaleEffect(on ? 1 : 0.4).opacity(on ? 0 : 1)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 14, height: 14)
        .onAppear { if active && !reduceMotion { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { on = true } } }
        .accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let style: StatusStyle
    var compact = false
    init(_ status: RunStatus, compact: Bool = false) { style = .of(status); self.compact = compact }
    init(tool status: ToolStatus, compact: Bool = false) { style = .of(status); self.compact = compact }
    var body: some View {
        HStack(spacing: 5) {
            if style.isActive { PulseDot(color: style.color, active: true) } else { Image(systemName: style.symbol).font(.system(size: 11, weight: .semibold)) }
            if !compact { Text(style.label).font(Theme.Font.captionStrong).lineLimit(1) }
        }
        .foregroundStyle(style.color)
        .padding(.horizontal, compact ? 4 : 8).padding(.vertical, 3)
        .background(style.color.opacity(0.13), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Status")).accessibilityValue(Text(style.label))
    }
}

struct TierBadge: View {
    let tier: ApprovalTier
    var body: some View {
        let (color, label, symbol) = StatusStyle.tier(tier)
        Label(label, systemImage: symbol)
            .font(Theme.Font.captionStrong).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }
}

struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color = Theme.textSecondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .medium)) }
            Text(text).font(Theme.Font.caption).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.11), in: Capsule())
    }
}

struct MetricTile: View {
    let title: LocalizedStringKey
    let value: String
    var detail: String?
    var symbol: String
    var tint: Color = Theme.violet
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 26, height: 26).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                Text(value).font(Theme.Font.metric).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let detail { Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.accentGradient)
                .frame(width: 72, height: 72).background(Theme.accentSoft, in: Circle())
            Text(title).font(Theme.Font.heading).foregroundStyle(Theme.text)
            Text(message).font(Theme.Font.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle()).padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.heading).foregroundStyle(Theme.text)
                if let subtitle { Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
            }
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) { self.title = title; self.subtitle = subtitle; self.trailing = EmptyView() }
}

struct PageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Font.display).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(Theme.Font.body).foregroundStyle(Theme.textSecondary) }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) { self.title = title; self.subtitle = subtitle; self.trailing = EmptyView() }
}

struct KeyValueRow: View {
    let key: LocalizedStringKey
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
            Text(value).font(mono ? Theme.Font.monoSmall : Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.bodyStrong).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Theme.accentGradient.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.text
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.bodyStrong).foregroundStyle(tint.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.surfaceRaised.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous).strokeBorder(Theme.strokeStrong))
    }
}

/// Monogram glyph for a provider. Drawn here; no third-party logo is bundled.
struct ProviderGlyph: View {
    let provider: ProviderID
    var size: CGFloat = 22
    var body: some View {
        let (letters, color): (String, Color) = {
            switch provider {
            case .anthropic: return ("A", Color(light: .init(srgbRed: 0.80, green: 0.42, blue: 0.27, alpha: 1), dark: .init(srgbRed: 0.90, green: 0.55, blue: 0.40, alpha: 1)))
            case .openai: return ("O", Color(light: .init(srgbRed: 0.10, green: 0.55, blue: 0.45, alpha: 1), dark: .init(srgbRed: 0.30, green: 0.78, blue: 0.65, alpha: 1)))
            case .openrouter: return ("R", Theme.blue)
            default: return (String(provider.rawValue.prefix(1)).uppercased(), Theme.neutral)
            }
        }()
        Text(letters).font(.system(size: size * 0.55, weight: .bold, design: .rounded)).foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(Text(provider.displayName))
    }
}

/// Skeleton line shown while data loads.
struct SkeletonLine: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    var body: some View {
        RoundedRectangle(cornerRadius: height / 2).fill(Theme.stroke).frame(width: width, height: height)
            .opacity(phase ? 0.45 : 1)
            .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { phase = true } } }
            .accessibilityHidden(true)
    }
}

/// An inline, dismissible message for errors and notices, with an optional recovery action.
struct Banner: View {
    enum Kind { case info, warning, error, success }
    let kind: Kind
    let text: String
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?
    var body: some View {
        let (color, symbol): (Color, String) = {
            switch kind {
            case .info: return (Theme.info, "info.circle.fill")
            case .warning: return (Theme.warning, "exclamationmark.triangle.fill")
            case .error: return (Theme.danger, "xmark.octagon.fill")
            case .success: return (Theme.success, "checkmark.circle.fill")
            }
        }()
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(Theme.Font.body).foregroundStyle(Theme.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.link) }
        }
        .padding(Theme.Space.m)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(color.opacity(0.35)))
    }
}

enum Format {
    static func duration(_ seconds: Double?) -> String {
        guard let s = seconds else { return "—" }
        if s < 1 { return String(format: "%.0f ms", s * 1000) }
        if s < 60 { return String(format: "%.1f s", s) }
        if s < 3600 { return "\(Int(s) / 60) min \(Int(s) % 60) s" }
        return "\(Int(s) / 3600) h \(Int(s) % 3600 / 60) min"
    }
    static func cost(_ usd: Double, complete: Bool = true) -> String {
        let v = usd < 0.01 && usd > 0 ? String(format: "$%.4f", usd) : String(format: "$%.2f", usd)
        return complete ? v : "≥ " + v
    }
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }
    static func dateTime(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "—" }
    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}
