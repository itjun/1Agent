// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GooseSSH",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "GooseSSH", targets: ["GooseSSH"]),
    ],
    targets: [
        .binaryTarget(
            name: "COpenSSL",
            path: "Artifacts/COpenSSL.xcframework"
        ),
        .binaryTarget(
            name: "CLibSSH2",
            path: "Artifacts/CLibSSH2.xcframework"
        ),
        .target(
            name: "CGooseSSHSupport",
            dependencies: ["CLibSSH2"]
        ),
        .target(
            name: "GooseSSH",
            dependencies: ["CLibSSH2", "COpenSSL", "CGooseSSHSupport"]
        ),
        .testTarget(
            name: "GooseSSHTests",
            dependencies: ["GooseSSH"]
        ),
    ]
)
