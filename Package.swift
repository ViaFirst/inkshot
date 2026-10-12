// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PSE",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PSE", path: "Sources/PSE")
    ]
)
