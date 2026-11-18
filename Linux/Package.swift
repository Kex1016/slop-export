// swift-tools-version:6.0
import PackageDescription

// The Linux desktop app (GTK 3) for Linux Mint and Ubuntu, D-016. It is its own package so the
// root package (SlopCore, the CLI, the macOS app) keeps building with no GTK headers installed.
// It reuses SlopCore from the root package; no export, upload or verify logic lives here.
//
// Build: apt-get install libgtk-3-dev libsecret-1-dev, then `swift build --package-path Linux`.
let package = Package(
    name: "slop-export-linux",
    products: [
        .executable(name: "slop-export-gtk", targets: ["slop-export-gtk"]),
    ],
    dependencies: [
        // Identity is the folder name of the repository checkout ("slop-export").
        .package(name: "slop-export", path: ".."),
    ],
    targets: [
        .systemLibrary(name: "CGtk", pkgConfig: "gtk+-3.0", providers: [.apt(["libgtk-3-dev"])]),
        .systemLibrary(name: "CSecret", pkgConfig: "libsecret-1", providers: [.apt(["libsecret-1-dev"])]),
        .target(
            name: "SlopLinux",
            dependencies: [
                .product(name: "SlopCore", package: "slop-export"),
                "CSecret",
            ]
        ),
        .executableTarget(
            name: "slop-export-gtk",
            dependencies: [
                "SlopLinux",
                "CGtk",
                .product(name: "SlopCore", package: "slop-export"),
            ]
        ),
        .testTarget(
            name: "SlopLinuxTests",
            dependencies: [
                "SlopLinux",
                .product(name: "SlopCore", package: "slop-export"),
            ]
        ),
    ]
)
