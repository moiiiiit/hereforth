// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Hereforth",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hereforth", targets: ["hereforth"]),
        .executable(name: "HereforthApp", targets: ["HereforthApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "HereforthCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "hereforth", dependencies: ["HereforthCore"]),
        .executableTarget(name: "HereforthApp", dependencies: ["HereforthCore"]),
        .testTarget(name: "HereforthCoreTests", dependencies: ["HereforthCore"])
    ]
)
