// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/CanvasGeometry.swift
// Description: Geometry of the workflow canvas: absolute node frames, ports, edge curves, hit testing, viewport maths, grid snapping and keyboard navigation between connected nodes.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import CoreGraphics
import Foundation
import ORIXAppUI

/// World-space frames of a projected graph. Nested steps are stored relative to their container in the model; here
/// every frame is absolute.
struct CanvasGeometry: Sendable {
    static let grid: CGFloat = 20
    static let portRadius: CGFloat = 5

    private(set) var frames: [String: CGRect] = [:]
    private(set) var parents: [String: String] = [:]
    /// Node ids in drawing order (containers before their children).
    private(set) var order: [String] = []
    private(set) var outputPorts: [String: [WorkflowGraph.Port]] = [:]
    private(set) var bounds: CGRect = .zero

    init() {}

    init(graph: WorkflowGraph) {
        var byID: [String: WorkflowGraph.Node] = [:]
        for n in graph.nodes { byID[n.id] = n }
        var frames: [String: CGRect] = [:]
        func frame(_ id: String, depth: Int = 0) -> CGRect {
            if let f = frames[id] { return f }
            guard let n = byID[id] else { return .zero }
            var origin = CGPoint(x: n.x, y: n.y)
            if let p = n.parentID, depth < 32 {
                let pf = frame(p, depth: depth + 1)
                origin.x += pf.minX; origin.y += pf.minY
            }
            let f = CGRect(x: origin.x, y: origin.y, width: n.width, height: n.height)
            frames[id] = f
            return f
        }
        for n in graph.nodes {
            _ = frame(n.id)
            if let p = n.parentID { parents[n.id] = p }
            outputPorts[n.id] = n.outputs.filter { $0.id != "body" }
        }
        self.frames = frames
        // Containers first so children draw on top; depth = number of ancestors.
        func depth(_ id: String) -> Int { var d = 0; var c = id; while let p = parents[c], d < 32 { d += 1; c = p }; return d }
        order = graph.nodes.map(\.id).enumerated().sorted { a, b in
            let da = depth(a.element), db = depth(b.element)
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
        bounds = frames.values.reduce(CGRect.null) { $0.union($1) }
        if bounds.isNull { bounds = .zero }
    }

    func ancestors(of id: String) -> [String] {
        var out: [String] = []
        var c = id
        while let p = parents[c], out.count < 32 { out.append(p); c = p }
        return out
    }

    /// The frame of a node, shifted when it (or one of its containers) is being dragged.
    func frame(_ id: String, dragging: Set<String> = [], by translation: CGSize = .zero) -> CGRect? {
        guard let f = frames[id] else { return nil }
        guard !dragging.isEmpty, translation != .zero else { return f }
        if dragging.contains(id) || ancestors(of: id).contains(where: dragging.contains) { return f.offsetBy(dx: translation.width, dy: translation.height) }
        return f
    }

    static func inputPoint(_ f: CGRect) -> CGPoint { CGPoint(x: f.minX, y: f.midY) }

    /// Output ports are spread evenly on the right edge, in declaration order.
    func outputPoint(node id: String, port: String, frame f: CGRect) -> CGPoint {
        let ports = outputPorts[id] ?? []
        guard let i = ports.firstIndex(where: { $0.id == port }), ports.count > 1 else { return CGPoint(x: f.maxX, y: f.midY) }
        let usable = min(f.height - 24, CGFloat(ports.count - 1) * 18)
        let top = f.midY - usable / 2
        return CGPoint(x: f.maxX, y: top + usable * CGFloat(i) / CGFloat(ports.count - 1))
    }

    /// The deepest node under a world point.
    func node(at p: CGPoint) -> String? { order.last { frames[$0]?.contains(p) == true } }

    /// The output port under a world point, with a generous target.
    func outputPort(at p: CGPoint, tolerance: CGFloat) -> (node: String, port: String)? {
        for id in order.reversed() {
            guard let f = frames[id], f.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { continue }
            for port in outputPorts[id] ?? [] {
                let c = outputPoint(node: id, port: port.id, frame: f)
                if hypot(c.x - p.x, c.y - p.y) <= tolerance { return (id, port.id) }
            }
        }
        return nil
    }

    static func breakpointCenter(_ f: CGRect) -> CGPoint { CGPoint(x: f.minX + 14, y: f.maxY - 13) }

    static func snap(_ v: CGFloat) -> CGFloat { (v / grid).rounded() * grid }

    // MARK: Edges

    struct Curve: Sendable {
        var start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint
        func point(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * start.x + b * c1.x + c * c2.x + d * end.x, y: a * start.y + b * c1.y + c * c2.y + d * end.y)
        }
        func distance(to p: CGPoint) -> CGFloat {
            var best = CGFloat.greatestFiniteMagnitude
            for i in 0...24 { let q = point(CGFloat(i) / 24); best = min(best, hypot(q.x - p.x, q.y - p.y)) }
            return best
        }
    }

    static func curve(from a: CGPoint, to b: CGPoint) -> Curve {
        let dx = max(36, abs(b.x - a.x) / 2)
        return Curve(start: a, c1: CGPoint(x: a.x + dx, y: a.y), c2: CGPoint(x: b.x - dx, y: b.y), end: b)
    }

    func curve(for edge: WorkflowGraph.Edge, dragging: Set<String> = [], by translation: CGSize = .zero) -> Curve? {
        guard let a = frame(edge.from, dragging: dragging, by: translation), let b = frame(edge.to, dragging: dragging, by: translation) else { return nil }
        return Self.curve(from: outputPoint(node: edge.from, port: edge.fromPort, frame: a), to: Self.inputPoint(b))
    }

    func edge(at p: CGPoint, in graph: WorkflowGraph, tolerance: CGFloat) -> WorkflowGraph.Edge? {
        var best: (WorkflowGraph.Edge, CGFloat)?
        for e in graph.edges {
            guard let c = curve(for: e) else { continue }
            let box = CGRect(x: min(c.start.x, c.end.x), y: min(c.start.y, c.end.y), width: abs(c.end.x - c.start.x), height: abs(c.end.y - c.start.y))
                .insetBy(dx: -tolerance - 40, dy: -tolerance - 40)
            guard box.contains(p) else { continue }
            let d = c.distance(to: p)
            if d <= tolerance, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (e, d) }
        }
        return best?.0
    }
}

/// Pan and zoom of the canvas: `screen = world × zoom + offset`.
struct CanvasViewport: Equatable, Sendable {
    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 2.5
    var zoom: CGFloat = 1
    var offset: CGSize = .zero

    func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height) }
    func toWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.width) / zoom, y: (p.y - offset.height) / zoom) }
    func toScreen(_ r: CGRect) -> CGRect { CGRect(origin: toScreen(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom)) }
    func visibleWorld(in size: CGSize) -> CGRect {
        CGRect(origin: toWorld(.zero), size: CGSize(width: size.width / zoom, height: size.height / zoom))
    }

    /// Zooms by `factor` keeping the world point under `anchor` (screen) fixed.
    mutating func zoom(by factor: CGFloat, anchor: CGPoint) {
        let world = toWorld(anchor)
        zoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
        offset = CGSize(width: anchor.x - world.x * zoom, height: anchor.y - world.y * zoom)
    }

    mutating func setZoom(_ z: CGFloat, anchor: CGPoint) { zoom(by: z / zoom, anchor: anchor) }

    /// Shows all of `bounds` with a margin, never magnifying beyond 100 %.
    mutating func fit(_ bounds: CGRect, in size: CGSize, margin: CGFloat = 48) {
        guard bounds.width > 0, bounds.height > 0, size.width > margin * 2, size.height > margin * 2 else { return }
        let z = min((size.width - margin * 2) / bounds.width, (size.height - margin * 2) / bounds.height, 1)
        zoom = max(Self.minZoom, z)
        offset = CGSize(width: (size.width - bounds.width * zoom) / 2 - bounds.minX * zoom, height: (size.height - bounds.height * zoom) / 2 - bounds.minY * zoom)
    }

    /// Scrolls the least amount that brings `rect` (world) fully into view.
    mutating func reveal(_ rect: CGRect, in size: CGSize, margin: CGFloat = 24) {
        let r = toScreen(rect)
        if r.minX < margin { offset.width += margin - r.minX } else if r.maxX > size.width - margin { offset.width -= r.maxX - (size.width - margin) }
        if r.minY < margin { offset.height += margin - r.minY } else if r.maxY > size.height - margin { offset.height -= r.maxY - (size.height - margin) }
    }
}

enum CanvasDirection: Sendable { case left, right, up, down }

enum CanvasNavigation {
    /// The node the selection moves to with an arrow key. Right and left follow edges (successors, predecessors); up and
    /// down move to the nearest node above or below, preferring the same column. With nothing selected the first node is chosen.
    static func next(from current: String?, direction: CanvasDirection, graph: WorkflowGraph, geometry: CanvasGeometry) -> String? {
        guard let current, let frame = geometry.frames[current] else {
            return geometry.order.min { a, b in
                let fa = geometry.frames[a] ?? .zero, fb = geometry.frames[b] ?? .zero
                return fa.minX != fb.minX ? fa.minX < fb.minX : fa.minY < fb.minY
            }
        }
        func nearest(_ ids: [String]) -> String? {
            ids.min { a, b in
                let fa = geometry.frames[a] ?? .zero, fb = geometry.frames[b] ?? .zero
                return abs(fa.midY - frame.midY) < abs(fb.midY - frame.midY)
            }
        }
        switch direction {
        case .right:
            if let n = nearest(graph.edges.filter { $0.from == current }.map(\.to)) { return n }
            // A container leads into its first child.
            return nearest(graph.nodes.filter { $0.parentID == current }.map(\.id).sorted { (geometry.frames[$0]?.minX ?? 0) < (geometry.frames[$1]?.minX ?? 0) }.prefix(1).map { $0 })
        case .left:
            if let n = nearest(graph.edges.filter { $0.to == current }.map(\.from)) { return n }
            return geometry.parents[current]
        case .up, .down:
            let candidates = geometry.frames.filter { id, f in
                id != current && (direction == .up ? f.midY < frame.midY - 1 : f.midY > frame.midY + 1)
            }
            return candidates.min { a, b in
                func cost(_ f: CGRect) -> CGFloat { abs(f.midY - frame.midY) + abs(f.midX - frame.midX) * 3 }
                let ca = cost(a.value), cb = cost(b.value)
                return ca != cb ? ca < cb : a.key < b.key
            }?.key
        }
    }
}
