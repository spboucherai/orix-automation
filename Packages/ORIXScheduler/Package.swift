// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXScheduler/Package.swift
// Description: Cron and DST math, trigger models, durable queue engine with leases, FSEvents file watcher, system trigger monitor and LaunchAgent plist generation.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXScheduler",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXScheduler", targets: ["ORIXScheduler"]),
    ],
    dependencies: [
        .package(path: "../ORIXCore"),
    ],
    targets: [
        .target(name: "ORIXScheduler", dependencies: [.product(name: "ORIXCore", package: "ORIXCore")]),
        .testTarget(name: "ORIXSchedulerTests", dependencies: [
            "ORIXScheduler",
            .product(name: "ORIXCore", package: "ORIXCore"),
            .product(name: "ORIXTestingSupport", package: "ORIXCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
