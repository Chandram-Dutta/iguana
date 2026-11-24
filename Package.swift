// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Iguana",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IguanaCore"),
        .executableTarget(name: "iguana", dependencies: ["IguanaCore"]),
        .testTarget(name: "IguanaCoreTests", dependencies: ["IguanaCore"]),
        .testTarget(name: "IguanaAppTests", dependencies: ["iguana", "IguanaCore"]),
    ]
)
