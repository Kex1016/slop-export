// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "slop-export",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SlopCore", targets: ["SlopCore"]),
        .executable(name: "slop-export", targets: ["slop-export"]),
    ],
    dependencies: [
        // Pinned exactly: 0.4.0 is the last release that supports macOS 14 and Swift 6.0 (D-003).
        .package(url: "https://github.com/apple/swift-nio-imap.git", exact: "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        .target(
            name: "SlopCore",
            dependencies: [
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "slop-export",
            dependencies: [
                "SlopCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SlopCoreTests",
            dependencies: ["SlopCore"]
        ),
    ]
)
