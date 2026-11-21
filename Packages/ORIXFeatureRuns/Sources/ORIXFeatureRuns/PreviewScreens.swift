// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXFeatureRuns/Sources/ORIXFeatureRuns/PreviewScreens.swift
// Description      : Entry points the preview executable and the render tests
//                    use to open a screen in a given state (a detail tab, a
//                    scheduler tab, the editor sheet, a prepared console).
// Module           : ORIXFeatureRuns
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
