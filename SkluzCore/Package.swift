// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SkluzCore",
    platforms: [.macOS("26.5")],
    products: [
        .library(name: "SkluzCore", targets: ["SkluzCore"])
    ],
    targets: [
        .target(name: "SkluzCore"),
        .testTarget(name: "SkluzCoreTests", dependencies: ["SkluzCore"])
    ]
)
