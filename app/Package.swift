// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchDot",
    platforms: [.macOS(.v13), .iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "WatchDotCore", targets: ["WatchDotCore"])],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git",
                 revision: "2b5256c29ff4e20f2a0d5ee863b62b1a22144434")
    ],
    targets: [
        .target(name: "WatchDotCore", dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")]),
        .testTarget(name: "WatchDotCoreTests", dependencies: ["WatchDotCore"])
    ]
)
