// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "DeviceSync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeviceSync", targets: ["DeviceSync"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/awslabs/aws-sdk-swift.git",
            exact: "1.7.78"
        ),
    ],
    targets: [
        .executableTarget(
            name: "DeviceSync",
            dependencies: [
                .product(name: "AWSDynamoDB", package: "aws-sdk-swift"),
            ],
            path: "Sources/DeviceSync"
        ),
        .testTarget(
            name: "DeviceSyncTests",
            dependencies: ["DeviceSync"],
            path: "Tests/DeviceSyncTests"
        ),
    ]
)

