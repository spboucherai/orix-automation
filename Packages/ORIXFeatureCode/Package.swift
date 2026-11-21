// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXFeatureCode/Package.swift
// Description: Code Studio feature: a native code editor with syntax highlighting, diagnostics and completion for workflow source, a line diff viewer, an inline assistant, and a script workbench that runs through policy.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXFeatureCode",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXFeatureCode", targets: ["ORIXFeatureCode"]),
        .executable(name: "orix-preview-code", targets: ["orix-preview-code"]),
    ],
    dependencies: [.package(path: "../ORIXAppUI")],
    targets: [
        .target(name: "ORIXFeatureCode", dependencies: [.product(name: "ORIXAppUI", package: "ORIXAppUI")]),
        .executableTarget(name: "orix-preview-code", dependencies: ["ORIXFeatureCode"]),
        .testTarget(name: "ORIXFeatureCodeTests", dependencies: ["ORIXFeatureCode"]),
    ],
    swiftLanguageModes: [.v6]
)
