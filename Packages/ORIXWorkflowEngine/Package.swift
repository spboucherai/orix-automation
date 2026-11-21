// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXWorkflowEngine/Package.swift
// Description: Workflow IR, YAML/JSON codec, expression language, validator, execution engine, graph projection and built-in automations.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXWorkflowEngine",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXWorkflowEngine", targets: ["ORIXWorkflowEngine"]),
    ],
    dependencies: [
        .package(path: "../ORIXCore"),
    ],
    targets: [
        .target(
            name: "ORIXWorkflowEngine",
            dependencies: [.product(name: "ORIXCore", package: "ORIXCore")],
            resources: [.copy("Resources/Examples")]
        ),
        .testTarget(
            name: "ORIXWorkflowEngineTests",
            dependencies: [
                "ORIXWorkflowEngine",
                .product(name: "ORIXCore", package: "ORIXCore"),
                .product(name: "ORIXTestingSupport", package: "ORIXCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
