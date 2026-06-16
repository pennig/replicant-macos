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
