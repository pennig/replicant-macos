# Replicant — Design Spec

A reference for building the **Replicant** macOS app (a control surface for a
self‑replicating probe — a "replicant" — that prints and deploys devices across
nearby star systems). This document is written to be read by a coding agent or a
developer. The visual source of truth is the HTML mockups in this project
(`Replicant Dashboard.html`, `Sidebar Explorations.html`); colors are codified in
`ReplicantColors.xcassets` and `ReplicantDesignSystem.swift`.

---

## 1. Platform & character

- **Native macOS**, dark‑first but fully light/dark dynamic (asset catalog carries both).
- Three‑pane layout: **Sidebar** · **List** · **Inspector** (a `NavigationSplitView` is the natural fit).
- Aesthetic: "dark cosmic glass" — deep space backgrounds, subtle nebula glows, **amber** accent, data‑viz forward (gauges, status dots, progress bars), minimal imagery.
- Typography: **system font (SF)** for UI, **SF Mono** for IDs / codes / numeric readouts.

## 2. Color tokens

Use the named colors from `ReplicantColors.xcassets` (see `Color.rc*` in
`ReplicantDesignSystem.swift`). Never hard‑code hex in views.

| Token | Role | Dark | Light |
|---|---|---|---|
| `WindowBackground` | window base | `#0B1019` | `#F1ECE3` |
| `ContentBackground` | inspector / main pane | `#0A1019` | `#F9F5EE` |
| `SidebarBackground` | source list | `#0E1421` | `#ECE6DC` |
| `SurfaceRaised` | cards / panels | `#12161F` | `#F2EEE7` |
| `SurfaceRaisedStrong` | buttons / chips | `#171C26` | `#ECE7DE` |
| `Separator` / `SeparatorSoft` | hairlines (alpha) | white 9% / 5.5% | ink 12% / 7% |
| `TextPrimary/Secondary/Tertiary` | text ramp | `#E9EEF7` / `#9AA6BC` / `#697488` | `#1B2230` / `#5A6478` / `#929BAD` |
| `AccentPrimary` | selection, primary action | `#FFB23E` | `#CF8418` |
| `AccentOnColor` | text on accent fills | `#2A1A05` | `#FFFFFF` |
| `AccentMuted` / `AccentBorder` | selection bg / hairline | amber 12% / 34% | amber 13% / 45% |
| `NPCAccent` | NPC indicator | `#B58BFF` | `#7B4FD6` |
| `Danger` / `DangerMuted` | destructive | `#E58A83` | `#BB463C` |

**Status taxonomy** — each device/replicant status maps to a *tone*; the tone has a color. Use `DeviceStatus.tone(for:)`.

| Tone | Color token | Statuses |
|---|---|---|
| ready | `StatusReady` (green) | idle |
| working | `StatusWorking` (amber) | mining, printing, repairing, diverting, collecting, depositing |
| transit | `StatusTransit` (blue) | travelling, cruising, surging, recalling |
| sensing | `StatusSensing` (cyan) | prospecting, scanning, tracking, monitoring, patrolling, coordinating |
| relay | `StatusRelay` (violet) | relaying |
| waiting | `StatusWaiting` (gold) | recall_waiting, waiting_for_surge_plate, waiting_for_resources |
| offline | `StatusOffline` (gray) | stowed, inactive, decommissioning |

## 3. Spacing / radius / type

- **Spacing** 4 · 8 · 12 · 16 · 24 (`Space.xs…xl`).
- **Radius** controls 8, cards 12, pills full (`Radius.*`). Window corners are the OS's.
- **Type** (`Font.rc*`): Title 20/bold · Headline 15/semibold · Body 13 · Caption 11 · Section label 11/bold UPPERCASE + tracking · Mono 12 (IDs).
- Selected list rows carry a **3pt amber left bar** + `AccentMuted` fill + `AccentBorder` hairline.

## 4. Domain model (from the backend)

```jsonc
// device
{ "device_code": "B58FCC78", "device_type": "mining_drone",
  "replicant_code": "30B93F2F", "location": "TARAZEDAR-BELT-1",
  "features": ["cruise","mine","stow"],
  "available_commands": ["change_owner","deactivate","decommission","deploy",
                         "recall","retarget","start_mining","stow","travel"],
  "operational_capacity": 67.0, "status": "mining (iron)" }
```

- **Replicant** lives inside exactly one **host**: `vessel` (spacecraft, can travel), `matrix` (container, immobile), `hub` (claims a system). The header/switcher icon reflects the host (`HostKind`). A replicant has **experience (XP), no levels**, a **Plan** (editable), and may be flagged **NPC** (read‑only badge; edited elsewhere).
- **Account** (the human operator) is distinct from replicants: name, email, total XP, replicants owned.

## 5. Screen anatomy

### Sidebar (settled — see `Sidebar Explorations.html` → V4)
1. **Active‑replicant picker** — titled ("ACTIVE REPLICANT") bounded box: host icon · name · subtitle `"<HostLabel> · [NPC icon]"` · chevron → opens a switcher listing all replicants (host icon, status, NPC, device count) + "Commission new replicant".
2. Below the box (compact): **travel/idle status** (traveling → progress bar + time remaining + destination; idle → location); meta line `"<xp> XP · <n> dev"` + **Show in Replicants ↗**; **Plan** (inline‑editable one‑liner).
3. **Nav**, sectioned: **Catalog** (Stars, Devices, Replicants, Blueprints) · **Operations** (Print Queue, Signals[soon]) · **Comms** (Messages[unread badge], Bobnet[live dot], Event Log). Scrolls.
4. **Account chip** (footer): key glyph + "LOGGED IN" · name/email · **bold accent** XP + replicant count (gray labels) · right‑aligned chevron.

### List (Devices example)
Header (title + count + "n deployed" + filter + All/Active). Rows: host/type glyph tile · type name + mono code · status dot+label · location · capacity % + mini bar. Selected = amber left bar.

### Inspector (a selected device)
Header (glyph tile, type name, status pill, code · location, ⋯). Readouts row: **operational‑capacity ring** (+ integrity/signal) and **active‑task** card (label, progress bar, rate/cargo/ETA). **Details** + **Position** (orbital mini‑map) row. **Commands**: grid of available commands; clicking a command that needs parameters reveals an inline panel — destination **combobox** (Travel/Retarget/Recall), resource **chips** (Start mining), dropdown (Stow/Change owner), or confirm‑with‑warning (Deactivate/Decommission). Advanced/destructive commands separated.

## 6. Key behaviors

- Selecting a list item populates the inspector.
- Commands are **parameterized** — never fire destination/resource commands without an input affordance + confirm.
- Travel shows **live progress + time remaining**; only `vessel` hosts can travel.
- Plan is editable inline; NPC is a read‑only badge in this surface.

## 7. What is intentionally invented (replace with real values)

Operator identity (K. Pennig / kell@pennig.name), replicant roster beyond the API sample, XP numbers, integrity/signal, blueprint/star counts, device roster. The *structure* is real; the *data* is placeholder.
