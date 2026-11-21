// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXToolRegistry/Package.swift
// Description: Tool registry, the ToolExecutor pipeline, the confined ProcessRunner and the built-in filesystem/shell/git/http/documents/python/script/system tools.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXToolRegistry",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXToolRegistry", targets: ["ORIXToolRegistry"]),
    ],
    dependencies: [
        .package(path: "../ORIXCore"),
    ],
    targets: [
        .target(name: "ORIXToolRegistry", dependencies: [.product(name: "ORIXCore", package: "ORIXCore")]),
        .testTarget(name: "ORIXToolRegistryTests", dependencies: [
            "ORIXToolRegistry",
            .product(name: "ORIXCore", package: "ORIXCore"),
            .product(name: "ORIXTestingSupport", package: "ORIXCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
