// swift-tools-version: 6.0
// ORIX OS Automation
// File: Packages/ORIXProviderAdapters/Package.swift
// Description: LLM provider adapters (Anthropic, OpenAI, OpenRouter) over URLSession: SSE streaming, tool calls, usage, typed errors, retry, model registry.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import PackageDescription

let package = Package(
    name: "ORIXProviderAdapters",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ORIXProviderAdapters", targets: ["ORIXProviderAdapters"]),
    ],
    dependencies: [
        .package(path: "../ORIXCore"),
    ],
    targets: [
        .target(name: "ORIXProviderAdapters", dependencies: [.product(name: "ORIXCore", package: "ORIXCore")]),
        .testTarget(name: "ORIXProviderAdaptersTests", dependencies: [
            "ORIXProviderAdapters",
            .product(name: "ORIXCore", package: "ORIXCore"),
            .product(name: "ORIXTestingSupport", package: "ORIXCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
