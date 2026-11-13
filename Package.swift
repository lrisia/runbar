// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "runbar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "runbar", targets: ["runbar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "RunbarCore",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]
        ),
        .executableTarget(
            name: "runbar",
            dependencies: ["RunbarCore"]
        ),
        .testTarget(
            name: "RunbarCoreTests",
            dependencies: ["RunbarCore"]
        ),
    ]
)
