// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MageController",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "MageKit"),
        .executableTarget(
            name: "mage-helper",
            dependencies: ["MageKit"],
            path: "Sources/mage-helper"
        ),
        .executableTarget(
            name: "MageControllerApp",
            dependencies: ["MageKit"],
            path: "Sources/MageControllerApp"
        ),
    ]
)
