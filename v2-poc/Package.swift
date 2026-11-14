// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "v2-poc",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "poc",
            path: "Sources/poc"
        ),
    ]
)
