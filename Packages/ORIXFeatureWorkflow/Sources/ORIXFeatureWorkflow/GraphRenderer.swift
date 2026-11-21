// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/GraphRenderer.swift
// Description: Immediate-mode drawing of a workflow graph (containers, edges, node cards, ports, live status) into a SwiftUI Canvas, with culling and level of detail so large graphs stay smooth.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

/// Symbol, accent and words for a node category.
struct CategoryStyle {
    let symbol: String
    let color: Color
    let label: LocalizedStringKey

    private static func rgb(_ light: UInt32, _ dark: UInt32) -> Color {
        func ns(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
        return Color(light: ns(light), dark: ns(dark))
    }
    static let teal = rgb(0x0E8F8A, 0x3CCFC8)
    static let amber = rgb(0xB36B00, 0xF2A93B)
    static let pink = rgb(0xC23B8E, 0xF27FC4)
    static let slate = rgb(0x5A6478, 0x9AA5BD)

    static func of(_ c: WorkflowGraph.Category) -> CategoryStyle {
        switch c {
        case .trigger: return .init(symbol: "bolt.fill", color: amber, label: "Trigger")
        case .tool: return .init(symbol: "wrench.and.screwdriver.fill", color: Theme.blue, label: "Tool")
        case .agent: return .init(symbol: "sparkles", color: Theme.violet, label: "Agent")
        case .logic: return .init(symbol: "arrow.triangle.branch", color: teal, label: "Logic")
        case .parallelism: return .init(symbol: "rectangle.split.3x1", color: teal, label: "Parallel")
        case .data: return .init(symbol: "cylinder.split.1x2", color: slate, label: "Data")
        case .control: return .init(symbol: "hand.raised.fill", color: pink, label: "Control")
        case .output: return .init(symbol: "square.and.arrow.up", color: Theme.success, label: "Output")
        case .error: return .init(symbol: "exclamationmark.triangle.fill", color: Theme.danger, label: "Error handler")
        }
    }

    /// A more specific symbol for a step kind, where one helps.
    static func symbol(kind: String, category: WorkflowGraph.Category) -> String {
        if category == .error { return of(.error).symbol }
        switch kind {
        case "condition": return "arrow.triangle.branch"
        case "switch": return "arrow.triangle.swap"
        case "foreach": return "repeat"
        case "loop": return "arrow.clockwise"
        case "transform": return "function"
        case "subworkflow": return "point.3.connected.trianglepath.dotted"
        case "set": return "equal.square"
        case "verify": return "checkmark.seal.fill"
        case "approval": return "hand.raised.fill"
        case "delay": return "timer"
        case "fail": return "xmark.octagon.fill"
        case "notify": return "bell.fill"
        case "output": return "square.and.arrow.up"
        default: return of(category).symbol
        }
    }
}

/// Colour, symbol and words for a step status. Never colour alone.
struct StepStyle {
    let color: Color
    let symbol: String
    let label: String
    let isActive: Bool

    static func of(_ s: StepStatus, waitingApproval: Bool = false) -> StepStyle {
        if waitingApproval { return .init(color: Theme.violet, symbol: "hand.raised.fill", label: String(localized: "Waiting for approval"), isActive: true) }
        switch s {
        case .pending: return .init(color: Theme.neutral, symbol: "circle.dotted", label: String(localized: "Pending"), isActive: false)
        case .running: return .init(color: Theme.blue, symbol: "play.circle.fill", label: String(localized: "Running"), isActive: true)
        case .succeeded: return .init(color: Theme.success, symbol: "checkmark.circle.fill", label: String(localized: "Succeeded"), isActive: false)
        case .simulated: return .init(color: Theme.info, symbol: "eye.circle.fill", label: String(localized: "Simulated"), isActive: false)
        case .skipped: return .init(color: Theme.neutral, symbol: "arrow.uturn.right.circle", label: String(localized: "Skipped"), isActive: false)
        case .failed: return .init(color: Theme.danger, symbol: "xmark.octagon.fill", label: String(localized: "Failed"), isActive: false)
        case .timedOut: return .init(color: Theme.danger, symbol: "clock.badge.exclamationmark", label: String(localized: "Timed out"), isActive: false)
        case .canceled: return .init(color: Theme.neutral, symbol: "stop.circle.fill", label: String(localized: "Canceled"), isActive: false)
        case .notApproved: return .init(color: Theme.warning, symbol: "hand.raised.slash.fill", label: String(localized: "Not approved"), isActive: false)
        case .blockedPermission: return .init(color: Theme.danger, symbol: "lock.trianglebadge.exclamationmark", label: String(localized: "Permission missing"), isActive: false)
        case .budgetExceeded: return .init(color: Theme.warning, symbol: "gauge.with.dots.needle.100percent", label: String(localized: "Budget exceeded"), isActive: false)
        case .recoveryRequired: return .init(color: Theme.warning, symbol: "bandage.fill", label: String(localized: "Needs recovery"), isActive: false)
        }
    }
}

/// Everything one frame of the canvas needs. A plain value so drawing can be timed in tests.
struct CanvasScene {
    var graph: WorkflowGraph
    var geometry: CanvasGeometry
    var viewport = CanvasViewport()
    var selection: Set<String> = []
    var selectedEdge: String?
    var dragging: Set<String> = []
    var translation: CGSize = .zero
    var stepInfo: [String: StepRunInfo] = [:]
    var waiting: Set<String> = []
    var pausedAt: Set<String> = []
    var breakpoints: Set<String> = []
    var errorSteps: Set<String> = []
    var warningSteps: Set<String> = []
    /// A connection being dragged, in world coordinates.
    var connection: (from: CGPoint, to: CGPoint)?
    var marquee: CGRect?
    /// Ports, breakpoint dots and the grid are drawn only on an editable canvas.
    var interactive = true
}

enum GraphRenderer {
    static func clipped(_ s: String, _ max: Int) -> String { s.count > max ? String(s.prefix(Swift.max(1, max - 1))) + "…" : s }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, scene: CanvasScene) {
        let vp = scene.viewport
        let zoom = vp.zoom
        let visible = vp.visibleWorld(in: size).insetBy(dx: -40, dy: -40)
        let showText = zoom >= 0.22
        let showDetail = zoom >= 0.42

        if scene.interactive, zoom >= 0.5 {
            // Dot grid, in screen space so the dots stay one point wide.
            let step = CanvasGeometry.grid * 2 * zoom
            var dots = Path()
            var x = vp.offset.width.truncatingRemainder(dividingBy: step)
            while x < size.width {
                var y = vp.offset.height.truncatingRemainder(dividingBy: step)
                while y < size.height { dots.addRect(CGRect(x: x, y: y, width: 1, height: 1)); y += step }
                x += step
            }
            ctx.fill(dots, with: .color(Theme.strokeStrong))
        }

        var world = ctx
        world.translateBy(x: vp.offset.width, y: vp.offset.height)
        world.scaleBy(x: zoom, y: zoom)

        var nodes: [String: WorkflowGraph.Node] = [:]
        for n in scene.graph.nodes { nodes[n.id] = n }
        func frame(_ id: String) -> CGRect? { scene.geometry.frame(id, dragging: scene.dragging, by: scene.translation) }

        // Containers first: groups drawn around their children.
        for id in scene.geometry.order {
            guard let n = nodes[id], n.isContainer, let f = frame(id), f.intersects(visible) else { continue }
            drawContainer(&world, n, f, scene: scene, showText: showText, showDetail: showDetail)
        }

        // Edges.
        var usedPorts = Set<String>()
        for e in scene.graph.edges {
            usedPorts.insert(e.from + "\u{1}" + e.fromPort)
            guard let c = scene.geometry.curve(for: e, dragging: scene.dragging, by: scene.translation) else { continue }
            let box = CGRect(x: min(c.start.x, c.end.x), y: min(c.start.y, c.end.y), width: abs(c.end.x - c.start.x), height: abs(c.end.y - c.start.y)).insetBy(dx: -40, dy: -8)
            guard box.intersects(visible) else { continue }
            drawEdge(&world, e, c, selected: scene.selectedEdge == e.id, zoom: zoom, showLabel: showDetail)
        }
        if let conn = scene.connection {
            var p = Path(); let c = CanvasGeometry.curve(from: conn.from, to: conn.to)
            p.move(to: c.start); p.addCurve(to: c.end, control1: c.c1, control2: c.c2)
            world.stroke(p, with: .color(Theme.violet), style: StrokeStyle(lineWidth: 2 / max(zoom, 0.5), lineCap: .round, dash: [6, 4]))
        }

        // Leaf nodes on top.
        for id in scene.geometry.order {
            guard let n = nodes[id], !n.isContainer, let f = frame(id), f.intersects(visible) else { continue }
            drawNode(&world, n, f, scene: scene, usedPorts: usedPorts, showText: showText, showDetail: showDetail)
        }

        if let m = scene.marquee {
            world.fill(Path(m), with: .color(Theme.violet.opacity(0.10)))
            world.stroke(Path(m), with: .color(Theme.violet), lineWidth: 1 / zoom)
        }
    }

    private static func symbol(_ ctx: inout GraphicsContext, _ name: String, color: Color, center: CGPoint, size: CGFloat) {
        var img = ctx.resolve(Image(systemName: name))
        img.shading = .color(color)
        let s = img.size
        guard s.width > 0, s.height > 0 else { return }
        let k = size / max(s.width, s.height)
        ctx.draw(img, in: CGRect(x: center.x - s.width * k / 2, y: center.y - s.height * k / 2, width: s.width * k, height: s.height * k))
    }

    private static func drawContainer(_ ctx: inout GraphicsContext, _ n: WorkflowGraph.Node, _ f: CGRect, scene: CanvasScene, showText: Bool, showDetail: Bool) {
        let style = CategoryStyle.of(n.category)
        let selected = scene.selection.contains(n.id)
        let shape = Path(roundedRect: f, cornerRadius: 14, style: .continuous)
        ctx.fill(shape, with: .color(style.color.opacity(0.06)))
        let info = scene.stepInfo[n.id]
        let status = info.map { StepStyle.of($0.status, waitingApproval: scene.waiting.contains(n.id)) }
        ctx.stroke(shape, with: .color(selected ? Theme.violet : (status?.color ?? style.color).opacity(0.55)), lineWidth: selected ? 2.5 : 1.2)
        guard showText else { return }
        symbol(&ctx, CategoryStyle.symbol(kind: n.kind, category: n.category), color: style.color, center: CGPoint(x: f.minX + 22, y: f.minY + 22), size: 14)
        let chars = Int((f.width - 60) / 6.6)
        ctx.draw(Text(clipped(n.title, max(6, chars / 2))).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text), at: CGPoint(x: f.minX + 38, y: f.minY + 8), anchor: .topLeading)
        if showDetail {
            ctx.draw(Text(clipped(n.subtitle, max(6, chars))).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary), at: CGPoint(x: f.minX + 38, y: f.minY + 24), anchor: .topLeading)
            if let status, let info {
                let text = status.label + (info.durationSeconds.map { " · " + Format.duration($0) } ?? "")
                ctx.draw(Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(status.color), at: CGPoint(x: f.maxX - 12, y: f.minY + 10), anchor: .topTrailing)
            }
        }
        if scene.interactive { drawPorts(&ctx, n, f, scene: scene, usedPorts: [], showLabels: false) }
        if scene.interactive, showDetail { drawBreakpoint(&ctx, n, f, scene: scene) }
    }

    private static func drawBreakpoint(_ ctx: inout GraphicsContext, _ n: WorkflowGraph.Node, _ f: CGRect, scene: CanvasScene) {
        guard n.category != .trigger else { return }
        let c = CanvasGeometry.breakpointCenter(f)
        let dot = Path(ellipseIn: CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
        if scene.breakpoints.contains(n.id) {
            ctx.fill(dot, with: .color(Theme.danger))
            if scene.pausedAt.contains(n.id) { ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(Theme.danger), lineWidth: 1.2) }
        } else {
            ctx.stroke(dot, with: .color(scene.pausedAt.contains(n.id) ? Theme.warning : Theme.strokeStrong), lineWidth: 1.2)
        }
    }

    private static func drawPorts(_ ctx: inout GraphicsContext, _ n: WorkflowGraph.Node, _ f: CGRect, scene: CanvasScene, usedPorts: Set<String>, showLabels: Bool) {
        let r = CanvasGeometry.portRadius
        func port(_ p: CGPoint, _ color: Color) {
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(Theme.surface))
            ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.5)
        }
        if !n.inputs.isEmpty { port(CanvasGeometry.inputPoint(f), Theme.strokeStrong) }
        for p in scene.geometry.outputPorts[n.id] ?? [] {
            let c = scene.geometry.outputPoint(node: n.id, port: p.id, frame: f)
            let color: Color = p.id == "error" ? Theme.danger : (p.id == "out" ? Theme.textTertiary : Theme.blue)
            port(c, color)
            if showLabels, p.id != "out", !usedPorts.contains(n.id + "\u{1}" + p.id) {
                ctx.draw(Text(clipped(p.label, 12)).font(.system(size: 9, weight: .medium)).foregroundStyle(color), at: CGPoint(x: c.x + 8, y: c.y), anchor: .leading)
            }
        }
    }

    private static func drawNode(_ ctx: inout GraphicsContext, _ n: WorkflowGraph.Node, _ f: CGRect, scene: CanvasScene, usedPorts: Set<String>, showText: Bool, showDetail: Bool) {
        let style = CategoryStyle.of(n.category)
        let selected = scene.selection.contains(n.id)
        let isTrigger = n.category == .trigger
        let shape = Path(roundedRect: f, cornerRadius: isTrigger ? 20 : 11, style: .continuous)
        let info = scene.stepInfo[n.id]
        let status = info.map { StepStyle.of($0.status, waitingApproval: scene.waiting.contains(n.id)) }
        if selected { ctx.fill(Path(roundedRect: f.insetBy(dx: -4, dy: -4), cornerRadius: isTrigger ? 24 : 15, style: .continuous), with: .color(Theme.violet.opacity(0.18))) }
        ctx.fill(shape, with: .color(Theme.surface))
        if !showText {
            // Far away: a tinted block per category is all that can be read.
            ctx.fill(shape, with: .color((status?.color ?? style.color).opacity(0.35)))
            ctx.stroke(shape, with: .color(selected ? Theme.violet : style.color.opacity(0.7)), lineWidth: selected ? 3 : 1.5)
            return
        }
        let border: Color = selected ? Theme.violet : (status.map { $0.color.opacity(0.75) } ?? Theme.strokeStrong)
        ctx.stroke(shape, with: .color(border), lineWidth: selected ? 2 : (status == nil ? 1 : 1.5))

        // Category tile.
        let tile = CGRect(x: f.minX + 10, y: f.minY + 10, width: 26, height: 26)
        ctx.fill(Path(roundedRect: tile, cornerRadius: 7, style: .continuous), with: .color(style.color.opacity(0.16)))
        symbol(&ctx, isTrigger ? style.symbol : CategoryStyle.symbol(kind: n.kind, category: n.category), color: style.color, center: CGPoint(x: tile.midX, y: tile.midY), size: 14)

        let hasMarker = scene.errorSteps.contains(n.id) || scene.warningSteps.contains(n.id)
        ctx.draw(Text(clipped(n.title, hasMarker ? 20 : 23)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text), at: CGPoint(x: f.minX + 44, y: f.minY + 9), anchor: .topLeading)
        if hasMarker {
            let isError = scene.errorSteps.contains(n.id)
            symbol(&ctx, isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill", color: isError ? Theme.danger : Theme.warning, center: CGPoint(x: f.maxX - 16, y: f.minY + 16), size: 12)
        }
        if showDetail {
            let sub = n.subtitle.isEmpty && isTrigger ? "" : n.subtitle
            ctx.draw(Text(clipped(sub, 26)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textSecondary), at: CGPoint(x: f.minX + 44, y: f.minY + 25), anchor: .topLeading)
            if !isTrigger {
                let rowY = f.maxY - 13
                if let status, let info {
                    if !status.isActive { symbol(&ctx, status.symbol, color: status.color, center: CGPoint(x: f.minX + 31, y: rowY), size: 11) }
                    let label = status.label + (info.instances > 1 ? " ×\(info.instances)" : "")
                    ctx.draw(Text(clipped(label, 22)).font(.system(size: 10, weight: .medium)).foregroundStyle(status.color), at: CGPoint(x: f.minX + 41, y: rowY), anchor: .leading)
                    if !status.isActive, let d = info.durationSeconds {
                        ctx.draw(Text(Format.duration(d)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textTertiary), at: CGPoint(x: f.maxX - 10, y: rowY), anchor: .trailing)
                    }
                } else {
                    ctx.draw(Text(style.label).font(.system(size: 10)).foregroundStyle(Theme.textTertiary), at: CGPoint(x: f.minX + 28, y: rowY), anchor: .leading)
                }
                if scene.interactive { drawBreakpoint(&ctx, n, f, scene: scene) }
            }
        }
        if scene.interactive { drawPorts(&ctx, n, f, scene: scene, usedPorts: usedPorts, showLabels: showDetail) }
    }

    private static func drawEdge(_ ctx: inout GraphicsContext, _ e: WorkflowGraph.Edge, _ c: CanvasGeometry.Curve, selected: Bool, zoom: CGFloat, showLabel: Bool) {
        var path = Path()
        path.move(to: c.start)
        path.addCurve(to: CGPoint(x: c.end.x - 6, y: c.end.y), control1: c.c1, control2: CGPoint(x: c.c2.x - 6, y: c.c2.y))
        let color: Color
        var dash: [CGFloat] = []
        switch e.kind {
        case .dependency: color = Theme.textSecondary
        case .trigger: color = CategoryStyle.amber
        case .branch: color = Theme.blue
        case .error: color = Theme.danger; dash = [6, 4]
        }
        let width: CGFloat = (selected ? 3 : 1.6) / max(zoom, 0.6)
        ctx.stroke(path, with: .color(selected ? Theme.violet : color.opacity(0.9)), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        var arrow = Path()
        arrow.move(to: CGPoint(x: c.end.x - 5, y: c.end.y))
        arrow.addLine(to: CGPoint(x: c.end.x - 13, y: c.end.y - 4.5))
        arrow.addLine(to: CGPoint(x: c.end.x - 13, y: c.end.y + 4.5))
        arrow.closeSubpath()
        ctx.fill(arrow, with: .color(selected ? Theme.violet : color))
        if showLabel, !e.label.isEmpty {
            let mid = c.point(0.5)
            let text = ctx.resolve(Text(clipped(e.label, 16)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color))
            let s = text.measure(in: CGSize(width: 200, height: 40))
            let box = CGRect(x: mid.x - s.width / 2 - 5, y: mid.y - s.height / 2 - 2, width: s.width + 10, height: s.height + 4)
            ctx.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Theme.canvas))
            ctx.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(color.opacity(0.5)), lineWidth: 0.8)
            ctx.draw(text, at: mid, anchor: .center)
        }
    }

    /// Overview drawing for the minimap: node blocks and the viewport rectangle.
    static func drawMinimap(_ ctx: inout GraphicsContext, size: CGSize, scene: CanvasScene, canvasSize: CGSize) {
        let mapping = minimapMapping(size: size, scene: scene, canvasSize: canvasSize)
        var nodes: [String: WorkflowGraph.Node] = [:]
        for n in scene.graph.nodes { nodes[n.id] = n }
        for id in scene.geometry.order {
            guard let n = nodes[id], let f = scene.geometry.frame(id, dragging: scene.dragging, by: scene.translation) else { continue }
            let r = mapping.rect(f)
            let style = CategoryStyle.of(n.category)
            let color = scene.stepInfo[id].map { StepStyle.of($0.status).color } ?? style.color
            if n.isContainer { ctx.stroke(Path(r), with: .color(color.opacity(0.6)), lineWidth: 0.6) }
            else { ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(scene.selection.contains(id) ? Theme.violet : color.opacity(0.75))) }
        }
        let view = mapping.rect(scene.viewport.visibleWorld(in: canvasSize)).intersection(CGRect(origin: .zero, size: size))
        if !view.isNull {
            ctx.fill(Path(view), with: .color(Theme.violet.opacity(0.10)))
            ctx.stroke(Path(view), with: .color(Theme.violet), lineWidth: 1.2)
        }
    }

    struct MinimapMapping {
        var scale: CGFloat
        var origin: CGPoint
        var world: CGRect
        func rect(_ r: CGRect) -> CGRect { CGRect(x: (r.minX - world.minX) * scale + origin.x, y: (r.minY - world.minY) * scale + origin.y, width: r.width * scale, height: r.height * scale) }
        func worldPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale + world.minX, y: (p.y - origin.y) / scale + world.minY) }
    }

    /// Maps the union of the graph and the visible area into the minimap.
    static func minimapMapping(size: CGSize, scene: CanvasScene, canvasSize: CGSize) -> MinimapMapping {
        var world = scene.geometry.bounds
        if world.width <= 0 || world.height <= 0 { world = CGRect(x: 0, y: 0, width: 400, height: 300) }
        world = world.insetBy(dx: -60, dy: -60)
        let scale = min(size.width / world.width, size.height / world.height)
        let origin = CGPoint(x: (size.width - world.width * scale) / 2, y: (size.height - world.height * scale) / 2)
        return MinimapMapping(scale: scale, origin: origin, world: world)
    }
}
