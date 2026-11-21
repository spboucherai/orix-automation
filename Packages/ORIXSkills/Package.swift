// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXSkills/Package.swift
// Description: Skill packages: manifest, static analysis, confined test runs, versioned installation with rollback, and the tools that let an agent propose one.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
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
