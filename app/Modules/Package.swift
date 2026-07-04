// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ReplicouldKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "AccountManager", targets: ["AccountManager"]),
        .library(name: "API", targets: ["API"]),
        .library(name: "BlueprintsFeature", targets: ["BlueprintsFeature"]),
        .library(name: "DevicesFeature", targets: ["DevicesFeature"]),
        .library(name: "GameModels", targets: ["GameModels"]),
        .library(name: "GameServices", targets: ["GameServices"]),
        .library(name: "GameSync", targets: ["GameSync"]),
        .library(name: "LocationsFeature", targets: ["LocationsFeature"]),
        .library(name: "LoginFeature", targets: ["LoginFeature"]),
        .library(name: "MessagesFeature", targets: ["MessagesFeature"]),
        .library(name: "PrintingUI", targets: ["PrintingUI"]),
        .library(name: "PrintQueueFeature", targets: ["PrintQueueFeature"]),
        .library(name: "RawAPIFeature", targets: ["RawAPIFeature"]),
        .library(name: "ReplicantsFeature", targets: ["ReplicantsFeature"]),
        .library(name: "SidebarFeature", targets: ["SidebarFeature"]),
        .library(name: "StarMapFeature", targets: ["StarMapFeature"]),
        .library(name: "UI", targets: ["UI"]),
        .library(name: "UniverseModels", targets: ["UniverseModels"]),
        .library(name: "Utils", targets: ["Utils"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.8.2"),
        .package(url: "https://github.com/siteline/swiftui-introspect", exact: "26.0.1"),
    ],
    targets: [
        .target(
            name: "AccountManager",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "API",
                "GameModels",
                "GameServices",
            ],
            path: "AccountManager/Sources"
        ),
        .testTarget(
            name: "AccountManagerTests",
            dependencies: [
                "AccountManager",
                "API",
                "GameModels",
                "GameServices",
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "AccountManager/Tests"
        ),
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
            dependencies: [
                "API"
            ],
            path: "API/Tests"
        ),
        .target(
            name: "BlueprintsFeature",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "BlueprintsFeature/Sources"
        ),
        .testTarget(
            name: "BlueprintsFeatureTests",
            dependencies: [
                "BlueprintsFeature",
                "GameModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "BlueprintsFeature/Tests"
        ),
        .target(
            name: "DevicesFeature",
            dependencies: [
                "GameModels",
                "GameServices",
                "PrintingUI",
                "UI",
                "UniverseModels",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "DevicesFeature/Sources"
        ),
        .testTarget(
            name: "DevicesFeatureTests",
            dependencies: [
                "DevicesFeature",
                "GameModels",
                "GameServices",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "DevicesFeature/Tests"
        ),
        .target(
            name: "GameModels",
            dependencies: [
                "API",
                "Utils",
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameModels/Sources"
        ),
        .target(
            name: "GameServices",
            dependencies: [
                "API",
                "GameModels",
                "Utils",
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            path: "GameServices/Sources",
        ),
        .testTarget(
            name: "GameServicesTests",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameServices/Tests"
        ),
        .target(
            name: "GameSync",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameSync/Sources"
        ),
        .testTarget(
            name: "GameSyncTests",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                "GameSync",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameSync/Tests"
        ),
        .target(
            name: "LocationsFeature",
            dependencies: [
                "GameModels",
                "GameServices",
                "UI",
                "UniverseModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "LocationsFeature/Sources"
        ),
        .testTarget(
            name: "LocationsFeatureTests",
            dependencies: [
                "LocationsFeature",
                "GameModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "LocationsFeature/Tests"
        ),
        .target(
            name: "LoginFeature",
            dependencies: [
                "AccountManager",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            path: "LoginFeature/Sources",
        ),
        .testTarget(
            name: "LoginFeatureTests",
            dependencies: [
                "AccountManager",
                "LoginFeature",
            ],
            path: "LoginFeature/Tests"
        ),
        .target(
            name: "MessagesFeature",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "MessagesFeature/Sources"
        ),
        .testTarget(
            name: "MessagesFeatureTests",
            dependencies: [
                "GameModels",
                "MessagesFeature",
            ],
            path: "MessagesFeature/Tests"
        ),
        .target(
            name: "PrintingUI",
            dependencies: [
                "GameModels",
                "UI",
            ],
            path: "PrintingUI/Sources"
        ),
        .target(
            name: "PrintQueueFeature",
            dependencies: [
                "GameModels",
                "GameServices",
                "PrintingUI",
                "UI",
                "UniverseModels",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "PrintQueueFeature/Sources"
        ),
        .testTarget(
            name: "PrintQueueFeatureTests",
            dependencies: [
                "GameModels",
                "GameServices",
                "PrintQueueFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "PrintQueueFeature/Tests"
        ),
        .target(
            name: "RawAPIFeature",
            dependencies: [
                "UI",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SwiftUIIntrospect", package: "swiftui-introspect"),
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
            name: "ReplicantsFeature",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                "UI",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "ReplicantsFeature/Sources"
        ),
        .testTarget(
            name: "ReplicantsFeatureTests",
            dependencies: [
                "GameModels",
                "GameServices",
                "ReplicantsFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "ReplicantsFeature/Tests"
        ),
        .target(
            name: "SidebarFeature",
            dependencies: [
                "GameModels",
                "GameServices",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "SidebarFeature/Sources"
        ),
        .testTarget(
            name: "SidebarFeatureTests",
            dependencies: [
                "GameModels",
                "GameServices",
                "SidebarFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "SidebarFeature/Tests"
        ),
        .target(
            name: "StarMapFeature",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                "UI",
                "UniverseModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "StarMapFeature/Sources"
        ),
        .testTarget(
            name: "StarMapFeatureTests",
            dependencies: [
                "StarMapFeature",
                "UniverseModels",
            ],
            path: "StarMapFeature/Tests"
        ),
        .target(
            name: "UI",
            path: "UI/Sources",
            resources: [
                .copy("Colors.xcassets"),
                .copy("Symbols.xcassets"),
            ]
        ),
        .testTarget(
            name: "UITests",
            dependencies: [
                "UI"
            ],
            path: "UI/Tests"
        ),
        .target(
            name: "UniverseModels",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "UniverseModels/Sources"
        ),
        .testTarget(
            name: "UniverseModelsTests",
            dependencies: [
                "UniverseModels"
            ],
            path: "UniverseModels/Tests"
        ),
        .target(
            name: "Utils",
            path: "Utils/Sources",
        ),
    ],
    swiftLanguageModes: [.v6]
)
