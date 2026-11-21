// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/PreviewScreens.swift
// Description: Entry points the preview executable and the render tests use to open a screen in a given state (a detail tab, a scheduler tab, the editor sheet, a prepared console).
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import ORIXAppUI
import SwiftUI

/// Not part of the app's API: screens in a chosen state, for screenshots and render tests.
@_spi(Preview) @MainActor
public enum RunsPreviewScreens {
    /// `tab`: `timeline`, `receipt`, `usage` or `console`.
    public static func runs(tab: String) -> some View { RunsView(initialTab: RunTab(rawValue: tab) ?? .timeline) }
    /// `tab`: `schedules`, `agenda` or `queue`.
    public static func scheduler(tab: String) -> some View { SchedulerView(initialTab: SchedulerTab(rawValue: tab) ?? .schedules) }
    public static func scheduleEditor(existing: Schedule?, workflows: [WorkflowRow]) -> some View {
        ScheduleEditor(existing: existing, workflows: workflows) {}
    }
    public static func console(_ model: ConsoleModel) -> some View { ConsoleSurface(console: model) }
    public static func recovery(_ run: RunRecord) -> some View { RecoverySheet(run: run) }
}
