// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlideSVC",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SlideCore",
            targets: ["SlideCore"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "COpenSlide",
            path: "COpenSlide",
            pkgConfig: "openslide",
            providers: [
                .brew(["openslide"])
            ]
        ),
        .target(
            name: "SlideCore",
            dependencies: ["COpenSlide"],
            path: "Sources/SlideCore"
        ),
        .testTarget(
            name: "SlideCoreTests",
            dependencies: ["SlideCore"],
            path: "Tests/SlideCoreTests"
        ),
    ]
)
