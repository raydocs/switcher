// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Switcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
        .executable(name: "switcher", targets: ["switcher"]),
        .executable(name: "SwitcherApp", targets: ["SwitcherApp"]),
    ],
    targets: [
        .target(name: "SwitcherCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "switcher", dependencies: ["SwitcherCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "SwitcherApp", dependencies: ["SwitcherCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
