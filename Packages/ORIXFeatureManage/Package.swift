// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXFeatureManage/Package.swift
// Description: Feature package for the management sections: Agents, Skills, Permissions, Settings, Onboarding and Watch & Learn, plus a preview executable that renders every screen to PNG.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXFeatureManage",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXFeatureManage", targets: ["ORIXFeatureManage"]),
        .executable(name: "orix-preview-manage", targets: ["orix-preview-manage"]),
    ],
    dependencies: [.package(path: "../ORIXAppUI")],
    targets: [
        .target(name: "ORIXFeatureManage", dependencies: [.product(name: "ORIXAppUI", package: "ORIXAppUI")]),
        .executableTarget(name: "orix-preview-manage", dependencies: ["ORIXFeatureManage"]),
        .testTarget(name: "ORIXFeatureManageTests", dependencies: ["ORIXFeatureManage"]),
    ],
    swiftLanguageModes: [.v6]
)
