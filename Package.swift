// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "disk-viewer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "dv", targets: ["dv"]),
        .executable(name: "dv-tests", targets: ["dv-tests"]),
        .library(name: "DiskScanCore", targets: ["DiskScanCore"])
    ],
    targets: [
        .target(
            name: "CDiskScan",
            dependencies: [],
            publicHeadersPath: "include"
        ),
        .target(
            name: "DiskScanCore",
            dependencies: ["CDiskScan"]
        ),
        .executableTarget(
            name: "dv",
            dependencies: ["DiskScanCore"]
        ),
        .executableTarget(
            name: "dv-tests",
            dependencies: ["DiskScanCore"],
            path: "Tests/dv-tests"
        )
    ]
)
