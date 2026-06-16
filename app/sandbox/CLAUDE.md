# CLAUDE.md — Replicant macOS app

> Drop this file at your repository root. Claude Code reads it automatically and
> will follow it on every session.

## What this app is
A native **macOS** control surface for a self‑replicating probe (a "replicant")
that prints and deploys devices across nearby star systems. Three‑pane layout:
**Sidebar · List · Inspector**.

## Design source of truth
- **`DESIGN_SPEC.md`** — full UI spec (layout, components, behaviors, domain model). Read this first.
- **`ReplicantDesignSystem.swift`** — color tokens (`Color.rc*`), status taxonomy (`DeviceStatus.tone(for:)`), `HostKind`, spacing/radius/type, `StatusBadge`.
- **`ReplicantColors.xcassets`** — dynamic light/dark colors. Reference by name; do not hard‑code hex.
- **HTML mockups** (`Replicant Dashboard.html`, `Sidebar Explorations.html`) — the visual reference. Open/read them for exact layout.

## Rules
- **Never hard‑code colors, spacing, or font sizes.** Use the tokens in `ReplicantDesignSystem.swift` (`.rcTextPrimary`, `Space.m`, `Radius.card`, `Font.rcTitle`, etc.). If a needed token is missing, add it to the design system + asset catalog rather than inlining a value.
- Map backend status strings through `DeviceStatus.tone(for:)` — don't invent per‑status colors.
- Dark‑first, but every screen must read correctly in light mode (the catalog handles both; verify with `.preferredColorScheme`).
- Prefer `NavigationSplitView`, system materials for chrome, SF for text, SF Mono for IDs/codes/readouts.
- Commands are **parameterized**: surface an input affordance (destination combobox, resource chips, or confirm) before firing — never a bare destructive action.
- Keep data‑model names aligned with the backend payload (`device_code`, `device_type`, `replicant_code`, `available_commands`, `operational_capacity`, `status`).

## Don't
- Don't introduce new accent colors or gradients beyond the token set.
- Don't add decorative imagery; this UI is data‑viz forward (gauges, dots, bars).
- Don't represent a replicant without its host icon (vessel / matrix / hub).
