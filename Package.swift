// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NapeHUD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NapeHUD",
            path: "Sources/NapeHUD"
        )
    ]
)
