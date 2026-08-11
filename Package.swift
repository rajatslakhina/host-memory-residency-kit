// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HostMemoryResidencyKit",
    // Only the two platforms CI actually builds are declared. Adding watchOS or
    // tvOS here would be a claim this package has never compiled against.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "HostMemoryResidency", targets: ["HostMemoryResidency"]),
        .library(name: "HostMemoryResidencyUI", targets: ["HostMemoryResidencyUI"]),
    ],
    targets: [
        // Core imports Foundation only, so the whole decision layer is
        // buildable and testable on Linux CI.
        .target(
            name: "HostMemoryResidency",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "HostMemoryResidencyUI",
            dependencies: ["HostMemoryResidency"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HostMemoryResidencyTests",
            dependencies: ["HostMemoryResidency"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
