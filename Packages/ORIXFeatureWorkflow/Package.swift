// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXFeatureWorkflow/Package.swift
// Description: Workflow Studio feature: the visual view of the workflow model (library, canvas, inspector, runs, history) and its screenshot harness.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXFeatureWorkflow",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXFeatureWorkflow", targets: ["ORIXFeatureWorkflow"]),
        .executable(name: "orix-preview-workflow", targets: ["orix-preview-workflow"]),
    ],
    dependencies: [.package(path: "../ORIXAppUI")],
    targets: [
        .target(name: "ORIXFeatureWorkflow", dependencies: [.product(name: "ORIXAppUI", package: "ORIXAppUI")]),
        .executableTarget(name: "orix-preview-workflow", dependencies: ["ORIXFeatureWorkflow"]),
        .testTarget(name: "ORIXFeatureWorkflowTests", dependencies: ["ORIXFeatureWorkflow"]),
    ],
    swiftLanguageModes: [.v6]
)
