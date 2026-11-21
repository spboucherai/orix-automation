// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/FormControls.swift
// Description: Small form controls of the inspector: fields that commit on Return or focus loss and show the refusal inline, step-id lists, key-value and assertion editors.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

/// A text field that applies its value on Return or when it loses focus. `commit` returns the reason when the value is
/// refused; the reason is shown under the field and the document is left unchanged.
struct CommitField: View {
    var title: LocalizedStringKey?
    var help: String = ""
    let value: String
    var prompt: String = ""
    var mono = false
    var multiline = false
    var identifier: String?
    let commit: (String) -> String?

    @State private var text = ""
    @State private var error: String?
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title {
                Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            }
            Group {
                if multiline {
                    TextField(prompt, text: $text, axis: .vertical).lineLimit(2...8)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(mono ? Theme.Font.monoSmall : Theme.Font.body)
            .foregroundStyle(Theme.text)
            .focused($focused)
            .onSubmit(apply)
            .accessibilityIdentifier(identifier ?? "")
            .padding(.horizontal, 7).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(error != nil ? Theme.danger : (focused ? Theme.violet : Theme.stroke), lineWidth: 1))
            if !help.isEmpty, error == nil { Text(help).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
            if let error {
                Label { Text(error).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                    .font(Theme.Font.caption).foregroundStyle(Theme.danger)
                    .accessibilityIdentifier("workflow.field.error")
            }
        }
        .onAppear { if !loaded { text = value; loaded = true } }
        .onChange(of: value) { _, new in text = new; error = nil }
        .onChange(of: focused) { _, isFocused in if !isFocused { apply() } }
        .onDisappear { if loaded, text != value { _ = commit(text) } }
    }

    private func apply() {
        guard text != value else { error = nil; return }
        error = commit(text)
    }
}

struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary).textCase(.uppercase).accessibilityAddTraits(.isHeader)
            content
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.stroke))
    }
}

struct InlineError: View {
    let text: String?
    var body: some View {
        if let text {
            Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                .font(Theme.Font.caption).foregroundStyle(Theme.danger)
        }
    }
}

/// An ordered list of step ids (needs, branch lists) with remove buttons and an "add" menu of the allowed steps.
struct StepListEditor: View {
    let title: LocalizedStringKey
    let ids: [String]
    let candidates: [String]
    let commit: ([String]) -> String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    let free = candidates.filter { !ids.contains($0) }
                    if free.isEmpty { Text("No other step in this list") }
                    ForEach(free, id: \.self) { id in Button(id) { error = commit(ids + [id]) } }
                } label: { Image(systemName: "plus.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(Text("Add a step to this list"))
            }
            if ids.isEmpty { Text("None").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 6) {
                    Image(systemName: "smallcircle.filled.circle").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                    Text(id).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Button { error = commit(ids.filter { $0 != id }) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel(Text("Remove \(id)"))
                }
            }
            InlineError(text: error)
        }
    }
}

/// Name → value pairs. Values are read the way YAML would read them: JSON literals keep their type, the rest is text.
struct KeyValueEditor: View {
    let title: LocalizedStringKey
    let values: [String: JSONValue]
    var namePrompt: String = String(localized: "name")
    let commit: ([String: JSONValue]) -> String?
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            if values.isEmpty { Text("None").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            ForEach(values.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 6) {
                    Text(key).font(Theme.Font.monoSmall).foregroundStyle(Theme.text).lineLimit(1).frame(width: 78, alignment: .leading).padding(.top, 5)
                    CommitField(value: ArgumentForm.text(for: values[key]), mono: true) { text in
                        var v = values; v[key] = ArgumentForm.parseLoose(text); return commit(v)
                    }
                    Button { var v = values; v[key] = nil; error = commit(v) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).padding(.top, 5)
                        .accessibilityLabel(Text("Remove \(key)"))
                }
            }
            HStack(spacing: 6) {
                TextField(namePrompt, text: $newName).textFieldStyle(.roundedBorder).font(Theme.Font.monoSmall).onSubmit(add)
                Button(action: add) { Text("Add") }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            InlineError(text: error)
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard values[name] == nil else { error = String(localized: "“\(name)” already exists."); return }
        var v = values; v[name] = .string("")
        error = commit(v)
        if error == nil { newName = "" }
    }
}

/// One text entry per line (paths, hosts, bundle identifiers).
struct LinesField: View {
    let title: LocalizedStringKey
    let lines: [String]
    var prompt: String = ""
    let commit: ([String]) -> String?
    var body: some View {
        CommitField(title: title, value: lines.joined(separator: "\n"), prompt: prompt, mono: true, multiline: true) { text in
            commit(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
    }
}

/// An optional number: empty text clears it.
struct NumberField: View {
    let title: LocalizedStringKey
    let value: Double?
    var integer = false
    var help: String = ""
    let commit: (Double?) -> String?
    var body: some View {
        CommitField(title: title, help: help, value: value.map { ArgumentForm.text(for: ArgumentForm.normalized(.number($0))) } ?? "", prompt: String(localized: "not set")) { text in
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return commit(nil) }
            guard let d = Double(t.replacingOccurrences(of: ",", with: ".")), d.isFinite, !integer || d.rounded() == d else {
                return integer ? String(localized: "Enter a whole number.") : String(localized: "Enter a number.")
            }
            return commit(d)
        }
    }
}

/// Editor for `verify` assertions and agent expectations.
struct AssertionsEditor: View {
    let assertions: [WorkflowAssertion]
    let kinds: [String]
    let commit: ([WorkflowAssertion]) -> String?
    @State private var error: String?

    static func title(_ kind: String) -> LocalizedStringKey {
        switch kind {
        case "fileExists": return "File exists"
        case "fileNonEmpty": return "File is not empty"
        case "fileContains": return "File contains text"
        case "dirNonEmpty": return "Folder is not empty"
        case "equals": return "Two values are equal"
        case "truthy": return "Value is true"
        default: return "Step succeeded"
        }
    }

    static func parts(_ a: WorkflowAssertion) -> (String, String) {
        switch a {
        case .fileExists(let p), .fileNonEmpty(let p), .dirNonEmpty(let p): return (p, "")
        case .fileContains(let p, let t): return (p, t)
        case .equals(let x, let y): return (ArgumentForm.text(for: x), ArgumentForm.text(for: y))
        case .truthy(let v): return (ArgumentForm.text(for: v), "")
        case .stepSucceeded(let s): return (s, "")
        }
    }

    static func make(_ kind: String, _ a: String, _ b: String) -> WorkflowAssertion {
        switch kind {
        case "fileExists": return .fileExists(path: a)
        case "fileNonEmpty": return .fileNonEmpty(path: a)
        case "fileContains": return .fileContains(path: a, text: b)
        case "dirNonEmpty": return .dirNonEmpty(path: a)
        case "equals": return .equals(ArgumentForm.parseLoose(a), ArgumentForm.parseLoose(b))
        case "truthy": return .truthy(ArgumentForm.parseLoose(a))
        default: return .stepSucceeded(a)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if assertions.isEmpty { Text("No assertion yet").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            ForEach(Array(assertions.enumerated()), id: \.offset) { i, a in
                let (first, second) = Self.parts(a)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Picker(selection: Binding(get: { a.kindName }, set: { k in replace(i, Self.make(k, first, second)) })) {
                            ForEach(kinds, id: \.self) { k in Text(Self.title(k)).tag(k) }
                        } label: { EmptyView() }
                        .labelsHidden()
                        Spacer()
                        Button { var list = assertions; list.remove(at: i); error = commit(list) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).accessibilityLabel(Text("Remove this assertion"))
                    }
                    CommitField(value: first, prompt: a.kindName == "stepSucceeded" ? String(localized: "step id") : (a.kindName == "equals" || a.kindName == "truthy" ? String(localized: "value or ${{ expression }}") : String(localized: "path")), mono: true) { text in
                        update(i, Self.make(a.kindName, text, second))
                    }
                    if a.kindName == "fileContains" || a.kindName == "equals" {
                        CommitField(value: second, prompt: a.kindName == "equals" ? String(localized: "expected value") : String(localized: "text to find"), mono: true) { text in
                            update(i, Self.make(a.kindName, first, text))
                        }
                    }
                }
                .padding(6).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            }
            Menu {
                ForEach(kinds, id: \.self) { k in Button { error = commit(assertions + [Self.make(k, "", "")]) } label: { Text(Self.title(k)) } }
            } label: { Label("Add assertion", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize()
            InlineError(text: error)
        }
    }

    private func update(_ i: Int, _ a: WorkflowAssertion) -> String? {
        var list = assertions
        guard list.indices.contains(i) else { return nil }
        list[i] = a
        return commit(list)
    }

    private func replace(_ i: Int, _ a: WorkflowAssertion) { error = update(i, a) }
}

/// A two-state switch whose change can be refused.
struct CommitToggle: View {
    let title: LocalizedStringKey
    let isOn: Bool
    let commit: (Bool) -> String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { isOn }, set: { error = commit($0) })) { Text(title).font(Theme.Font.body) }
                .toggleStyle(.switch).controlSize(.small)
            InlineError(text: error)
        }
    }
}
