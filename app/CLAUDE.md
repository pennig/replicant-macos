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

### Backend access

- **Use the generated OpenAPI client for all backend calls.** The `API` module generates a `Client` from `openapi.json` at build time (swift-openapi-generator, `accessModifier: public`), wired with bearer auth + rate limiting + logging middleware.
- **Get the client from the shared `@Dependency(\.gameClient)`, not by building one yourself.** `GameClient` (in `DependencyClients`) vends a `Client` authenticated with the stored session token (read live from the Keychain) over a process-shared rate-limit governor — so the session token lives in exactly one place and is never threaded through feature state or call sites. A feature's domain client (e.g. `MessagesClient`, `StarsClient`) resolves `@Dependency(\.gameClient)` in its `liveValue`, calls generated operations on `gameClient()`, and maps the generated `Components.Schemas.*` types to the feature's own value types. Such features depend on both the `API` and `DependencyClients` products. See `Modules/API/Sources/Event Log/GameLogFetching.swift` for the operation-call pattern (`extension Client { … try output.ok.body.json … }`), and `MessagesClient`/`StarsClient` for feature-side usage.
  - Do **not** pass the API key into feature state or client methods. (`ReplicantSpace.client(apiKey:)` exists, but the only direct caller should be `GameClient`.)
  - Generated operation method names come from the path (no operationIds), e.g. `getV1Messages`, `getV1ReplicantsReplicantCodeStars`. Generated property names are idiomatic camelCase (`per_page` → `perPage`); treat generated schema properties as optional and coalesce.
  - When an endpoint is paged, resolve `gameClient()` **once** and reuse that client across the whole walk. (The governor is process-shared via `GameClient`, but reusing one client per walk is still the clean shape — see `StarsClient.survey`.)
- **The one exception is `RawAPIFeature`**, which is a power-user raw HTTP console: it intentionally uses its own `URLSession` so it can send arbitrary requests. Do not route it through the generated client.
- **Do not hand-roll `URLSession` calls in other features** for endpoints the spec already covers.
- **To see what an endpoint actually returns, probe the live API** with the `replicant raw <METHOD> <path>` CLI before trusting `openapi.json` (which lags the server). Paths are base-relative (`devices/ABCD1234`, not `v1/...`). Use the **`probe-api`** skill — it covers the path convention, output format, the openapi-drift workflow, and the rule that GET is safe while POST/PATCH/DELETE mutate the one live account and must be announced first.

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

### 3. Verify the package resolves

    swift package resolve

If it errors, check that the path: values in Package.swift match the directories created in step 1, and that all dependency names exactly match existing targets.

### Notes
- `swift-composable-architecture` is already declared as a package dependency — do not add it again.
- `UI` is an existing target in this package — reference it by string name only, not as a package product.
- If NAME/Sources or NAME/Tests already exist, skip mkdir and go straight to the Package.swift edits.
