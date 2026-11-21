// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXFeatureChat/Package.swift
// Description: Agent Chat feature: sessions, composer, live streaming transcript with tool activity, plans, approvals, verification and receipts.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXFeatureChat",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXFeatureChat", targets: ["ORIXFeatureChat"]),
        .executable(name: "orix-preview-chat", targets: ["orix-preview-chat"]),
    ],
    dependencies: [.package(path: "../ORIXAppUI"), .package(path: "../ORIXCore")],
    targets: [
        .target(name: "ORIXFeatureChat", dependencies: [.product(name: "ORIXAppUI", package: "ORIXAppUI")]),
        .executableTarget(name: "orix-preview-chat", dependencies: ["ORIXFeatureChat"]),
        .testTarget(name: "ORIXFeatureChatTests", dependencies: ["ORIXFeatureChat", .product(name: "ORIXTestingSupport", package: "ORIXCore")]),
    ],
    swiftLanguageModes: [.v6]
)
