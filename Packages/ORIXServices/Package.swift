// swift-tools-version: 6.0
// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXServices/Package.swift
// Description      : Composition root shared by the app, the background agent
//                    and the orixctl command-line tool: wires store, policy,
//                    tools, providers, agent runtime, workflows and scheduler.
// Module           : Packages
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

import PackageDescription

let names = ["ORIXCore", "ORIXSecurity", "ORIXPersistence", "ORIXProviderAdapters", "ORIXToolRegistry", "ORIXAppleAutomation",
             "ORIXBrowserAutomation", "ORIXScheduler", "ORIXWorkflowEngine", "ORIXAgentRuntime", "ORIXSkills"]
let deps: [Target.Dependency] = names.map { .product(name: $0, package: $0) }

let package = Package(
    name: "ORIXServices",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXServices", targets: ["ORIXServices"]),
        .executable(name: "orixctl", targets: ["orixctl"]),
    ],
    dependencies: names.map { .package(path: "../\($0)") },
    targets: [
        .target(name: "ORIXServices", dependencies: deps),
        .executableTarget(name: "orixctl", dependencies: ["ORIXServices"] + deps),
        .testTarget(name: "ORIXServicesTests", dependencies: ["ORIXServices", .product(name: "ORIXTestingSupport", package: "ORIXCore")] + deps,
                    resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
