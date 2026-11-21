// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXFeatureRuns/Package.swift
// Description: Feature package for the Dashboard, the Runs history (timeline, receipt, usage, console) and the Scheduler, plus a preview executable that renders every screen to PNG.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXFeatureRuns",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXFeatureRuns", targets: ["ORIXFeatureRuns"]),
        .executable(name: "orix-preview-runs", targets: ["orix-preview-runs"]),
    ],
    dependencies: [.package(path: "../ORIXAppUI")],
    targets: [
        .target(name: "ORIXFeatureRuns", dependencies: [.product(name: "ORIXAppUI", package: "ORIXAppUI")]),
        .executableTarget(name: "orix-preview-runs", dependencies: ["ORIXFeatureRuns", .product(name: "ORIXAppUI", package: "ORIXAppUI")]),
        .testTarget(name: "ORIXFeatureRunsTests", dependencies: ["ORIXFeatureRuns", .product(name: "ORIXAppUI", package: "ORIXAppUI")]),
    ],
    swiftLanguageModes: [.v6]
)
