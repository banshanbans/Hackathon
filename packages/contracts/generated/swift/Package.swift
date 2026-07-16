// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoloShotContracts",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SoloShotContracts", targets: ["SoloShotContracts"]),
    ],
    targets: [
        .target(
            name: "SoloShotContracts",
            path: "OpenAPIGenerated/Sources/SoloShotContracts"
        ),
        .testTarget(
            name: "SoloShotContractsTests",
            dependencies: ["SoloShotContracts"],
            path: "Tests/SoloShotContractsTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
