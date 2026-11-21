// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/StepInspector.swift
// Description: Inspector for the selected step: identity, kind-specific fields (tool arguments generated from the input schema), flow options, tool facts and the step's data from the selected run.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

struct StepInspector: View {
    @Bindable var vm: WorkflowStudioModel
    let location: WorkflowStepLocation

    private var step: WorkflowStep { location.step }
    private var id: String { step.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            let problems = vm.diagnostics(forStep: id)
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, d in
                        Banner(kind: d.severity == .error ? .error : (d.severity == .warning ? .warning : .info), text: d.message)
                    }
                }
            }
            kindSection
            flowSection
            if case .tool(let t) = step.kind, let m = vm.manifestByID[t.tool] { toolFacts(m) }
            runSection
        }
    }

    // MARK: Identity

    private var header: some View {
        let category: WorkflowGraph.Category = vm.graph.node(id)?.category ?? WorkflowGraph.category(of: step.kind)
        let style = CategoryStyle.of(category)
        return InspectorSection(title: "Step") {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: CategoryStyle.symbol(kind: step.kind.name, category: category)).font(.system(size: 13, weight: .semibold)).foregroundStyle(style.color)
                    .frame(width: 26, height: 26).background(style.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.label).font(Theme.Font.bodyStrong).foregroundStyle(Theme.text)
                    Text(verbatim: step.kind.name + (location.containerID.map { " · in \($0)" } ?? "")).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                Button { vm.toggleBreakpoint(id) } label: {
                    Image(systemName: vm.breakpoints.contains(id) ? "circle.fill" : "circle").foregroundStyle(vm.breakpoints.contains(id) ? Theme.danger : Theme.textTertiary)
                }
                .buttonStyle(.plain).help(Text("Pause here when debugging"))
                .accessibilityLabel(Text(loc(vm.breakpoints.contains(id), "Remove breakpoint", "Add breakpoint")))
            }
            CommitField(title: "Identifier", help: String(localized: "Other steps refer to this one by its identifier. Renaming updates every reference."), value: id, mono: true, identifier: "workflow.inspector.id") { vm.rename(id, to: $0) }
            CommitField(title: "Name", value: step.name ?? "", prompt: String(localized: "Shown on the canvas"), identifier: "workflow.inspector.name") { text in
                let t = text.trimmingCharacters(in: .whitespaces)
                return vm.setField(id, .name(t.isEmpty ? nil : t))
            }
        }
    }

    // MARK: Kind-specific

    @ViewBuilder private var kindSection: some View {
        switch step.kind {
        case .tool(let t): toolSection(t)
        case .agent(let a): agentSection(a)
        case .condition(let c):
            InspectorSection(title: "Condition") {
                CommitField(title: "Expression", value: c.condition, mono: true, multiline: true) { text in setKind { .condition(ConditionStep(condition: text, then: c.then, otherwise: c.otherwise)) } }
                StepListEditor(title: "Then run", ids: c.then, candidates: vm.siblings(of: id)) { ids in setKind { .condition(ConditionStep(condition: c.condition, then: ids, otherwise: c.otherwise.filter { !ids.contains($0) })) } }
                StepListEditor(title: "Otherwise run", ids: c.otherwise, candidates: vm.siblings(of: id)) { ids in setKind { .condition(ConditionStep(condition: c.condition, then: c.then.filter { !ids.contains($0) }, otherwise: ids)) } }
            }
        case .switch(let sw): switchSection(sw)
        case .foreach(let f):
            InspectorSection(title: "For each") {
                CommitField(title: "Items", help: String(localized: "An expression that yields a list, or a JSON list."), value: ArgumentForm.text(for: f.items), mono: true, multiline: true) { text in
                    var n = f
                    let loose = ArgumentForm.parseLoose(text)
                    n.items = loose.arrayValue != nil ? loose : .string(text)
                    return setKind { .foreach(n) }
                }
                CommitField(title: "Item name", value: f.itemName, mono: true) { text in var n = f; n.itemName = text.trimmingCharacters(in: .whitespaces); return setKind { .foreach(n) } }
                NumberField(title: "Items at the same time", value: Double(f.concurrency), integer: true) { v in
                    guard let v, v >= 1 else { return String(localized: "Use 1 or more.") }
                    var n = f; n.concurrency = Int(v); return setKind { .foreach(n) }
                }
                Picker(selection: Binding(get: { f.collect ?? "" }, set: { v in var n = f; n.collect = v.isEmpty ? nil : v; pickerError = setKind { .foreach(n) } })) {
                    Text("Every step's output").tag("")
                    ForEach(f.steps.map(\.id), id: \.self) { Text(verbatim: $0).tag($0) }
                } label: { Text("Collect").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                bodyNote(count: f.steps.count)
                InlineError(text: pickerError)
            }
        case .parallel(let p): parallelSection(p)
        case .loop(let l):
            InspectorSection(title: "Loop while") {
                CommitField(title: "Condition", value: l.condition, mono: true, multiline: true) { text in var n = l; n.condition = text; return setKind { .loop(n) } }
                NumberField(title: "Most iterations", value: Double(l.maxIterations), integer: true) { v in
                    guard let v, v >= 1 else { return String(localized: "A loop needs an upper bound of 1 or more.") }
                    var n = l; n.maxIterations = Int(v); return setKind { .loop(n) }
                }
                bodyNote(count: l.steps.count)
            }
        case .approval(let a):
            InspectorSection(title: "Approval gate") {
                CommitField(title: "Message", help: String(localized: "Shown to the person who approves. The run waits here."), value: a.message, multiline: true, identifier: "workflow.inspector.approval") { text in
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Say what is being approved.") : setKind { .approval(ApprovalStep(message: text)) }
                }
            }
        case .delay(let d):
            InspectorSection(title: "Delay") {
                CommitField(title: "Seconds", help: String(localized: "A number, or an expression that yields one."), value: ArgumentForm.text(for: d.seconds), mono: true) { text in
                    let v = ArgumentForm.parseLoose(text)
                    if let n = v.doubleValue { return n >= 0 ? setKind { .delay(DelayStep(seconds: v)) } : String(localized: "A delay cannot be negative.") }
                    guard ArgumentForm.isExpression(text) else { return String(localized: "Enter a number of seconds, or an expression.") }
                    return setKind { .delay(DelayStep(seconds: .string(text))) }
                }
            }
        case .set(let s):
            InspectorSection(title: "Set variables") {
                KeyValueEditor(title: "Variables", values: s.values, namePrompt: String(localized: "variable name")) { v in setKind { .set(SetStep(values: v)) } }
            }
        case .transform(let t):
            InspectorSection(title: "Transform") {
                CommitField(title: "Expression", value: t.expression, mono: true, multiline: true) { text in setKind { .transform(TransformStep(expression: text, into: t.into)) } }
                CommitField(title: "Also store in variable", value: t.into ?? "", prompt: String(localized: "optional"), mono: true) { text in
                    let n = text.trimmingCharacters(in: .whitespaces)
                    return setKind { .transform(TransformStep(expression: t.expression, into: n.isEmpty ? nil : n)) }
                }
            }
        case .verify(let v):
            InspectorSection(title: "Verify") {
                AssertionsEditor(assertions: v.assertions, kinds: WorkflowAssertion.kindNames) { list in setKind { .verify(VerifyStep(assertions: list)) } }
            }
        case .subworkflow(let s):
            InspectorSection(title: "Run another workflow") {
                Picker(selection: Binding(get: { s.workflow }, set: { v in pickerError = setKind { .subworkflow(SubworkflowStep(workflow: v, inputs: s.inputs)) } })) {
                    if !vm.rows.contains(where: { $0.id == s.workflow }) { Text(verbatim: s.workflow.isEmpty ? "—" : s.workflow).tag(s.workflow) }
                    ForEach(vm.rows.filter { $0.id != vm.workflowID }) { r in Text(verbatim: r.name).tag(r.id) }
                } label: { Text("Workflow").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                KeyValueEditor(title: "Inputs", values: s.inputs, namePrompt: String(localized: "parameter name")) { v in setKind { .subworkflow(SubworkflowStep(workflow: s.workflow, inputs: v)) } }
                InlineError(text: pickerError)
            }
        case .notify(let n):
            InspectorSection(title: "Notify") {
                CommitField(title: "Message", value: n.message, multiline: true) { text in setKind { .notify(NotifyStep(message: text, title: n.title)) } }
                CommitField(title: "Title", value: n.title ?? "", prompt: String(localized: "optional")) { text in setKind { .notify(NotifyStep(message: n.message, title: text.isEmpty ? nil : text)) } }
            }
        case .fail(let f):
            InspectorSection(title: "Fail") {
                CommitField(title: "Message", value: f.message, multiline: true) { text in setKind { .fail(FailStep(message: text)) } }
            }
        case .output(let o):
            InspectorSection(title: "Output") {
                KeyValueEditor(title: "Values", values: o.values, namePrompt: String(localized: "output name")) { v in setKind { .output(OutputStep(values: v, artifacts: o.artifacts)) } }
                LinesField(title: "Files to keep as artifacts (one per line)", lines: o.artifacts) { lines in setKind { .output(OutputStep(values: o.values, artifacts: lines)) } }
            }
        }
    }

    @State private var pickerError: String?

    private func setKind(_ make: @escaping () -> WorkflowStepKind) -> String? { vm.setField(id, .kind(make())) }

    private func bodyNote(count: Int) -> some View {
        Text(loc(count == 0, "No step inside yet. Select this step and add one from the palette.", "\(count) steps inside. Select this step and use Add to put another one in."))
            .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Tool

    private func toolSection(_ t: ToolStep) -> some View {
        let manifest = vm.manifestByID[t.tool]
        let fields = manifest.map { ArgumentForm.fields(of: $0.inputSchema) } ?? []
        let known = Set(fields.map(\.name))
        let extra = t.arguments.keys.filter { !known.contains($0) }.sorted()
        return InspectorSection(title: "Tool") {
            Picker(selection: Binding(get: { t.tool }, set: { v in pickerError = vm.setTool(id, to: v) })) {
                if manifest == nil { Text(verbatim: t.tool).tag(t.tool) }
                ForEach(Dictionary(grouping: vm.manifests, by: \.family).sorted { $0.key < $1.key }, id: \.key) { family, tools in
                    Section(family) { ForEach(tools, id: \.identifier) { m in Text(verbatim: m.identifier).tag(m.identifier) } }
                }
            } label: { Text("Tool").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
            .accessibilityIdentifier("workflow.inspector.tool")
            InlineError(text: pickerError)
            if let manifest {
                Text(manifest.summary).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Banner(kind: .error, text: String(localized: "The tool “\(t.tool)” is not installed. Choose another tool, or install the skill that provides it."))
            }
            if !fields.isEmpty {
                Divider()
                Text("Arguments").font(Theme.Font.captionStrong).foregroundStyle(Theme.textSecondary)
                ForEach(fields) { f in argumentField(f, value: t.arguments[f.name]) }
            }
            ForEach(extra, id: \.self) { key in
                CommitField(title: LocalizedStringKey(key), help: String(localized: "This argument is not in the tool's input schema."), value: ArgumentForm.text(for: t.arguments[key]), mono: true) { text in
                    vm.setField(id, .toolArgument(key, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ArgumentForm.parseLoose(text)))
                }
            }
        }
    }

    @ViewBuilder private func argumentField(_ f: SchemaField, value: JSONValue?) -> some View {
        let text = ArgumentForm.text(for: value)
        let isExpr = ArgumentForm.isExpression(text)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(verbatim: f.name).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                if f.required { Text("required").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.violet) }
                Spacer()
                Text(verbatim: f.kind.label).font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            }
            switch f.kind {
            case .boolean where !isExpr:
                BooleanArgument(value: value?.boolValue, required: f.required) { v in vm.setField(id, .toolArgument(f.name, v.map(JSONValue.bool))) }
            case .enumeration(let options) where !isExpr:
                EnumArgument(value: value?.stringValue, options: options, required: f.required) { v in vm.setField(id, .toolArgument(f.name, v.map(JSONValue.string))) }
            default:
                CommitField(value: text, prompt: f.required ? "" : String(localized: "not set"), mono: true, multiline: f.kind == .string || f.kind == .array || f.kind == .object || f.kind == .any,
                            identifier: "workflow.inspector.arg.\(f.name)") { vm.setArgument(id, field: f, text: $0) }
            }
            if !f.summary.isEmpty { Text(f.summary).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.vertical, 2)
    }

    private func toolFacts(_ m: ToolManifest) -> some View {
        InspectorSection(title: "What this tool does") {
            HStack(spacing: 6) {
                TierBadge(tier: m.defaultTier)
                Pill(text: SideEffectStyle.label(m.sideEffect), symbol: SideEffectStyle.symbol(m.sideEffect), color: SideEffectStyle.color(m.sideEffect))
            }
            HStack(spacing: 6) {
                if m.supportsDryRun { Pill(text: String(localized: "can be simulated"), symbol: "eye") } else { Pill(text: String(localized: "not executed in a dry run"), symbol: "eye.slash") }
                if m.idempotent { Pill(text: String(localized: "safe to retry"), symbol: "arrow.clockwise") }
            }
            if !m.macPermissions.isEmpty {
                Text("Needs these macOS permissions").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                ForEach(m.macPermissions, id: \.self) { p in Pill(text: p.rawValue, symbol: "lock.shield", color: Theme.warning) }
            }
            schemaSummary(title: "Input", schema: m.inputSchema)
            schemaSummary(title: "Output", schema: m.outputSchema)
            if m.outputIsUntrusted {
                Text("The output can contain text from outside this Mac. It is treated as data, never as instructions.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func schemaSummary(title: LocalizedStringKey, schema: JSONSchema) -> some View {
        let lines = ArgumentForm.summaryLines(of: schema)
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                if lines.isEmpty { Text("No declared fields").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
                ForEach(lines, id: \.name) { l in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: l.name + (l.required ? " *" : "")).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                        Text(verbatim: l.type).font(Theme.Font.monoSmall).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
        } label: {
            Text(title).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) + Text(verbatim: "  \(lines.count)").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Agent

    private func agentSection(_ a: AgentStep) -> some View {
        let profileName: String? = { if case .profile(let p) = a.agent { return p }; return nil }()
        let inline: InlineAgent? = { if case .inline(let i) = a.agent { return i }; return nil }()
        return InspectorSection(title: "Agent") {
            Picker(selection: Binding(get: { profileName ?? "\u{1}inline" }, set: { v in
                var n = a
                n.agent = v == "\u{1}inline" ? .inline(inline ?? InlineAgent(instructions: "")) : .profile(v)
                pickerError = setKind { .agent(n) }
            })) {
                if let p = profileName, !vm.agents.contains(where: { $0.name == p }) { Text(verbatim: p).tag(p) }
                ForEach(vm.agents) { p in Text(verbatim: p.name).tag(p.name) }
                Divider()
                Text("Instructions written here").tag("\u{1}inline")
            } label: { Text("Profile").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
            .accessibilityIdentifier("workflow.inspector.agent")
            InlineError(text: pickerError)
            if let i = inline {
                CommitField(title: "Instructions", value: i.instructions, multiline: true) { text in var n = a; n.agent = .inline(InlineAgent(instructions: text, model: i.model, tools: i.tools)); return setKind { .agent(n) } }
                CommitField(title: "Model", help: String(localized: "provider/model, for example anthropic/claude-sonnet-4-5. Empty uses the default model."), value: i.model ?? "", prompt: String(localized: "default model"), mono: true) { text in
                    let t = text.trimmingCharacters(in: .whitespaces)
                    var n = a; n.agent = .inline(InlineAgent(instructions: i.instructions, model: t.isEmpty ? nil : t, tools: i.tools)); return setKind { .agent(n) }
                }
                LinesField(title: "Tools it may use (one per line, family.* allowed)", lines: i.tools) { lines in var n = a; n.agent = .inline(InlineAgent(instructions: i.instructions, model: i.model, tools: lines)); return setKind { .agent(n) } }
            } else if let p = vm.agents.first(where: { $0.name == profileName }) {
                Text(verbatim: p.role).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            CommitField(title: "Objective", value: a.objective, prompt: String(localized: "What the agent must achieve"), multiline: true, identifier: "workflow.inspector.objective") { text in var n = a; n.objective = text; return setKind { .agent(n) } }
            KeyValueEditor(title: "Inputs", values: a.inputs, namePrompt: String(localized: "input name")) { v in var n = a; n.inputs = v; return setKind { .agent(n) } }
            Text("Expected results").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
            AssertionsEditor(assertions: a.expect, kinds: ["fileExists", "fileNonEmpty", "fileContains", "dirNonEmpty"]) { list in var n = a; n.expect = list; return setKind { .agent(n) } }
        }
    }

    // MARK: Switch and parallel

    private func switchSection(_ sw: SwitchStep) -> some View {
        InspectorSection(title: "Switch") {
            CommitField(title: "Value to compare", value: sw.on, mono: true, multiline: true) { text in var n = sw; n.on = text; return setKind { .switch(n) } }
            ForEach(Array(sw.cases.enumerated()), id: \.offset) { i, c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        CommitField(title: "When it equals", value: ArgumentForm.text(for: c.value), mono: true) { text in var n = sw; n.cases[i].value = ArgumentForm.parseLoose(text); return setKind { .switch(n) } }
                        Button { var n = sw; n.cases.remove(at: i); pickerError = setKind { .switch(n) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).accessibilityLabel(Text("Remove this case"))
                    }
                    StepListEditor(title: "Run", ids: c.steps, candidates: vm.siblings(of: id)) { ids in var n = sw; n.cases[i].steps = ids; return setKind { .switch(n) } }
                }
                .padding(6).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
            }
            Button { var n = sw; n.cases.append(SwitchCase(value: .string("value\(sw.cases.count + 1)"), steps: [])); pickerError = setKind { .switch(n) } } label: { Label("Add case", systemImage: "plus") }
                .buttonStyle(.borderless)
            StepListEditor(title: "Otherwise run", ids: sw.defaultSteps, candidates: vm.siblings(of: id)) { ids in var n = sw; n.defaultSteps = ids; return setKind { .switch(n) } }
            InlineError(text: pickerError)
        }
    }

    private func parallelSection(_ p: ParallelStep) -> some View {
        InspectorSection(title: "Parallel") {
            if p.branches.isEmpty { Text("No branch yet").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary) }
            ForEach(Array(p.branches.enumerated()), id: \.offset) { i, b in
                HStack(alignment: .top) {
                    CommitField(value: b.name, mono: true) { text in
                        let name = text.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return String(localized: "A branch needs a name.") }
                        guard !p.branches.enumerated().contains(where: { $0.offset != i && $0.element.name == name }) else { return String(localized: "Another branch already has this name.") }
                        var n = p; n.branches[i].name = name; return setKind { .parallel(n) }
                    }
                    Text("\(b.steps.count) steps").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).padding(.top, 5).fixedSize()
                    Button { var n = p; n.branches.remove(at: i); pickerError = setKind { .parallel(n) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).padding(.top, 5).disabled(!b.steps.isEmpty)
                        .help(Text(loc(b.steps.isEmpty, "Remove this branch", "Delete or move its steps first")))
                        .accessibilityLabel(Text("Remove branch \(b.name)"))
                }
            }
            Button {
                var n = p
                var k = p.branches.count + 1
                while n.branches.contains(where: { $0.name == "branch\(k)" }) { k += 1 }
                n.branches.append(ParallelBranch(name: "branch\(k)"))
                pickerError = setKind { .parallel(n) }
            } label: { Label("Add branch", systemImage: "plus") }.buttonStyle(.borderless)
            Text("New steps added while this step is selected go into the first branch.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            InlineError(text: pickerError)
        }
    }

    // MARK: Flow

    private var flowSection: some View {
        let siblings = vm.siblings(of: id)
        return InspectorSection(title: "Flow") {
            StepListEditor(title: "Needs (runs after)", ids: step.needs, candidates: siblings) { ids in vm.update(id) { $0.needs = ids } }
            CommitField(title: "Only when", help: String(localized: "Expression. The step is skipped when it is false."), value: step.when ?? "", prompt: String(localized: "always"), mono: true) { text in
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return vm.setField(id, .when(t.isEmpty ? nil : text))
            }
            NumberField(title: "Time limit (seconds)", value: step.timeoutSeconds) { v in
                if let v, v <= 0 { return String(localized: "Use a positive number of seconds.") }
                return vm.setField(id, .timeoutSeconds(v))
            }
            CommitToggle(title: "Retry on failure", isOn: step.retry != nil) { on in vm.setField(id, .retry(on ? WorkflowRetryPolicy(maxAttempts: 3, backoffSeconds: 2, backoffMultiplier: 2) : nil)) }
            if let r = step.retry {
                HStack(alignment: .top) {
                    NumberField(title: "Attempts", value: Double(r.maxAttempts), integer: true) { v in
                        guard let v, v >= 1 else { return String(localized: "Use 1 or more.") }
                        var n = r; n.maxAttempts = Int(v); return vm.setField(id, .retry(n))
                    }
                    NumberField(title: "Wait (s)", value: r.backoffSeconds) { v in
                        guard let v, v >= 0 else { return String(localized: "Use 0 or more.") }
                        var n = r; n.backoffSeconds = v; return vm.setField(id, .retry(n))
                    }
                    NumberField(title: "Multiplier", value: r.backoffMultiplier) { v in
                        guard let v, v >= 1 else { return String(localized: "Use 1 or more.") }
                        var n = r; n.backoffMultiplier = v; return vm.setField(id, .retry(n))
                    }
                }
                CommitToggle(title: "Retry even if repeating may act twice", isOn: r.force) { on in var n = r; n.force = on; return vm.setField(id, .retry(n)) }
            }
            CommitToggle(title: "Continue if this step fails", isOn: step.continueOnError) { vm.setField(id, .continueOnError($0)) }
            Picker(selection: Binding(get: { step.onError ?? "" }, set: { v in flowError = vm.setField(id, .onError(v.isEmpty ? nil : v)) })) {
                Text("Nothing").tag("")
                ForEach(siblings, id: \.self) { Text(verbatim: $0).tag($0) }
            } label: { Text("On error, run").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
            .accessibilityIdentifier("workflow.inspector.onError")
            InlineError(text: flowError)
        }
    }

    @State private var flowError: String?

    // MARK: Last run

    @ViewBuilder private var runSection: some View {
        if vm.activeRunID != nil {
            InspectorSection(title: "In the selected run") {
                if let info = vm.stepInfo[id] {
                    let style = StepStyle.of(info.status, waitingApproval: vm.isWaitingApproval(id))
                    HStack(spacing: 6) {
                        if style.isActive { PulseDot(color: style.color, active: true) } else { Image(systemName: style.symbol).foregroundStyle(style.color) }
                        Text(verbatim: style.label).font(Theme.Font.bodyStrong).foregroundStyle(style.color)
                        Spacer()
                        if vm.runIsDry { Pill(text: String(localized: "dry run"), symbol: "eye", color: Theme.info) }
                    }
                    .accessibilityElement(children: .combine)
                    KeyValueRow(key: "Attempts", value: info.attempts > 0 ? "\(info.attempts)" : "—")
                    KeyValueRow(key: "Duration", value: Format.duration(info.durationSeconds))
                    if info.instances > 1 { KeyValueRow(key: "Times run", value: "\(info.instances)") }
                    if let note = info.note, !note.isEmpty { Text(note).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    if let e = info.error, !e.isEmpty { Banner(kind: .error, text: e) }
                    if let out = info.output, !out.isNull {
                        Text("Output").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                        ScrollView {
                            Text(verbatim: Redactor.shared.redact(String(out.serialized(pretty: true).prefix(20_000)))).font(Theme.Font.monoSmall).foregroundStyle(Theme.text)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.s)
                        }
                        .frame(maxHeight: 180)
                        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.s))
                    } else if info.status.isTerminal {
                        Text("No output is kept for this step in this run.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    Text("This step did not run.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

enum SideEffectStyle {
    static func label(_ s: SideEffect) -> String {
        switch s {
        case .read: return String(localized: "reads only")
        case .write: return String(localized: "changes files or state")
        case .external: return String(localized: "sends outside this Mac")
        case .destructive: return String(localized: "can destroy data")
        case .privileged: return String(localized: "privileged")
        }
    }
    static func symbol(_ s: SideEffect) -> String {
        switch s {
        case .read: return "eye"
        case .write: return "pencil"
        case .external: return "paperplane"
        case .destructive: return "flame"
        case .privileged: return "lock.open"
        }
    }
    static func color(_ s: SideEffect) -> Color {
        switch s {
        case .read: return Theme.success
        case .write: return Theme.blue
        case .external: return Theme.warning
        case .destructive, .privileged: return Theme.danger
        }
    }
}

private struct BooleanArgument: View {
    let value: Bool?
    let required: Bool
    let commit: (Bool?) -> String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(selection: Binding(get: { value.map { $0 ? "true" : "false" } ?? "" }, set: { v in error = commit(v.isEmpty ? nil : v == "true") })) {
                if !required { Text("not set").tag("") }
                Text("true").tag("true")
                Text("false").tag("false")
            } label: { EmptyView() }
            .pickerStyle(.segmented).labelsHidden()
            InlineError(text: error)
        }
    }
}

private struct EnumArgument: View {
    let value: String?
    let options: [String]
    let required: Bool
    let commit: (String?) -> String?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(selection: Binding(get: { value ?? "" }, set: { v in error = commit(v.isEmpty ? nil : v) })) {
                if !required || value == nil { Text("not set").tag("") }
                if let value, !options.contains(value) { Text(verbatim: value).tag(value) }
                ForEach(options, id: \.self) { Text(verbatim: $0).tag($0) }
            } label: { EmptyView() }
            .labelsHidden()
            InlineError(text: error)
        }
    }
}
