# CLAUDE.md — Replicould macOS app

## What this app is
A native **macOS** interface for Replicant Space, a Von Neumann probe exploration game which is run as an API-only service found at https://replicant.space
An instance of the self-replicating probe is called a Replicant (so the app name is a play on words).
It's intended to be a fully-featured real-time interface for the game, with a compelling UX to engage with the API surface area, along with a direct API access feature for power users.
It primarily exists through a three-panel split view interface, though certain things such as the Stars view and Event Log will only have the sidebar and content (no third detail pane).

## Engineering notes (memory)
Accumulated, hard-won notes about this codebase — feature summaries, API/spec-drift findings, and non-obvious gotchas — live under `.claude/memory/` as one fact per file. The index below is loaded automatically; open the linked file when a note looks relevant, and add/update notes there (with a matching index line) as you learn things.
@.claude/memory/MEMORY.md

## Design source of truth
Look in the `Modules/UI` folder for the Swift package that represents the design source of truth.
- **`DESIGN_SPEC.md`** — full UI spec (layout, components, behaviors, domain model). Read this first.
- **`DesignSystem.swift`** — color tokens (`Color.rc*`), status taxonomy (`DeviceStatus.tone(for:)`), `HostKind`, spacing/radius/type, `StatusBadge`.
- **`Colors.xcassets`** — dynamic light/dark colors. Reference by name; do not hard‑code hex.
- **`Controls.swift`** — the collection of shared controls to be used across the app.

## Rules
- Abide by Point-Free's patterns and guidance whenever possible. Refer to the pfw-\* skills for more information.
- Never hard‑code colors, spacing, or font sizes.** Use the tokens in `DesignSystem.swift` (`.rcTextPrimary`, `Space.m`, `Radius.card`, `Font.rcTitle`, etc.). If a needed token is missing, add it to the design system + asset catalog rather than inlining a value.
- Map backend status strings through `DeviceStatus.tone(for:)` — don't invent per‑status colors.
- Dark‑first, but every screen must read correctly in light mode (the catalog handles both; verify with `.preferredColorScheme`).
- Prefer `NavigationSplitView`, system materials for chrome, SF for text, SF Mono for IDs/codes/readouts.
- **Always render system names and location names (e.g. SOL, SOL-3, SOL-3-1, etc) in monospace.** A system/location name is a designation code, so anywhere one is displayed — map labels/dossiers, list rows, headers — use a monospaced font token (`.rcMono`, `.rcMonoSmall`, or the prominence-matched `.rcTitleMono` / `.rcHeadlineMono` / `.rcBodyEmphMono`). Add a new mono token to `DesignSystem.swift` if you need a size/weight that doesn't exist yet rather than inlining `design: .monospaced`.
- Keep data‑model names aligned with the backend payload (`device_code`, `device_type`, `replicant_code`, `available_commands`, `operational_capacity`, `status`).

## Don't
- Don't introduce new accent colors or gradients beyond the token set.
- Don't add decorative imagery; this UI is data‑viz forward (gauges, dots, bars).
- Don't represent a replicant without its host icon (vessel / matrix / hub).

## Documentation

The backend API service has copious documentation:
- The API Docs site itself: https://replicant.space/docs/ It describes how the game works, the various core concepts, as well as the main classes of endpoints (accounts, devices, etc). If there's ever a question about a business rule, consult the docs first.
- The OpenAPI spec: https://api.replicant.space/swagger/openapi.json. It does a great job of documenting the full capabilities and surface area of the API. We've already run into a few issues though, so this doc seems to be hand-maintained and carries with it mismatches between spec and implementation. Use caution.

The docs website seems to be updated more diligently to match the real implementation, so if there's ever a mismatch between expectation and reality, check the docs site to see if that mismatch can be resolved without further debugging.

---
## Review and Code Comprehension Protocols
All agents and reviewing subagents must utilize Swift-LSP (SourceKit-LSP) to analyze code changes. Before signing off on any code:
1. Query the Swift-LSP language server (e.g., `goToDefinition`, `findReferences`) for syntax, type correctness, and unresolved references.
2. Cross-reference usage by checking symbol references.
3. Treat LSP output as the single source of truth over simple text matching.
---

## Implementation Notes

- This app targets macOS 26 and newer, so feel free to use the latest SwiftUI and other SDK APIs.
- When engaging with the backend for implementation or for testing/mocks/previews, you may follow the aforementioned OpenAPI spec (regularly updated locally in the repository as well in the Modules/API/Sources/openapi.json)
- While the app is written predominantly in SwiftUI, it's acceptable to wrap AppKit views and behaviors when they're important to the UX.


### Backend access

- **Use the generated OpenAPI client for all backend calls.** The `API` module generates a `Client` from `openapi.json` at build time (swift-openapi-generator, `accessModifier: public`), wired with bearer auth + rate limiting + logging middleware.
- **Get the client from the shared `@Dependency(\.gameClient)`, not by building one yourself.** `GameClient` (in `GameSession`) vends a `Client` authenticated with the stored session token (read live from the Keychain) over a process-shared rate-limit governor — so the session token lives in exactly one place and is never threaded through feature state or call sites. A feature's domain client (e.g. `MessagesClient`, `StarsClient`) resolves `@Dependency(\.gameClient)` in its `liveValue`, calls generated operations on `gameClient()`, and maps the generated `Components.Schemas.*` types to the feature's own value types. Such features depend on the `API` and `GameSession` products (add `GameServices` only when the feature also needs engine services — the reconciler, the poll coordinator, domain freshness, or another domain client that lives there). See `Modules/API/Sources/Event Log/GameLogFetching.swift` for the operation-call pattern (`extension Client { … try output.ok.body.json … }`), and `MessagesClient`/`StarsClient` for feature-side usage.
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
- **TCA is for feature modules only, by manifest.** The template's `ComposableArchitecture` product is for feature targets; a non-feature module (a service, client, or models tier) declares `.product(name: "Dependencies", package: "swift-dependencies")` instead (plus `Sharing`/`SQLiteData` as needed) — see `GameSession`/`GameServices`/`GameSync`/`AccountManager`.
- `UI` is an existing target in this package — reference it by string name only, not as a package product.
- If NAME/Sources or NAME/Tests already exist, skip mkdir and go straight to the Package.swift edits.
