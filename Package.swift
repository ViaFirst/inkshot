// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Inkshot",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Inkshot", path: "Sources/Inkshot")
    ]
)
