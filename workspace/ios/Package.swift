// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GitLeafCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "GitLeafCore", targets: ["GitLeafCore"])
    ],
    targets: [
        .target(
            name: "GitLeafCore",
            path: "GitLeaf/Core",
            exclude: ["Transport/OBDTransports.swift"]
        ),
        .testTarget(
            name: "GitLeafCoreTests",
            dependencies: ["GitLeafCore"],
            path: "Tests/GitLeafCoreTests"
        )
    ]
)
