// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GooseTailcat",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [
        .library(name: "GooseTailcat", targets: ["GooseTailcat"])
    ],
    targets: [
        // The gomobile-built tailcat (WireGuard/DERP) client. One xcframework
        // serves macOS + iOS, like GooseSSH's libssh2/OpenSSL artifacts.
        .binaryTarget(
            name: "Tailcat",
            path: "Artifacts/Tailcat.xcframework"
        ),
        .target(
            name: "GooseTailcat",
            dependencies: ["Tailcat"]
        ),
    ]
)
