// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NephosCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "NephosCore", targets: ["NephosCore"])],
    targets: [
        .target(name: "NephosCore", path: "Nephos/Core"),
        .testTarget(name: "NephosCoreTests", dependencies: ["NephosCore"], path: "Tests/NephosCoreTests"),
    ]
)
