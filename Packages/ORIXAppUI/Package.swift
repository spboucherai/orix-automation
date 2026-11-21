// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXAppUI/Package.swift
// Description: Shared UI layer: design system, the observable app model over ORIXServices, approval and plan sheets, and a harness that renders any view to a PNG.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXAppUI",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ORIXAppUI", targets: ["ORIXAppUI"])],
    dependencies: ["ORIXCore", "ORIXServices", "ORIXAgentRuntime", "ORIXWorkflowEngine", "ORIXScheduler", "ORIXSkills", "ORIXPersistence", "ORIXSecurity", "ORIXAppleAutomation", "ORIXProviderAdapters", "ORIXToolRegistry"].map { .package(path: "../\($0)") },
    targets: [
        .target(name: "ORIXAppUI", dependencies: ["ORIXCore", "ORIXServices", "ORIXAgentRuntime", "ORIXWorkflowEngine", "ORIXScheduler", "ORIXSkills",
                                                  "ORIXPersistence", "ORIXSecurity", "ORIXAppleAutomation", "ORIXProviderAdapters", "ORIXToolRegistry"]
            .map { .product(name: $0, package: $0) }),
        .testTarget(name: "ORIXAppUITests", dependencies: ["ORIXAppUI"]),
    ],
    swiftLanguageModes: [.v6]
)
