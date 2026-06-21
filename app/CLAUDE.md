# CLAUDE.md — Replicould macOS app

## What this app is
A native **macOS** interface for Replicant Space, a Von Neumann probe exploration game which is run as an API-only service found at https://replicant.space
An instance of the self-replicating probe is called a Replicant (so the app name is a play on words).
It's intended to be a fully-featured real-time interface for the game, with a compelling UX to engage with the API surface area, along with a direct API access feature for power users.
It primarily exists through a three-panel split view interface, though certain things such as the Stars view and Event Log will only have the sidebar and content (no third detail pane).

## Design source of truth
Look in the `Modules/UI` folder for the Swift package that represents the design source of truth.
- **`DESIGN_SPEC.md`** — full UI spec (layout, components, behaviors, domain model). Read this first.
- **`DesignSystem.swift`** — color tokens (`Color.rc*`), status taxonomy (`DeviceStatus.tone(for:)`), `HostKind`, spacing/radius/type, `StatusBadge`.
- **`Colors.xcassets`** — dynamic light/dark colors. Reference by name; do not hard‑code hex.
- **`Controls.swift`** — the collection of shared controls to be used across the app.

## Rules
- **Never hard‑code colors, spacing, or font sizes.** Use the tokens in `DesignSystem.swift` (`.rcTextPrimary`, `Space.m`, `Radius.card`, `Font.rcTitle`, etc.). If a needed token is missing, add it to the design system + asset catalog rather than inlining a value.
- Map backend status strings through `DeviceStatus.tone(for:)` — don't invent per‑status colors.
- Dark‑first, but every screen must read correctly in light mode (the catalog handles both; verify with `.preferredColorScheme`).
- Prefer `NavigationSplitView`, system materials for chrome, SF for text, SF Mono for IDs/codes/readouts.
- Keep data‑model names aligned with the backend payload (`device_code`, `device_type`, `replicant_code`, `available_commands`, `operational_capacity`, `status`).

## Don't
- Don't introduce new accent colors or gradients beyond the token set.
- Don't add decorative imagery; this UI is data‑viz forward (gauges, dots, bars).
- Don't represent a replicant without its host icon (vessel / matrix / hub).

---

## Implementation Notes

- This app targets macOS 26 and newer, so feel free to use the latest SwiftUI and other SDK APIs.
- When engaging with the backend for implementation or for testing/mocks/previews, you may follow the OpenAPI spec found here: https://api.replicant.space/swagger/openapi.json (last fetched June 21, 2026)
- While the app is written predominantly in SwiftUI, it's acceptable to wrap AppKit views and behaviors when they're important to the UX.

---

## Adding a new SPM module

When asked to add a new module, feature target, or library to this package, follow these steps exactly. The requested module name is referred to as NAME below — preserve the casing provided.

### 1. Create directory structure

    mkdir -p "NAME/Sources"
    mkdir -p "NAME/Tests"

Create a minimal placeholder if needed to satisfy SPM's non-empty target requirement:

    // NAME.swift (or NAMETests.swift)
    // This file intentionally left minimal.

### 2. Edit Package.swift (three edits)

Append to the products array:

    .library(
        name: "NAME",
        targets: ["NAME"]
    ),

Append the source target to the targets array:

    .target(
        name: "NAME",
        dependencies: [
            .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            "UI",
        ],
        path: "NAME/Sources"
    ),

Append the test target to the targets array:

    .testTarget(
        name: "NAMETests",
        dependencies: ["NAME"],
        path: "NAME/Tests"
    ),

Insert in alphabetical order (case-insensitive) and preserve existing formatting and trailing commas. Do not reorder unrelated targets.

### 3. Wire into the Xcode project

If you have a skill or the Xcode MCP allows you to do this step, leverage that. Otherwise, follow these steps to perform the update manually.

Locate the .pbxproj:

    find . -name "*.xcodeproj" -maxdepth 2

Generate two 24-character UUIDs (UUID_A for the product dependency, UUID_B for the build file):

    uuidgen | tr -d '-' | cut -c1-24
    uuidgen | tr -d '-' | cut -c1-24

Add to XCSwiftPackageProductDependency:

    UUID_A /* NAME */ = {
        isa = XCSwiftPackageProductDependency;
        productName = NAME;
    };

Add to PBXBuildFile:

    UUID_B /* NAME in Frameworks */ = {
        isa = PBXBuildFile;
        productRef = UUID_A /* NAME */;
    };

Add to the app target's PBXFrameworksBuildPhase files array:

    UUID_B /* NAME in Frameworks */,

Add to the app target's PBXNativeTarget packageProductDependencies array:

    UUID_A /* NAME */,

Verify with:

    grep -c "NAME" *.xcodeproj/project.pbxproj   # expect 4 or more occurrences

### 4. Verify the package resolves

    swift package resolve

If it errors, check that the path: values in Package.swift match the directories created in step 1, and that all dependency names exactly match existing targets.

### Notes
- `swift-composable-architecture` is already declared as a package dependency — do not add it again.
- `UI` is an existing target in this package — reference it by string name only, not as a package product.
- If NAME/Sources or NAME/Tests already exist, skip mkdir and go straight to the Package.swift edits.
