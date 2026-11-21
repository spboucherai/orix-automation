// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXSecurity/Package.swift
// Description: Deny-by-default policy engine, Keychain secret storage and tamper-evident audit log.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXSecurity",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXSecurity", targets: ["ORIXSecurity"]),
    ],
    dependencies: [
        .package(path: "../ORIXCore"),
    ],
    targets: [
        .target(name: "ORIXSecurity", dependencies: [.product(name: "ORIXCore", package: "ORIXCore")]),
        .testTarget(name: "ORIXSecurityTests", dependencies: [
            "ORIXSecurity",
            .product(name: "ORIXCore", package: "ORIXCore"),
            .product(name: "ORIXTestingSupport", package: "ORIXCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
