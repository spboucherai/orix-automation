// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXCore/Package.swift
// Description: Shared contracts: JSON values and schemas, tool/provider/policy protocols, run models, redaction. No UI, no I/O beyond path resolution.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXCore", targets: ["ORIXCore"]),
        .library(name: "ORIXTestingSupport", targets: ["ORIXTestingSupport"]),
    ],
    targets: [
        .target(name: "ORIXCore"),
        .target(name: "ORIXTestingSupport", dependencies: ["ORIXCore"]),
        .testTarget(name: "ORIXCoreTests", dependencies: ["ORIXCore", "ORIXTestingSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
