// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXServices/Package.swift
// Description: Composition root shared by the app, the background agent and the orixctl command-line tool: wires store, policy, tools, providers, agent runtime, workflows and scheduler.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
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
