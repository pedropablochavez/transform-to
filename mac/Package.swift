// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TransformTo",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "TransformTo", path: "Sources/TransformTo"),
    ]
)
