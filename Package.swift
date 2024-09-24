// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MijickCameraView",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(name: "MijickCameraView", targets: ["MijickCameraView"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Mijick/Timer", from: "1.0.1"),
        .package(url: "https://github.com/chaert-s/TiltKit.git", .upToNextMajor(from: "1.2.0"))
    ],
    targets: [
        .target(
            name: "MijickCameraView",
            dependencies: [
                .product(name: "MijickTimer", package: "Timer"),
                .product(name: "TiltKit", package: "TiltKit")
            ],
            path: "Sources"
        )
    ]
)
