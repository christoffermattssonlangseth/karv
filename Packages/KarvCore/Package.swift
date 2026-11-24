// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KarvCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "KarvCore",
            targets: ["KarvCore"]
        )
    ],
    targets: [
        .target(
            name: "KarvCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "KarvCoreTests",
            dependencies: ["KarvCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
