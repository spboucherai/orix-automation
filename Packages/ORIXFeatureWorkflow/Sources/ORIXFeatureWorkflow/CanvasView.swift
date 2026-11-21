// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/CanvasView.swift
// Description: The interactive workflow canvas: pan, zoom, selection, marquee, dragging with grid snapping, connecting ports, breakpoints, keyboard navigation, live step overlays and the minimap.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

/// Receives scroll-wheel and trackpad scroll events while the pointer is over the canvas.
@MainActor
final class ScrollMonitor {
    private var token: Any?
    func start(_ handler: @escaping @MainActor (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { handler(event) } ? nil : event
        }
    }
    func stop() { if let token { NSEvent.removeMonitor(token) }; token = nil }
}

extension WorkflowStudioModel {
    /// The value the canvas draws from, for the current state.
    func scene(connection: (from: CGPoint, to: CGPoint)? = nil, marquee: CGRect? = nil) -> CanvasScene {
        var s = CanvasScene(graph: graph, geometry: geometry, viewport: viewport)
        s.selection = selection
        s.selectedEdge = selectedEdgeID
        s.dragging = draggingIDs
        s.translation = dragTranslation
        s.stepInfo = stepInfo
        s.waiting = Set(stepInfo.keys.filter(isWaitingApproval))
        s.pausedAt = Set(runState?.pausedAt ?? [])
        s.breakpoints = breakpoints
        s.errorSteps = Set(errors.compactMap(\.stepID))
        s.warningSteps = Set(warnings.compactMap(\.stepID))
        s.connection = connection
        s.marquee = marquee
        return s
    }
}

struct WorkflowCanvasView: View {
    @Bindable var vm: WorkflowStudioModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum DragMode {
        case pan(CGSize)
        case move
        case connect(node: String, port: String)
        case marquee(CGPoint)
    }

    @State private var mode: DragMode?
    @State private var connection: (from: CGPoint, to: CGPoint)?
    @State private var marquee: CGRect?
    @State private var hover: CGPoint?
    @State private var pinchBase: CGFloat?
    @State private var marqueeTool = false
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var monitor = ScrollMonitor()
    @FocusState private var focused: Bool
    @FocusState private var renameFocused: Bool

    var body: some View {
        GeometryReader { geo in
            let scene = vm.scene(connection: connection, marquee: marquee)
            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: false) { ctx, size in
                    GraphRenderer.draw(&ctx, size: size, scene: scene)
                }
                .accessibilityLabel(Text("Workflow canvas"))
                .accessibilityChildren {
                    ForEach(vm.graph.nodes) { n in
                        Button { vm.focus(step: n.id) } label: { Text(verbatim: "\(n.title), \(n.kind)") }
                            .accessibilityValue(Text(verbatim: vm.stepInfo[n.id].map { StepStyle.of($0.status).label } ?? ""))
                    }
                }

                liveOverlays(scene)
                if let id = renamingID, let f = vm.geometry.frames[id] { renameField(id, vm.viewport.toScreen(f)) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Theme.surfaceSunken)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .onTapGesture(coordinateSpace: .local) { tap($0) }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): hover = p
                case .ended: hover = nil
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: [.down, .repeat]) { key($0) }
            .contextMenu { contextMenu }
            .overlay(alignment: .bottomTrailing) { minimap(scene).padding(Theme.Space.m) }
            .overlay(alignment: .bottomLeading) { zoomControls.padding(Theme.Space.m) }
            .onAppear {
                vm.canvasSize = geo.size
                if vm.needsFit { vm.zoomToFit() }
                monitor.start { event in scroll(event) }
            }
            .onDisappear { monitor.stop() }
            .onChange(of: geo.size) { _, new in
                vm.canvasSize = new
                if vm.needsFit { vm.zoomToFit() }
            }
            .onChange(of: vm.needsFit) { _, needs in if needs { vm.zoomToFit() } }
            .accessibilityIdentifier("workflow.canvas")
        }
    }

    // MARK: Overlays

    /// Running steps get a real pulse and a ticking elapsed time; everything else is drawn by the canvas.
    @ViewBuilder private func liveOverlays(_ scene: CanvasScene) -> some View {
        let live = vm.stepInfo.filter { $0.value.status == .running }
        if vm.viewport.zoom >= 0.42 {
            ForEach(Array(live.keys).sorted(), id: \.self) { id in
                if let node = vm.graph.node(id), !node.isContainer, let f = vm.geometry.frame(id, dragging: vm.draggingIDs, by: vm.dragTranslation) {
                    let s = vm.viewport.toScreen(f)
                    let style = StepStyle.of(.running, waitingApproval: scene.waiting.contains(id))
                    PulseDot(color: style.color, active: true)
                        .scaleEffect(vm.viewport.zoom)
                        .position(x: s.minX + 31 * vm.viewport.zoom, y: s.maxY - 13 * vm.viewport.zoom)
                    if let start = live[id]?.startedAt {
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(Format.duration(max(0, context.date.timeIntervalSince(start))))
                                .font(.system(size: 10 * vm.viewport.zoom).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                        }
                        .position(x: s.maxX - 26 * vm.viewport.zoom, y: s.maxY - 13 * vm.viewport.zoom)
                    }
                }
            }
        }
    }

    private func renameField(_ id: String, _ frame: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(String(localized: "Name"), text: $renameText)
                .textFieldStyle(.roundedBorder).font(Theme.Font.bodyStrong)
                .focused($renameFocused)
                .onSubmit { commitRename(id) }
                .onExitCommand { renamingID = nil; focused = true }
                .accessibilityIdentifier("workflow.canvas.rename")
            if let renameError { Text(renameError).font(Theme.Font.caption).foregroundStyle(Theme.danger).padding(4).background(Theme.surface, in: RoundedRectangle(cornerRadius: 4)) }
        }
        .frame(width: max(180, frame.width - 20))
        .position(x: frame.midX, y: frame.minY + 20)
        .onAppear { renameFocused = true }
    }

    private func beginRename(_ id: String) {
        guard let step = vm.document?.step(id: id) else { return }
        renameText = step.name ?? ""
        renameError = nil
        renamingID = id
    }

    private func commitRename(_ id: String) {
        let t = renameText.trimmingCharacters(in: .whitespaces)
        if let refused = vm.setField(id, .name(t.isEmpty ? nil : t)) { renameError = refused; return }
        renamingID = nil
        focused = true
    }

    private func minimap(_ scene: CanvasScene) -> some View {
        let size = CGSize(width: 168, height: 112)
        return Canvas { ctx, s in GraphRenderer.drawMinimap(&ctx, size: s, scene: scene, canvasSize: vm.canvasSize) }
            .frame(width: size.width, height: size.height)
            .background(Theme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.strokeStrong))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                // Clicking or dragging in the minimap centres the view there.
                let mapping = GraphRenderer.minimapMapping(size: size, scene: scene, canvasSize: vm.canvasSize)
                let w = mapping.worldPoint(g.location)
                vm.viewport.offset = CGSize(width: vm.canvasSize.width / 2 - w.x * vm.viewport.zoom, height: vm.canvasSize.height / 2 - w.y * vm.viewport.zoom)
            })
            .accessibilityLabel(Text("Minimap"))
            .accessibilityHint(Text("Shows the whole workflow and the part in view. Click to move the view."))
            .accessibilityIdentifier("workflow.minimap")
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            iconButton("minus.magnifyingglass", "Zoom out") { vm.zoom(by: 1 / 1.25) }.keyboardShortcut("-", modifiers: .command)
            Button { vm.resetZoom() } label: {
                Text(verbatim: "\(Int((vm.viewport.zoom * 100).rounded())) %").font(Theme.Font.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary).frame(width: 44)
            }
            .buttonStyle(.plain).keyboardShortcut("0", modifiers: .command)
            .help(Text("Actual size")).accessibilityLabel(Text("Zoom to actual size"))
            iconButton("plus.magnifyingglass", "Zoom in") { vm.zoom(by: 1.25) }.keyboardShortcut("+", modifiers: .command)
            Divider().frame(height: 16)
            iconButton("arrow.up.left.and.arrow.down.right", "Zoom to fit") { vm.zoomToFit() }.keyboardShortcut("9", modifiers: .command)
            iconButton(marqueeTool ? "rectangle.dashed" : "hand.draw", marqueeTool ? "Drag selects an area. Click to make dragging move the view." : "Drag moves the view. Click to make dragging select an area (or hold Shift).") { marqueeTool.toggle() }
                .foregroundStyle(marqueeTool ? Theme.violet : Theme.textSecondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Theme.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.strokeStrong))
    }

    private func iconButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
            .help(Text(label)).accessibilityLabel(Text(label))
    }

    @ViewBuilder private var contextMenu: some View {
        let steps = vm.selectedStepIDs
        if steps.count == 1 {
            Button("Rename…") { beginRename(steps[0]) }
            Button(vm.breakpoints.contains(steps[0]) ? "Remove breakpoint" : "Add breakpoint") { vm.toggleBreakpoint(steps[0]) }
        }
        if !steps.isEmpty {
            Button("Duplicate") { vm.duplicateSelection() }
            Button("Group into parallel") { vm.groupSelectionIntoParallel() }
            Button("Wrap in for each") { vm.wrapSelectionInForeach() }
        }
        if !vm.selection.isEmpty || vm.selectedEdgeID != nil {
            Button("Delete", role: .destructive) { vm.removeSelection() }
            Divider()
        }
        Button("Add step…") { vm.showPalette = true }
        Button("Select all") { vm.selectAll() }
        Button("Tidy up layout") { vm.autoLayout() }
        Button("Zoom to fit") { vm.zoomToFit() }
    }

    // MARK: Gestures

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { g in
                focused = true
                let startWorld = vm.viewport.toWorld(g.startLocation)
                let world = vm.viewport.toWorld(g.location)
                if mode == nil { mode = begin(at: startWorld) }
                switch mode {
                case .pan(let base):
                    vm.viewport.offset = CGSize(width: base.width + g.translation.width, height: base.height + g.translation.height)
                case .move:
                    vm.dragTranslation = CGSize(width: CanvasGeometry.snap(g.translation.width / vm.viewport.zoom), height: CanvasGeometry.snap(g.translation.height / vm.viewport.zoom))
                case .connect(let node, let port):
                    guard let f = vm.geometry.frames[node] else { return }
                    connection = (vm.geometry.outputPoint(node: node, port: port, frame: f), world)
                case .marquee(let origin):
                    marquee = CGRect(x: min(origin.x, world.x), y: min(origin.y, world.y), width: abs(world.x - origin.x), height: abs(world.y - origin.y))
                case nil: break
                }
            }
            .onEnded { g in
                let world = vm.viewport.toWorld(g.location)
                switch mode {
                case .move:
                    let ids = vm.draggingIDs, t = vm.dragTranslation
                    vm.draggingIDs = []; vm.dragTranslation = .zero
                    vm.commitMove(ids, by: t)
                case .connect(let node, let port):
                    if let target = vm.geometry.node(at: world), target != node { vm.connect(from: node, port: port, to: target) }
                    connection = nil
                case .marquee:
                    if let m = marquee { vm.select(in: m, extend: NSEvent.modifierFlags.contains(.shift)) }
                    marquee = nil
                default: break
                }
                mode = nil
            }
    }

    private func begin(at world: CGPoint) -> DragMode {
        let flags = NSEvent.modifierFlags
        if let p = vm.geometry.outputPort(at: world, tolerance: 9 / min(1, vm.viewport.zoom)) { return .connect(node: p.node, port: p.port) }
        if let id = vm.geometry.node(at: world), !(flags.contains(.shift) && vm.graph.node(id)?.isContainer == true) {
            if !vm.selection.contains(id) { vm.selection = [id] }
            vm.draggingIDs = vm.selection
            return .move
        }
        if marqueeTool || flags.contains(.shift) || flags.contains(.option) { return .marquee(world) }
        return .pan(vm.viewport.offset)
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                let base = pinchBase ?? vm.viewport.zoom
                if pinchBase == nil { pinchBase = base }
                vm.viewport.setZoom(base * g.magnification, anchor: g.startLocation)
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func tap(_ location: CGPoint) {
        focused = true
        if renamingID != nil { renamingID = nil }
        let world = vm.viewport.toWorld(location)
        let extend = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
        if let id = vm.geometry.node(at: world), let f = vm.geometry.frames[id] {
            let bp = CanvasGeometry.breakpointCenter(f)
            if !id.hasPrefix("trigger:"), hypot(bp.x - world.x, bp.y - world.y) <= 9 { vm.toggleBreakpoint(id); return }
            if NSApp.currentEvent?.clickCount == 2, !id.hasPrefix("trigger:") { vm.selection = [id]; beginRename(id); return }
            // An edge drawn over a container wins over the container itself.
            if vm.graph.node(id)?.isContainer == true, let e = vm.geometry.edge(at: world, in: vm.graph, tolerance: 6 / vm.viewport.zoom) { vm.selection = []; vm.selectedEdgeID = e.id; return }
            vm.select(id, extend: extend)
            return
        }
        if let e = vm.geometry.edge(at: world, in: vm.graph, tolerance: 6 / vm.viewport.zoom) {
            vm.selection = []
            vm.selectedEdgeID = e.id
            return
        }
        if !extend { vm.clearSelection() }
    }

    /// Two-finger scroll pans; with Command (or a mouse wheel with Option) it zooms at the pointer.
    private func scroll(_ event: NSEvent) -> Bool {
        guard let hover, vm.document != nil else { return false }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)
            vm.viewport.zoom(by: exp(delta), anchor: hover)
        } else {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            vm.viewport.offset.width += event.scrollingDeltaX * k
            vm.viewport.offset.height += event.scrollingDeltaY * k
        }
        return true
    }

    // MARK: Keyboard

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard renamingID == nil else { return .ignored }
        let option = press.modifiers.contains(.option)
        switch press.key {
        case .leftArrow: if option { vm.nudgeSelection(dx: -1, dy: 0) } else { vm.moveSelection(.left) }; return .handled
        case .rightArrow: if option { vm.nudgeSelection(dx: 1, dy: 0) } else { vm.moveSelection(.right) }; return .handled
        case .upArrow: if option { vm.nudgeSelection(dx: 0, dy: -1) } else { vm.moveSelection(.up) }; return .handled
        case .downArrow: if option { vm.nudgeSelection(dx: 0, dy: 1) } else { vm.moveSelection(.down) }; return .handled
        case .delete, .deleteForward: vm.removeSelection(); return .handled
        case .escape: vm.clearSelection(); return .handled
        case .return:
            if let id = vm.selectedStepIDs.first, vm.selection.count == 1 { beginRename(id); return .handled }
            return .ignored
        default: break
        }
        if press.modifiers.contains(.command) {
            switch press.characters.lowercased() {
            case "a": vm.selectAll(); return .handled
            case "d": vm.duplicateSelection(); return .handled
            case "z": if press.modifiers.contains(.shift) { vm.redo() } else { vm.undo() }; return .handled
            default: break
            }
        }
        if press.characters == "b", let id = vm.selectedStepIDs.first, vm.selection.count == 1 { vm.toggleBreakpoint(id); return .handled }
        return .ignored
    }
}

/// A read-only drawing of a document's graph, fitted to its frame. Used for previews (generated workflows, templates).
struct GraphPreview: View {
    let document: WorkflowDocument
    var body: some View {
        let graph = WorkflowGraph(document: document)
        let geometry = CanvasGeometry(graph: graph)
        Canvas { ctx, size in
            var scene = CanvasScene(graph: graph, geometry: geometry)
            scene.interactive = false
            scene.viewport.fit(geometry.bounds, in: size, margin: 20)
            GraphRenderer.draw(&ctx, size: size, scene: scene)
        }
        .background(Theme.surfaceSunken)
        .accessibilityLabel(Text("Preview of the workflow graph: \(graph.nodes.count) nodes"))
    }
}
