// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Package.swift
// Description: macOS automation tools: AppleScript/JXA, Accessibility, screen capture/OCR/compare, app control, clipboard, notifications, permission status, Watch & Learn recorder.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXAppleAutomation",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXAppleAutomation", targets: ["ORIXAppleAutomation"]),
    ],
    dependencies: [
        .package(path: "../ORIXCore"),
    ],
    targets: [
        .target(name: "ORIXAppleAutomation", dependencies: [.product(name: "ORIXCore", package: "ORIXCore")]),
        .testTarget(name: "ORIXAppleAutomationTests", dependencies: [
            "ORIXAppleAutomation",
            .product(name: "ORIXCore", package: "ORIXCore"),
            .product(name: "ORIXTestingSupport", package: "ORIXCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
