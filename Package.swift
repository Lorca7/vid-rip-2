// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VidRip",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VidRip",
            path: "Sources/VidRip"
        )
    ]
)
