// swift-tools-version:5.9
import PackageDescription

// 外部依存0。CopyfitCoreはFoundationのみ（Linuxでもbuild/test可能）。
// CopyfitMacはmacOSでのみVision/CoreText/ImageIOを使い、他OSでは空実装になる。
let package = Package(
    name: "copyfit",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "copyfit", targets: ["copyfit"]),
        .library(name: "CopyfitCore", targets: ["CopyfitCore"]),
    ],
    targets: [
        .target(
            name: "CopyfitCore",
            resources: [.copy("Rulesets")]
        ),
        .target(name: "CopyfitMac", dependencies: ["CopyfitCore"]),
        .executableTarget(name: "copyfit", dependencies: ["CopyfitCore", "CopyfitMac"]),
        .testTarget(name: "CopyfitCoreTests", dependencies: ["CopyfitCore"], exclude: ["Golden"]),
        .testTarget(
            name: "CopyfitIntegrationTests",
            dependencies: ["CopyfitCore", "CopyfitMac"]
        ),
    ]
)
