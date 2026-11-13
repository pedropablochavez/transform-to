// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TransformTo",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "TransformTo", path: "Sources/TransformTo"),
        // Smoke test for the built-in PPTX/XLSX → PDF renderer; CI feeds it sample files (see build.yml).
        .testTarget(name: "TransformToTests", dependencies: ["TransformTo"], path: "Tests/TransformToTests"),
    ]
)
