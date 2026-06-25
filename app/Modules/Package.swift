// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ReplicouldKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "API", targets: ["API"]),
        .library(name: "DependencyClients", targets: ["DependencyClients"]),
        .library(name: "LoginFeature", targets: ["LoginFeature"]),
        .library(name: "MessagesFeature", targets: ["MessagesFeature"]),
        .library(name: "RawAPIFeature", targets: ["RawAPIFeature"]),
        .library(name: "StarMapFeature", targets: ["StarMapFeature"]),
        .library(name: "UI", targets: ["UI"]),
        .library(name: "Utils", targets: ["Utils"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.6.0"),
        .package(url: "https://github.com/siteline/swiftui-introspect", exact: "26.0.1"),
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
            name: "DependencyClients",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "API",
            ],
            path: "DependencyClients/Sources",
        ),
        .target(
            name: "LoginFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "API",
                "DependencyClients",
                "UI",
            ],
            path: "LoginFeature/Sources",
        ),
        .testTarget(
            name: "LoginFeatureTests",
            dependencies: [
                "LoginFeature",
                "API",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            path: "LoginFeature/Tests"
        ),
        .target(
            name: "MessagesFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "API",
                "DependencyClients",
                "UI",
            ],
            path: "MessagesFeature/Sources"
        ),
        .testTarget(
            name: "MessagesFeatureTests",
            dependencies: ["MessagesFeature"],
            path: "MessagesFeature/Tests"
        ),
        .target(
            name: "RawAPIFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
                "UI",
                "Utils",
            ],
            path: "RawAPIFeature/Sources"
        ),
        .testTarget(
            name: "RawAPIFeatureTests",
            dependencies: [
                "RawAPIFeature"
            ],
            path: "RawAPIFeature/Tests"
        ),
        .target(
            name: "StarMapFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "API",
                "DependencyClients",
                "UI",
            ],
            path: "StarMapFeature/Sources"
        ),
        .testTarget(
            name: "StarMapFeatureTests",
            dependencies: ["StarMapFeature"],
            path: "StarMapFeature/Tests"
        ),
        .target(
            name: "UI",
            path: "UI/Sources",
            resources: [
                .copy("Colors.xcassets"),
            ]
        ),
        .target(
            name: "Utils",
            path: "Utils/Sources",
        ),
    ],
    swiftLanguageModes: [.v6]
)
