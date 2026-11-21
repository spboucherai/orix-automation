// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/Graph.swift
// Description      : Graph projection of a workflow document for the visual
//                    editor: nodes, ports, edges, container membership and a
//                    deterministic layered auto-layout.
// Module           : ORIXWorkflowEngine
// Repository       : https://git.spboucher.ai/orix-automation
// Created          : 2026-11-21
// Last Modified    : 2026-11-21
//
// =============================================================================
// AUTHOR & PROFESSIONAL AFFILIATION
// =============================================================================
//
// Author           : Simon-Pierre Boucher
// Position         : Professor of Finance
// Institution      : Université du Québec en Outaouais (UQO)
// Department       : Département des sciences administratives
// Organization     : SP Boucher
//
// Website          : https://spboucher.ai
// Git              : https://git.spboucher.ai
//
// =============================================================================
// OFFICIAL CONTACT DIRECTORY
// =============================================================================
//
// General          : info@spboucher.ai
// Professional     : contact@spboucher.ai
// Direct           : simon@spboucher.ai
// Research         : research@spboucher.ai
// Development      : dev@spboucher.ai
// Support          : support@spboucher.ai
// Security/Admin   : admin@spboucher.ai
// Notifications    : notifications@spboucher.ai
//
// Preferred Contact: support@spboucher.ai
//
// =============================================================================
// COPYRIGHT & INTELLECTUAL PROPERTY
// =============================================================================
//
// Copyright (c) 2026
// Simon-Pierre Boucher
//
// All rights reserved where applicable.
//
// This file is governed by the applicable project license,
// copyright notices, institutional agreements and relevant law.
//
// Unless expressly authorized by the applicable license or
// rights holder, copying, redistribution, sublicensing,
// publication and commercial exploitation are not permitted.
//
// Existing third-party rights and notices remain unaffected.
//
// =============================================================================
// CONFIDENTIALITY & SECURITY
// =============================================================================
//
// Classification   : Public
// Distribution     : Public repository; use is governed by the project license
// Security Contact : admin@spboucher.ai
//
// Access to this source does not independently grant permission
// to redistribute or disclose confidential materials.
//
// Do not embed credentials, private keys, access tokens,
// certificates or confidential personal information.
//
// =============================================================================
// LICENSE & MAINTENANCE
// =============================================================================
//
// License          : Proprietary, all rights reserved (see license file)
// License File     : LICENSE
// Maintainer       : Simon-Pierre Boucher
// Technical Contact: dev@spboucher.ai
//
// =============================================================================
// END OF SP BOUCHER SOURCE HEADER
// =============================================================================

import Foundation
import ORIXCore

public struct WorkflowGraph: Sendable, Hashable {
    /// Node categories of the visual studio.
    public enum Category: String, Sendable, Hashable, Codable, CaseIterable {
        case trigger, agent, tool, logic, parallelism, data, control, output, error
    }

    public struct Port: Sendable, Hashable, Identifiable {
        public var id: String
        public var label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }

    public struct Node: Sendable, Hashable, Identifiable {
        /// Step id, or `trigger:<index>` for a trigger.
        public var id: String
        /// Step kind name (`tool`, `agent`, …) or `trigger`.
        public var kind: String
        public var category: Category
        public var title: String
        public var subtitle: String
        public var inputs: [Port]
        public var outputs: [Port]
        /// Top-left corner. Relative to the container for nested steps.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// Container step id for nested steps.
        public var parentID: String?
        /// Parallel branch name for steps of a `parallel` container.
        public var branch: String?
        public var isContainer: Bool
    }

    public enum EdgeKind: String, Sendable, Hashable, Codable { case dependency, branch, error, trigger }

    public struct Edge: Sendable, Hashable, Identifiable {
        public var id: String
        public var from: String
        public var fromPort: String
        public var to: String
        public var toPort: String
        public var kind: EdgeKind
        public var label: String
    }

    public var nodes: [Node]
    public var edges: [Edge]

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    public func children(of containerID: String) -> [Node] { nodes.filter { $0.parentID == containerID } }

    // MARK: Metrics

    public static let leafSize = (width: 220.0, height: 72.0)
    public static let triggerSize = (width: 200.0, height: 64.0)
    public static let columnGap = 80.0
    public static let rowGap = 32.0
    static let containerPadding = 24.0
    static let containerHeader = 44.0
    static let containerMinimum = (width: 268.0, height: 140.0)

    // MARK: Projection

    public init(document doc: WorkflowDocument) {
        let layout = Self.compute(doc, overrides: doc.spec.layout)
        var nodes: [Node] = []
        var edges: [Edge] = []
        let rootHandlers = Set(doc.spec.steps.compactMap(\.onError))
        let rootGated = Set(doc.spec.steps.flatMap(\.gatedStepIDs))

        for (i, t) in doc.spec.triggers.enumerated() {
            let id = "trigger:\(i)"
            let pos = doc.spec.layout[id] ?? layout.positions[id] ?? WorkflowNodePosition(x: 0, y: 0)
            nodes.append(Node(id: id, kind: "trigger", category: .trigger, title: Self.triggerTitle(t), subtitle: Self.triggerSubtitle(t),
                              inputs: [], outputs: [Port(id: "out", label: "")], x: pos.x, y: pos.y,
                              width: Self.triggerSize.width, height: Self.triggerSize.height, parentID: nil, branch: nil, isContainer: false))
            for s in doc.spec.steps where s.needs.isEmpty && !rootHandlers.contains(s.id) && !rootGated.contains(s.id) {
                edges.append(Edge(id: "trigger:\(id)->\(s.id)", from: id, fromPort: "out", to: s.id, toPort: "in", kind: .trigger, label: ""))
            }
        }

        for scope in doc.scopes {
            let ids = Set(scope.steps.map(\.id))
            let handlers = Set(scope.steps.compactMap(\.onError))
            for s in scope.steps {
                let pos = doc.spec.layout[s.id] ?? layout.positions[s.id] ?? WorkflowNodePosition(x: 0, y: 0)
                let size = layout.sizes[s.id] ?? Size(w: Self.leafSize.width, h: Self.leafSize.height)
                var category = Self.category(of: s.kind)
                if handlers.contains(s.id) || scope.kind == .onError { category = .error }
                nodes.append(Node(id: s.id, kind: s.kind.name, category: category, title: s.name ?? s.id, subtitle: Self.subtitle(of: s),
                                  inputs: [Port(id: "in", label: "")], outputs: Self.outputs(of: s), x: pos.x, y: pos.y,
                                  width: size.w, height: size.h, parentID: scope.containerID, branch: scope.branch, isContainer: s.isContainer))
                for need in s.needs where ids.contains(need) && need != s.id {
                    edges.append(Edge(id: "dependency:\(need)->\(s.id)", from: need, fromPort: "out", to: s.id, toPort: "in", kind: .dependency, label: ""))
                }
                func branch(_ port: String, _ label: String, _ targets: [String]) {
                    for t in targets where ids.contains(t) && t != s.id {
                        edges.append(Edge(id: "branch:\(s.id).\(port)->\(t)", from: s.id, fromPort: port, to: t, toPort: "in", kind: .branch, label: label))
                    }
                }
                switch s.kind {
                case .condition(let c): branch("then", "then", c.then); branch("else", "else", c.otherwise)
                case .switch(let sw):
                    for (i, c) in sw.cases.enumerated() { branch("case:\(i)", c.value.displayString, c.steps) }
                    branch("default", "default", sw.defaultSteps)
                default: break
                }
                if let h = s.onError, ids.contains(h), h != s.id {
                    edges.append(Edge(id: "error:\(s.id)->\(h)", from: s.id, fromPort: "error", to: h, toPort: "in", kind: .error, label: "on error"))
                }
            }
        }
        self.nodes = nodes
        self.edges = edges
    }

    public static func project(_ doc: WorkflowDocument) -> WorkflowGraph { WorkflowGraph(document: doc) }

    public static func category(of kind: WorkflowStepKind) -> Category {
        switch kind {
        case .tool: return .tool
        case .agent: return .agent
        case .condition, .switch, .foreach, .loop, .transform, .subworkflow: return .logic
        case .parallel: return .parallelism
        case .set, .verify: return .data
        case .approval, .delay, .fail: return .control
        case .notify, .output: return .output
        }
    }

    static func outputs(of s: WorkflowStep) -> [Port] {
        var out = [Port(id: "out", label: "")]
        switch s.kind {
        case .condition: out += [Port(id: "then", label: "then"), Port(id: "else", label: "else")]
        case .switch(let sw):
            out += sw.cases.enumerated().map { Port(id: "case:\($0.offset)", label: $0.element.value.displayString) }
            out.append(Port(id: "default", label: "default"))
        case .foreach, .loop, .parallel: out.append(Port(id: "body", label: "body"))
        default: break
        }
        if s.onError != nil { out.append(Port(id: "error", label: "on error")) }
        return out
    }

    static func short(_ s: String) -> String {
        let line = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    static func subtitle(of s: WorkflowStep) -> String {
        switch s.kind {
        case .tool(let t): return t.tool
        case .agent(let a):
            if case .profile(let p) = a.agent { return p }
            return "inline agent"
        case .condition(let c): return short("if \(c.condition)")
        case .switch(let sw): return short("switch \(sw.on)")
        case .foreach(let f): return short("for each \(f.itemName) in \(f.items.displayString)")
        case .parallel(let p): return "\(p.branches.count) branch\(p.branches.count == 1 ? "" : "es")"
        case .loop(let l): return short("while \(l.condition) (max \(l.maxIterations))")
        case .approval(let a): return short(a.message)
        case .delay(let d): return short("\(d.seconds.displayString) s")
        case .set(let st): return short(st.values.keys.sorted().joined(separator: ", "))
        case .transform(let t): return short(t.expression)
        case .verify(let v): return "\(v.assertions.count) assertion\(v.assertions.count == 1 ? "" : "s")"
        case .subworkflow(let sw): return short(sw.workflow)
        case .notify(let n): return short(n.message)
        case .fail(let f): return short(f.message)
        case .output(let o): return short((o.values.keys.sorted() + o.artifacts).joined(separator: ", "))
        }
    }

    static func triggerTitle(_ t: WorkflowTrigger) -> String {
        switch t {
        case .manual: return "Manual"
        case .schedule: return "Schedule"
        case .once: return "Once"
        case .interval: return "Interval"
        case .fileChange: return "File change"
        case .login: return "Login"
        case .appLaunch: return "App launch"
        }
    }

    static func triggerSubtitle(_ t: WorkflowTrigger) -> String {
        switch t {
        case .manual, .login: return ""
        case .schedule(let cron, let tz): return short(cron + (tz.map { " (\($0))" } ?? ""))
        case .once(let at): return short(at)
        case .interval(let s): return "every \(JSONValue.number(s).intValue.map(String.init) ?? String(s)) s"
        case .fileChange(let path, let glob, _): return short(path + (glob.map { "/\($0)" } ?? ""))
        case .appLaunch(let b): return short(b)
        }
    }

    // MARK: Layout

    struct Size: Sendable, Hashable { var w: Double; var h: Double }

    /// Auto positions for every node (steps and `trigger:<index>`), and node sizes. Containers are sized around the
    /// effective positions of their children (`overrides` first, auto position otherwise).
    static func compute(_ doc: WorkflowDocument, overrides: [String: WorkflowNodePosition]) -> (positions: [String: WorkflowNodePosition], sizes: [String: Size]) {
        var positions: [String: WorkflowNodePosition] = [:]
        var sizes: [String: Size] = [:]

        func size(_ s: WorkflowStep) -> Size {
            guard s.isContainer else { return Size(w: leafSize.width, h: leafSize.height) }
            var right = 0.0
            var y = containerHeader
            for child in s.childScopes {
                let box = layoutScope(child.steps, originX: containerPadding, originY: y)
                right = max(right, box.right)
                y = max(y, box.bottom) + rowGap
            }
            return Size(w: max(containerMinimum.width, right + containerPadding), h: max(containerMinimum.height, y - rowGap + containerPadding))
        }

        /// Lays out one step list in layers; returns the right and bottom extents of its nodes.
        func layoutScope(_ steps: [WorkflowStep], originX: Double, originY: Double) -> (right: Double, bottom: Double) {
            guard !steps.isEmpty else { return (originX, originY) }
            for s in steps where sizes[s.id] == nil { sizes[s.id] = size(s) }
            let ids = Set(steps.map(\.id))
            var preds: [String: [String]] = [:]
            for s in steps {
                for n in s.needs where ids.contains(n) && n != s.id { preds[s.id, default: []].append(n) }
                for t in s.gatedStepIDs where ids.contains(t) && t != s.id { preds[t, default: []].append(s.id) }
                if let h = s.onError, ids.contains(h), h != s.id { preds[h, default: []].append(s.id) }
            }
            var layer: [String: Int] = [:]
            func depth(_ id: String, _ trail: Set<String>) -> Int {
                if let d = layer[id] { return d }
                var d = 0
                for p in preds[id] ?? [] where !trail.contains(p) { d = max(d, depth(p, trail.union([id])) + 1) }
                layer[id] = d
                return d
            }
            for s in steps { _ = depth(s.id, []) }
            let count = (layer.values.max() ?? 0) + 1
            var widths = [Double](repeating: 0, count: count)
            for s in steps { widths[layer[s.id]!] = max(widths[layer[s.id]!], sizes[s.id]!.w) }
            var xs = [Double](repeating: originX, count: count)
            for i in 1..<max(count, 1) where i < count { xs[i] = xs[i - 1] + widths[i - 1] + columnGap }
            var nextY = [Double](repeating: originY, count: count)
            var right = originX, bottom = originY
            for s in steps {
                let l = layer[s.id]!
                let auto = WorkflowNodePosition(x: xs[l], y: nextY[l])
                positions[s.id] = auto
                nextY[l] += sizes[s.id]!.h + rowGap
                let eff = overrides[s.id] ?? auto
                right = max(right, eff.x + sizes[s.id]!.w)
                bottom = max(bottom, eff.y + sizes[s.id]!.h)
            }
            return (right, bottom)
        }

        let root = layoutScope(doc.spec.steps, originX: 0, originY: 0)
        _ = layoutScope(doc.spec.onError, originX: 0, originY: doc.spec.steps.isEmpty ? 0 : root.bottom + columnGap)
        for i in doc.spec.triggers.indices {
            positions["trigger:\(i)"] = WorkflowNodePosition(x: -(triggerSize.width + columnGap), y: Double(i) * (triggerSize.height + rowGap))
        }
        return (positions, sizes)
    }

    /// Deterministic layered layout ignoring `spec.layout`: a position for every step id (nested steps relative to their
    /// container) and every `trigger:<index>`.
    public static func autoLayout(_ doc: WorkflowDocument) -> [String: WorkflowNodePosition] {
        compute(doc, overrides: [:]).positions
    }
}

extension WorkflowDocument {
    /// The document with `spec.layout` replaced by the auto-layout of its steps (trigger positions are not stored).
    public func applyingAutoLayout() -> WorkflowDocument {
        var copy = self
        copy.spec.layout = WorkflowGraph.autoLayout(self).filter { !$0.key.hasPrefix("trigger:") }
        return copy
    }
}
