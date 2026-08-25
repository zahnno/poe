// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Poe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Poe",
            path: "Sources/Poe"
        )
    ]
)
