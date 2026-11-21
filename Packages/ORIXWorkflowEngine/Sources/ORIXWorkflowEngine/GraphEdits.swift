// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Sources/ORIXWorkflowEngine/GraphEdits.swift
// Description: Edit operations of the visual editor. Each takes a document and returns a new, structurally valid document or throws.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore

public enum WorkflowEditError: Error, Sendable, Hashable, LocalizedError {
    case unknownStep(String)
    case duplicateID(String)
    case invalidID(String)
    case wouldCreateCycle(String)
    case differentScopes(String, String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unknownStep(let id): return "There is no step '\(id)'."
        case .duplicateID(let id): return "The id '\(id)' is already used; step ids are unique in the whole document."
        case .invalidID(let id): return "'\(id)' is not a valid id (letters, digits, '_' and '-', not starting with a digit or '-')."
        case .wouldCreateCycle(let m): return "This would create a dependency cycle: \(m)"
        case .differentScopes(let a, let b): return "'\(a)' and '\(b)' are not in the same step list; dependencies only link steps of one list."
        case .invalid(let m): return m
        }
    }
}

/// A single field of a step, for `WorkflowEdit.setField`.
public enum StepField: Sendable, Hashable {
    case name(String?)
    case when(String?)
    case timeoutSeconds(Double?)
    case continueOnError(Bool)
    case onError(String?)
    case retry(WorkflowRetryPolicy?)
    /// Sets (or removes, with nil) one argument of a tool step.
    case toolArgument(String, JSONValue?)
    case kind(WorkflowStepKind)
}

public enum WorkflowEdit {
    // MARK: Helpers

    static func nestedIDs(_ step: WorkflowStep) -> [String] {
        step.childScopes.flatMap { $0.steps.flatMap { [$0.id] + nestedIDs($0) } }
    }

    /// Refuses a structurally invalid result (invalid/duplicate ids, unknown `needs`, cycles).
    static func validated(_ doc: WorkflowDocument) throws -> WorkflowDocument {
        guard let e = WorkflowValidator.structuralErrors(doc).first else { return doc }
        switch e.code {
        case "dependency-cycle", "self-need": throw WorkflowEditError.wouldCreateCycle(e.message)
        case "duplicate-id": throw WorkflowEditError.duplicateID(e.stepID ?? "")
        case "invalid-id": throw WorkflowEditError.invalidID(e.stepID ?? "")
        default: throw WorkflowEditError.invalid(e.message)
        }
    }

    private static func checkNewID(_ id: String, in doc: WorkflowDocument, taken extra: Set<String> = []) throws {
        guard WorkflowValidator.isValidIdentifier(id) else { throw WorkflowEditError.invalidID(id) }
        if extra.contains(id) || doc.step(id: id) != nil { throw WorkflowEditError.duplicateID(id) }
    }

    private static func dropStaleLayout(_ doc: inout WorkflowDocument) {
        let ids = Set(doc.allSteps.map(\.step.id))
        doc.spec.layout = doc.spec.layout.filter { ids.contains($0.key) || $0.key.hasPrefix("trigger:") }
    }

    // MARK: Add / remove / rename

    /// Adds `step` to the root list, or to the body of container `inContainer` (`branch` names the parallel branch; a new
    /// branch is created when it does not exist). `index` defaults to the end of the list.
    public static func addStep(_ step: WorkflowStep, to doc: WorkflowDocument, inContainer: String? = nil, branch: String? = nil,
                               at index: Int? = nil) throws -> WorkflowDocument {
        var taken: Set<String> = []
        for id in [step.id] + nestedIDs(step) {
            try checkNewID(id, in: doc, taken: taken)
            taken.insert(id)
        }
        var out = doc
        func insert(_ list: inout [WorkflowStep]) { list.insert(step, at: max(0, min(index ?? list.count, list.count))) }
        guard let container = inContainer else {
            insert(&out.spec.steps)
            return try validated(out)
        }
        let found = try out.transformStep(container) { c in
            switch c.kind {
            case .foreach(var f): insert(&f.steps); c.kind = .foreach(f)
            case .loop(var l): insert(&l.steps); c.kind = .loop(l)
            case .parallel(var p):
                guard let name = branch else { throw WorkflowEditError.invalid("Adding a step to the parallel step '\(container)' needs a branch name.") }
                if let i = p.branches.firstIndex(where: { $0.name == name }) { insert(&p.branches[i].steps) }
                else { p.branches.append(ParallelBranch(name: name, steps: [step])) }
                c.kind = .parallel(p)
            default: throw WorkflowEditError.invalid("Step '\(container)' is a \(c.kind.name) step and cannot contain steps.")
            }
        }
        guard found else { throw WorkflowEditError.unknownStep(container) }
        return try validated(out)
    }

    /// Removes a step (and its nested steps), every structural reference to it (`needs`, branch lists, `onError`,
    /// `collect`, `stepSucceeded`) and its layout entries. Expressions that read `steps.<id>` are left for the validator to flag.
    public static func removeStep(_ id: String, from doc: WorkflowDocument) throws -> WorkflowDocument {
        guard let step = doc.step(id: id) else { throw WorkflowEditError.unknownStep(id) }
        let removed = Set([id] + nestedIDs(step))
        var out = doc
        out.transformList(containing: id) { $0.removeAll { $0.id == id } }
        out.transformEveryStep { s in s.transformStepReferences { removed.contains($0) ? nil : $0 } }
        for r in removed { out.spec.layout[r] = nil }
        return try validated(out)
    }

    /// Renames a step and rewrites `needs`, branch lists, `onError`, `collect`, `stepSucceeded`, the layout key and
    /// `steps.<old>` in every expression and template.
    public static func renameStep(_ old: String, to new: String, in doc: WorkflowDocument) throws -> WorkflowDocument {
        guard doc.step(id: old) != nil else { throw WorkflowEditError.unknownStep(old) }
        if old == new { return doc }
        try checkNewID(new, in: doc)
        var out = doc
        out.transformEveryStep { s in
            if s.id == old { s.id = new }
            s.transformStepReferences { $0 == old ? new : $0 }
            s.transformTexts { text, role, _ in
                WorkflowExpression.renamingStep(in: text, from: old, to: new, isExpressionField: role == .expression)
            }
        }
        if let p = out.spec.layout.removeValue(forKey: old) { out.spec.layout[new] = p }
        return try validated(out)
    }

    // MARK: Connections

    /// Makes `to` need `from`. Both must be in the same list. Connecting twice is a no-op.
    public static func connect(from: String, to: String, in doc: WorkflowDocument) throws -> WorkflowDocument {
        guard let a = doc.location(of: from) else { throw WorkflowEditError.unknownStep(from) }
        guard let b = doc.location(of: to) else { throw WorkflowEditError.unknownStep(to) }
        if from == to { throw WorkflowEditError.wouldCreateCycle("step '\(to)' cannot need itself") }
        guard a.scopeID == b.scopeID else { throw WorkflowEditError.differentScopes(from, to) }
        if b.step.needs.contains(from) { return doc }
        var out = doc
        out.transformStep(to) { $0.needs.append(from) }
        return try validated(out)
    }

    /// Removes `from` from `to.needs`. A missing connection is a no-op.
    public static func disconnect(from: String, to: String, in doc: WorkflowDocument) throws -> WorkflowDocument {
        guard doc.step(id: from) != nil else { throw WorkflowEditError.unknownStep(from) }
        guard doc.step(id: to) != nil else { throw WorkflowEditError.unknownStep(to) }
        var out = doc
        out.transformStep(to) { $0.needs.removeAll { $0 == from } }
        return try validated(out)
    }

    // MARK: Layout

    /// Stores a node position (`id` is a step id or `trigger:<index>`). Nested steps are positioned relative to their container.
    public static func moveNode(_ id: String, x: Double, y: Double, in doc: WorkflowDocument) throws -> WorkflowDocument {
        if id.hasPrefix("trigger:") {
            guard let i = Int(id.dropFirst("trigger:".count)), doc.spec.triggers.indices.contains(i) else { throw WorkflowEditError.unknownStep(id) }
        } else if doc.step(id: id) == nil { throw WorkflowEditError.unknownStep(id) }
        guard x.isFinite, y.isFinite else { throw WorkflowEditError.invalid("A node position must be finite.") }
        var out = doc
        out.spec.layout[id] = WorkflowNodePosition(x: x, y: y)
        return out
    }

    // MARK: Fields

    /// General step edit. The id cannot change here (use `renameStep`).
    public static func updateStep(_ id: String, in doc: WorkflowDocument, _ body: (inout WorkflowStep) throws -> Void) throws -> WorkflowDocument {
        var out = doc
        var changedID: String?
        let found = try out.transformStep(id) { s in
            try body(&s)
            if s.id != id { changedID = s.id }
        }
        guard found else { throw WorkflowEditError.unknownStep(id) }
        if let changedID { throw WorkflowEditError.invalid("updateStep cannot change the id ('\(id)' → '\(changedID)'); use renameStep.") }
        dropStaleLayout(&out)
        return try validated(out)
    }

    public static func setField(_ id: String, _ field: StepField, in doc: WorkflowDocument) throws -> WorkflowDocument {
        if case .onError(let h?) = field {
            guard let a = doc.location(of: id) else { throw WorkflowEditError.unknownStep(id) }
            guard let b = doc.location(of: h) else { throw WorkflowEditError.unknownStep(h) }
            if h == id { throw WorkflowEditError.invalid("A step cannot be its own onError handler.") }
            guard a.scopeID == b.scopeID else { throw WorkflowEditError.differentScopes(id, h) }
        }
        return try updateStep(id, in: doc) { s in
            switch field {
            case .name(let v): s.name = v
            case .when(let v): s.when = v
            case .timeoutSeconds(let v): s.timeoutSeconds = v
            case .continueOnError(let v): s.continueOnError = v
            case .onError(let v): s.onError = v
            case .retry(let v): s.retry = v
            case .toolArgument(let key, let value):
                guard case .tool(var t) = s.kind else { throw WorkflowEditError.invalid("Step '\(id)' is not a tool step; it has no 'with' arguments.") }
                t.arguments[key] = value
                s.kind = .tool(t)
            case .kind(let k): s.kind = k
            }
        }
    }

    // MARK: Duplicate

    /// Copies a step right after the original. The copy and its nested steps get fresh ids (`<id>-copy`, `<id>-copy2`, …);
    /// references between the copied nested steps follow the new ids. Layout is offset by (+40, +40).
    public static func duplicateStep(_ id: String, in doc: WorkflowDocument, newID: String? = nil) throws -> WorkflowDocument {
        guard let original = doc.step(id: id) else { throw WorkflowEditError.unknownStep(id) }
        var taken = Set(doc.allSteps.map(\.step.id))
        func fresh(_ base: String) -> String {
            var candidate = "\(base)-copy"
            var n = 2
            while taken.contains(candidate) { candidate = "\(base)-copy\(n)"; n += 1 }
            taken.insert(candidate)
            return candidate
        }
        var map: [String: String] = [:]
        if let newID {
            try checkNewID(newID, in: doc)
            taken.insert(newID)
            map[id] = newID
        } else { map[id] = fresh(id) }
        for nested in nestedIDs(original) { map[nested] = fresh(nested) }
        let nestedMap = map.filter { $0.key != id }
        func remap(_ s: WorkflowStep, top: Bool) -> WorkflowStep {
            var s = s
            s.mapChildLists { $0.map { remap($0, top: false) } }
            s.id = map[s.id] ?? s.id
            // The copy keeps its outside dependencies; only references to copied nested steps move.
            s.transformStepReferences { nestedMap[$0] ?? $0 }
            s.transformTexts { text, role, _ in
                var t = text
                for (o, n) in nestedMap.sorted(by: { $0.key < $1.key }) {
                    t = WorkflowExpression.renamingStep(in: t, from: o, to: n, isExpressionField: role == .expression)
                }
                return t
            }
            return s
        }
        let copy = remap(original, top: true)
        var out = doc
        out.transformList(containing: id) { list in
            let i = list.firstIndex { $0.id == id } ?? list.count - 1
            list.insert(copy, at: i + 1)
        }
        for (o, n) in map {
            guard let p = doc.spec.layout[o] else { continue }
            out.spec.layout[n] = o == id ? WorkflowNodePosition(x: p.x + 40, y: p.y + 40) : p
        }
        return try validated(out)
    }

    // MARK: Grouping

    /// Replaces `ids` (steps of one list) by a container built by `make` from the members, rewiring dependencies.
    private static func group(_ ids: [String], containerID: String, in doc: WorkflowDocument,
                              make: ([WorkflowStep]) -> WorkflowStepKind) throws -> WorkflowDocument {
        guard let firstID = ids.first else { throw WorkflowEditError.invalid("Select at least one step.") }
        guard Set(ids).count == ids.count else { throw WorkflowEditError.invalid("A step is selected twice.") }
        guard let first = doc.location(of: firstID) else { throw WorkflowEditError.unknownStep(firstID) }
        for id in ids.dropFirst() {
            guard let l = doc.location(of: id) else { throw WorkflowEditError.unknownStep(id) }
            guard l.scopeID == first.scopeID else { throw WorkflowEditError.differentScopes(firstID, id) }
        }
        try checkNewID(containerID, in: doc)
        let selected = Set(ids)
        var out = doc
        try out.transformList(containing: firstID) { list in
            var members = list.filter { selected.contains($0.id) }
            // Branch lists and error routes cannot cross a container boundary.
            for s in list {
                let links = s.gatedStepIDs + (s.onError.map { [$0] } ?? [])
                for target in links where selected.contains(s.id) != selected.contains(target) {
                    throw WorkflowEditError.invalid("'\(s.id)' routes to '\(target)' through a branch or onError; both must be inside or outside the group.")
                }
            }
            var outside: [String] = []
            for i in members.indices {
                for n in members[i].needs where !selected.contains(n) && !outside.contains(n) { outside.append(n) }
                members[i].needs.removeAll { !selected.contains($0) }
            }
            let container = WorkflowStep(id: containerID, needs: outside, kind: make(members))
            let at = list.firstIndex { selected.contains($0.id) } ?? 0
            list.removeAll { selected.contains($0.id) }
            list.insert(container, at: min(at, list.count))
            for i in list.indices where list[i].id != containerID {
                var needs: [String] = []
                for n in list[i].needs {
                    let mapped = selected.contains(n) ? containerID : n
                    if !needs.contains(mapped) { needs.append(mapped) }
                }
                list[i].needs = needs
            }
        }
        let anchor = ids.compactMap { doc.spec.layout[$0] }.first
        for id in ids { out.spec.layout[id] = nil }
        if let anchor { out.spec.layout[containerID] = anchor }
        return try validated(out)
    }

    /// Groups steps of one list into a `parallel` step. Members linked by `needs` (or by a branch/onError route) stay in
    /// the same branch, named after its first step. The container inherits the members' outside `needs`; outside steps
    /// that needed a member now need the container.
    public static func groupIntoParallel(_ ids: [String], containerID: String, in doc: WorkflowDocument) throws -> WorkflowDocument {
        try group(ids, containerID: containerID, in: doc) { members in
            let set = Set(members.map(\.id))
            var parent: [String: String] = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.id) })
            func find(_ x: String) -> String { var x = x; while let p = parent[x], p != x { x = p }; return x }
            for m in members {
                for other in m.needs + m.gatedStepIDs + (m.onError.map { [$0] } ?? []) where set.contains(other) {
                    let a = find(m.id), b = find(other)
                    if a != b { parent[a] = b }
                }
            }
            var branches: [ParallelBranch] = []
            var index: [String: Int] = [:]
            for m in members {
                let root = find(m.id)
                if let i = index[root] { branches[i].steps.append(m) }
                else { index[root] = branches.count; branches.append(ParallelBranch(name: m.id, steps: [m])) }
            }
            return .parallel(ParallelStep(branches: branches))
        }
    }

    /// Wraps steps of one list in a `foreach` over `items` (an expression). Members keep their internal `needs`.
    public static func wrapInForeach(_ ids: [String], containerID: String, items: String, itemName: String = "item",
                                     in doc: WorkflowDocument) throws -> WorkflowDocument {
        guard WorkflowValidator.isValidName(itemName), !["params", "vars", "steps", "env", "index", "loop", "error", "true", "false", "null"].contains(itemName) else {
            throw WorkflowEditError.invalid("'\(itemName)' is not a usable loop variable name.")
        }
        return try group(ids, containerID: containerID, in: doc) { members in
            .foreach(ForeachStep(items: .string(items), itemName: itemName, steps: members))
        }
    }

    // MARK: Reorder

    /// Moves a step to `index` inside its own list (clamped).
    public static func reorder(_ id: String, to index: Int, in doc: WorkflowDocument) throws -> WorkflowDocument {
        var out = doc
        let found = out.transformList(containing: id) { list in
            guard let i = list.firstIndex(where: { $0.id == id }) else { return }
            let step = list.remove(at: i)
            list.insert(step, at: max(0, min(index, list.count)))
        }
        guard found else { throw WorkflowEditError.unknownStep(id) }
        return try validated(out)
    }
}
