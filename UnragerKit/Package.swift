// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UnragerKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "UnragerKit", targets: ["UnragerKit"])
    ],
    targets: [
        .target(
            name: "UnragerKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "UnragerKitTests",
            dependencies: ["UnragerKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
