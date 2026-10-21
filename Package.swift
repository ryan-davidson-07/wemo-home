// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WemoHomeCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "WemoCore", targets: ["WemoCore"])],
    targets: [
        .target(name: "WemoCore"),
        .testTarget(name: "WemoCoreTests", dependencies: ["WemoCore"])
    ]
)
