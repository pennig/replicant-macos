# Replicant — Xcode bootstrap kit

Everything here is meant to be copied into your macOS app project. It turns the
HTML design exploration into things Xcode (and a coding agent) can build against.

```
xcode/
├─ ReplicantColors.xcassets/     ← 24 dynamic light/dark color sets
├─ ReplicantAppIcon.appiconset/  ← macOS App Icon set (Bloom mark)
├─ ReplicantDesignSystem.swift   ← Color tokens, status taxonomy, hosts, type/spacing, StatusBadge
├─ ReplicantControls.swift       ← Button styles (RCButtonStyle) + text fields (RCField) + gallery
├─ Swatches.swift                ← living style guide (all tokens, light + dark)
├─ ReplicantSplitView.swift      ← NavigationSplitView scaffold (sidebar · list · inspector)
├─ FirstLaunchView.swift         ← first-launch / sign-in screen (animated Bloom background)
├─ DESIGN_SPEC.md                ← agent-/developer-readable spec of the whole UI
├─ CLAUDE.md                     ← drop at your repo root so coding agents auto-orient
└─ README.md                     ← this file
```

> **`FirstLaunchView.swift`** is a self-contained port of the Bloom launch
> screen — the live radiating-ring field (`TimelineView`+`Canvas`), the Bloom
> mark logo, seeded starfield, violet gradient + nebula + veil, and the Log in /
> Create account forms. macOS 12+. Host it in a hidden-title-bar window for the
> full-bleed look; ring parameters live in `RingTweaks` (defaults match the
> values you dialed in). No assets needed.

## 1. Install the colors

1. Drag **`ReplicantColors.xcassets`** into your app target (or merge its
   `*.colorset` folders into an existing `Assets.xcassets`). Asset catalogs are
   just folders — Xcode picks them up immediately.
2. Add **`ReplicantDesignSystem.swift`** to the target.
3. Use the tokens — they resolve light/dark automatically:

```swift
import SwiftUI

struct DeviceRow: View {
    let device: Device
    var body: some View {
        HStack(spacing: 12) {
            Text(device.typeName).font(.rcBodyEmph).foregroundStyle(.rcTextPrimary)
            Text(device.code).font(.rcMonoSmall).foregroundStyle(.rcTextTertiary)
            Spacer()
            StatusBadge(device.status, parameter: device.resource) // ● Mining · Iron
        }
        .padding(.horizontal, Space.m).padding(.vertical, Space.s)
        .background(.rcSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.control))
    }
}
```

Status colors come straight from the taxonomy:

```swift
let tone = DeviceStatus.tone(for: "mining") // .working
Circle().fill(tone.color)
```

> Catalog colors carry their own light **and** dark values, so you rarely need
> to read `@Environment(\.colorScheme)`. To preview both, set
> `.preferredColorScheme(.dark)` / `.light` on your `#Preview`.
>
> Mixing AppKit? Every token is also reachable as `NSColor(named: "AccentPrimary")`.

## 2. Build order suggestion

1. `NavigationSplitView` shell → sidebar / list / inspector (§5 of the spec).
2. Sidebar V4 (the settled one) — picker, status, Plan, nav, account chip.
3. Devices list + selection → Inspector.
4. Parameterized command panel (combobox / chips / confirm).
5. Swap placeholder data for your API models.

## 2½. App icon

`ReplicantAppIcon.appiconset/` is a ready-to-use macOS App Icon set (Bloom mark —
the device cube replicating into the FTL-relay rings). Drag it into
`Assets.xcassets` (or set it as your target's App Icon source). It carries all
macOS slots: 16, 32, 128, 256, 512 pt at @1x/@2x. The vector master lives at the
project root as **`Replicant Icon.svg`** (1024² **`Replicant Icon 1024.png`** too),
regenerate any size from the SVG.

> Corners are transparent (the squircle is baked in). This is a full-bleed mark;
> if you prefer the classic macOS inset look (icon floating with margin + shadow),
> add ~10% padding around the SVG before rasterizing — say the word and I'll bake
> an inset variant.

## 3. Referencing this design from a Claude agent in Xcode

Short answer: **yes** — the reliable way is to put these files *in your repo* and
let the agent read them. Agents work from files, not from a live design tool, so
the spec + tokens + mockups are exactly what they need.

Concretely:

- **Keep `DESIGN_SPEC.md`, `ReplicantDesignSystem.swift`, and the `.xcassets` in
  the repo.** They're the contract. Point the agent at `DESIGN_SPEC.md` first
  ("implement the Sidebar from DESIGN_SPEC.md §5 using the tokens in
  ReplicantDesignSystem.swift").
- **Drop `CLAUDE.md` at the repo root.** Claude Code (the terminal/agent that
  works inside a repo) reads it automatically on every session and will orient
  itself to the design without you re‑explaining each time.
- **Bring the HTML mockups along** (`Replicant Dashboard.html`,
  `Sidebar Explorations.html`). They're self‑contained — an agent can open/read
  them for exact layout, and *you* can open them in a browser as the visual
  reference while reviewing the agent's output.
- **Screenshots help** for any pixel question — open a mockup, grab the region,
  paste it into the conversation.

Whatever Claude integration you use inside Xcode, the same principle holds: it can
only "see" the design through files in the project. These files are built to be
that bridge. (I can also generate a single‑file bundle of either mockup, or a
flat token JSON, if your toolchain prefers one artifact — just ask.)

## 4. Things I can generate next (just ask)

- An **SF Symbols** set or a custom‑symbol template for the device/host glyphs
  (so the schematic look survives natively).
- An **inset** App Icon variant (margin + baked shadow) if you want the classic
  macOS look instead of full‑bleed.
- **Spacing/type** as a flat `design-tokens.json` if you want a single source.
