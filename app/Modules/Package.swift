// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ReplicantKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "API", targets: ["API", "APITests"]),
        .library(name: "Utils", targets: ["Utils"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "API",
            dependencies: [
                "Utils",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            path: "API/Sources",
            plugins: [
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .testTarget(
            name: "APITests",
            dependencies: ["API"],
            path: "API/Tests"
        ),
        .target(
            name: "Utils",
            path: "Utils/Sources",
        ),
    ],
    swiftLanguageModes: [.v6]
)
