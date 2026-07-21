// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Modules",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "AccountFeature", targets: ["AccountFeature"]),
        .library(name: "AccountManager", targets: ["AccountManager"]),
        .library(name: "API", targets: ["API"]),
        .library(name: "BlueprintsFeature", targets: ["BlueprintsFeature"]),
        .library(name: "DevicesFeature", targets: ["DevicesFeature"]),
        .library(name: "EventLogFeature", targets: ["EventLogFeature"]),
        .library(name: "GameDatabase", targets: ["GameDatabase"]),
        .library(name: "GameModels", targets: ["GameModels"]),
        .library(name: "GameServices", targets: ["GameServices"]),
        .library(name: "GameSession", targets: ["GameSession"]),
        .library(name: "GameSync", targets: ["GameSync"]),
        .library(name: "LocationEventsFeature", targets: ["LocationEventsFeature"]),
        .library(name: "LocationsFeature", targets: ["LocationsFeature"]),
        .library(name: "LoginFeature", targets: ["LoginFeature"]),
        .library(name: "MessagesFeature", targets: ["MessagesFeature"]),
        .library(name: "NewStarMapFeature", targets: ["NewStarMapFeature", "CStarMapShaderTypes"]),
        .library(name: "PrintingUI", targets: ["PrintingUI"]),
        .library(name: "PrintQueueFeature", targets: ["PrintQueueFeature"]),
        .library(name: "RawAPIFeature", targets: ["RawAPIFeature"]),
        .library(name: "ReplicantsFeature", targets: ["ReplicantsFeature"]),
        .library(name: "SidebarFeature", targets: ["SidebarFeature"]),
        .library(name: "TravelUI", targets: ["TravelUI"]),
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
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.0"),
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.8.2"),
        .package(url: "https://github.com/siteline/swiftui-introspect", exact: "26.0.1"),
    ],
    targets: [
        .target(
            name: "AccountFeature",
            dependencies: [
                "AccountManager",
                "API",
                "GameModels",
                "GameSession",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "AccountFeature/Sources"
        ),
        .testTarget(
            name: "AccountFeatureTests",
            dependencies: [
                "AccountFeature",
                "GameDatabase",
                "GameModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "AccountFeature/Tests"
        ),
        .target(
            name: "AccountManager",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "SQLiteData", package: "sqlite-data"),
                "API",
                "GameModels",
                "GameSession",
            ],
            path: "AccountManager/Sources"
        ),
        .testTarget(
            name: "AccountManagerTests",
            dependencies: [
                "AccountManager",
                "API",
                "GameDatabase",
                "GameModels",
                "GameSession",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "Sharing", package: "swift-sharing"),
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
                "GameDatabase",
                "GameModels",
                "GameSession",
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
                "GameDatabase",
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
                "TravelUI",
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
                "GameDatabase",
                "GameModels",
                "GameServices",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "DevicesFeature/Tests"
        ),
        .target(
            name: "EventLogFeature",
            dependencies: [
                "GameModels",
                "UI",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "EventLogFeature/Sources"
        ),
        .testTarget(
            name: "EventLogFeatureTests",
            dependencies: [
                "EventLogFeature",
                "API",
                "GameDatabase",
                "GameModels",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "EventLogFeature/Tests"
        ),
        .target(
            name: "GameDatabase",
            dependencies: [
                "GameModels",
                "UniverseModels",
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameDatabase/Sources"
        ),
        .testTarget(
            name: "GameDatabaseTests",
            dependencies: [
                "GameDatabase",
                "GameModels",
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameDatabase/Tests"
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
        .testTarget(
            name: "GameModelsTests",
            dependencies: [
                "API",
                "GameModels",
                "Utils",
            ],
            path: "GameModels/Tests"
        ),
        .target(
            name: "GameServices",
            dependencies: [
                "API",
                "GameModels",
                "GameSession",
                "UniverseModels",
                "Utils",
                .product(name: "SQLiteData", package: "sqlite-data"),
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            path: "GameServices/Sources",
        ),
        .testTarget(
            name: "GameServicesTests",
            dependencies: [
                "API",
                "GameDatabase",
                "GameModels",
                "GameServices",
                "GameSession",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameServices/Tests"
        ),
        // Session-tier module: the authenticated transport (`GameClient`) and
        // the Keychain-backed token store. Deliberately tiny — read-only
        // features that need nothing but an authenticated client depend on
        // this instead of the engine-heavy `GameServices`, so engine edits
        // don't rebuild them.
        .target(
            name: "GameSession",
            dependencies: [
                "API",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            path: "GameSession/Sources"
        ),
        .target(
            name: "GameSync",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                "GameSession",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameSync/Sources"
        ),
        .testTarget(
            name: "GameSyncTests",
            dependencies: [
                "API",
                "GameDatabase",
                "GameModels",
                "GameServices",
                "GameSession",
                "GameSync",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "GameSync/Tests"
        ),
        .target(
            name: "LocationEventsFeature",
            dependencies: [
                "GameModels",
                "GameServices",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "LocationEventsFeature/Sources"
        ),
        .testTarget(
            name: "LocationEventsFeatureTests",
            dependencies: [
                "API",
                "GameModels",
                "GameServices",
                "LocationEventsFeature",
                "Utils",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "LocationEventsFeature/Tests"
        ),
        .target(
            name: "LocationsFeature",
            dependencies: [
                "GameModels",
                "GameServices",
                "TravelUI",
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
                "GameDatabase",
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
                "GameDatabase",
                "GameModels",
                "GameServices",
                "GameSession",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "MessagesFeature/Sources"
        ),
        .testTarget(
            name: "MessagesFeatureTests",
            dependencies: [
                "API",
                "GameDatabase",
                "GameModels",
                "GameServices",
                "MessagesFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            path: "MessagesFeature/Tests"
        ),
        // The Metal reimplementation of the star map (ported from the standalone
        // prototype). `CStarMapShaderTypes` is the shared CPU<->GPU struct header
        // (single source of truth), imported by Swift and #included by the
        // bundled Shaders.metal. Default MainActor isolation matches the
        // prototype's build environment (SWIFT_DEFAULT_ACTOR_ISOLATION).
        .target(
            name: "CStarMapShaderTypes",
            path: "NewStarMapFeature/CShaderTypes"
        ),
        .target(
            name: "NewStarMapFeature",
            dependencies: [
                "CStarMapShaderTypes",
                "GameModels",
                "GameServices",
                "TravelUI",
                "UI",
                "UniverseModels",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "NewStarMapFeature/Sources",
            // ShaderCommon.h is #included by the .metal files (not compiled on its
            // own), so exclude it from the target's file list.
            exclude: ["ShaderCommon.h"],
            resources: [
                // Compiled into the target's default.metallib, loaded at runtime
                // via `device.makeDefaultLibrary(bundle: .module)`. Split from the
                // former monolithic Shaders.metal; shared helpers live in ShaderCommon.h.
                .process("StarField.metal"),
                .process("Orrery.metal"),
                .process("Overlays.metal"),
                .process("Tonemap.metal"),
            ]
        ),
        .testTarget(
            name: "NewStarMapFeatureTests",
            dependencies: [
                "GameModels",
                "GameServices",
                "NewStarMapFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
            path: "NewStarMapFeature/Tests"
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
                "GameDatabase",
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
                "AccountManager",
                "GameModels",
                "GameServices",
                "UI",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "ReplicantsFeature/Sources"
        ),
        .testTarget(
            name: "ReplicantsFeatureTests",
            dependencies: [
                "GameDatabase",
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
                "GameDatabase",
                "GameModels",
                "GameServices",
                "SidebarFeature",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "SidebarFeature/Tests"
        ),
        .target(
            name: "TravelUI",
            dependencies: [
                "GameModels",
                "UI",
            ],
            path: "TravelUI/Sources"
        ),
        .target(
            name: "UI",
            dependencies: [
                "Utils",
            ],
            path: "UI/Sources",
            resources: [
                .process("Colors.xcassets"),
                .process("Symbols.xcassets"),
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
                "GameModels",
                "Utils",
                .product(name: "SQLiteData", package: "sqlite-data"),
            ],
            path: "UniverseModels/Sources"
        ),
        .testTarget(
            name: "UniverseModelsTests",
            dependencies: [
                "API",
                "UniverseModels",
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
