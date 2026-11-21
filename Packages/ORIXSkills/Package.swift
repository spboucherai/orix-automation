// swift-tools-version: 6.0
// =============================================================================
//                  SP BOUCHER | SOFTWARE & RESEARCH
//             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
// =============================================================================
//
// PROJECT METADATA
// -----------------------------------------------------------------------------
// Project          : ORIX OS Automation
// File             : Packages/ORIXSkills/Package.swift
// Description      : Skill packages: manifest, static analysis, confined test
//                    runs, versioned installation with rollback, and the tools
//                    that let an agent propose one.
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

let package = Package(
    name: "ORIXSkills",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ORIXSkills", targets: ["ORIXSkills"])],
    dependencies: [.package(path: "../ORIXCore"), .package(path: "../ORIXToolRegistry")],
    targets: [
        .target(name: "ORIXSkills", dependencies: [
            .product(name: "ORIXCore", package: "ORIXCore"), .product(name: "ORIXToolRegistry", package: "ORIXToolRegistry"),
        ]),
        .testTarget(name: "ORIXSkillsTests", dependencies: [
            "ORIXSkills", .product(name: "ORIXCore", package: "ORIXCore"), .product(name: "ORIXTestingSupport", package: "ORIXCore"),
            .product(name: "ORIXToolRegistry", package: "ORIXToolRegistry"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
