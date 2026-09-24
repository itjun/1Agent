// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GooseKit",
    // iOS 18 to match GooseTailcat's embedded tailcat xcframework (and GooseSSH).
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "GooseKit", targets: ["GooseKit"])
    ],
    dependencies: [
        .package(path: "../GooseTailcat")
    ],
    targets: [
        .target(
            name: "GooseKit",
            dependencies: [
                .product(name: "GooseTailcat", package: "GooseTailcat")
            ],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(name: "GooseKitTests", dependencies: ["GooseKit"])
    ],
    // Keep Swift 5 semantics; the bump to tools 6.0 is only for the iOS 18
    // platform literal, not a move to the Swift 6 language mode.
    swiftLanguageModes: [.v5]
)
