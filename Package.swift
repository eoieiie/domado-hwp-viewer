// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HwpReader",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "HwpKit", targets: ["HwpKit"]),
        .executable(name: "hwpcli", targets: ["hwpcli"]),
        .executable(name: "HwpViewer", targets: ["HwpViewer"]),
        .library(name: "HwpSpotlight", type: .dynamic, targets: ["HwpSpotlight"]),
    ],
    targets: [
        .target(name: "HwpKit"),
        .executableTarget(name: "hwpcli", dependencies: ["HwpKit"]),
        .executableTarget(name: "HwpViewer", dependencies: ["HwpKit"]),
        .target(name: "HwpSpotlight", dependencies: ["HwpKit"]),
    ]
)
