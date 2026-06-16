// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReplicantKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ReplicantKit", targets: ["ReplicantKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "ReplicantKit",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            plugins: [
                // Generates Types.swift / Client.swift at build time from
                // Sources/ReplicantKit/openapi.{yaml,json} + the config file.
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .testTarget(
            name: "ReplicantKitTests",
            dependencies: ["ReplicantKit"]
        ),
    ]
)
