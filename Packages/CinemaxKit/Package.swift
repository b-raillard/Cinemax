// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CinemaxKit",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18)
    ],
    products: [
        .library(name: "CinemaxKit", targets: ["CinemaxKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", .upToNextMajor(from: "0.4.1")),
        .package(url: "https://github.com/kean/Nuke.git", .upToNextMajor(from: "12.8.0"))
    ],
    targets: [
        .target(
            name: "CinemaxKit",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke")
            ]
        ),
        .testTarget(
            name: "CinemaxKitTests",
            dependencies: ["CinemaxKit"]
        )
    ]
)
