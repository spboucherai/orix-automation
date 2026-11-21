// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Sources/ORIXFeatureWorkflow/PreviewSupport.swift
// Description: Entry points for the screenshot harness and the tests of this package: generated graphs of any size and the individual screens around an existing studio model.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

package enum WorkflowStudioSamples {
    /// A valid layered workflow with `count` steps (tools, variables, transforms and checks wired by `needs`), used to
    /// measure and to show the canvas with large graphs. Deterministic.
    package static func layered(count: Int, id: String = "generated-graph", width: Int = 5) -> WorkflowDocument {
        var steps: [WorkflowStep] = []
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(max(1, n))) }
        for i in 0..<count {
            let layer = i / width
            var needs: [String] = []
            if layer > 0 {
                let start = (layer - 1) * width
                let previous = Array(start..<min(start + width, count))
                needs.append("s\(previous[next(previous.count)])")
                let second = "s\(previous[next(previous.count)])"
                if i % 3 == 0, !needs.contains(second) { needs.append(second) }
            }
            let kind: WorkflowStepKind
            switch i % 5 {
            case 0: kind = .tool(ToolStep(tool: "system.info"))
            case 1: kind = .set(SetStep(values: ["v\(i)": .int(i)]))
            case 2: kind = .transform(TransformStep(expression: "${{ \(i) * 2 }}"))
            case 3: kind = .tool(ToolStep(tool: "system.powerState"))
            default: kind = .verify(VerifyStep(assertions: [.truthy(.bool(true))]))
            }
            steps.append(WorkflowStep(id: "s\(i)", name: "Step \(i + 1)", needs: needs, kind: kind))
        }
        return WorkflowDocument(metadata: WorkflowMetadata(id: id, name: "Generated graph · \(count) steps", description: "Generated to exercise the canvas."),
                                spec: WorkflowSpec(triggers: [.manual], steps: steps))
    }
}

package extension WorkflowStudioModel {
    /// The whole studio around this model.
    @MainActor func studioView() -> some View { StudioContent(vm: self) }
    @MainActor func templateGalleryView() -> some View { TemplateGallery(vm: self) }
    @MainActor func permissionReviewView(dryRun: Bool = false) -> some View { PermissionReviewSheet(vm: self, kind: dryRun ? .dryRun : .run) }
    @MainActor func paletteView() -> some View { PaletteView(vm: self) }
    @MainActor func historyView() -> some View { HistoryPopover(vm: self) }
    @MainActor func generateView() -> some View { GenerateSheet(vm: self) }

    @MainActor func selectNodes(_ ids: Set<String>) { selection = ids }
    @MainActor func fitWhenShown(exactly: Bool = false) { fitExactly = exactly; canvasSize = .zero; needsFit = true }
    @MainActor func showRunPanel(_ show: Bool) { showDrawer = show }
    @MainActor var openWorkflowID: String? { workflowID }
    @MainActor var selectedRunStatus: RunStatus? { runStatus }
    @MainActor var selectedRunIsLive: Bool { runIsLive }
    @MainActor var stepStatuses: [String: StepStatus] { stepInfo.mapValues(\.status) }

    /// Saves a document as a workflow and opens it.
    @MainActor @discardableResult func install(_ document: WorkflowDocument) async -> Bool {
        await saveNew(WorkflowCodec.emit(document, format: .yaml), note: "Generated sample")
    }

    /// Follows a run started outside the toolbar.
    @MainActor func follow(runID: String) async { await attach(runID: runID); showDrawer = true }
    @MainActor func debuggerStepOver() { stepOver() }
    @MainActor func debuggerResume() { resumeRun() }
}
