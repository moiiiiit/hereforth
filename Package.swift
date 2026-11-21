// swift-tools-version: 5.9
import Foundation
import PackageDescription

let binaryUpdater = ProcessInfo.processInfo.environment["HEREFORTH_BINARY_UPDATER"] == "1"
let appDependencies: [Target.Dependency] = binaryUpdater ? ["HereforthCore", "Sparkle"] : ["HereforthCore"]
let binaryTargets: [Target] = binaryUpdater ? [
    .binaryTarget(name: "Sparkle",
                  url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
                  checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a")
] : []

let package = Package(
    name: "Hereforth",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hereforth", targets: ["hereforth"]),
        .executable(name: "HereforthApp", targets: ["HereforthApp"])
    ],
    dependencies: [.package(url: "https://github.com/brokenhandsio/swift-webauthn.git", exact: "1.0.0-beta.4")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "HereforthCore", dependencies: ["CSQLite"], resources: [
            .copy("Resources/Humanizer"), .copy("Resources/PhoneWeb"), .copy("Resources/PasskeyLicenses.txt")
        ]),
        .executableTarget(name: "hereforth", dependencies: ["HereforthCore", .product(name: "WebAuthn", package: "swift-webauthn")]),
        .executableTarget(name: "HereforthApp", dependencies: appDependencies,
                          swiftSettings: binaryUpdater ? [.define("HEREFORTH_BINARY_UPDATER")] : [],
                          linkerSettings: binaryUpdater ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : []),
        .testTarget(name: "HereforthCoreTests", dependencies: ["HereforthCore"])
    ] + binaryTargets
)
