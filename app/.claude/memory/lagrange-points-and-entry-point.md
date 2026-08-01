---
name: lagrange-points-and-entry-point
description: "Per-planet Lagrange sites are NOT returned by the system-level locations endpoint (Planet.lagrange is empty for normally-fetched systems); every planet has 5 Lagrange points by construction and every system's entry_point is itself an L4. This silently broke Salvage Run relay emplacement."
metadata:
  type: reference
---

**The system-level `GET locations/{system}` does NOT return per-planet Lagrange sites.** Its
`planets[]` objects carry no `lagrange` key at all, so `Planet.lagrange` (in `LocationModels`)
stays **empty** for every system fetched that way. The DTO/`LocationModels` machinery that
attaches a `.lagrange` `SpecialSite` to its parent planet only fires when a payload actually
delivers such a site — which this endpoint doesn't. (Confirmed live 2026-07-31 probing
`locations/ALZEPHINA` etc.)

**Two domain facts that make this a non-issue if you use them:**
- **Every planet in every system has five Lagrange points**, deterministically named
  `<planet>-L1 … <planet>-L5` (operator-confirmed). So a planet's L4 can be *synthesised* as
  `<planet.designation>-L4` without any fetch.
- **Every system's `entry_point` is itself an L4** — `<planet>-N-L4` (verified across 9 systems:
  TOSLIT-8-L4, ARCTURUSAN-6-L4, ABSOLUTN-1-L4, MENKENTAN-6-L4, POLARISUM-5-L4, AINALRAM-1-L4,
  ALZEPHINA-6-L4, ESELLUSAU-3-L4, SOL-5-L4). The app *does* decode it (`StarSystem.entryPoint`),
  and a bare-designation travel lands the vessel **on it** ([[travel-system-proxy-codes]]).

**What it broke (fixed 2026-07-31, commit 649f38c):** `SalvageRun.lagrangePoint(in:)` read
`system.planets.flatMap(\.lagrange)` → always nil → `emplace`'s `guard let point … else` skipped
relay deployment on every target. The Salvage Run had effectively **never planted a relay live** —
it mined every system unmeshed (so the Haul Run's freighter couldn't reach off-mesh systems). The
"9 relays → 10 of 13 systems" figure in [[salvage-run-design]] was a catalogue *measurement*, not
observed behaviour. Fix: `lagrangePoint` now returns `entryPoint` when it ends `-L4` (free — the
vessel is already there), else synthesises `<lowest planet designation>-L4`; only a planet-less
system is genuinely unemplaceable.
