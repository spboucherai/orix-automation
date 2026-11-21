// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXBrowserAutomation/Package.swift
// Description: WebKit browser automation: an ORIX-owned WKWebView driven through the DOM, with a host allowlist enforced on every navigation, and the browser.* tools.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXBrowserAutomation",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXBrowserAutomation", targets: ["ORIXBrowserAutomation"]),
    ],
    dependencies: [
        .package(path: "../ORIXCore"),
    ],
    targets: [
        .target(name: "ORIXBrowserAutomation", dependencies: [.product(name: "ORIXCore", package: "ORIXCore")]),
        .testTarget(name: "ORIXBrowserAutomationTests", dependencies: [
            "ORIXBrowserAutomation",
            .product(name: "ORIXCore", package: "ORIXCore"),
            .product(name: "ORIXTestingSupport", package: "ORIXCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
