// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXAgentRuntime/Package.swift
// Description: Provider-independent agent loop: plan, act through the tool invoker, observe, verify postconditions, produce receipts.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXAgentRuntime",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ORIXAgentRuntime", targets: ["ORIXAgentRuntime"])],
    dependencies: [.package(path: "../ORIXCore")],
    targets: [
        .target(name: "ORIXAgentRuntime", dependencies: [.product(name: "ORIXCore", package: "ORIXCore")]),
        .testTarget(name: "ORIXAgentRuntimeTests", dependencies: [
            "ORIXAgentRuntime", .product(name: "ORIXCore", package: "ORIXCore"),
            .product(name: "ORIXTestingSupport", package: "ORIXCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
