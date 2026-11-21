// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXPersistence/Package.swift
// Description: SQLite-backed store for runs, events, receipts, workflows, documents, grants and leases, shared by the app and its background agent.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXPersistence",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXPersistence", targets: ["ORIXPersistence"]),
    ],
    dependencies: [
        .package(path: "../ORIXCore"),
    ],
    targets: [
        .target(
            name: "ORIXPersistence",
            dependencies: [.product(name: "ORIXCore", package: "ORIXCore")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "ORIXPersistenceTests", dependencies: [
            "ORIXPersistence",
            .product(name: "ORIXCore", package: "ORIXCore"),
            .product(name: "ORIXTestingSupport", package: "ORIXCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
