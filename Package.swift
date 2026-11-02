// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoREQ",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AutoREQ", targets: ["AutoREQ"]),
        .library(name: "AutoREQCore", targets: ["AutoREQCore"]),
    ],
    targets: [
        .target(name: "AutoREQCore"),
        .executableTarget(name: "AutoREQ", dependencies: ["AutoREQCore"]),
        .testTarget(name: "AutoREQCoreTests", dependencies: ["AutoREQCore"]),
    ],
    // The audio render closures cross threads freely. Swift 6 strict mode adds noise here, not safety.
    swiftLanguageModes: [.v5]
)
