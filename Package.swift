// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AttribloomKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AttribloomKit", targets: ["AttribloomKit"]),
    ],
    targets: [
        .target(
            name: "AttribloomKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AttribloomKitTests",
            dependencies: ["AttribloomKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
