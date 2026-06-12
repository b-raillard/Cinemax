// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CinemaxKit",
    platforms: [
        .iOS(.v26),
        .tvOS(.v26)
    ],
    products: [
        .library(name: "CinemaxKit", targets: ["CinemaxKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jellyfin/jellyfin-sdk-swift.git", .upToNextMajor(from: "0.4.1")),
        .package(url: "https://github.com/kean/Nuke.git", .upToNextMajor(from: "12.8.0")),
        // Same package the SDK builds on — needed to hand-roll requests for
        // endpoints newer than the generated Paths (e.g. /Items/{id}/Collections).
        .package(url: "https://github.com/kean/Get", from: "2.1.6")
    ],
    targets: [
        .target(
            name: "CinemaxKit",
            dependencies: [
                .product(name: "JellyfinAPI", package: "jellyfin-sdk-swift"),
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke"),
                .product(name: "Get", package: "Get")
            ]
        ),
        .testTarget(
            name: "CinemaxKitTests",
            dependencies: ["CinemaxKit"]
        )
    ]
)
