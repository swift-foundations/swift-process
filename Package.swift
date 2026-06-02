// swift-tools-version: 6.3.1

// ===----------------------------------------------------------------------===//
//
// This source file is part of the swift-process open source project
//
// Copyright (c) 2026 Coen ten Thije Boonkkamp and the swift-process project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// ===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "swift-process",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "Process", targets: ["Process"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-primitives/swift-path-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-kernel.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-posix.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-windows.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-strings.git", branch: "main"),
        .package(url: "https://github.com/swift-iso/swift-iso-9945.git", branch: "main")
    ],
    targets: [
        .target(
            name: "Process",
            dependencies: [
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "Path Primitives", package: "swift-path-primitives"),
                .product(
                    name: "POSIX Kernel",
                    package: "swift-posix",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                // Direct (POSIX-only) for the @_spi(Syscall) Poll.Entry.descriptor
                // accessor used by the v3 concurrent drain to mask out
                // closed slots via pollfd.fd = -1.
                .product(
                    name: "ISO 9945 Kernel Poll",
                    package: "swift-iso-9945",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS, .linux])
                ),
                .product(
                    name: "Windows Kernel Process",
                    package: "swift-windows",
                    condition: .when(platforms: [.windows])
                ),
                .product(
                    name: "Windows Kernel File",
                    package: "swift-windows",
                    condition: .when(platforms: [.windows])
                ),
                .product(name: "Strings", package: "swift-strings")
            ],
            path: "Sources/Process"
        ),
        .testTarget(
            name: "Process Tests",
            dependencies: [
                "Process"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    let ecosystem: [SwiftSetting] = [
        .strictMemorySafety(),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("LifetimeDependence"),
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("SuppressedAssociatedTypes"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("LifetimeDependence"),
    ]

    let package: [SwiftSetting] = []

    target.swiftSettings = (target.swiftSettings ?? []) + ecosystem + package
}
