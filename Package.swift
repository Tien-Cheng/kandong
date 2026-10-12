// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kandong",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "Kandong", targets: ["Kandong"]),
        .library(name: "KandongKit", targets: ["KandongKit"]),
    ],
    targets: [
        .target(name: "KandongKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Kandong", dependencies: ["KandongKit"]),
        .testTarget(
            name: "KandongKitTests",
            dependencies: ["KandongKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
