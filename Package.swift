// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kandong",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Kandong", targets: ["Kandong"]),
        .library(name: "KandongKit", targets: ["KandongKit"]),
    ],
    dependencies: [
        // Self-update (the app only; KandongKit and its tests don't use it).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "KandongKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Kandong", dependencies: ["KandongKit", .product(name: "Sparkle", package: "Sparkle")], resources: [.process("Resources")]),
        .testTarget(
            name: "KandongKitTests",
            dependencies: ["KandongKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
