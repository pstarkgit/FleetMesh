// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "DeviceSync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeviceSync", targets: ["DeviceSync"]),
    ],
    targets: [
        .executableTarget(
            name: "DeviceSync",
            path: "Sources/DeviceSync"
        ),
        .testTarget(
            name: "DeviceSyncTests",
            dependencies: ["DeviceSync"],
            path: "Tests/DeviceSyncTests"
        ),
    ]
)

